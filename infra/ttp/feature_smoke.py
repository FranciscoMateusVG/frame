"""Optional, read-only task-1 HTML/download contract; not browser visibility proof."""
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import urllib.parse

FREEZE = '270224676d61431c2d26a8e20ec911c328a1f5f3'
FAKE = '74e677c764a0dc11d3ec6ce61e62f10df417a2c2'
BUNDLE = '550698df3fa1e2e42a710ec6ca5d995ed1c5fe9d3a32c520c1f0c11c6430c85e'
FIXTURES = Path(__file__).with_name('smoke-fixtures')
CHECKPOINTS = {
    'flow': {'open': 'open', 'collected': 'files_collected', 'quote-pending': 'quote_pending',
             'quote-rejected': 'quote_rejected', 'quote-approved': 'quote_approved',
             'printed': 'printed', 'next-batch': 'open'},
    'cancel': {'approved': 'quote_approved', 'rebatched': 'open'},
    'empty-history': {'empty': None},
}
ACTION = {'open': 'collect', 'files_collected': 'upload-quote', 'quote_rejected': 'upload-quote',
          'quote_approved': 'mark-printed'}
LABEL = {'collect': 'Retirei os arquivos', 'upload-quote': 'Enviar orçamento', 'mark-printed': 'Marcar como impresso'}
MESSAGE = {'quote_pending': 'Aguardando aprovação do Financeiro', 'printed': 'Aguardando recebimento'}


def parse_config(raw):
    """Only non-secret, bounded metadata. Called once at init, then frozen in context."""
    if raw is None or raw == '': return {'mode': 'v1'}
    assert isinstance(raw, str) and len(raw.encode()) <= 4096, 'smoke_config_size'
    def unique(pairs):
        result = {}
        for k, v in pairs:
            assert k not in result, 'smoke_config_duplicate_key'
            result[k] = v
        return result
    return validate_config(json.loads(raw, object_pairs_hook=unique))


def validate_config(value):
    assert isinstance(value, dict), 'smoke_config_object'
    if value == {'mode': 'v1'}: return dict(value)
    keys = {'mode', 'trial_id', 'scenario', 'checkpoint', 'fake_sha', 'freeze_sha', 'bundle_sha256',
            'boot_id', 'generation', 'seed_sha256', 'admin_manifest_sha256'}
    assert set(value) == keys and value['mode'] == 'task1-v2', 'smoke_config_fields'
    assert all(isinstance(v, str) for k, v in value.items() if k != 'generation'), 'smoke_config_types'
    assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', value['trial_id']), 'smoke_trial_id'
    assert value['scenario'] in CHECKPOINTS, 'smoke_scenario'
    assert value['checkpoint'] in CHECKPOINTS[value['scenario']], 'smoke_checkpoint'
    assert (value['fake_sha'], value['freeze_sha'], value['bundle_sha256']) == (FAKE, FREEZE, BUNDLE), 'smoke_pins'
    assert re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', value['boot_id']), 'smoke_boot_id'
    assert type(value['generation']) is int and 0 < value['generation'] < 2**53, 'smoke_generation'
    for field in ('seed_sha256', 'admin_manifest_sha256'):
        assert re.fullmatch(r'[0-9a-f]{64}', value[field]), 'smoke_manifest_hash'
    return dict(value)


def expectation(config):
    validate_config(config)
    proof = json.loads((FIXTURES / 'provenance.json').read_text())
    assert proof['source_sha'] == FREEZE, 'fixture_freeze'
    for filename, digest in proof['files'].items():
        assert hashlib.sha256((FIXTURES / filename).read_bytes()).hexdigest() == digest, 'fixture_drift'
    fixture = json.loads((FIXTURES / 'print-portal-v2.fixture.json').read_text())
    scenario, checkpoint = config['scenario'], config['checkpoint']
    if scenario == 'empty-history': return None
    if checkpoint == 'next-batch': return fixture['nextBatch']['batch']
    if checkpoint == 'rebatched': return fixture['rebatchedBatch']['batch']
    state = CHECKPOINTS[scenario][checkpoint]
    return next(b for b in fixture['batches'] if b['status'] == state)


class Node:
    def __init__(self, tag, attrs=(), parent=None):
        self.tag, self.attrs, self.parent = tag, dict(attrs), parent
        self.children = []

    def marked(self, name):
        result = []
        for child in self.children:
            if isinstance(child, Node):
                if child.attrs.get('data-ttp') == name: result.append(child)
                result.extend(child.marked(name))
        return result

    def visible(self):
        own = not ('hidden' in self.attrs or self.attrs.get('aria-hidden', '').lower() == 'true'
                   or self.tag in ('script', 'style', 'template', 'noscript')
                   or re.search(r'(display\s*:\s*none|visibility\s*:\s*hidden)', self.attrs.get('style', ''), re.I))
        return own and (self.parent is None or self.parent.visible())

    def text(self):
        if not self.visible(): return ''
        return ''.join(c.text() if isinstance(c, Node) else c for c in self.children)


