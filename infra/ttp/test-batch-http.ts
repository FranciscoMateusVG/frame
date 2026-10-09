import assert from 'node:assert/strict';
import { once } from 'node:events';
import { test } from 'node:test';
import { serve } from '@hono/node-server';
import { createBatchApp } from './batch-http.js';
import { seedFactory } from './batch-runtime.js';
import type { Batch } from './batch-state.js';
import { loadFreeze } from './contract-freeze.js';
import fixture from './contracts/print-portal-v2.fixture.json';
import { TrialControl } from './trial-control.js';

const responseSchema = loadFreeze();
function responseDef(response: Response, path: string) {
  if (response.status >= 400) return 'BatchError';
  const route = path.split('?')[0] ?? '';
  if (route === '/batches') return 'BatchListResponse';
  if (route === '/batches/open') return 'OpenBatchResponse';
  return route.startsWith('/monthly-closes/') ? 'BatchCloseResponse' : 'BatchResponse';
}
async function validated(response: Response, path: string) {
  if ((response.headers.get('content-type') ?? '').includes('application/json'))
    responseSchema.validate(responseDef(response, path), await response.clone().json());
  return response;
}

test('JSON routes use real HTTP auth, session epoch, visibility, ETag and replay', async () => {
  const batch = structuredClone(fixture.batches[0]) as Batch;
  const control = new TrialControl(seedFactory(loadFreeze()));
  const epoch = control.reset({
    boot_id: control.boot_id,
    generation: 0,
    trial_id: 'http-test',
    scenario: 'flow',
  });
  control.start({ boot_id: epoch.boot_id, generation: epoch.generation, trial_id: 'http-test' });
  const token = 'synthetic-test-token-not-a-credential';
  const app = createBatchApp({ control, token });
  const server = serve({ fetch: app.fetch, hostname: '127.0.0.1', port: 0 });
  await once(server, 'listening');
  const addr = server.address();
  assert.ok(addr && typeof addr === 'object');
  const origin = `http://127.0.0.1:${addr.port}/api/print-portal/v2`;
  const req = (path: string, init: RequestInit = {}) =>
    fetch(origin + path, {
      ...init,
      headers: { Authorization: `Bearer ${token}`, ...init.headers },
    }).then((r) => validated(r, path));
  try {
    assert.equal((await validated(await fetch(`${origin}/batches`), '/batches')).status, 401);
    const get = await req('/batches/open');
    assert.equal(get.status, 200);
    const etag = get.headers.get('etag');
    assert.equal(etag, `"${batch.id}:1"`);
    assert.equal(get.headers.get('cache-control'), 'no-store');
    assert.equal((await get.json()).batch.id, batch.id);
    assert.equal((await req('/batches?limit=0')).status, 400);
    assert.equal((await req('/batches?cursor=forged')).status, 400);
    const command = {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'If-Match': etag ?? '',
        'Idempotency-Key': '00000000-0000-4000-8000-000000000001',
      },
      body: '{}',
    };
    const first = await req(`/batches/${batch.id}/collected`, command);
    assert.equal(first.status, 200);
    assert.equal((await first.json()).batch.status, 'files_collected');
    assert.deepEqual(await (await req('/batches/open')).json(), { batch: null });
    assert.equal((await (await req('/batches')).json()).items[0].status, 'files_collected');
    const replay = await req(`/batches/${batch.id}/collected`, command);
    assert.equal(replay.status, 200);
    assert.equal(replay.headers.get('idempotency-replayed'), 'true');
    const stale = await req(`/batches/${batch.id}/collected`, {
      ...command,
      headers: { ...command.headers, 'Idempotency-Key': '00000000-0000-4000-8000-000000000002' },
    });
    assert.equal(stale.status, 412);
    assert.equal(
      (await req(`/batches/${batch.id}/collected`, { ...command, body: '{"extra":1}' })).status,
      400,
    );
    assert.equal((await req(`/batches/${batch.id}/collected`)).status, 405);
    assert.equal((await req('/batches/00000000-0000-4000-8000-000000000999')).status, 404);
    assert.equal(control.current().memberStatus(batch.items[0].orderId), 'in_progress');
  } finally {
    server.close();
    if ('closeAllConnections' in server) server.closeAllConnections();
    await once(server, 'close');
  }
});

