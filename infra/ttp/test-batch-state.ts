import assert from 'node:assert/strict';
import { test } from 'node:test';
import { type Batch, type BatchItem, BatchState } from './batch-state.js';
import fixture from './contracts/print-portal-v2.fixture.json';

const frozen = (): Batch => structuredClone(fixture.batches[0]) as Batch;
const queueItem = (): BatchItem => ({
  ...structuredClone(frozen().items[0]),
  orderId: '00000000-0000-4000-8000-000000000002',
  reference: 'IMP-0002',
});
const key = (n: number) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
const next = (items: BatchItem[]): Batch => ({
  ...frozen(),
  id: key(257),
  reference: 'LOT-0002',
  itemCount: items.length,
  items,
});
const make = () => new BatchState({ batches: [frozen()], nextBatch: next });
const quote = () =>
  ({ ...structuredClone(fixture.batches[2].currentQuote), id: key(200) }) as NonNullable<
    Batch['currentQuote']
  >;

test('one visible current: collect is atomic; pending queue hidden until received', () => {
  const s = make();
  const b = frozen();
  const result = s.collect(b.id, { key: key(1), etag: s.etag(b.id) });
  assert.equal(result.body.batch.status, 'files_collected');
  assert.equal(s.memberStatus(b.items[0].orderId), 'in_progress');
  s.publish(queueItem());
  assert.equal(s.open(), null);
  assert.equal(s.list().length, 1);
  assert.ok(!JSON.stringify(s.list()).includes('IMP-0002'));
  s.submitQuote(b.id, quote(), { key: key(2), etag: s.etag(b.id) });
  s.decide(b.id, key(200), 'approved');
  s.print(b.id, key(200), { key: key(3), etag: s.etag(b.id) });
  assert.equal(s.open(), null);
  s.receive(b.id);
  assert.equal(s.memberStatus(b.items[0].orderId), 'approved');
  assert.equal(s.open()?.items[0].reference, 'IMP-0002');
  assert.equal(s.list().filter((x) => !['received', 'cancelled'].includes(x.status)).length, 1);
});

test('cancel preserves history, returns all members and clears price in next batch', () => {
  const s = make();
  const b = frozen();
  s.collect(b.id, { key: key(1), etag: s.etag(b.id) });
  s.publish(queueItem());
  s.submitQuote(b.id, quote(), { key: key(2), etag: s.etag(b.id) });
  s.decide(b.id, key(200), 'approved');
  s.cancel(b.id, 'Cancelamento sintético');
  assert.equal(s.get(b.id).status, 'cancelled');
  assert.equal(s.memberStatus(b.items[0].orderId), 'pending');
  assert.equal(s.open()?.items.length, 2);
  assert.equal(s.open()?.items[0].previouslyCancelledIn, 'LOT-0001');
  assert.equal(s.open()?.currentQuote, null);
  assert.equal(s.open()?.approvedAmountCents, null);
});

test('original intention replays after version advances; conflict/stale have no effects', () => {
  const s = make();
  const b = frozen();
  const pre = { key: key(1), etag: s.etag(b.id) };
  const first = s.collect(b.id, pre);
  s.submitQuote(b.id, quote(), { key: key(2), etag: s.etag(b.id) });
  const replay = s.collect(b.id, pre);
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay.body, first.body);
  assert.equal(replay.etag, first.etag);
  assert.throws(() => s.collect(b.id, { ...pre, etag: s.etag(b.id) }), /IDEMPOTENCY_CONFLICT/);
  assert.throws(() => s.collect(b.id, { ...pre, key: key(3) }), /VERSION_MISMATCH/);
  assert.equal(s.get(b.id).status, 'quote_pending');
});

test('rejected quote permits new quote, never pending/approved replacement; reset is fresh', () => {
  const s = make();
  const b = frozen();
  s.collect(b.id, { key: key(1), etag: s.etag(b.id) });
  s.submitQuote(b.id, quote(), { key: key(2), etag: s.etag(b.id) });
  assert.throws(
    () => s.submitQuote(b.id, quote(), { key: key(3), etag: s.etag(b.id) }),
    /INVALID_STATE/,
  );
  assert.throws(
    () => s.print(b.id, key(200), { key: key(4), etag: s.etag(b.id) }),
    /INVALID_STATE/,
  );
  s.decide(b.id, key(200), 'rejected', 'Corrigir quantidade');
  s.submitQuote(
    b.id,
    { ...quote(), id: key(201), revision: 2 },
    { key: key(5), etag: s.etag(b.id) },
  );
  assert.equal(s.get(b.id).currentQuote?.id, key(201));
  const fresh = make();
  assert.equal(fresh.get(b.id).version, 1);
  assert.equal(fresh.collect(b.id, { key: key(1), etag: fresh.etag(b.id) }).replayed, false);
});
