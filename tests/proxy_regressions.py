#!/usr/bin/env python3
"""Loopback-only TLS/CONNECT regressions with freshly generated test identities.

The probe alone trusts the temporary CA. The real CLI keeps its normal system
trust, and no private key or certificate fixture is stored in the repository.
cryptography is a required test dependency; missing coverage must fail loudly.
"""
import base64
import contextlib
import datetime
import http.server
import ipaddress
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


TARGET = 'https://www.nicovideo.jp/user/1'


class Certificates:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.now = datetime.datetime.now(datetime.timezone.utc)
        ca_key, ca = self.authority('temporary fixture CA')
        foreign_key, foreign_ca = self.authority('untrusted temporary fixture CA')
        self.ca = self.directory / 'ca.pem'
        self.ca.write_bytes(ca.public_bytes(serialization.Encoding.PEM))
        self.contexts = {}
        for name in ('valid', 'hostname', 'expired', 'untrusted'):
            self.contexts[name] = self.leaf(
                name, foreign_key if name == 'untrusted' else ca_key,
                foreign_ca if name == 'untrusted' else ca)

    def authority(self, common_name):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(self.now - datetime.timedelta(days=1))
                .not_valid_after(self.now + datetime.timedelta(days=30))
                .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                                             key_encipherment=False, data_encipherment=False,
                                             key_agreement=False, key_cert_sign=True,
                                             crl_sign=True, encipher_only=False,
                                             decipher_only=False), critical=True)
                .sign(key, hashes.SHA256()))
        return key, cert

    def leaf(self, name, ca_key, ca):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        names = ([x509.DNSName('wrong.invalid')] if name == 'hostname' else
                 [x509.DNSName('localhost'), x509.IPAddress(ipaddress.ip_address('127.0.0.1'))])
        cert = (x509.CertificateBuilder()
                .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)]))
                .issuer_name(ca.subject).public_key(key.public_key())
                .serial_number(x509.random_serial_number())
                .not_valid_before(self.now - datetime.timedelta(days=3))
                .not_valid_after(self.now + datetime.timedelta(days=-1 if name == 'expired' else 7))
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                .add_extension(x509.SubjectAlternativeName(names), critical=False)
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                .sign(ca_key, hashes.SHA256()))
        key_path = self.directory / (name + '.key')
        cert_path = self.directory / (name + '.pem')
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                              serialization.PrivateFormat.PKCS8,
                                              serialization.NoEncryption()))
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_path, key_path)
        return context


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = False
    block_on_close = True
    request_queue_size = 128

    def __init__(self, handler):
        self.lock = threading.Lock()
        self.sockets = set()
        self.release = threading.Event()
        self.requests = []
        super().__init__(('127.0.0.1', 0), handler)

    def track(self, connection):
        with self.lock:
            self.sockets.add(connection)
        return connection

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return self.track(connection), address

    def handle_error(self, *_):
        # TLS rejection and clients closing after a failed CONNECT are expected.
        pass

    def close_connections(self):
        self.release.set()
        with self.lock:
            connections = list(self.sockets)
        for connection in connections:
            with contextlib.suppress(OSError):
                connection.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(OSError):
                connection.close()


class OriginHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        if self.server.tls is not None:
            self.request = self.server.track(self.server.tls.wrap_socket(
                self.request, server_side=True, do_handshake_on_connect=False))
            try:
                self.request.do_handshake()
            except BaseException:
                self.request.close()
                raise
        super().setup()

    def finish(self):
        try:
            super().finish()
        finally:
            self.connection.close()

    def log_message(self, *_):
        pass

    def do_GET(self):
        with self.server.lock:
            self.server.requests.append((self.path, dict(self.headers), self.client_address))
        if self.server.redirect:
            self.send_response(302)
            self.send_header('Location', self.server.redirect)
            payload = b''
        else:
            self.send_response(200)
            payload = b'origin'
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        with self.server.lock:
            self.server.plaintext.append((self.path, dict(self.headers)))
        if self.server.forward_http:
            self.send_response(200)
            self.send_header('Content-Length', '9')
            self.end_headers()
            self.wfile.write(b'forwarded')
            self.wfile.flush()
            return
        self.send_error(502)

    def do_CONNECT(self):
        with self.server.lock:
            self.server.requests.append((self.path, dict(self.headers)))
        self.server.connected.set()
        authority = urllib.parse.urlsplit('//' + self.path)
        if authority.hostname not in ('127.0.0.1', 'localhost') or authority.port not in self.server.ports:
            self.send_error(403)
            return
        mode = self.server.modes.get(authority.port, 'forward')
        if mode == 'stall_connect':
            self.server.release.wait(15)
            self.close_connection = True
            return
        if mode in ('refused', 'auth'):
            # Leave the claimed error body unread. Cleanup must close this
            # socket instead of waiting for it or sending a plaintext GET.
            status = 407 if mode == 'auth' else 403
            self.connection.sendall(f'HTTP/1.1 {status} Rejected\r\nContent-Length: 100\r\n\r\n'.encode())
            return
        if mode == 'unavailable':
            self.connection.sendall(b'HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n')
            return
        if mode == 'unexpected':
            self.connection.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\nplaintext')
            return
        self.connection.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
        if mode == 'stall_tls':
            hello = self.connection.recv(4096)
            with self.server.lock:
                self.server.client_hellos.append(hello)
            self.server.release.wait(15)
            self.close_connection = True
            return
        upstream = self.server.track(socket.create_connection(('127.0.0.1', authority.port), timeout=5))
        self.close_connection = True
        try:
            # No DNS or non-loopback destination is reachable through this
            # fixture. Forward encrypted bytes unchanged in both directions.
            while not self.server.release.is_set():
                readable, _, _ = select.select([self.connection, upstream], [], [], .1)
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is self.connection else self.connection).sendall(data)
        except (OSError, ValueError):
            pass
        finally:
            upstream.close()


@contextlib.contextmanager
def serving(server):
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02})
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.close_connections()
        server.server_close()
        thread.join(timeout=5)
        if thread.is_alive():
            raise RuntimeError('fixture accept thread did not exit')


@contextlib.contextmanager
def origin(tls=None, redirect=None):
    server = Server(OriginHandler)
    server.tls = tls
    server.redirect = redirect
    server.url = f'{"https" if tls else "http"}://127.0.0.1:{server.server_port}'
    with serving(server):
        yield server


@contextlib.contextmanager
def proxy(*origins, modes=None, forward_http=False):
    server = Server(ProxyHandler)
    server.ports = {item.server_port for item in origins}
    server.modes = modes or {}
    server.plaintext = []
    server.forward_http = forward_http
    server.client_hellos = []
    server.connected = threading.Event()
    server.url = f'http://127.0.0.1:{server.server_port}'
    with serving(server):
        yield server


def clean_environment():
    # Host proxy settings must never route an offline test outside loopback.
    return {key: value for key, value in os.environ.items() if 'proxy' not in key.lower()}


