import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { type BatchRuntime, seedFactory } from './batch-runtime.js';
import { loadFreeze, sha256 } from './contract-freeze.js';
import { pairingCases } from './pairing-seed.js';

const freeze = loadFreeze();
const id = freeze.fixture.batches[0].id;
const pre = (s: BatchRuntime) => ({ key: randomUUID(), etag: s.etag(id) });
const pdf = freeze.assets.get('00000000-0000-4000-8000-0000000000c8');
assert.ok(pdf);
const upload = { bytes: pdf, name: 'quote.pdf', mime: 'application/pdf' };

test('flow: source bytes, stored upload hash, replay, hidden queue and once-only close', () => {
  const s = seedFactory(freeze)('flow').state;
  const item = s.get(id).items[0];
  const f = item.jobs[0].file;
  assert.equal(sha256(s.memberFile(id, item.orderId, f.id).bytes), f.sha256);
  assert.throws(() => s.memberFile(id, randomUUID(), f.id));
  s.collect(id, pre(s));
  s.checkpoint('publish-queued');
  assert.equal(s.open(), null);
  assert.equal(s.list().length, 1);
  const p = pre(s);
  s.checkpoint('quote-commit-503');
  const q = s.uploadQuote(id, upload, 45900, p);
  assert.equal(s.consumeQuoteFault(q.replayed), true);
  assert.equal(s.consumeQuoteFault(q.replayed), false);
  assert.deepEqual(s.uploadQuote(id, upload, 45900, p), { ...q, replayed: true });
  const quote = q.body.batch.currentQuote;
  assert.ok(quote);
  const document = quote.document;
  assert.equal(document.sha256, sha256(pdf));
  s.checkpoint('approve-quote');
  s.print(id, quote.id, pre(s));
  const before = s.month('2026-09');
  assert.equal(before.close.expectedTotalCents, 46900);
  s.checkpoint('receive');
  assert.equal(s.open()?.id, freeze.fixture.nextBatch.batch.id);
  assert.deepEqual(s.month('2026-09'), before);
  assert.equal(s.month('2026-08').close.id, null);
  const invoice = s.uploadInvoice('2026-09', upload, 46900, {
    key: randomUUID(),
    etag: s.monthEtag('2026-09'),
  });
  freeze.validate('BatchCloseResponse', invoice.body);
  assert.equal(invoice.body.close.state, 'submitted');
  assert.equal(s.invoiceFile('2026-09').bytes.length, pdf.length);
  assert.throws(() =>
    s.uploadInvoice('2026-08', upload, 1, { key: randomUUID(), etag: s.monthEtag('2026-08') }),
  );
});

test('cancel: immutable source history and both pending members in new open batch', () => {
  const s = seedFactory(freeze)('cancel').state;
  s.checkpoint('cancel');
  const b = s.open();
  assert.ok(b);
  assert.deepEqual(b.items, freeze.fixture.rebatchedBatch.batch.items);
  assert.equal(b.currentQuote, null);
  assert.equal(s.get(id).status, 'cancelled');
  assert.equal(s.memberStatus(b.items[0].orderId), 'pending');
  freeze.validate('Batch', b);
});

test('fresh reset clears counters and uploads; history seed and all schema DTOs are valid', () => {
  const factory = seedFactory(freeze);
  const s = factory('empty-history').state;
  assert.equal(s.open(), null);
  assert.equal(s.month('2026-09').close.expectedTotalCents, 46900);
  for (let i = 0; i < 120; i++) s.rate('read', 0);
  assert.throws(() => s.rate('read', 0), /RATE_LIMITED/);
  factory('empty-history').state.rate('read', 0);
  assert.throws(() => factory('unknown'));
  assert.equal(factory('flow').seed_sha256, factory('flow').seed_sha256);
  assert.notEqual(factory('flow').seed_sha256, factory('cancel').seed_sha256);
});

test('all seven explicit legacy pairing fixtures are reproducible supplier projections', () => {
  const factory = seedFactory(freeze);
  for (const c of pairingCases(freeze)) {
    const s = factory(`pairing-${c.name}`).state;
    const b = s.open();
    assert.ok(b);
    freeze.validate('Batch', b);
    const item = b.items[0];
    assert.ok(item);
    assert.deepEqual(
      item.jobs.map((j) => ({ title: j.title, fileId: j.file.id })),
      c.expectedPairs,
    );
    assert.deepEqual(
      item.generalInstructions?.files.map((f) => f.id) ?? [],
      c.expectedResidualFileIds,
    );
    for (const f of [...item.jobs.map((j) => j.file), ...(item.generalInstructions?.files ?? [])])
      assert.equal(sha256(s.memberFile(b.id, item.orderId, f.id).bytes), f.sha256);
    s.collect(b.id, pre(s));
    assert.deepEqual(s.get(b.id).items, b.items);
  }
});

test('identical scenario/generation yields identical successful IDs; failed validation is atomic', () => {
  const factory = seedFactory(freeze);
  const run = (generation: number, failed = false) => {
    const s = factory('flow', { generation }).state;
    s.collect(id, pre(s));
    const p = pre(s);
    const before = s.get(id);
    if (failed) {
      assert.throws(
        () => s.uploadQuote(id, { ...upload, name: '' }, 45900, p),
        /FROZEN_SCHEMA_INVALID/,
      );
      assert.deepEqual(s.get(id), before);
    }
    const q = s.uploadQuote(id, upload, 45900, p);
    assert.deepEqual(s.uploadQuote(id, upload, 45900, p), { ...q, replayed: true });
    s.checkpoint('approve-quote');
    const quote = q.body.batch.currentQuote;
    assert.ok(quote);
    s.print(id, quote.id, pre(s));
    const invoice = s.uploadInvoice('2026-09', upload, 46900, {
      key: randomUUID(),
      etag: s.monthEtag('2026-09'),
    });
    return {
      quote: quote.id,
      document: quote.document.id,
      invoice: invoice.body.close.document?.id,
    };
  };
  assert.deepEqual(run(7), run(7));
  assert.deepEqual(run(7, true), run(7));
  assert.notDeepEqual(run(7), run(8));
});

test('real next fixture mismatch rolls back receipt instead of overwriting expected items', () => {
  const s = seedFactory(freeze)('flow').state;
  s.collect(id, pre(s));
  s.publish({ ...structuredClone(freeze.fixture.queuedItem), title: 'Deliberate mismatch' });
  const q = s.uploadQuote(id, upload, 45900, pre(s)).body.batch.currentQuote;
  assert.ok(q);
  s.checkpoint('approve-quote');
  s.print(id, q.id, pre(s));
  const before = s.get(id);
  assert.throws(() => s.receive(id), /INVALID_SEED/);
  assert.deepEqual(s.get(id), before);
  assert.equal(s.memberStatus(before.items[0].orderId), 'in_progress');
  assert.equal(s.open(), null);
});

test('schema failure does not commit quote state or idempotency', () => {
  const s = seedFactory(freeze)('flow').state;
  s.collect(id, pre(s));
  const p = pre(s),
    before = s.get(id);
  assert.throws(
    () => s.uploadQuote(id, { ...upload, name: '' }, 45900, p),
    /FROZEN_SCHEMA_INVALID/,
  );
  assert.deepEqual(s.get(id), before);
  assert.equal(s.uploadQuote(id, upload, 45900, p).replayed, false);
});