class Document(HTMLParser):
    VOID = set('area base br col embed hr img input link meta param source track wbr'.split())
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.root = Node('root')
        self.stack = [self.root]
        self.feed(html)
        self.close()
        assert len(self.stack) == 1, 'unclosed_html'

    def handle_starttag(self, tag, attrs):
        assert len(attrs) == len(dict(attrs)), 'duplicate_html_attribute'
        node = Node(tag, attrs, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag == 'br': node.children.append('\n')
        if tag not in self.VOID: self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID: self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag in self.VOID: return
        assert len(self.stack) > 1 and self.stack[-1].tag == tag, 'unbalanced_html'
        self.stack.pop()

    def handle_data(self, value): self.stack[-1].children.append(value)


def normalized(text): return ' '.join(text.split())


def one(node, marker, expected=None):
    matches = node.marked(marker)
    assert len(matches) == 1 and matches[0].visible(), 'marker_' + marker
    result = matches[0]
    if expected is not None:
        assert normalized(result.text()) == normalized(str(expected)), 'text_' + marker
    return result


def download_path(origin, href):
    assert isinstance(href, str) and href and not re.search(r'[\s\\\x00-\x1f\x7f]', href), 'download_href'
    parsed = urllib.parse.urlsplit(urllib.parse.urljoin(origin + '/', href))
    base = urllib.parse.urlsplit(origin)
    assert (parsed.scheme, parsed.netloc) == (base.scheme, base.netloc), 'download_origin'
    assert not parsed.username and not parsed.password and not parsed.fragment, 'download_url'
    # No redirects, external/signed URLs, or calls to arbitrary upstream/admin endpoints.
    assert parsed.path.startswith('/') and not parsed.path.startswith('//'), 'download_path'
    return parsed.path + ('?' + parsed.query if parsed.query else '')


def verify(request, origin, config, result):
    batch = expectation(config)
    result['checkpoint'] = 'feature_v2_html'
    page = request('/', mime='text/html')
    doc = Document(page).root
    feature = {'mode': 'task1-v2', 'expectation': config, 'downloads': [],
               'administrative_correlation': 'required_before_and_after_trial',
               'visibility_proof': 'server_html_only'}
    result['feature'] = feature
    if batch is None:
        one(doc, 'empty', 'Nenhum pedido aguardando')
        assert not any(doc.marked(k) for k in ('batch', 'item', 'file', 'action')), 'empty_has_batch_content'
        feature['status'] = 'success'
        return
    root = one(doc, 'batch')
    assert not doc.marked('empty'), 'batch_has_empty_state'
    assert root.attrs.get('data-batch-id') == batch['id'] and root.attrs.get('data-status') == batch['status'], 'batch_identity'
    one(root, 'batch-reference', batch['reference'])
    items = root.marked('item')
    assert [i.attrs.get('data-order-id') for i in items] == [i['orderId'] for i in batch['items']], 'item_order'
    assert doc.marked('item') == items, 'items_outside_batch'
    cards_seen = []
    downloads = []
    for node, item in zip(items, batch['items']):
        assert node.visible(), 'item_hidden'
        one(node, 'item-reference', item['reference'])
        general = item.get('generalInstructions')
        if general: one(node, 'general-instructions', general['text'])
        else: assert not node.marked('general-instructions'), 'unexpected_general_instructions'
        previous = item.get('previouslyCancelledIn')
        if previous:
            warning = one(node, 'previously-cancelled')
            assert previous in warning.text(), 'cancelled_reference'
        else: assert not node.marked('previously-cancelled'), 'unexpected_cancelled_warning'
        files = [(j['file'], j['copies'], j['instructions']) for j in item['jobs']]
        files += [(f, None, None) for f in (general or {}).get('files', [])]
        cards = node.marked('file')
        assert [c.attrs.get('data-file-id') for c in cards] == [f['id'] for f, _, _ in files], 'file_card_order'
        cards_seen.extend(cards)
        for card, (file, copies, instructions) in zip(cards, files):
            assert card.visible(), 'file_hidden'
            one(card, 'file-name', file['name'])
            size = one(card, 'file-size')
            assert size.attrs.get('data-bytes') == str(file['bytes']) and normalized(size.text()), 'file_size'
            if copies is not None:
                one(card, 'copies', copies)
                one(card, 'instructions', instructions or '')
            else:
                assert not card.marked('copies') and not card.marked('instructions'), 'residual_must_not_guess'
            link = one(card, 'download', 'Baixar arquivo')
            assert link.tag == 'a', 'download_not_anchor'
            downloads.append((download_path(origin, link.attrs.get('href')), file))
    assert doc.marked('file') == cards_seen, 'files_outside_items'
    assert len(doc.marked('download')) == len(downloads), 'extra_downloads'
    actions = doc.marked('action')
    expected_action = ACTION.get(batch['status'])
    assert len(actions) == (1 if expected_action else 0), 'action_count'
    if expected_action:
        action = one(root, 'action')
        assert action.attrs.get('data-action') == expected_action, 'state_action'
        assert action.tag in ('button', 'form', 'input'), 'action_not_control'
        assert LABEL[expected_action] in normalized(action.text() or action.attrs.get('value', '')), 'action_label'
        assert not root.marked('status-message'), 'unexpected_wait_message'
    else:
        one(root, 'status-message', MESSAGE[batch['status']])
    result['checkpoint'] = 'feature_v2_downloads'
    for path, file in downloads:
        payload = request(path, raw=True, limit=file['bytes'], mime=file['mime'])
        digest = hashlib.sha256(payload).hexdigest()
        assert len(payload) == file['bytes'] and digest == file['sha256'], 'download_hash'
        feature['downloads'].append({'file_id': file['id'], 'bytes': len(payload), 'sha256': digest})
    feature.update(status='success', batch_id=batch['id'], batch_status=batch['status'])
