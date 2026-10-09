// Raw upstream freeze, validated before constructing a runtime or opening listeners.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import type { Batch, BatchItem, FileDto } from './batch-state.js';
import type fixtureType from './contracts/print-portal-v2.fixture.json';

export const SOURCE_SHA = '270224676d61431c2d26a8e20ec911c328a1f5f3';
export const sha256 = (bytes: string | Uint8Array) =>
  createHash('sha256').update(bytes).digest('hex');
type Manifest = {
  source_repository: string;
  source_sha: string;
  files: Record<string, { source_path: string; bytes: number; sha256: string }>;
  deviations: string[];
};
export type FreezeFixture = Omit<
  typeof fixtureType,
  'batches' | 'queuedItem' | 'nextBatch' | 'rebatchedBatch'
> & {
  batches: Batch[];
  queuedItem: BatchItem;
  nextBatch: { batch: Batch };
  rebatchedBatch: { batch: Batch };
};
function requireFreeze(ok: unknown, code: string): asserts ok {
  if (!ok) throw new Error(code);
}
function fileObjects(value: unknown): FileDto[] {
  if (!value || typeof value !== 'object') return [];
  if ('sha256' in value && 'mime' in value && 'bytes' in value) return [value as FileDto];
  return Object.values(value).flatMap(fileObjects);
}
export function loadFreeze(root = fileURLToPath(new URL('./contracts/', import.meta.url))) {
  const rawManifest = readFileSync(join(root, 'manifest.json'));
  const manifest = JSON.parse(rawManifest.toString('utf8')) as Manifest;
  requireFreeze(manifest.source_sha === SOURCE_SHA, 'FROZEN_SOURCE_DRIFT');
  requireFreeze(
    manifest.source_repository === 'FranciscoMateusVG/monorepo-incluir',
    'FROZEN_SOURCE_DRIFT',
  );
  const raw = new Map<string, Buffer>();
  for (const [name, meta] of Object.entries(manifest.files)) {
    requireFreeze(
      /^[a-zA-Z0-9._/-]+$/.test(name) && !name.split('/').includes('..') && !name.startsWith('/'),
      'FROZEN_PATH_INVALID',
    );
    requireFreeze(
      meta.source_path === `apps/hono-app/docs/contracts/${name}`,
      'FROZEN_SOURCE_DRIFT',
    );
    const bytes = readFileSync(join(root, name));
    requireFreeze(
      bytes.length === meta.bytes && sha256(bytes) === meta.sha256,
      'FROZEN_FILE_DRIFT',
    );
    raw.set(name, bytes);
  }
  const json = (name: string) => {
    const bytes = raw.get(name);
    requireFreeze(bytes, 'FROZEN_FILE_MISSING');
    return JSON.parse(bytes.toString('utf8'));
  };
  const fixture = json('print-portal-v2.fixture.json') as FreezeFixture;
  const pairing: unknown = json('print-portal-v2.legacy-pairing.fixture.json');
  const schema = json('print-portal-v2.schema.json');
  const validators = new Map<string, z.ZodType>();
  function validate(def: string, value: unknown) {
    requireFreeze(Object.hasOwn(schema.$defs, def), 'FROZEN_SCHEMA_UNKNOWN');
    let validator = validators.get(def);
    if (!validator) {
      validator = z.fromJSONSchema({ ...schema, $ref: `#/$defs/${def}` });
      validators.set(def, validator);
    }
    requireFreeze(validator.safeParse(value).success, 'FROZEN_SCHEMA_INVALID');
  }
  const assets = new Map<string, Buffer>();
  const index = json('print-portal-v2.assets/index.json') as Record<string, string>;
  for (const [id, name] of Object.entries(index)) {
    requireFreeze(name === `${id}.pdf`, 'FROZEN_ASSET_PATH_INVALID');
    const bytes = raw.get(`print-portal-v2.assets/${name}`);
    requireFreeze(bytes?.subarray(0, 5).toString('ascii') === '%PDF-', 'FROZEN_ASSET_INVALID');
    requireFreeze(bytes.toString('ascii').includes('%%EOF'), 'FROZEN_ASSET_INVALID');
    assets.set(id, bytes);
  }
  requireFreeze(assets.size === 7, 'FROZEN_ASSET_COUNT');
  for (const file of fileObjects([fixture, pairing])) {
    const bytes = assets.get(file.id);
    requireFreeze(
      bytes &&
        file.mime === 'application/pdf' &&
        bytes.length === file.bytes &&
        sha256(bytes) === file.sha256,
      'FROZEN_ASSET_DRIFT',
    );
    validate('File', file);
  }
  for (const batch of [...fixture.batches, fixture.nextBatch.batch, fixture.rebatchedBatch.batch]) {
    validate('Batch', batch);
    requireFreeze(batch.itemCount === batch.items.length, 'FROZEN_ITEM_COUNT');
    requireFreeze(
      new Set(batch.items.map((i) => i.orderId)).size === batch.items.length,
      'FROZEN_ITEM_DUPLICATE',
    );
    for (const item of batch.items) {
      const files = fileObjects(item);
      requireFreeze(new Set(files.map((f) => f.id)).size === files.length, 'FROZEN_FILE_DUPLICATE');
    }
  }
  validate('BatchItem', fixture.queuedItem);
  validate('BatchCloseResponse', fixture.monthlyClose);
  return { manifest, bundleHash: sha256(rawManifest), fixture, pairing, assets, validate };
}
export type ContractFreeze = ReturnType<typeof loadFreeze>;
