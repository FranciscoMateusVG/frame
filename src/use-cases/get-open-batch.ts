import type { Tagged } from '../adapters/print-api.js';
import type { Batch } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** The open batch, or null (none, or a collected…printed batch is active). */
export function getOpenBatch(deps: PrintDeps): Promise<Tagged<Batch> | null> {
  return inSpan(deps.observability.tracer, 'getOpenBatch', {}, () => deps.printApi.getOpenBatch());
}
