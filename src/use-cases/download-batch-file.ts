import type { Download } from '../adapters/print-api.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Stream one file of a batch member request. Does not mark collection. */
export function downloadBatchFile(
  deps: PrintDeps,
  input: { readonly batchId: string; readonly orderId: string; readonly fileId: string },
): Promise<Download> {
  return inSpan(
    deps.observability.tracer,
    'downloadBatchFile',
    {
      'print.batch.id': input.batchId,
      'print.order.id': input.orderId,
      'print.file.id': input.fileId,
    },
    async (span) => {
      const download = await deps.printApi.downloadBatchFile(
        input.batchId,
        input.orderId,
        input.fileId,
      );
      span.setAttribute('print.file.size', download.size);
      return download;
    },
  );
}
