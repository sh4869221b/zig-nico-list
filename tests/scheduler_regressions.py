#!/usr/bin/env python3
"""Correctness-only scheduler timeout and lowest-terminal-page regressions."""
import argparse
import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import urllib.parse


ROOT = Path(__file__).resolve().parents[1]
TARGET = 'https://www.nicovideo.jp/user/1'


def payload(ids=(), total=300):
    return json.dumps({'meta': {'status': 200}, 'data': {
        'totalCount': total,
        'items': [{'essential': {'id': value, 'registeredAt': '2024-01-01T00:00:00Z',
                                'count': {'comment': 12}}} for value in ids],
    }}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        server = self.server
        page = int(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['page'][0])
        with server.lock:
            server.requests.append(page)
        status = 200
        body = payload(['sm1'] if page == 1 else [])
        if server.mode == 'short_deadline':
            time.sleep(.008)
            body = payload(['sm1'], total=1)
        elif server.mode == 'adaptive_timeout_headers':
            server.release.wait(2)
        elif server.mode == 'adaptive_timeout_body':
            body = payload(['sm1'], total=1)
        elif page == 3:
            server.third_started.set()
            server.release.wait(2)
        elif page == 2:
            # Ensure the later timeout is in flight before the earlier terminal.
            server.third_started.wait(.04)
            if server.mode == 'earlier_404':
                status, body = 404, b''
            elif server.mode == 'earlier_error':
                status, body = 500, b''
        try:
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if server.mode == 'adaptive_timeout_body':
                self.wfile.flush()
                server.release.wait(2)
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


@contextlib.contextmanager
def fixture(mode):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.mode = mode
    server.lock = threading.Lock()
    server.requests = []
    server.third_started = threading.Event()
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


def run(binary, mode):
    with fixture(mode) as server:
        argv = [str(binary), '--no-progress', '-P', '3', '-H', '3', '--retries', '1',
                '--timeout', '1ms' if mode == 'short_deadline' else '400ms', '--json', TARGET]
        if mode.startswith('adaptive_timeout_'):
            argv[1:1] = ['-A', '--http-metrics']
        env = dict(os.environ, NICO_BASE_URL=f'http://127.0.0.1:{server.server_port}/v3')
        try:
            result = subprocess.run(argv, env=env, capture_output=True, timeout=3)
        except subprocess.TimeoutExpired as error:
            return {'pass': False, 'hung': True, 'stdout': str(error.stdout),
                    'stderr': str(error.stderr), 'requests': server.requests}
        output = json.loads(result.stdout)
        expected_ids = [] if mode == 'short_deadline' or mode.startswith('adaptive_timeout_') else ['sm1']
        expects_error = mode == 'earlier_error'
        target = output['targets'][0]
        passed = (result.returncode == int(expects_error)
                  and output['items'] == expected_ids
                  and target['items'] == expected_ids
                  and bool(target['error']) == expects_error)
        if mode.startswith('earlier_'):
            passed &= sorted(server.requests) == [1, 2, 3]
        if mode.startswith('adaptive_timeout_'):
            logs = [json.loads(line) for line in result.stderr.decode().splitlines() if line.startswith('{')]
            metrics = next(item['http'] for item in logs if item.get('msg') == 'http_metrics')
            passed &= metrics['adaptive']['overload_errors'] == 1
            passed &= server.requests == [1]
        return {'pass': passed, 'exit': result.returncode, 'output': output,
                'stderr': result.stderr.decode(), 'requests': server.requests}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    binaries = {'selected': args.binary.resolve()}
    results = {}
    for mode in ('earlier_empty', 'earlier_404', 'earlier_error', 'short_deadline',
                 'adaptive_timeout_headers', 'adaptive_timeout_body'):
        results[mode] = {}
        for label, binary in binaries.items():
            result = run(binary, mode)
            results[mode][label] = result
            print(f'{mode:20} {label:8} {"PASS" if result["pass"] else "FAIL"}', flush=True)
    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + '\n')
    return 0 if all(item['pass'] for values in results.values() for item in values.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
