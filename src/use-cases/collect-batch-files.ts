import type { CommandResult, Preconditions } from '../adapters/print-api.js';
import type { Batch } from '../domain/print-batch.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/**
 * The print shop declares it has collected every file of the batch it saw
 * (open → files_collected; If-Match freezes that exact membership). A
 * declaration, never inferred from downloads.
 */
export function collectBatchFiles(
  deps: PrintDeps,
  input: { readonly batchId: string },
  pre: Preconditions,
): Promise<CommandResult<Batch>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'collectBatchFiles',
    { 'print.batch.id': input.batchId },
    async (span) => {
      const result = await printApi.markCollected(input.batchId, pre);
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('print_batch.files_collected', {
        batchId: input.batchId,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
