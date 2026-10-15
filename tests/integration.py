#!/usr/bin/env python3
"""Offline, cross-platform CLI integration checks; no niconico network traffic."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

import scheduler_regressions
import stale_connection_regressions

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
            self.server.connections.append(self.client_address)
            attempt = len(self.server.requests)
        status, payload, headers, stall = self.server.reply(page, attempt, self.path)
        if status == 0:
            # Deterministic transport failure before any response headers.
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return
        try:
            if stall == 'headers':
                self.server.release.wait(8)
            self.send_response(status)
            if headers.get('Content-Length', True) is not None and 'Transfer-Encoding' not in headers:
                self.send_header('Content-Length', headers.get('Content-Length', str(len(payload))))
            for key, value in headers.items():
                if key != 'Content-Length':
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.flush()
            self.server.headers_sent.set()
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
    server.connections = []
    server.release = threading.Event()
    server.headers_sent = threading.Event()
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
        self.assertEqual(version.stdout, 'zig-nico-list version v0.03\n')
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

    def test_no_sort_dedupe_across_completed_targets(self):
        with fixture() as server:
            result = command(server, '-T1', '--no-sort', '--dedupe', USER, MYLIST)
            self.check_ok(result, 'sm10\nsm2\n')
            self.assertIn('fetch_ok=2 fetch_err=0 output_count=2', result.stderr)

    def test_no_sort_retains_error_summary_after_later_target(self):
        def reply(page, attempt, path):
            if '/users/' in path:
                return 500, b'', {}, False
            return 200, body(mylist=True) if page == 1 else body((), mylist=True), {}, False
        with fixture(reply) as server:
            result = command(server, '-T1', '--no-sort', '--retries', '1', USER, MYLIST)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stdout, 'sm10\nsm2\n')
            self.assertIn('fetch_ok=1 fetch_err=1 output_count=2', result.stderr)
            self.assertTrue(result.stderr.endswith('Error: unexpected status: 500\n'))

    def test_http_metrics_snapshot_schema(self):
        for adaptive in (False, True):
            with self.subTest(adaptive=adaptive), fixture() as server:
                flags = ['-A'] if adaptive else []
                result = command(server, *flags, '-T1', '-P1', '-H2', '--http-metrics', USER)
                self.check_ok(result, 'sm2\nsm10\n')
                http = next(json.loads(line)['http'] for line in result.stderr.splitlines()
                            if line.startswith('{') and json.loads(line).get('msg') == 'http_metrics')
                self.assertEqual(set(http), {'admission', 'metrics', 'elapsed_seconds'} |
                                 ({'adaptive'} if adaptive else set()))
                self.assertEqual(set(http['admission']),
                                 {'hard_max', 'limit', 'reserved', 'peak_reserved', 'pending', 'peak_pending'})
                self.assertEqual(http['admission']['hard_max'], 2)
                self.assertEqual(http['admission']['limit'], 2)
                self.assertEqual(http['admission']['reserved'], 0)
                self.assertEqual(http['admission']['pending'], 0)
                self.assertEqual(http['metrics']['attempts'], 2)
                self.assertEqual(http['metrics']['pages'], 2)
                if adaptive:
                    self.assertEqual(http['adaptive']['pending'], 0)
                    self.assertEqual(http['adaptive']['in_flight'], 0)
                    self.assertIsInstance(http['adaptive']['decisions'], list)
                    self.assertNotIn('decision_buffer', http['adaptive'])
                    self.assertNotIn('decision_count', http['adaptive'])

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

    def test_timeout_reports_failed_target(self):
        with fixture(lambda *_: (200, body(), {}, True)) as server:
            result = command(server, '--timeout', '100ms', '--json', USER)
            self.assertEqual(result.returncode, 1, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output['items'], [])
            self.assertEqual(output['targets'][0]['error'], 'Timeout')
            self.assertIn('fetch_ok=0 fetch_err=1', result.stderr)
            self.assertEqual(server.requests, [1])
            self.assertIn('failed to read response body', result.stderr)

    def test_later_page_timeout_preserves_prefix_and_reports_failure(self):
        for flags in ([], ['--no-sort'], ['--json'], ['--best-effort'], ['-P2', '--json']):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as tmp:
                def reply(page, attempt, path):
                    return 200, body((f'sm{page}',), total=200), {}, page == 2
                with fixture(reply) as server:
                    logfile = Path(tmp) / 'failure.jsonl'
                    result = command(server, '--timeout', '100ms', '--logfile',
                                     str(logfile), '--http-metrics', *flags, USER)
                    self.assertEqual(result.returncode, int('--best-effort' not in flags), result.stderr)
                    if '--json' in flags:
                        output = json.loads(result.stdout)
                        self.assertEqual(output['items'], ['sm1'])
                        self.assertEqual(output['targets'][0]['error'], 'Timeout')
                    else:
                        self.assertEqual(result.stdout, 'sm1\n')
                    self.assertIn('fetch_ok=0 fetch_err=1 output_count=1', result.stderr)
                    logs = [json.loads(line) for line in logfile.read_text().splitlines()]
                    self.assertTrue(any(row['level'] == 'ERROR' and row.get('msg') == 'failed to get video list' for row in logs))
                    metrics = next(row['http']['metrics'] for row in logs if row.get('msg') == 'http_metrics')
                    self.assertEqual(metrics['pages'], 2)
                    self.assertEqual(metrics['page_success'], 1)
                    self.assertEqual(metrics['page_errors'], 1)
                    self.assertEqual(metrics['transport_errors'], 1)
                    self.assertEqual(metrics['retries'], 0)
                    self.assertEqual(server.requests, [1, 2])

    def test_transport_retry_recovers_and_exhaustion_fails(self):
        for recover in (True, False):
            with self.subTest(recover=recover):
                def reply(page, attempt, path):
                    failed = page == 2 and (not recover or attempt == 2)
                    return (0 if failed else 200), body((f'sm{page}',), total=200), {}, False
                with fixture(reply) as server:
                    result = command(server, '-P2', '--http-metrics', USER)
                    self.assertEqual(result.returncode, 0 if recover else 1, result.stderr)
                    self.assertEqual(result.stdout, 'sm1\nsm2\n' if recover else 'sm1\n')
                    self.assertIn('fetch_ok=1 fetch_err=0' if recover else 'fetch_ok=0 fetch_err=1', result.stderr)
                    self.assertEqual(server.requests, [1, 2, 2] if recover else [1, 2, 2, 2])
                    metrics = next(json.loads(line)['http']['metrics'] for line in result.stderr.splitlines()
                                   if line.startswith('{') and json.loads(line).get('msg') == 'http_metrics')
                    self.assertEqual(metrics['attempts'], 2 if recover else 3)
                    self.assertEqual(metrics['retries'], 0 if recover else 1)
                    self.assertEqual(metrics['transport_replays'], 1)
                    self.assertEqual(metrics['page_errors'], 0 if recover else 1)
                    self.assertEqual(metrics['transport_errors'], 0 if recover else 2)

    def test_other_http_status_is_counted_and_logged(self):
        for recover in (True, False):
            with self.subTest(recover=recover):
                def reply(page, attempt, path):
                    if not recover or attempt == 1:
                        return 403, b'', {}, False
                    return 200, body(('sm1',), total=1), {}, False
                with fixture(reply) as server:
                    result = command(server, '-P2', '--http-metrics', USER)
                    self.assertEqual(result.returncode, 0 if recover else 1, result.stderr)
                    logs = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
                    status_logs = [row for row in logs if row.get('msg') == 'HTTP attempt returned error status']
                    self.assertEqual(len(status_logs), 1 if recover else 2)
                    self.assertTrue(all(row.get('error') == '403' for row in status_logs), status_logs)
                    metrics = next(row['http']['metrics'] for row in logs if row.get('msg') == 'http_metrics')
                    self.assertEqual(metrics['http_other'], 1 if recover else 2)
                    self.assertEqual(metrics['retries'], 1)
                    self.assertEqual(metrics['attempts'], sum(metrics[key] for key in
                                     ('http_200', 'http_404', 'http_429', 'http_5xx', 'http_other', 'transport_errors')))

    def test_empty_error_response_retains_connection(self):
        for status in (403, 429, 500):
            for metrics_enabled in (False, True):
                with self.subTest(status=status, metrics=metrics_enabled):
                    def reply(page, attempt, path):
                        return (status, b'', {}, False) if attempt == 1 else (200, body(('sm1',)), {}, False)
                    with fixture(reply) as server:
                        flags = ['--http-metrics'] if metrics_enabled else []
                        self.check_ok(command(server, '-P2', *flags, USER), 'sm1\n')
                        self.assertEqual(server.requests, [1, 1])
                        self.assertEqual(len(set(server.connections)), 1)

    def test_error_connection_close_and_unread_bodies_are_not_reused(self):
        for payload, headers, stall in ((b'', {'Connection': 'close'}, False),
                                        (b'not delivered', {}, True),
                                        (b'', {'Transfer-Encoding': 'chunked'}, True)):
            with self.subTest(headers=headers, stall=stall):
                def reply(page, attempt, path):
                    return (403, payload, headers, stall) if attempt == 1 else (200, body(('sm1',)), {}, False)
                with fixture(reply) as server:
                    self.check_ok(command(server, '-P2', '--http-metrics', USER), 'sm1\n')
                    self.assertEqual(len(set(server.connections)), 2)

    def test_complete_chunked_body_and_trailers_remain_valid(self):
        payload = body(('sm1',))
        middle = len(payload) // 2
        wire = (f'{middle:x};fixture=yes\r\n'.encode() + payload[:middle] + b'\r\n' +
                f'{len(payload) - middle:x}\r\n'.encode() + payload[middle:] +
                b'\r\n0\r\nX-Fixture: complete\r\n\r\n')
        with fixture(lambda *_: (200, wire, {'Transfer-Encoding': 'chunked'}, False)) as server:
            self.check_ok(command(server, '-P2', '--http-metrics', USER), 'sm1\n')

    def test_empty_404_can_reuse_connection_for_next_target(self):
        def reply(page, attempt, path):
            return (404, b'', {}, False) if '/users/1/' in path else (200, body(('sm2',)), {}, False)
        with fixture(reply) as server:
            self.check_ok(command(server, '-T1', '-P2', '--http-metrics', USER,
                                  'https://www.nicovideo.jp/user/2'), 'sm2\n')
            self.assertEqual(len(set(server.connections)), 1)

    def test_unknown_length_error_body_does_not_block_or_reuse(self):
        def reply(page, attempt, path):
            return (403, b'not delivered', {'Content-Length': None}, True) if attempt == 1 else (200, body(('sm1',)), {}, False)
        with fixture(reply) as server:
            self.check_ok(command(server, '-P2', '--timeout', '250ms', '--http-metrics', USER), 'sm1\n')
            self.assertEqual(len(set(server.connections)), 2)

    def test_attempt_trace_timeout_phase_and_received_status(self):
        for phase in ('head', 'body'):
            with self.subTest(phase=phase), fixture(lambda *_: (200, body(), {}, 'headers' if phase == 'head' else True)) as server:
                result = command(server, '-A', '--http-metrics', '--timeout', '100ms', USER)
                self.assertEqual(result.returncode, 1, result.stderr)
                rows = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
                trace, = [row['attempt'] for row in rows if row.get('msg') == 'http_attempt']
                metrics = next(row['http']['metrics'] for row in rows if row.get('msg') == 'http_metrics')
                self.assertEqual(trace['phase'], phase)
                self.assertEqual(trace['error_name'], 'Timeout')
                self.assertEqual(trace['status'], 200 if phase == 'body' else 0)
                self.assertGreater(trace[phase + '_ns'], 0)
                self.assertEqual(metrics['timeouts'], 1)
                self.assertEqual(metrics['cancellations'], 0)
                self.assertEqual(metrics['body_errors'], int(phase == 'body'))
                self.assertEqual(metrics['response_200_heads'], int(phase == 'body'))
                self.assertEqual(metrics['transport_errors'], 1)
                self.assertEqual(metrics['retries'], 0)

    def test_attempt_trace_correlates_retries_without_private_urls(self):
        statuses = [403, 401, 500, 429, 0, 200]
        def reply(page, attempt, path):
            status = statuses[attempt - 1]
            return status, body(('sm1',)) if status == 200 else b'', {}, False
        with fixture(reply) as server:
            result = command(server, '-A', '-P2', '--retries', '6', '--http-metrics',
                             'https://www.nicovideo.jp/user/987654321?private=secret')
            self.check_ok(result, 'sm1\n')
            rows = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
            traces = [row['attempt'] for row in rows if row.get('msg') == 'http_attempt']
            metrics = next(row['http']['metrics'] for row in rows if row.get('msg') == 'http_metrics')
            self.assertEqual([t['request_id'] for t in traces], [1, 2, 3, 4, 5])
            self.assertEqual([t['attempt'] for t in traces], [1, 2, 3, 4, 5])
            self.assertEqual([t['retry_cause'] for t in traces], ['none', 'http_403', 'http_other', 'http_5xx', 'http_429'])
            self.assertEqual({(t['target_sequence'], t['page']) for t in traces}, {(0, 1)})
            self.assertEqual(traces[-1]['response_version'], 'HTTP/1.1')
            self.assertEqual(traces[3]['throttle_decision']['reason'], 'http_429')
            for cause in ('http_403', 'http_other', 'http_5xx', 'http_429'):
                self.assertEqual(metrics['retry_' + cause], 1)
            self.assertEqual(metrics['retry_transport'], 0)
            self.assertEqual(metrics['retries'], 4)
            self.assertEqual(metrics['transport_replays'], 1)
            self.assertEqual(traces[-1]['transport_replays'], 1)
            self.assertEqual(server.requests, [1, 1, 1, 1, 1, 1])
            self.assertEqual(metrics['http_403'], 1)
            self.assertGreater(metrics['pool_hits'], 0)
            self.assertEqual(sum(metrics[k] for k in ('pool_hits', 'pool_misses', 'pool_lookup_unknown')), 5)
            for trace in traces:
                self.assertGreaterEqual(trace['duration_ns'], sum(trace[k] for k in
                    ('acquire_ns', 'send_ns', 'head_ns', 'body_ns', 'cleanup_ns')))
            self.assertNotIn('987654321', result.stderr)
            self.assertNotIn('secret', result.stderr)
            self.assertNotIn('registeredAt', result.stderr)

    def test_attempt_trace_is_opt_in(self):
        with fixture() as server:
            result = command(server, USER)
            self.check_ok(result, 'sm2\nsm10\n')
            self.assertNotIn('http_attempt', result.stderr)

    @unittest.skipUnless(os.name == 'posix', 'POSIX graceful SIGINT test')
    def test_sigint_body_is_neutral_and_not_timeout(self):
        with fixture(lambda *_: (200, body(), {}, True)) as server:
            env = dict(os.environ, NICO_BASE_URL=f'http://127.0.0.1:{server.server_port}/v3')
            proc = subprocess.Popen([BINARY, '--no-progress', '-A', '--json', '--http-metrics',
                                     '--timeout', '5s', USER], env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(server.headers_sent.wait(5))
                proc.send_signal(signal.SIGINT)
                stdout, stderr = proc.communicate(timeout=3)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate(timeout=3)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)['items'], [])
            self.assertEqual(json.loads(stdout)['targets'][0]['error'], '')
            rows = [json.loads(line) for line in stderr.splitlines() if line.startswith('{')]
            trace, = [row['attempt'] for row in rows if row.get('msg') == 'http_attempt']
            http = next(row['http'] for row in rows if row.get('msg') == 'http_metrics')
            self.assertEqual(trace['error_name'], 'Canceled')
            self.assertEqual(http['metrics']['cancellations'], 1)
            self.assertEqual(http['metrics']['timeouts'], 0)
            self.assertEqual(http['adaptive']['overload_errors'], 0)
            self.assertEqual(server.requests, [1])

    def test_truncated_body_records_body_failure_without_retry(self):
        valid_json = body(('sm1',))
        # Include complete JSON with missing HTTP framing: parsing the prefix
        # would otherwise falsely report success. Also cover malformed JSON.
        for wire, headers in ((b'{', {'Content-Length': '100'}),
                              (valid_json, {'Content-Length': str(len(valid_json) + 10)}),
                              (f'{len(valid_json):x}\r\n'.encode() + valid_json,
                               {'Transfer-Encoding': 'chunked'})):
            headers = dict(headers, Connection='close')
            with self.subTest(headers=headers), fixture(lambda *_: (200, wire, headers, False)) as server:
                result = command(server, '-P2', '--http-metrics', USER)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, '')
                rows = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
                trace, = [row['attempt'] for row in rows if row.get('msg') == 'http_attempt']
                metrics = next(row['http']['metrics'] for row in rows if row.get('msg') == 'http_metrics')
                self.assertEqual(trace['phase'], 'body')
                self.assertIn('error_name', trace)
                self.assertEqual(metrics['body_errors'], 1)
                self.assertEqual(metrics['decode_errors'], 0)
                self.assertEqual(metrics['response_200_heads'], 1)
                self.assertEqual(metrics['timeouts'], 0)
                self.assertEqual(metrics['retries'], 0)

    def test_later_truncated_body_retains_successful_prefix(self):
        for flags in ([], ['--no-sort'], ['--json', '--best-effort']):
            with self.subTest(flags=flags):
                def reply(page, attempt, path):
                    payload = body((f'sm{page}',), total=200)
                    headers = {} if page == 1 else {'Content-Length': str(len(payload) + 10), 'Connection': 'close'}
                    return 200, payload, headers, False
                with fixture(reply) as server:
                    result = command(server, '-P2', *flags, USER)
                    self.assertEqual(result.returncode, int('--best-effort' not in flags), result.stderr)
                    if '--json' in flags:
                        output = json.loads(result.stdout)
                        self.assertEqual(output['items'], ['sm1'])
                        self.assertEqual(output['targets'][0]['error'], 'TruncatedResponseBody')
                    else:
                        self.assertEqual(result.stdout, 'sm1\n')
                    self.assertIn('fetch_ok=0 fetch_err=1 output_count=1', result.stderr)
                    self.assertEqual(server.requests, [1, 2])

    def test_close_delimited_body_remains_valid(self):
        with fixture(lambda *_: (200, body(('sm1',)), {'Content-Length': None, 'Connection': 'close'}, False)) as server:
            self.check_ok(command(server, '-P2', USER), 'sm1\n')

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


def load_tests(loader, tests, pattern):
    tests.addTests(stale_connection_regressions.suite(BINARY))
    return tests


if __name__ == '__main__':
    unittest.main(verbosity=2)