test('real HTTP multipart + downloads + committed-503 replay + monthly invoice', async () => {
  const freeze = loadFreeze();
  const control = new TrialControl(seedFactory(freeze));
  const stamp = { boot_id: control.boot_id, generation: 0, trial_id: 'full-http' };
  const epoch = control.reset({ ...stamp, scenario: 'flow' });
  control.start({ ...stamp, generation: epoch.generation });
  const s = control.current();
  const id = freeze.fixture.batches[0].id;
  const token = 'synthetic-http-only-token-never-real';
  const server = serve({
    fetch: createBatchApp({ control, token }).fetch,
    hostname: '127.0.0.1',
    port: 0,
  });
  await once(server, 'listening');
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  const root = `http://127.0.0.1:${address.port}/api/print-portal/v2`;
  const req = (path: string, init: RequestInit = {}) =>
    fetch(root + path, {
      ...init,
      headers: { Authorization: `Bearer ${token}`, ...init.headers },
    }).then((r) => validated(r, path));
  const pdf = freeze.assets.get('00000000-0000-4000-8000-0000000000c8');
  assert.ok(pdf);
  const key = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const post = (path: string, etag: string, k: string, value: unknown) =>
    req(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'If-Match': etag, 'Idempotency-Key': k },
      body: JSON.stringify(value),
    });
  const form = (
    field: string,
    amount: string,
    bytes: Uint8Array = pdf,
    mime = 'application/pdf',
  ) => {
    const body = new FormData();
    body.set(field, amount);
    body.set('file', new Blob([new Uint8Array(bytes)], { type: mime }), 'synthetic.pdf');
    return body;
  };
  try {
    const original = s.etag(id);
    s.checkpoint('revise-open');
    assert.equal((await post(`/batches/${id}/collected`, original, key(1), {})).status, 412);
    const race = await Promise.all(
      [2, 3].map((n) => post(`/batches/${id}/collected`, s.etag(id), key(n), {})),
    );
    assert.deepEqual(race.map((r) => r.status).sort(), [200, 412]);
    for (const r of race) await r.arrayBuffer();
    s.checkpoint('publish-queued');
    assert.equal((await (await req('/batches')).json()).items.length, 1);
    const qp = s.etag(id),
      qk = key(4);
    s.checkpoint('quote-commit-503');
    const send = (body: FormData, k = qk, auth = token) =>
      req(`/batches/${id}/quotes`, {
        method: 'POST',
        headers: { 'If-Match': qp, 'Idempotency-Key': k, Authorization: `Bearer ${auth}` },
        body,
      });
    assert.equal((await send(form('amountCents', '45900'))).status, 503);
    const replay = await send(form('amountCents', '45900'));
    assert.equal(replay.status, 201);
    assert.equal(replay.headers.get('idempotency-replayed'), 'true');
    const qbody = await replay.json();
    freeze.validate('BatchResponse', qbody);
    assert.equal(qbody.batch.currentQuote.revision, 1);
    assert.equal((await send(form('amountCents', '45900'), qk, 'wrong')).status, 401);
    assert.equal((await send(form('amountCents', '45901'))).status, 409);
    const quote = await req(`/batches/${id}/quotes/${qbody.batch.currentQuote.id}/file`);
    assert.equal(quote.headers.get('content-length'), String(pdf.length));
    assert.equal(quote.headers.get('content-type'), 'application/pdf');
    assert.equal(quote.headers.get('x-content-type-options'), 'nosniff');
    assert.match(quote.headers.get('content-disposition') ?? '', /^attachment;/);
    assert.deepEqual(Buffer.from(await quote.arrayBuffer()), pdf);
    s.checkpoint('reject-quote');
    const q2 = await req(`/batches/${id}/quotes`, {
      method: 'POST',
      headers: { 'If-Match': s.etag(id), 'Idempotency-Key': key(5) },
      body: form('amountCents', '45900'),
    });
    assert.equal(q2.status, 201);
    const second = await q2.json();
    assert.equal(second.batch.currentQuote.revision, 2);
    s.checkpoint('approve-quote');
    assert.equal(
      (
        await post(`/batches/${id}/printed`, s.etag(id), key(6), {
          quoteId: second.batch.currentQuote.id,
        })
      ).status,
      200,
    );
    s.checkpoint('receive');
    assert.equal(
      (await (await req('/batches/open')).json()).batch.id,
      freeze.fixture.nextBatch.batch.id,
    );
    const month = await req('/monthly-closes/2026-09');
    const close = await month.json();
    freeze.validate('BatchCloseResponse', close);
    assert.equal(close.close.expectedTotalCents, 46900);
    const invoice = await req('/monthly-closes/2026-09/invoice', {
      method: 'POST',
      headers: { 'If-Match': month.headers.get('etag') ?? '', 'Idempotency-Key': key(7) },
      body: form('declaredTotalCents', '46900'),
    });
    assert.equal(invoice.status, 201);
    freeze.validate('BatchCloseResponse', await invoice.json());
    assert.deepEqual(
      Buffer.from(await (await req('/monthly-closes/2026-09/invoice')).arrayBuffer()),
      pdf,
    );
    const page = await (await req('/batches?limit=1')).json();
    assert.ok(page.nextCursor);
    assert.equal(
      (await (await req(`/batches?limit=1&cursor=${page.nextCursor}`)).json()).items.length,
      1,
    );
    assert.equal((await req('/api/print-batches')).status, 404);
  } finally {
    server.close();
    if ('closeAllConnections' in server) server.closeAllConnections();
    await once(server, 'close');
  }
});

