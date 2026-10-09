/**
 * The FROZEN v2 batch fixture (monorepo-incluir #1053 @ 27022467, copied
 * verbatim to tests/helpers/print-portal-v2.fixture.json) and the real
 * synthetic PDFs every File.id maps to (vendored byte-exact, with
 * provenance, in infra/ttp/smoke-fixtures/print-portal-v2.assets).
 */
import { readFileSync } from 'node:fs';
import type { Batch, BatchItem, BatchStatus } from '../../src/domain/print-batch.js';

const read = (url: URL) => readFileSync(url);

export const V2_FIXTURE = JSON.parse(
  read(new URL('./print-portal-v2.fixture.json', import.meta.url)).toString('utf8'),
) as {
  readonly batches: readonly Batch[];
  readonly nextBatch: { readonly batch: Batch };
  readonly rebatchedBatch: { readonly batch: Batch };
  readonly queuedItem: BatchItem;
  readonly monthlyClose: { readonly close: unknown };
};

const ASSETS = new URL('../../infra/ttp/smoke-fixtures/print-portal-v2.assets/', import.meta.url);
const index = JSON.parse(read(new URL('index.json', ASSETS)).toString('utf8')) as Record<
  string,
  string
>;

/** Bytes of every fixture File.id. */
export const V2_ASSETS: ReadonlyMap<string, Uint8Array> = new Map(
  Object.entries(index).map(([id, name]) => [id, new Uint8Array(read(new URL(name, ASSETS)))]),
);

/** The frozen snapshot of the one synthetic batch in `status`. */
export function fixtureBatch(status: BatchStatus): Batch {
  const batch = V2_FIXTURE.batches.find((b) => b.status === status);
  if (!batch) throw new Error(`no fixture batch in ${status}`);
  return structuredClone(batch);
}
