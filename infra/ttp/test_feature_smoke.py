"""Actual loopback HTTP session/download boundaries, synthetic frozen PDFs only."""
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import unittest
import urllib.error

import staging

FIXTURES = Path(__file__).with_name('smoke-fixtures')
FIXTURE = json.loads((FIXTURES / 'print-portal-v2.fixture.json').read_text())
SHA = 'a' * 40
V1_ID = '6b8337b0-4dbc-4c1f-8644-9691aa494c21'


def config(checkpoint='open', scenario='flow'):
    return {'mode': 'task1-v2', 'trial_id': 'synthetic-smoke', 'scenario': scenario,
            'checkpoint': checkpoint, 'fake_sha': '74e677c764a0dc11d3ec6ce61e62f10df417a2c2',
            'freeze_sha': '270224676d61431c2d26a8e20ec911c328a1f5f3',
            'bundle_sha256': '550698df3fa1e2e42a710ec6ca5d995ed1c5fe9d3a32c520c1f0c11c6430c85e',
            'boot_id': '00000000-0000-4000-8000-000000000099', 'generation': 1,
            'seed_sha256': 'b' * 64, 'admin_manifest_sha256': 'c' * 64}


def marker(kind, value, attrs=''):
    return f'<span data-ttp="{kind}" {attrs}>{html.escape(str(value))}</span>'


def page(batch):
    if batch is None:
        return marker('empty', 'Nenhum pedido aguardando')
    result = f'<main data-ttp="batch" data-batch-id="{batch["id"]}" data-status="{batch["status"]}">'
    result += marker('batch-reference', batch['reference'])
    for item in batch['items']:
        result += f'<section data-ttp="item" data-order-id="{item["orderId"]}">'
        result += marker('item-reference', item['reference'])
        general = item.get('generalInstructions')
        if general:
            result += marker('general-instructions', general['text'])
        if item.get('previouslyCancelledIn'):
            result += marker('previously-cancelled', item['previouslyCancelledIn'])
        files = [(j['file'], j['copies'], j['instructions']) for j in item['jobs']]
        files += [(f, None, None) for f in (general or {}).get('files', [])]
        for f, copies, instructions in files:
            result += f'<article data-ttp="file" data-file-id="{f["id"]}">'
            result += marker('file-name', f['name'])
            result += marker('file-size', f['bytes'], f'data-bytes="{f["bytes"]}"')
            if copies is not None:
                result += marker('copies', copies) + marker('instructions', instructions or '')
            result += f'<a data-ttp="download" href="/files/{f["id"]}">Baixar arquivo</a></article>'
        result += '</section>'
    action = {'open': ('collect', 'Retirei os arquivos'), 'files_collected': ('upload-quote', 'Enviar orçamento'),
              'quote_rejected': ('upload-quote', 'Enviar orçamento'), 'quote_approved': ('mark-printed', 'Marcar como impresso')}.get(batch['status'])
    if action:
        result += f'<button data-ttp="action" data-action="{action[0]}">{action[1]}</button>'
    else:
        result += marker('status-message', {'quote_pending': 'Aguardando aprovação do Financeiro',
                          'printed': 'Aguardando recebimento'}[batch['status']])
    return result + '</main>'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, status, body=b'', mime='application/json', headers=None):
        if isinstance(body, dict): body = json.dumps(body).encode()
        if isinstance(body, str): body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass  # Size-cap client closes early.

    def do_GET(self):
        self.server.paths.append(self.path)
        if self.path == '/version': return self.reply(200, {'revision': SHA})
        if self.path == '/healthz': return self.reply(200, {'status': 'ok'})
        if self.path == '/login': return self.reply(200, '<form>Login</form>', 'text/html')
        if self.path == '/api/session': return self.reply(200, {'authenticated': False, 'csrfToken': 'before'})
        if self.headers.get('Cookie') != 'session=local': return self.reply(401)
        if self.path == '/': return self.reply(200, self.server.page, 'text/html')
        if self.path == '/orders': return self.reply(200, f'<a href="/orders/{V1_ID}">Order</a>', 'text/html')
        if self.path == '/api/print/v1/orders': return self.reply(200, {'items': [{'id': V1_ID}], 'nextCursor': None})
        if self.path.startswith('/files/'):
            if self.server.redirect:
                return self.reply(302, headers={'Location': self.server.redirect})
            raw = (FIXTURES / 'print-portal-v2.assets' / (self.path.rsplit('/', 1)[1] + '.pdf')).read_bytes()
            return self.reply(200, raw + self.server.suffix, self.server.mime)
        return self.reply(404)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        ok = (self.path == '/api/session' and self.headers.get('Origin') == self.server.origin
              and self.headers.get('X-CSRF-Token') == 'before' and data == {'password': 'synthetic-password'})
        if not ok: return self.reply(403)
        return self.reply(200, {'authenticated': True, 'csrfToken': 'after'}, headers={'Set-Cookie': 'session=local; Path=/; HttpOnly'})

    def do_DELETE(self):
        ok = (self.path == '/api/session' and self.headers.get('Cookie') == 'session=local'
              and self.headers.get('Origin') == self.server.origin and self.headers.get('X-CSRF-Token') == 'after')
        self.server.logout = ok
        return self.reply(204 if ok else 403)


class FeatureSmokeTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.origin = 'http://127.0.0.1:' + str(self.server.server_port)
        self.server.page = page(FIXTURE['batches'][0])
        self.server.logout = False
        self.server.suffix = b''
        self.server.mime = 'application/pdf'
        self.server.redirect = None
        self.server.paths = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.result = {}

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()

    def run_smoke(self, setting=None):
        ctx = {'variant': 'ts', 'source_sha': SHA}
        if setting is not None: ctx['smoke_config'] = setting
        return staging.portal_smoke(ctx, self.server.origin, 'synthetic-password', self.result)

    def test_default_preserves_v1(self):
        self.run_smoke()
        self.assertTrue(self.result['fixture_match'])
        self.assertTrue(self.server.logout)
        self.assertNotIn('/', self.server.paths)

    def test_v2_real_session_all_three_downloads(self):
        self.run_smoke(config())
        self.assertEqual(len(self.result['feature']['downloads']), 3)
        self.assertNotIn('/orders', self.server.paths)
        self.assertTrue(self.server.logout)
        self.assertFalse(self.result['visually_verified'])

    def test_baseline_fails_and_logs_out(self):
        self.server.page = '<h1>Orders</h1>'
        with self.assertRaises(AssertionError): self.run_smoke(config())
        self.assertTrue(self.server.logout)
        self.assertEqual(self.result['checkpoint'], 'feature_v2_html')

    def test_bad_hash_and_size_fail_and_logout(self):
        for suffix in (b'wrong', b'x' * (1024 * 1024)):
            with self.subTest(size=len(suffix)):
                self.server.suffix = suffix
                with self.assertRaises(AssertionError): self.run_smoke(config())
                self.assertTrue(self.server.logout)

    def test_wrong_mime(self):
        self.server.mime = 'text/html'
        with self.assertRaises(AssertionError): self.run_smoke(config())
        self.assertTrue(self.server.logout)

    def test_redirect_is_not_followed(self):
        self.server.redirect = '/must-not-follow'
        with self.assertRaises(urllib.error.HTTPError) as caught: self.run_smoke(config())
        caught.exception.close()
        self.assertNotIn('/must-not-follow', self.server.paths)
        self.assertTrue(self.server.logout)

    def test_cross_origin_is_rejected_before_request(self):
        self.server.page = self.server.page.replace('href="/files/', 'href="https://example.invalid/files/')
        with self.assertRaises(AssertionError): self.run_smoke(config())
        self.assertFalse(any(p.startswith('/files/') for p in self.server.paths))
        self.assertTrue(self.server.logout)

    def test_missing_duplicate_hidden_wrong_action_or_group_fail(self):
        original = self.server.page
        variants = [original.replace('data-ttp="file"', 'data-ttp="missing"', 1),
                    original.replace('</main>', original + '</main>'),
                    original.replace('<article ', '<article hidden ', 1),
                    original.replace('data-action="collect"', 'data-action="mark-printed"'),
                    original.replace('data-order-id="00000000-0000-4000-8000-000000000001"', 'data-order-id="wrong"'),
                    original.replace('Frente e verso', 'wrong'),
                    original.replace('data-ttp="copies" >24', 'data-ttp="copies" >12')]
        for value in variants:
            with self.subTest(case=variants.index(value)):
                self.server.page = value
                with self.assertRaises(AssertionError): self.run_smoke(config())
                self.assertTrue(self.server.logout)

    def test_every_state_action(self):
        mapping = {'open': 'open', 'files_collected': 'collected', 'quote_pending': 'quote-pending',
                   'quote_rejected': 'quote-rejected', 'quote_approved': 'quote-approved', 'printed': 'printed'}
        for state, checkpoint in mapping.items():
            with self.subTest(state=state):
                self.server.page = page(next(b for b in FIXTURE['batches'] if b['status'] == state))
                self.run_smoke(config(checkpoint))
                self.assertTrue(self.server.logout)
        self.server.page = page(None)
        self.run_smoke(config('empty', 'empty-history'))

    def test_next_and_rebatched_batch(self):
        for key, scenario, checkpoint in [('nextBatch', 'flow', 'next-batch'),
                                          ('rebatchedBatch', 'cancel', 'rebatched')]:
            with self.subTest(checkpoint=checkpoint):
                self.server.page = page(FIXTURE[key]['batch'])
                self.run_smoke(config(checkpoint, scenario))
                self.assertEqual(self.result['feature']['batch_id'], FIXTURE[key]['batch']['id'])
                self.assertTrue(self.server.logout)

    def test_same_size_wrong_bytes_fail_hash(self):
        # Keep metadata/card correct but serve another real PDF of the same size.
        self.server.page = self.server.page.replace('/files/00000000-0000-4000-8000-00000000000b',
                                                   '/files/00000000-0000-4000-8000-00000000000c')
        with self.assertRaisesRegex(AssertionError, 'download_hash'): self.run_smoke(config())
        self.assertTrue(self.server.logout)

    def test_config_parse_and_fixture_provenance(self):
        from feature_smoke import parse_config, expectation
        self.assertEqual(parse_config(None), {'mode': 'v1'})
        self.assertEqual(parse_config(''), {'mode': 'v1'})
        self.assertEqual(parse_config(json.dumps(config())), config())
        with self.assertRaises(AssertionError): parse_config('{"mode":"v1","mode":"v1"}')
        with self.assertRaises(AssertionError): parse_config('x' * 4097)
        self.assertEqual(expectation(config())['id'], FIXTURE['batches'][0]['id'])

    def test_invalid_config_is_fail_closed_before_login(self):
        for bad in ({'mode': 'typo'}, {**config(), 'generation': True},
                    {**config(), 'fake_sha': '0' * 40}, {**config(), 'extra': 'no'},
                    {**config(), 'checkpoint': 'empty'}):
            with self.subTest(config=bad):
                with self.assertRaises((AssertionError, ValueError)): self.run_smoke(bad)
                self.assertFalse(self.server.logout)
                self.assertEqual(self.server.paths, [])


if __name__ == '__main__': unittest.main()
