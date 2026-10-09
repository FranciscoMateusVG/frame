import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { loadFreeze } from './contract-freeze.js';

test('freeze verifies raw files, all seven asset bytes and schema before serving', () => {
  const f = loadFreeze();
  assert.equal(f.manifest.source_sha, '270224676d61431c2d26a8e20ec911c328a1f5f3');
  assert.equal(f.assets.size, 7);
  assert.match(f.bundleHash, /^[a-f0-9]{64}$/);
  for (const b of f.fixture.batches) f.validate('Batch', b);
  f.validate('BatchCloseResponse', f.fixture.monthlyClose);
  f.validate('BatchItem', f.fixture.queuedItem);
  f.validate('BatchResponse', f.fixture.nextBatch);
  f.validate('BatchResponse', f.fixture.rebatchedBatch);
  assert.throws(() => f.validate('Batch', { ...f.fixture.batches[0], extra: true }));
  assert.equal(f.fixture.rebatchedBatch.batch.items.length, 2);
  assert.equal(f.fixture.nextBatch.batch.items[0].orderId, f.fixture.queuedItem.orderId);
});

test('tampered PDF, missing files or source drift fail closed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ttp-freeze-'));
  try {
    cpSync(new URL('./contracts/', import.meta.url), dir, { recursive: true });
    const pdf = join(dir, 'print-portal-v2.assets/00000000-0000-4000-8000-00000000000b.pdf');
    const original = readFileSync(pdf);
    writeFileSync(pdf, Buffer.concat([original, Buffer.from('drift')]));
    assert.throws(() => loadFreeze(dir), /FROZEN_FILE_DRIFT/);
    writeFileSync(pdf, original);
    assert.equal(loadFreeze(dir).assets.size, 7);
    const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
    manifest.source_sha = '0'.repeat(40);
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest));
    assert.throws(() => loadFreeze(dir), /FROZEN_SOURCE_DRIFT/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
