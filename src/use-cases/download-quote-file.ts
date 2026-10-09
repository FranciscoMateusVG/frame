import type { Download } from '../adapters/print-api.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Stream the document of the batch's current quote. */
export function downloadQuoteFile(
  deps: PrintDeps,
  input: { readonly batchId: string; readonly quoteId: string },
): Promise<Download> {
  return inSpan(
    deps.observability.tracer,
    'downloadQuoteFile',
    { 'print.batch.id': input.batchId, 'print.quote.id': input.quoteId },
    async (span) => {
      const download = await deps.printApi.downloadQuoteFile(input.batchId, input.quoteId);
      span.setAttribute('print.file.size', download.size);
      return download;
    },
  );
}