class ProxyTests(unittest.TestCase):
    binary = None
    probe = None

    @classmethod
    def setUpClass(cls):
        if not cls.probe.is_file():
            raise RuntimeError(f'required TLS probe missing: {cls.probe}; run zig build tls-probe')
        cls.temporary = tempfile.TemporaryDirectory(prefix='nico-tls-')
        try:
            cls.certificates = Certificates(cls.temporary.name)
        except BaseException:
            cls.temporary.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_probe(self, proxy_url, *urls):
        return subprocess.run([str(self.probe), str(self.certificates.ca), proxy_url or '-', *urls],
                              env=clean_environment(), capture_output=True, text=True, timeout=15)

    def run_cli(self, endpoint, proxy_url=None, timeout='2s'):
        env = clean_environment()
        env['NICO_BASE_URL'] = endpoint + '/v3'
        if proxy_url:
            env['https_proxy'] = proxy_url
        return subprocess.run([str(self.binary), '--no-progress', '--retries', '2', '--timeout', timeout,
                               '--json', '--http-metrics', TARGET], env=env,
                              capture_output=True, text=True, timeout=15)

    def assert_probe_ok(self, result, lines):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), lines)

    def test_direct_http_and_trusted_https(self):
        with origin() as plain, origin(self.certificates.contexts['valid']) as secure:
            result = self.run_probe(None, plain.url + '/plain', secure.url + '/secure')
            self.assert_probe_ok(result, ['OK 200 6', 'OK 200 6'])
            self.assertEqual([r[0] for r in plain.requests], ['/plain'])
            self.assertEqual([r[0] for r in secure.requests], ['/secure'])

    def test_trusted_tls_tunnel_reuse_and_proxy_credential_isolation(self):
        with origin(self.certificates.contexts['valid']) as secure, proxy(secure) as tunnel:
            authenticated = tunnel.url.replace('://', '://proxy-user:proxy-secret@')
            endpoint = secure.url.replace('://', '://origin-user:origin-secret@')
            result = self.run_probe(authenticated, endpoint + '/one', endpoint + '/two')
            self.assert_probe_ok(result, ['OK 200 6', 'OK 200 6'])
            self.assertEqual(len(tunnel.requests), 1, tunnel.requests)
            self.assertEqual(len(secure.requests), 2, secure.requests)
            self.assertEqual(secure.requests[0][2], secure.requests[1][2])
            connect_headers = {k.lower(): v for k, v in tunnel.requests[0][1].items()}
            proxy_auth = 'Basic ' + base64.b64encode(b'proxy-user:proxy-secret').decode()
            origin_auth = 'Basic ' + base64.b64encode(b'origin-user:origin-secret').decode()
            self.assertEqual(connect_headers.get('proxy-authorization'), proxy_auth)
            self.assertNotIn('x-frontend-id', connect_headers)
            self.assertNotIn('authorization', connect_headers)
            for _, headers, _ in secure.requests:
                headers = {k.lower(): v for k, v in headers.items()}
                self.assertNotIn('proxy-authorization', headers)
                self.assertEqual(headers.get('authorization'), origin_auth)
                self.assertEqual(headers.get('x-frontend-id'), '6')
            self.assertEqual(tunnel.plaintext, [])

    def test_plain_http_tunnel_authentication_and_reuse(self):
        with origin() as plain, proxy(plain) as tunnel:
            authenticated = tunnel.url.replace('://', '://proxy-user:proxy-secret@')
            result = self.run_probe(authenticated, plain.url + '/one', plain.url + '/two')
            self.assert_probe_ok(result, ['OK 200 6', 'OK 200 6'])
            self.assertEqual(len(tunnel.requests), 1, tunnel.requests)
            headers = {key.lower(): value for key, value in tunnel.requests[0][1].items()}
            authorization = 'Basic ' + base64.b64encode(b'proxy-user:proxy-secret').decode()
            self.assertEqual(headers.get('proxy-authorization'), authorization)
            self.assertEqual(plain.requests[0][2], plain.requests[1][2])
            for _, headers, _ in plain.requests:
                self.assertNotIn('proxy-authorization', {key.lower() for key in headers})
            self.assertEqual(tunnel.plaintext, [])

    def test_overlong_proxy_credentials_fail_before_network_io(self):
        with origin(self.certificates.contexts['valid']) as secure, proxy(secure) as tunnel:
            credentials = 'u' * 600
            authenticated = tunnel.url.replace('://', '://' + credentials + '@')
            result = self.run_probe(authenticated, secure.url)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('AuthenticationTooLong', result.stderr)
            result = self.run_cli(secure.url, authenticated)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('AuthenticationTooLong', result.stderr)
            self.assertNotIn(credentials, result.stderr)
            self.assertEqual(tunnel.requests, [])
            self.assertEqual(secure.requests, [])

    def test_plain_http_failed_connect_closes_before_forwarding(self):
        for mode in ('refused', 'unavailable'):
            with self.subTest(mode=mode), origin() as plain, \
                    proxy(plain, modes={plain.server_port: mode}, forward_http=True) as tunnel:
                started = time.monotonic()
                result = self.run_probe(tunnel.url, plain.url + '/one', plain.url + '/two')
                self.assertLess(time.monotonic() - started, 3)
                self.assert_probe_ok(result, ['OK 200 9', 'OK 200 9'])
                # A failed tunnel must never be leased as an established origin
                # connection and receive an origin-form request on the next GET.
                self.assertEqual([path for path, _ in tunnel.plaintext],
                                 [plain.url + '/one', plain.url + '/two'])
                self.assertEqual(plain.requests, [])

    def test_plain_http_cancel_during_connect_does_not_forward(self):
        with origin() as stalled, origin() as good, \
                proxy(stalled, good, modes={stalled.server_port: 'stall_connect'},
                      forward_http=True) as tunnel:
            result = self.run_probe(tunnel.url, '^' + stalled.url, good.url)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(result.stdout, r'^EXPECTED_CANCEL (Canceled|ReadFailed)\nOK 200 6\n$')
            self.assertEqual(len(tunnel.requests), 2)
            self.assertEqual(tunnel.plaintext, [])
            self.assertEqual(len(good.requests), 1)

    def test_certificate_rejections_release_failed_tunnels(self):
        for kind in ('untrusted', 'hostname', 'expired'):
            for proxied in (False, True):
                with self.subTest(kind=kind, proxied=proxied), contextlib.ExitStack() as stack:
                    bad = stack.enter_context(origin(self.certificates.contexts[kind]))
                    good = stack.enter_context(origin(self.certificates.contexts['valid']))
                    tunnel = stack.enter_context(proxy(bad, good)) if proxied else None
                    result = self.run_probe(tunnel.url if tunnel else None, '!' + bad.url, good.url)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertRegex(result.stdout, r'^EXPECTED_ERROR (TlsInitializationFailed|TlsAlert)\nOK 200 6\n$')
                    self.assertEqual(bad.requests, [])
                    self.assertEqual(len(good.requests), 1)
                    if tunnel:
                        self.assertEqual(len(tunnel.requests), 2)
                        self.assertEqual(tunnel.plaintext, [])

    def test_connect_failures_never_fall_back_and_next_tunnel_succeeds(self):
        for mode, error in (('refused', 'ProxyTunnelRefused'),
                            ('auth', 'ProxyAuthenticationRequired'),
                            ('unexpected', 'ProxyTunnelUnexpectedData')):
            with self.subTest(mode=mode), origin(self.certificates.contexts['valid']) as bad, \
                    origin(self.certificates.contexts['valid']) as good, \
                    proxy(bad, good, modes={bad.server_port: mode}) as tunnel:
                result = self.run_probe(tunnel.url, '!' + bad.url, good.url)
                self.assert_probe_ok(result, ['EXPECTED_ERROR ' + error, 'OK 200 6'])
                self.assertEqual(bad.requests, [])
                self.assertEqual(len(good.requests), 1)
                self.assertEqual(len(tunnel.requests), 2)
                self.assertEqual(tunnel.plaintext, [])

    def test_http_to_https_redirect_direct_and_through_proxy(self):
        for proxied in (False, True):
            with self.subTest(proxied=proxied), contextlib.ExitStack() as stack:
                secure = stack.enter_context(origin(self.certificates.contexts['valid']))
                plain = stack.enter_context(origin(redirect=secure.url + '/redirected'))
                tunnel = stack.enter_context(proxy(plain, secure)) if proxied else None
                result = self.run_probe(tunnel.url if tunnel else None, plain.url + '/start')
                self.assert_probe_ok(result, ['OK 200 6'])
                self.assertEqual([r[0] for r in plain.requests], ['/start'])
                self.assertEqual([r[0] for r in secure.requests], ['/redirected'])
                if tunnel:
                    self.assertEqual(len(tunnel.requests), 2)
                    self.assertEqual(tunnel.plaintext, [])

    def test_cli_system_trust_rejects_temporary_ca_and_redirect(self):
        for redirect in (False, True):
            with self.subTest(redirect=redirect), contextlib.ExitStack() as stack:
                secure = stack.enter_context(origin(self.certificates.contexts['valid']))
                start = stack.enter_context(origin(redirect=secure.url + '/redirected')) if redirect else secure
                tunnel = stack.enter_context(proxy(secure))
                result = self.run_cli(start.url, tunnel.url)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(json.loads(result.stdout)['items'], [])
                self.assertEqual(json.loads(result.stdout)['targets'][0]['error'], 'TlsInitializationFailed')
                self.assertEqual(secure.requests, [])
                # The CLI intentionally bypasses environment proxies for its
                # loopback HTTP development override, including its redirect.
                self.assertEqual(bool(tunnel.requests), not redirect)
                self.assertEqual(tunnel.plaintext, [])

    def test_unsupported_https_proxy_is_rejected_before_network_io(self):
        with origin(self.certificates.contexts['valid']) as secure, proxy(secure) as tunnel:
            unsupported = tunnel.url.replace('http://', 'https://')
            result = self.run_probe(unsupported, '!' + secure.url)
            self.assert_probe_ok(result, ['EXPECTED_ERROR HttpsProxyUnsupported'])
            result = self.run_cli(secure.url, unsupported)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('HTTPS proxy endpoints are unsupported',
                          json.loads(result.stdout)['targets'][0]['error'])
            self.assertEqual(tunnel.requests, [])
            self.assertEqual(secure.requests, [])

    def test_cli_deadline_bounds_connect_and_tls_stalls(self):
        for mode in ('stall_connect', 'stall_tls'):
            with self.subTest(mode=mode), origin(self.certificates.contexts['valid']) as secure, \
                    proxy(secure, modes={secure.server_port: mode}) as tunnel:
                started = time.monotonic()
                result = self.run_cli(secure.url, tunnel.url, timeout='400ms')
                self.assertLess(time.monotonic() - started, 8)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(json.loads(result.stdout)['targets'][0]['error'], 'Timeout')
                self.assertEqual(len(tunnel.requests), 1)
                self.assertEqual(secure.requests, [])
                rows = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
                metrics = next(row['http']['metrics'] for row in rows if row.get('msg') == 'http_metrics')
                self.assertEqual(metrics['timeouts'], 1)
                self.assertEqual(metrics['retries'], 0)
                if mode == 'stall_tls':
                    self.assertTrue(tunnel.client_hellos)
                    self.assertEqual(tunnel.client_hellos[0][:1], b'\x16')

    def test_native_cancel_releases_connect_and_tls_stalls(self):
        for mode in ('stall_connect', 'stall_tls'):
            with self.subTest(mode=mode), origin(self.certificates.contexts['valid']) as stalled, \
                    origin(self.certificates.contexts['valid']) as good, \
                    proxy(stalled, good, modes={stalled.server_port: mode}) as tunnel:
                result = self.run_probe(tunnel.url, '^' + stalled.url, good.url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(result.stdout, r'^EXPECTED_CANCEL (Canceled|ReadFailed|ProxyTunnelFailed)\nOK 200 6\n$')
                self.assertEqual(len(tunnel.requests), 2)
                self.assertEqual(stalled.requests, [])
                self.assertEqual(len(good.requests), 1)
                self.assertEqual(tunnel.plaintext, [])
                if mode == 'stall_tls':
                    self.assertTrue(tunnel.client_hellos)
                    self.assertEqual(tunnel.client_hellos[0][:1], b'\x16')


def suite(binary, probe=None):
    binary = Path(binary).resolve()
    executable = 'tls-probe.exe' if binary.suffix.lower() == '.exe' else 'tls-probe'
    # An isolated subclass keeps suite configuration local to this invocation.
    tests = type('ConfiguredProxyTests', (ProxyTests,), {
        'binary': binary, 'probe': Path(probe).resolve() if probe else binary.with_name(executable)})
    return unittest.defaultTestLoader.loadTestsFromTestCase(tests)


if __name__ == '__main__':
    import sys
    binary = sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zig-nico-list'
    probe_path = sys.argv[2] if len(sys.argv) > 2 else None
    result = unittest.TextTestRunner(verbosity=2).run(suite(binary, probe_path))
    raise SystemExit(not result.wasSuccessful())
