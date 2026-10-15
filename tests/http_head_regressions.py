#!/usr/bin/env python3
"""Loopback-only response-head cleanup and informational-response regressions."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import unittest


TARGET = 'https://www.nicovideo.jp/user/1'
HEAD_ERRORS = {
    'invalid_content_length': 'HttpHeadersInvalid',
    'unknown_content_encoding': 'HttpHeadersInvalid',
    'unaccepted_content_encoding': 'HttpContentEncodingUnsupported',
    'missing_location': 'HttpRedirectLocationMissing',
    'invalid_location': 'HttpRedirectLocationInvalid',
    'oversize_location': 'HttpRedirectLocationOversize',
    'protocol_switch': 'HttpProtocolSwitchUnsupported',
}


def payload(*, total=True):
    data = {'items': [{'essential': {
        'id': 'sm1', 'registeredAt': '2024-01-01T00:00:00Z',
        'count': {'comment': 1}}}]}
    if total:
        data['totalCount'] = 1
    return json.dumps({'meta': {'status': 200}, 'data': data}).encode()


def response(status=b'200 OK', headers=(), body=b''):
    return (b'HTTP/1.1 ' + status + b'\r\n' +
            b''.join(name + b': ' + value + b'\r\n' for name, value in headers) +
            b'\r\n' + body)


def success(*, total=True):
    body = payload(total=total)
    return response(headers=((b'Content-Length', str(len(body)).encode()),), body=body)


def informational(status):
    return response(str(status).encode() + b' Interim')


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def write(self, data):
        self.wfile.write(data)
        self.wfile.flush()

    def stall(self, data):
        self.write(data)
        # Keep the body and socket open until the client has finished. Cleanup
        # must close an unusable response instead of draining it to its deadline.
        self.server.release.wait(3)

    def do_GET(self):
        server = self.server
        with server.lock:
            server.requests.append(self.client_address[1])
            n = len(server.requests)
        mode = server.mode
        try:
            if mode in ('redirect_close_delimited', 'redirect_truncated'):
                if n == 1:
                    headers = [(b'Location', b'/redirected')]
                    if mode == 'redirect_truncated':
                        headers.append((b'Content-Length', b'100'))
                    self.write(response(b'302 Found', headers, body=b'prefix'))
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                else:
                    self.write(success())
                return

            if mode in ('interim_eof', 'interim_timeout'):
                if n == 1:
                    # An unknown total schedules page 2 on this pooled socket.
                    self.write(success(total=False))
                elif mode == 'interim_eof':
                    self.write(informational(103))
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                else:
                    self.write(informational(100))
                    time.sleep(.25)
                    self.write(informational(102))
                    time.sleep(.05)
                    self.stall(informational(103))
                return

            if mode == 'oversize_location' and n == 1:
                self.write(response(b'302 Found', (
                    (b'Location', b'/' + b'a' * 1024), (b'Content-Length', b'0'))))
                return

            failure_request = 2 if mode == 'oversize_location' else 1
            if n > failure_request:
                self.write(success())
                return

            if mode == 'invalid_content_length':
                self.stall(response(headers=((b'Content-Length', b'invalid'),)))
            elif mode == 'unknown_content_encoding':
                self.stall(response(headers=((b'Content-Encoding', b'fixture-unknown'),
                                             (b'Content-Length', b'1000'))))
            elif mode == 'unaccepted_content_encoding':
                self.stall(response(headers=((b'Content-Encoding', b'zstd'),
                                             (b'Content-Length', b'1000'))))
            elif mode in ('missing_location', 'invalid_location', 'oversize_location'):
                headers = [(b'Content-Length', b'1000')]
                if mode == 'invalid_location':
                    headers.append((b'Location', b'//[invalid'))
                elif mode == 'oversize_location':
                    # Each head fits the 8192-byte read buffer; this Location
                    # exceeds the redirect buffer remaining after the first URI.
                    headers.append((b'Location', b'/' + b'b' * 7500))
                self.stall(response(b'302 Found', headers))
            elif mode == 'overlong_redirect_auth':
                location = (b'http://' + b'u' * 600 + b'@127.0.0.1:' +
                            str(server.server_port).encode() + b'/redirected')
                self.stall(response(b'302 Found', ((b'Location', location),
                                                 (b'Content-Length', b'1000'))))
            elif mode == 'protocol_switch':
                self.stall(response(b'101 Switching Protocols', (
                    (b'Connection', b'Upgrade'), (b'Upgrade', b'fixture'))))
            elif mode.startswith('invalid_status_'):
                status = mode.removeprefix('invalid_status_').encode()
                body = payload()
                self.stall(response(status + b' Invalid',
                                    ((b'Content-Length', str(len(body)).encode()),), body))
            elif mode in ('early_hints', 'mixed_informational'):
                statuses = (103,) if mode == 'early_hints' else (100, 102, 103, 100, 103)
                self.write(b''.join(informational(status) for status in statuses) + success())
            elif mode.startswith('informational_status_'):
                status = mode.removeprefix('informational_status_').encode()
                self.write(b''.join(informational(value) for value in (100, 102, 103)) +
                           response(status + b' Final', ((b'Content-Length', b'0'),)))
            elif mode == 'too_many_informational':
                self.stall(informational(103) * 17)
            elif mode == 'informational_headers_oversize':
                # Three individually valid heads exceed the cumulative budget,
                # while staying below the separate informational-count limit.
                head = response(b'103 Early Hints', ((b'X-Pad', b'x' * 3000),))
                self.stall(head * 3)
            else:
                raise AssertionError(mode)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            self.close_connection = True


@contextlib.contextmanager
def fixture(mode):
    server = Server(('127.0.0.1', 0), Handler)
    server.mode = mode
    server.lock = threading.Lock()
    server.requests = []
    server.release = threading.Event()
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=.01), daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.release.set()
        server.shutdown()
        server.server_close()
        thread.join()


def run(binary, mode, retries=1):
    with fixture(mode) as server:
        env = {key: value for key, value in os.environ.items() if 'proxy' not in key.lower()}
        env['NICO_BASE_URL'] = f'http://127.0.0.1:{server.server_port}/v3'
        argv = [str(binary), '--no-progress', '-T1', '-P2', '-H1', '--retries', str(retries),
                '--timeout', '400ms' if mode == 'interim_timeout' else '1s',
                '--http-metrics', '--json', TARGET]
        started = time.monotonic()
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=6)
        elapsed = time.monotonic() - started
        logs = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
        http = next((row['http'] for row in logs if row.get('msg') == 'http_metrics'), None)
        if http is None:
            raise AssertionError({'exit': result.returncode, 'stdout': result.stdout,
                                  'stderr': result.stderr, 'requests': list(server.requests)})
        return {'exit': result.returncode, 'elapsed': elapsed, 'requests': list(server.requests),
                'output': json.loads(result.stdout), 'logs': logs, 'metrics': http['metrics'],
                'traces': [row['attempt'] for row in logs if row.get('msg') == 'http_attempt']}


class HttpHeadTests(unittest.TestCase):
    binary = None

    def assert_head_error(self, result, error):
        self.assertEqual(result['exit'], 1, result)
        message = f'unexpected status: {error[4:]}' if error.startswith('Http') else error
        self.assertEqual(result['output']['targets'][0]['error'], message, result)
        self.assertEqual(result['metrics']['transport_replays'], 0, result)
        self.assertEqual(result['metrics']['timeouts'], 0, result)
        trace = result['traces'][-1]
        self.assertEqual(trace['phase'], 'head', result)
        self.assertEqual(trace['error_name'], error, result)
        self.assertEqual(trace['transport_error'], error, result)
        self.assertLess(trace['duration_ns'], 750_000_000, result)

    def test_unusable_heads_preserve_errors_without_draining(self):
        for mode, error in HEAD_ERRORS.items():
            with self.subTest(mode=mode):
                result = run(self.binary, mode)
                self.assert_head_error(result, error)
                self.assertEqual(result['metrics']['attempts'], 1, result)
                self.assertEqual(result['metrics']['retries'], 0, result)
                self.assertEqual(len(result['requests']), 2 if mode == 'oversize_location' else 1,
                                 result)

    def test_head_failures_retry_on_a_fresh_connection(self):
        for mode, error in HEAD_ERRORS.items():
            with self.subTest(mode=mode):
                result = run(self.binary, mode, retries=2)
                self.assertEqual(result['exit'], 0, result)
                self.assertEqual(result['output']['items'], ['sm1'], result)
                self.assertEqual(result['metrics']['attempts'], 2, result)
                self.assertEqual(result['metrics']['transport_errors'], 1, result)
                self.assertEqual(result['metrics']['retries'], 1, result)
                self.assertEqual(result['metrics']['retry_transport'], 1, result)
                self.assertEqual(result['metrics']['transport_replays'], 0, result)
                self.assertEqual(result['metrics']['timeouts'], 0, result)
                self.assertEqual(len(result['requests']), 3 if mode == 'oversize_location' else 2,
                                 result)
                self.assertNotEqual(result['requests'][-2], result['requests'][-1], result)
                failed, = [trace for trace in result['traces'] if trace.get('error_name')]
                self.assertEqual(failed['error_name'], error, result)
                self.assertEqual(failed['transport_error'], error, result)

    def test_informational_responses_continue_within_one_attempt(self):
        for mode in ('early_hints', 'mixed_informational'):
            with self.subTest(mode=mode):
                result = run(self.binary, mode)
                self.assertEqual(result['exit'], 0, result)
                self.assertEqual(result['output']['items'], ['sm1'], result)
                self.assertEqual(len(result['requests']), 1, result)
                self.assertEqual(result['metrics']['attempts'], 1, result)
                self.assertEqual(result['metrics']['http_200'], 1, result)
                self.assertEqual(result['metrics']['http_other'], 0, result)
                self.assertEqual(result['metrics']['transport_errors'], 0, result)
                self.assertEqual(result['metrics']['retries'], 0, result)
                self.assertEqual(result['traces'][0]['status'], 200, result)

    def test_redirect_eof_follows_on_a_fresh_connection(self):
        for mode in ('redirect_close_delimited', 'redirect_truncated'):
            with self.subTest(mode=mode):
                result = run(self.binary, mode)
                self.assertEqual(result['exit'], 0, result)
                self.assertEqual(result['output']['items'], ['sm1'], result)
                self.assertEqual(len(result['requests']), 2, result)
                self.assertNotEqual(*result['requests'], result)
                self.assertEqual(result['metrics']['attempts'], 1, result)
                self.assertEqual(result['metrics']['transport_errors'], 0, result)
                self.assertEqual(result['metrics']['transport_replays'], 0, result)
                self.assertEqual(result['metrics']['retries'], 0, result)

    def test_overlong_redirect_credentials_reject_without_draining_or_retrying(self):
        result = run(self.binary, 'overlong_redirect_auth', retries=3)
        self.assert_head_error(result, 'AuthenticationTooLong')
        self.assertEqual(len(result['requests']), 1, result)
        self.assertEqual(result['metrics']['attempts'], 1, result)
        self.assertEqual(result['metrics']['retries'], 0, result)
        self.assertNotIn('u' * 600, str(result['logs']))

    def test_only_final_error_status_is_classified(self):
        for status, metric in ((403, 'http_other'), (500, 'http_5xx')):
            with self.subTest(status=status):
                result = run(self.binary, f'informational_status_{status}')
                self.assertEqual(result['exit'], 1, result)
                self.assertEqual(result['output']['targets'][0]['error'],
                                 f'unexpected status: {status}', result)
                self.assertEqual(len(result['requests']), 1, result)
                self.assertEqual(result['metrics']['attempts'], 1, result)
                self.assertEqual(result['metrics'][metric], 1, result)
                self.assertEqual(result['metrics']['transport_errors'], 0, result)
                self.assertEqual(result['metrics']['retries'], 0, result)
                self.assertEqual(result['traces'][0]['status'], status, result)

    def test_non_digit_status_is_never_success(self):
        for status in ('1:0', '2a0', '200x'):
            with self.subTest(status=status):
                result = run(self.binary, f'invalid_status_{status}')
                self.assert_head_error(result, 'HttpHeadersInvalid')
                self.assertEqual(result['output']['items'], [], result)
                self.assertEqual(result['metrics']['http_200'], 0, result)

    def test_eof_after_interim_does_not_replay_a_reused_socket(self):
        result = run(self.binary, 'interim_eof')
        self.assert_head_error(result, 'HttpConnectionClosing')
        self.assertEqual(result['output']['items'], ['sm1'], result)
        self.assertEqual(len(result['requests']), 2, result)
        self.assertEqual(result['requests'][0], result['requests'][1], result)
        self.assertEqual(result['metrics']['attempts'], 2, result)
        self.assertEqual(result['metrics']['transport_errors'], 1, result)
        self.assertEqual(result['metrics']['retries'], 0, result)

    def test_interim_responses_keep_the_original_deadline(self):
        result = run(self.binary, 'interim_timeout')
        self.assertEqual(result['exit'], 1, result)
        self.assertEqual(result['output']['targets'][0]['error'], 'Timeout', result)
        self.assertEqual(result['output']['items'], ['sm1'], result)
        self.assertEqual(len(result['requests']), 2, result)
        self.assertEqual(result['requests'][0], result['requests'][1], result)
        self.assertEqual(result['metrics']['attempts'], 2, result)
        self.assertEqual(result['metrics']['transport_replays'], 0, result)
        self.assertEqual(result['metrics']['timeouts'], 1, result)
        self.assertEqual(result['metrics']['retries'], 0, result)
        trace = result['traces'][-1]
        self.assertEqual(trace['phase'], 'head', result)
        self.assertEqual(trace['error_name'], 'Timeout', result)
        self.assertEqual(trace['status'], 0, result)
        # The last interim arrives after 300 ms of the original 400 ms budget.
        self.assertLess(trace['duration_ns'], 600_000_000, result)

    def test_informational_count_and_header_bytes_are_bounded(self):
        for mode, error in (('too_many_informational', 'TooManyHttpInformationalResponses'),
                            ('informational_headers_oversize', 'HttpHeadersOversize')):
            with self.subTest(mode=mode):
                result = run(self.binary, mode)
                self.assert_head_error(result, error)
                self.assertEqual(len(result['requests']), 1, result)
                self.assertEqual(result['metrics']['attempts'], 1, result)


def suite(binary):
    class Configured(HttpHeadTests):
        pass
    Configured.binary = Path(binary).resolve()
    return unittest.defaultTestLoader.loadTestsFromTestCase(Configured)


if __name__ == '__main__':
    import sys
    result = unittest.TextTestRunner(verbosity=2).run(suite(sys.argv[1]))
    raise SystemExit(not result.wasSuccessful())