test('multipart limits and type checks reject malformed data without state change', async () => {
  const freeze = loadFreeze();
  const control = new TrialControl(seedFactory(freeze));
  const epoch = control.reset({
    boot_id: control.boot_id,
    generation: 0,
    trial_id: 'uploads',
    scenario: 'flow',
  });
  control.start({ boot_id: epoch.boot_id, generation: epoch.generation, trial_id: 'uploads' });
  const s = control.current();
  const id = freeze.fixture.batches[0].id;
  s.collect(id, { etag: s.etag(id), key: '00000000-0000-4000-8000-000000000001' });
  const token = 'synthetic-only-upload-negative-test';
  const server = serve({
    fetch: createBatchApp({ control, token }).fetch,
    hostname: '127.0.0.1',
    port: 0,
  });
  await once(server, 'listening');
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  const url = `http://127.0.0.1:${address.port}/api/print-portal/v2/batches/${id}/quotes`;
  let n = 2;
  const send = (body: FormData) =>
    fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'If-Match': s.etag(id),
        'Idempotency-Key': `00000000-0000-4000-8000-${String(n++).padStart(12, '0')}`,
      },
      body,
    });
  const form = (mime: string, bytes: Uint8Array) => {
    const b = new FormData();
    b.set('amountCents', '1');
    b.set('file', new Blob([new Uint8Array(bytes)], { type: mime }), 'test.pdf');
    return b;
  };
  try {
    assert.equal((await send(form('application/pdf', Buffer.from('not pdf')))).status, 415);
    assert.equal((await send(form('text/plain', Buffer.from('%PDF-test')))).status, 415);
    assert.equal(
      (await send(form('application/pdf', Buffer.alloc(5 * 1024 * 1024 + 1)))).status,
      413,
    );
    assert.equal((await send(form('application/pdf', Buffer.alloc(6 * 1024 * 1024)))).status, 413);
    const duplicate = form('application/pdf', Buffer.from('%PDF-test'));
    duplicate.append('amountCents', '2');
    assert.equal((await send(duplicate)).status, 400);
    assert.equal(s.get(id).status, 'files_collected');
    // Same signature/MIME checks for allowed images, but no image transcode in the fake.
    const image = form('image/png', Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 0]));
    const accepted = await send(image);
    assert.equal(accepted.status, 201);
    const dto = await accepted.json();
    assert.equal(dto.batch.currentQuote.document.mime, 'image/png');
    assert.equal(dto.batch.currentQuote.document.bytes, 9);
  } finally {
    server.close();
    if ('closeAllConnections' in server) server.closeAllConnections();
    await once(server, 'close');
  }
});
