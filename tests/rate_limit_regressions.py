#!/usr/bin/env python3
"""Loopback-only rate conversion, pacing, and cancellation regressions."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import unittest

TARGET = 'https://www.nicovideo.jp/user/1'
TINY_RATES = ('1e-10', '5e-324', '1.0842021724855044e-10')


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        with self.server.lock:
            self.server.requests.append(time.monotonic())
            first = len(self.server.requests) == 1
        # Omitting totalCount makes the next empty page necessary.
        items = [{'essential': {'id': 'sm1', 'registeredAt': '2024-01-01T00:00:00Z',
                                'count': {'comment': 1}}}] if first else []
        payload = json.dumps({'meta': {'status': 200}, 'data': {'items': items}}).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
        if first:
            self.server.first_response.set()
        else:
            self.server.second_request.set()


@contextlib.contextmanager
def fixture():
    server = Server(('127.0.0.1', 0), Handler)
    server.lock = threading.Lock()
    server.requests = []
    server.first_response = threading.Event()
    server.second_request = threading.Event()
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def start(binary, server, rate):
    env = {key: value for key, value in os.environ.items() if 'proxy' not in key.lower()}
    env['NICO_BASE_URL'] = f'http://127.0.0.1:{server.server_port}/v3'
    return subprocess.Popen([str(binary), '--no-progress', '-T1', '-P1', '-H1',
                             '--retries', '1', '--timeout', '100ms',
                             '--rate-limit', rate, TARGET],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def stop(proc):
    if proc.poll() is None:
        proc.kill()
    return proc.communicate(timeout=5)


class RateLimitTests(unittest.TestCase):
    binary = None

    def test_normal_rate_preserves_request_spacing(self):
        with fixture() as server:
            proc = start(self.binary, server, '5')
            try:
                stdout, stderr = proc.communicate(timeout=5)
            finally:
                stop(proc)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertEqual(stdout, 'sm1\n')
            self.assertEqual(len(server.requests), 2, stderr)
            self.assertGreaterEqual(server.requests[1] - server.requests[0], .15)

    def test_tiny_and_boundary_rates_keep_second_request_waiting(self):
        for rate in TINY_RATES:
            with self.subTest(rate=rate), fixture() as server:
                proc = start(self.binary, server, rate)
                try:
                    self.assertTrue(server.first_response.wait(5), 'first request was not sent')
                    # Waiting exceeds --timeout: pacing is not an HTTP attempt.
                    self.assertFalse(server.second_request.wait(.25), 'rate limiter sent another request')
                    self.assertIsNone(proc.poll(), 'rate wait must remain active')
                    self.assertEqual(len(server.requests), 1)
                finally:
                    stop(proc)

    @unittest.skipUnless(os.name == 'posix', 'POSIX graceful SIGINT contract')
    def test_saturated_rate_wait_is_cancelled_by_sigint(self):
        with fixture() as server:
            proc = start(self.binary, server, '5e-324')
            try:
                self.assertTrue(server.first_response.wait(5), 'first request was not sent')
                self.assertFalse(server.second_request.wait(.25))
                proc.send_signal(signal.SIGINT)
                stdout, stderr = proc.communicate(timeout=3)
            finally:
                stop(proc)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertEqual(stdout, '')
            self.assertEqual(len(server.requests), 1)
            self.assertIn('fetch_err=0', stderr)


def suite(binary):
    RateLimitTests.binary = Path(binary).resolve()
    return unittest.defaultTestLoader.loadTestsFromTestCase(RateLimitTests)


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(suite(sys.argv[1]))
    raise SystemExit(not result.wasSuccessful())
