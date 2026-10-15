#!/usr/bin/env python3
"""Loopback regressions for deadline/cancellation supervision during stdout backpressure."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import threading
import time
import unittest
import urllib.parse


TARGET = 'https://www.nicovideo.jp/user/1'
STALLED_TARGET = 'https://www.nicovideo.jp/user/2'
# Larger than subprocess pipe buffers on the supported native platforms. Long
# numeric suffixes also keep fixture parsing cheap relative to the output size.
IDS = [f'sm{i:064d}' for i in range(3600)]


def payload(ids):
    return json.dumps({'meta': {'status': 200}, 'data': {'items': [
        {'essential': {'id': value, 'registeredAt': '2024-01-01T00:00:00Z',
                       'count': {'comment': 1}}} for value in ids]}}).encode()


LARGE_BODY = payload(IDS + IDS[:2])
EMPTY_BODY = payload([])


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        server = self.server
        page = int(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['page'][0])
        if '/users/2/' in self.path:
            self.close_connection = True
            server.stalled_at = time.monotonic()
            server.stalled_started.set()
            self.connection.settimeout(6)
            try:
                if self.connection.recv(1) == b'':
                    server.closed_at = time.monotonic()
                    server.stalled_closed.set()
            except (ConnectionResetError, ConnectionAbortedError):
                server.closed_at = time.monotonic()
                server.stalled_closed.set()
            except socket.timeout:
                pass
            return
        if server.stall and page == 1:
            server.stalled_started.wait(3)
        body = LARGE_BODY if page == 1 else EMPTY_BODY
        try:
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            if page == 2:
                server.output_ready.set()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


@contextlib.contextmanager
def fixture(stall=True):
    server = Server(('127.0.0.1', 0), Handler)
    server.stall = stall
    server.stalled_started = threading.Event()
    server.stalled_closed = threading.Event()
    server.output_ready = threading.Event()
    server.stalled_at = server.closed_at = None
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class OutputBackpressureTests(unittest.TestCase):
    binary = None

    def start(self, server, timeout='800ms', *extra, buffered=False):
        env = dict(os.environ, NICO_BASE_URL=f'http://127.0.0.1:{server.server_port}/v3')
        targets = [TARGET, STALLED_TARGET] if server.stall else [TARGET]
        output_options = [] if buffered else ['--no-sort']
        return subprocess.Popen([str(self.binary), '--no-progress', *output_options,
                                 '-T2', '-P1', '-H2', '--retries', '1', '--timeout', timeout,
                                 *extra, *targets], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)

    def wait_for_output(self, proc, server):
        self.assertTrue(server.output_ready.wait(3), 'successful target did not finish')
        # Nothing reads stdout until the supervision assertion is captured.
        time.sleep(.1)
        self.assertIsNone(proc.poll(), 'large output should be backpressured')

    def cleanup(self, proc):
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=3)

    def test_original_deadline_closes_socket_before_stdout_is_drained(self):
        with fixture() as server:
            proc = self.start(server)
            try:
                self.wait_for_output(proc, server)
                closed_before_drain = server.stalled_closed.wait(2)
                still_backpressured = proc.poll() is None
                stdout, stderr = proc.communicate(timeout=3)
            finally:
                self.cleanup(proc)
            self.assertTrue(closed_before_drain, 'HTTP deadline waited for stdout to drain')
            self.assertTrue(still_backpressured, 'the assertion must precede stdout drain')
            self.assertLess(server.closed_at - server.stalled_at, 1.8)
            self.assertEqual(proc.returncode, 1, stderr)
            self.assertEqual(stdout, ''.join(value + '\n' for value in IDS + IDS[:2]).encode())
            self.assertIn(b'"error":"Timeout"', stderr)
            self.assertIn(b'fetch_ok=1 fetch_err=1', stderr)

    @unittest.skipUnless(os.name == 'posix', 'POSIX graceful SIGINT test')
    def test_sigint_cancels_http_and_exits_without_stdout_drain(self):
        with fixture() as server:
            proc = self.start(server, '5s')
            try:
                self.wait_for_output(proc, server)
                proc.send_signal(signal.SIGINT)
                proc.wait(timeout=3)
                closed_before_drain = server.stalled_closed.wait(1)
                stdout, stderr = proc.communicate(timeout=3)
            finally:
                self.cleanup(proc)
            self.assertTrue(closed_before_drain)
            self.assertEqual(proc.returncode, 1, stderr)
            self.assertLess(len(stdout), sum(len(value) + 1 for value in IDS))
            self.assertIn(b'Error: WriteFailed', stderr)
            self.assertNotIn(b'"error":"Timeout"', stderr)

    def test_broken_pipe_cancels_pending_http(self):
        with fixture() as server:
            proc = self.start(server, '5s')
            try:
                self.wait_for_output(proc, server)
                proc.stdout.close()
                proc.stdout = None
                proc.wait(timeout=3)
                closed = server.stalled_closed.wait(1)
                _, stderr = proc.communicate(timeout=3)
            finally:
                self.cleanup(proc)
            self.assertTrue(closed)
            self.assertEqual(proc.returncode, 1, stderr)
            self.assertIn(b'Error: WriteFailed', stderr)

    @unittest.skipUnless(os.name == 'posix', 'POSIX graceful SIGINT test')
    def test_sigint_cancels_buffered_output_without_stdout_drain(self):
        for extra in ((), ('--json',)):
            with self.subTest(output=extra), fixture(stall=False) as server:
                proc = self.start(server, '3s', *extra, buffered=True)
                try:
                    self.wait_for_output(proc, server)
                    proc.send_signal(signal.SIGINT)
                    proc.wait(timeout=3)
                    stdout, stderr = proc.communicate(timeout=3)
                finally:
                    self.cleanup(proc)
                self.assertEqual(proc.returncode, 1, stderr)
                self.assertLess(len(stdout), sum(len(value) + 1 for value in IDS))
                self.assertIn(b'Error: WriteFailed', stderr)

    def test_buffered_output_broken_pipe_exits_with_write_failure(self):
        for extra in ((), ('--json',)):
            with self.subTest(output=extra), fixture(stall=False) as server:
                proc = self.start(server, '3s', *extra, buffered=True)
                try:
                    self.wait_for_output(proc, server)
                    proc.stdout.close()
                    proc.stdout = None
                    proc.wait(timeout=3)
                    _, stderr = proc.communicate(timeout=3)
                finally:
                    self.cleanup(proc)
                self.assertEqual(proc.returncode, 1, stderr)
                self.assertIn(b'Error: WriteFailed', stderr)

    def test_normal_output_keeps_all_data_and_dedupe_order(self):
        with fixture(stall=False) as server:
            proc = self.start(server, '3s', '--dedupe', '--url')
            try:
                stdout, stderr = proc.communicate(timeout=5)
            finally:
                self.cleanup(proc)
            self.assertEqual(proc.returncode, 0, stderr)
            expected = ''.join(f'https://www.nicovideo.jp/watch/{value}\n' for value in IDS)
            self.assertEqual(stdout, expected.encode())
            self.assertIn(b'fetch_ok=1 fetch_err=0 output_count=3600', stderr)


def suite(binary):
    class Configured(OutputBackpressureTests):
        pass
    Configured.binary = Path(binary).resolve()
    return unittest.defaultTestLoader.loadTestsFromTestCase(Configured)


if __name__ == '__main__':
    import sys
    result = unittest.TextTestRunner(verbosity=2).run(suite(sys.argv[1]))
    raise SystemExit(not result.wasSuccessful())
