#!/usr/bin/env python3
"""Offline, cross-platform CLI integration checks; no niconico network traffic."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

import scheduler_regressions

BINARY = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else str(Path('zig-out/bin/zig-nico-list').resolve())
USER = 'https://www.nicovideo.jp/user/1'
MYLIST = 'https://www.nicovideo.jp/mylist/2'


def body(ids=('sm10', 'sm2'), *, total=None, mylist=False):
    entries = [{'id': value, 'registeredAt': '2024-01-01T00:00:00Z', 'count': {'comment': i + 1}} for i, value in enumerate(ids)]
    data = {'totalCount': len(ids) if total is None else total,
            'items': [{('video' if mylist else 'essential'): item} for item in entries]}
    return json.dumps({'meta': {'status': 200}, 'data': {'mylist': data} if mylist else data}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass
    def do_GET(self):
        page = int(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['page'][0])
        with self.server.lock:
            self.server.requests.append(page)
            attempt = len(self.server.requests)
        status, payload, headers, stall = self.server.reply(page, attempt, self.path)
        try:
            self.send_response(status)
            self.send_header('Content-Length', str(len(payload)))
            for key, value in headers.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.flush()
            if stall:
                self.server.release.wait(8)
            self.wfile.write(payload)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


@contextlib.contextmanager
def fixture(reply=None):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.lock = threading.Lock()
    server.requests = []
    server.release = threading.Event()
    server.reply = reply or (lambda p, a, path: (200, body(mylist='/mylists/' in path) if p == 1 else body(()), {}, False))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.release.set()
        server.shutdown()
        server.server_close()
        thread.join()


def command(server, *args, **kwargs):
    env = dict(os.environ, NICO_BASE_URL=f'http://127.0.0.1:{server.server_port}/v3')
    return subprocess.run([BINARY, '--no-progress', '--retries', '2', '--timeout', '2s', *args],
                          env=env, capture_output=True, text=True, timeout=15, **kwargs)


class CliIntegration(unittest.TestCase):
    def check_ok(self, result, expected):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)
        self.assertIn('summary ', result.stderr)

    def test_version_help(self):
        version = subprocess.run([BINARY, '--version'], capture_output=True, text=True, check=True)
        self.assertEqual(version.stdout, 'zig-nico-list version v0.01\n')
        help_result = subprocess.run([BINARY, '--help'], capture_output=True, text=True, check=True)
        self.assertIn('--concurrency-targets', help_result.stdout)
        self.assertEqual(help_result.stderr, '')

    def test_sorted_user(self):
        with fixture() as server:
            self.check_ok(command(server, USER), 'sm2\nsm10\n')

    def test_mylist(self):
        with fixture() as server:
            self.check_ok(command(server, MYLIST), 'sm2\nsm10\n')

    def test_json_dedupe_order(self):
        with fixture() as server:
            result = command(server, '--json', '--dedupe', USER, MYLIST)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output['items'], ['sm2', 'sm10'])
            self.assertEqual(len(output['targets']), 2)
            self.assertEqual(output['targets'][0]['items'], ['sm10', 'sm2'])

    def test_url_and_no_sort(self):
        with fixture() as server:
            self.check_ok(command(server, '--url', '--no-sort', USER),
                          'https://www.nicovideo.jp/watch/sm10\nhttps://www.nicovideo.jp/watch/sm2\n')

    def test_stdin_and_file(self):
        with fixture() as server, tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'inputs.txt'
            path.write_text(USER + '\n', encoding='utf-8')
            self.check_ok(command(server, '--dedupe', '--input-file', str(path), '--stdin', input=MYLIST + '\n'), 'sm2\nsm10\n')

    def test_comment_filter(self):
        with fixture() as server:
            self.check_ok(command(server, '--comment', '1', USER), 'sm2\n')

    def test_date_filter(self):
        with fixture() as server:
            self.check_ok(command(server, '--dateafter', '20240102', USER), '')
            self.check_ok(command(server, '--dateafter', '20240101', '--datebefore', '20240101', USER), 'sm2\nsm10\n')

    def test_invalid_and_best_effort(self):
        with fixture() as server:
            result = command(server, '--strict', 'invalid', USER)
            self.assertEqual(result.returncode, 1)
            self.assertIn('sm2', result.stdout)
            self.check_ok(command(server, '--best-effort', 'invalid', USER), 'sm2\nsm10\n')

    def test_unknown_flag(self):
        result = subprocess.run([BINARY, '--does-not-exist'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')

    def test_parallel_pagination(self):
        def reply(page, attempt, path):
            return 200, body((f'sm{page}',), total=300), {}, False
        with fixture(reply) as server:
            self.check_ok(command(server, '-P3', '-H2', USER), 'sm1\nsm2\nsm3\n')
            self.assertEqual(sorted(server.requests), [1, 2, 3])

    def test_404_body_is_not_drained(self):
        with fixture(lambda *_: (404, b'never delivered', {}, True)) as server:
            result = command(server, '--http-metrics', '--timeout', '250ms', USER)
            self.check_ok(result, '')
            metrics = next(json.loads(line)['http']['metrics'] for line in result.stderr.splitlines()
                           if line.startswith('{') and json.loads(line).get('msg') == 'http_metrics')
            self.assertEqual(metrics['http_404'], 1)
            self.assertEqual(metrics['transport_errors'], 0)
            self.assertEqual(server.requests, [1])

    def test_error_body_stall_retries(self):
        with fixture(lambda *_: (500, b'never delivered', {}, True)) as server:
            result = command(server, '--timeout', '250ms', USER)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertEqual(server.requests, [1, 1])
            self.assertIn('500', result.stderr)

    def test_429_retry_after_then_success(self):
        def reply(page, attempt, path):
            if attempt == 1:
                return 429, b'never delivered', {'Retry-After': '0'}, True
            return 200, body(('sm1',)), {}, False
        with fixture(reply) as server:
            self.check_ok(command(server, '-A', '--timeout', '250ms', USER), 'sm1\n')
            self.assertEqual(server.requests, [1, 1])

    def test_malformed_body_fails(self):
        with fixture(lambda *_: (200, b'{bad JSON', {}, False)) as server:
            result = command(server, USER)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(server.requests, [1])
            self.assertEqual(result.stdout, '')

    def test_timeout_discards_target(self):
        with fixture(lambda *_: (200, body(), {}, True)) as server:
            result = command(server, '--timeout', '100ms', '--json', USER)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['items'], [])
            self.assertEqual(server.requests, [1])
            self.assertIn('failed to read response body', result.stderr)

    def test_logfile_keeps_stdout_clean(self):
        with fixture() as server, tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'run.log'
            result = command(server, '--logfile', str(path), USER)
            self.check_ok(result, 'sm2\nsm10\n')
            self.assertIn('video list', path.read_text())
            self.assertNotIn('"level"', result.stdout)
            first = path.read_bytes()
            self.check_ok(command(server, '--logfile', str(path), USER), 'sm2\nsm10\n')
            appended = path.read_bytes()
            self.assertTrue(appended.startswith(first))
            self.assertGreater(len(appended), len(first))

    def test_scheduler_terminal_and_deadline_regressions(self):
        for mode in ('earlier_empty', 'earlier_404', 'earlier_error', 'short_deadline',
                     'adaptive_timeout_headers', 'adaptive_timeout_body'):
            with self.subTest(mode=mode):
                result = scheduler_regressions.run(Path(BINARY), mode)
                self.assertTrue(result['pass'], result)

    @unittest.skipUnless(os.name == 'posix', 'POSIX graceful SIGINT test')
    def test_sigint_open_stdin(self):
        with fixture() as server:
            env = dict(os.environ, NICO_BASE_URL=f'http://127.0.0.1:{server.server_port}/v3')
            proc = subprocess.Popen([BINARY, '--no-progress', '--stdin'], env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # Wait until the handler is certainly installed by sending a valid target
                # and observing its HTTP request, while keeping stdin open.
                proc.stdin.write(USER + '\n'); proc.stdin.flush()
                import time
                deadline = time.monotonic() + 5
                while not server.requests and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(server.requests)
                proc.send_signal(signal.SIGINT)
                proc.wait(timeout=5)
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
