import type { Tagged } from '../adapters/print-api.js';
import { ACTIVE_BATCH_STATUSES, type Batch } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/**
 * The ONE batch the print shop works on: the open batch, or — since
 * `GET /batches/open` is null while a collected…printed batch is active —
 * that active batch. Null when there is none. Read-only: never collects or
 * creates a batch.
 */
export function getCurrentBatch(deps: PrintDeps): Promise<Tagged<Batch> | null> {
  return inSpan(deps.observability.tracer, 'getCurrentBatch', {}, async (span) => {
    const open = await deps.printApi.getOpenBatch();
    if (open) {
      span.setAttribute('print.batch.status', open.value.status);
      return open;
    }
    for (const status of ACTIVE_BATCH_STATUSES) {
      const page = await deps.printApi.listBatches({ status, limit: 1 });
      const active = page.items[0];
      if (active) {
        span.setAttribute('print.batch.status', active.status);
        return deps.printApi.getBatch(active.id);
      }
    }
    span.setAttribute('print.batch.status', 'none');
    return null;
  });
}
