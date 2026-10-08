import type { Download } from '../adapters/print-api.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Stream one file of the order's current revision. Does not mark collection. */
export function downloadOrderFile(
  deps: PrintDeps,
  input: { readonly orderId: string; readonly fileId: string },
): Promise<Download> {
  return inSpan(
    deps.observability.tracer,
    'downloadOrderFile',
    { 'print.order.id': input.orderId, 'print.file.id': input.fileId },
    async (span) => {
      const download = await deps.printApi.downloadOrderFile(input.orderId, input.fileId);
      span.setAttribute('print.file.size', download.size);
      return download;
    },
  );
}
