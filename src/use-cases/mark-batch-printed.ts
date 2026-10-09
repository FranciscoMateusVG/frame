import type { CommandResult, Preconditions } from '../adapters/print-api.js';
import type { Batch } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Declare the batch printed against its approved quote (quote_approved → printed). */
export function markBatchPrinted(
  deps: PrintDeps,
  input: { readonly batchId: string; readonly quoteId: string },
  pre: Preconditions,
): Promise<CommandResult<Batch>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'markBatchPrinted',
    { 'print.batch.id': input.batchId, 'print.quote.id': input.quoteId },
    async (span) => {
      const result = await printApi.markPrinted(input.batchId, { quoteId: input.quoteId }, pre);
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('print_batch.printed', {
        batchId: input.batchId,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
