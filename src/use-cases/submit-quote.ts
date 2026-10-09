import type { CommandResult, Preconditions, Upload } from '../adapters/print-api.js';
import type { Batch } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Submit one quote (total amount + document) for the whole batch. */
export function submitQuote(
  deps: PrintDeps,
  input: { readonly batchId: string; readonly amountCents: number; readonly file: Upload },
  pre: Preconditions,
): Promise<CommandResult<Batch>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'submitQuote',
    { 'print.batch.id': input.batchId, 'print.document.size': input.file.bytes.byteLength },
    async (span) => {
      const result = await printApi.submitQuote(
        input.batchId,
        { amountCents: input.amountCents, file: input.file },
        pre,
      );
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('print_batch.quote_submitted', {
        batchId: input.batchId,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
