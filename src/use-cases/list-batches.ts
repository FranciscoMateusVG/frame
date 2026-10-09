import type { ListBatchesQuery } from '../adapters/print-api.js';
import type { BatchPage } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** The print shop's batch history, oldest first, keyset-paginated upstream. */
export function listBatches(deps: PrintDeps, query: ListBatchesQuery): Promise<BatchPage> {
  return inSpan(
    deps.observability.tracer,
    'listBatches',
    { 'print.list.limit': query.limit, 'print.list.status': query.status ?? 'all' },
    async (span) => {
      const page = await deps.printApi.listBatches(query);
      span.setAttribute('print.list.count', page.items.length);
      return page;
    },
  );
}
