import type { Tagged } from '../adapters/print-api.js';
import type { Batch } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** One batch (current or historical) with its ETag. */
export function getBatch(deps: PrintDeps, batchId: string): Promise<Tagged<Batch>> {
  return inSpan(deps.observability.tracer, 'getBatch', { 'print.batch.id': batchId }, () =>
    deps.printApi.getBatch(batchId),
  );
}
