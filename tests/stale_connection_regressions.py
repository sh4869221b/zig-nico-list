#!/usr/bin/env python3
"""Loopback-only stale keep-alive replay and deadline regressions."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import threading
import time
import unittest

TARGET = 'https://www.nicovideo.jp/user/1'


def payload(first):
    return json.dumps({'meta': {'status': 200}, 'data': {'items': [
        {'essential': {'id': 'sm1', 'registeredAt': '2024-01-01T00:00:00Z',
                       'count': {'comment': 1}}}] if first else []}}).encode()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def handle_error(self, *_):
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.connection_requests = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        server = self.server
        self.connection_requests += 1
        with server.lock:
            n = len(server.requests) + 1
            server.requests.append(self.client_address[1])
        mode = server.mode
        if mode == 'adaptive' and self.connection_requests == 2:
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if mode == 'fresh_eof' or n == 2 and mode in ('reused_eof', 'double_eof', 'partial', 'informational', 'replay_timeout') or n == 3 and mode in ('double_eof', 'redirect'):
            if mode == 'partial':
                self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Len')
                self.wfile.flush()
            elif mode == 'informational':
                self.wfile.write(b'HTTP/1.1 100 Continue\r\n\r\n')
                self.wfile.flush()
            elif mode == 'replay_timeout':
                time.sleep(.25)
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if n == 2 and mode == 'head_timeout' or n == 3 and mode == 'replay_timeout':
            server.release.wait(2)
        if n == 2 and mode == 'redirect':
            self.send_response(302)
            self.send_header('Content-Length', '0')
            self.send_header('Location', '/redirected')
            self.end_headers()
            return
        if n == 2 and mode in ('403', '429', '500'):
            self.send_response(int(mode))
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = payload(n == 1)
        if mode == 'adaptive':
            data = json.loads(payload(True))
            data['data']['totalCount'] = 1
            body = json.dumps(data).encode()
        try:
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            if mode == 'idle_reset' and n == 1:
                # Deliver RST while the client's pacing wait leaves this
                # previously successful socket idle in its pool.
                linger_format = 'HH' if os.name == 'nt' else 'ii'
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                           struct.pack(linger_format, 1, 0))
                self.close_connection = True
        except (BrokenPipeError, ConnectionResetError):
            pass


@contextlib.contextmanager
def fixture(mode):
    server = Server(('127.0.0.1', 0), Handler)
    server.mode = mode
    server.lock = threading.Lock()
    server.requests = []
    server.release = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.release.set()
        server.shutdown()
        server.server_close()
        thread.join()


def run(binary, mode, metrics=True):
    with fixture(mode) as server:
        env = {k: v for k, v in os.environ.items() if 'proxy' not in k.lower()}
        env['NICO_BASE_URL'] = f'http://127.0.0.1:{server.server_port}/v3'
        args = [str(binary), '--no-progress', '-A', '-T1', '-P1', '-H1', '--retries', '4' if mode == 'idle_reset' else '1',
                '--timeout', '400ms' if mode == 'replay_timeout' else '160ms', '--json', TARGET]
        if mode == 'idle_reset':
            args.extend(['--min-interval', '100ms'])
        if metrics:
            args.append('--http-metrics')
        started = time.monotonic()
        result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=3)
        elapsed = time.monotonic() - started
        logs = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
        return {'exit': result.returncode, 'elapsed': elapsed, 'requests': list(server.requests),
                'output': json.loads(result.stdout), 'logs': logs}


class StaleConnectionTests(unittest.TestCase):
    binary = None

    def test_reused_eof_replays_once_without_application_retry_or_overload(self):
        for metrics in (False, True):
            with self.subTest(metrics=metrics):
                result = run(self.binary, 'reused_eof', metrics)
                self.assertEqual(result['exit'], 0, result)
                self.assertEqual(result['output']['items'], ['sm1'])
                self.assertEqual(len(result['requests']), 3)
                self.assertEqual(result['requests'][0], result['requests'][1])
                self.assertNotEqual(result['requests'][1], result['requests'][2])
                if metrics:
                    http = next(row['http'] for row in result['logs'] if row.get('msg') == 'http_metrics')
                    self.assertEqual(http['metrics']['attempts'], 2)
                    self.assertEqual(http['metrics']['transport_replays'], 1)
                    self.assertEqual(http['metrics']['transport_errors'], 0)
                    self.assertEqual(http['metrics']['retries'], 0)
                    self.assertEqual(http['adaptive']['overload_errors'], 0)
                    trace = next(row['attempt'] for row in result['logs'] if row.get('attempt', {}).get('transport_replays'))
                    self.assertEqual(trace['replay_cause'], 'HttpConnectionClosing')
                    self.assertLessEqual(sum(trace[key] for key in ('acquire_ns', 'send_ns', 'head_ns', 'body_ns', 'cleanup_ns')), trace['duration_ns'])

    def test_non_replayable_outcomes_remain_failures(self):
        for mode, wire_count in (('fresh_eof', 1), ('double_eof', 3), ('partial', 2),
                                 ('informational', 2), ('redirect', 3), ('403', 2),
                                 ('429', 2), ('500', 2), ('head_timeout', 2)):
            with self.subTest(mode=mode):
                result = run(self.binary, mode)
                self.assertEqual(result['exit'], 1, result)
                self.assertEqual(len(result['requests']), wire_count, result)
                http = next(row['http'] for row in result['logs'] if row.get('msg') == 'http_metrics')
                self.assertEqual(http['metrics']['transport_replays'], int(mode == 'double_eof'))
                self.assertEqual(http['metrics']['retries'], 0)
                self.assertTrue(result['output']['errors'])

    def test_replay_keeps_original_deadline(self):
        result = run(self.binary, 'replay_timeout')
        self.assertEqual(result['exit'], 1, result)
        self.assertEqual(len(result['requests']), 3, result)
        self.assertEqual(result['output']['targets'][0]['error'], 'Timeout')
        # 250 ms spent before replay leaves 150 ms, not a fresh 400 ms.
        self.assertLess(result['elapsed'], .60, result)
        http = next(row['http'] for row in result['logs'] if row.get('msg') == 'http_metrics')
        self.assertEqual(http['metrics']['transport_replays'], 1)
        self.assertEqual(http['metrics']['timeouts'], 1)

    def test_repeated_stale_sockets_do_not_collapse_adaptive_budget(self):
        with fixture('adaptive') as server:
            env = {k: v for k, v in os.environ.items() if 'proxy' not in k.lower()}
            env['NICO_BASE_URL'] = f'http://127.0.0.1:{server.server_port}/v3'
            inputs = ''.join(f'https://www.nicovideo.jp/user/{i}\n' for i in range(1, 129))
            result = subprocess.run([str(self.binary), '--stdin', '--no-progress', '--no-sort',
                                     '-A', '--http-metrics', '--retries', '1', '--timeout', '2s'],
                                    input=inputs, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(result.stdout.splitlines()), 128)
            logs = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
            http = next(row['http'] for row in logs if row.get('msg') == 'http_metrics')
            self.assertEqual(http['metrics']['attempts'], 128)
            self.assertEqual(http['metrics']['retries'], 0)
            self.assertEqual(http['metrics']['transport_errors'], 0)
            self.assertGreater(http['metrics']['transport_replays'], 0)
            self.assertEqual(http['adaptive']['overload_errors'], 0)
            self.assertEqual(http['adaptive']['decreases'], 0)
            self.assertGreaterEqual(http['adaptive']['current'], 8)

    def test_idle_reset_discards_connection_before_application_retry(self):
        result = run(self.binary, 'idle_reset')
        self.assertEqual(result['exit'], 0, result)
        self.assertEqual(result['output']['items'], ['sm1'])
        self.assertEqual(len(result['requests']), 2, result)
        self.assertNotEqual(result['requests'][0], result['requests'][1])
        http = next(row['http'] for row in result['logs'] if row.get('msg') == 'http_metrics')
        self.assertEqual(http['metrics']['attempts'], 3)
        self.assertEqual(http['metrics']['retries'], 1)
        self.assertEqual(http['metrics']['transport_errors'], 1)
        self.assertEqual(http['metrics']['transport_replays'], 0)
        failed, = [row['attempt'] for row in result['logs'] if row.get('attempt', {}).get('error_name')]
        # TCP stacks can report the idle RST on write or on the following read.
        # Both must discard this socket and use the normal application retry.
        self.assertIn((failed['phase'], failed['error_name']),
                      (('send', 'WriteFailed'), ('head', 'ReadFailed')), result)


def suite(binary):
    class Configured(StaleConnectionTests):
        pass
    Configured.binary = Path(binary).resolve()
    return unittest.defaultTestLoader.loadTestsFromTestCase(Configured)


if __name__ == '__main__':
    import sys
    result = unittest.TextTestRunner(verbosity=2).run(suite(sys.argv[1]))
    raise SystemExit(not result.wasSuccessful())
