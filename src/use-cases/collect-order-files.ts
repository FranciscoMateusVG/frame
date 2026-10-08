import type { CommandResult, Preconditions } from '../adapters/print-api.js';
import type { Order } from '../domain/print-order.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/**
 * The print shop declares it has collected every file of this revision
 * (ready → files_collected). A declaration, never inferred from downloads.
 */
export function collectOrderFiles(
  deps: PrintDeps,
  input: { readonly orderId: string; readonly revision: number },
  pre: Preconditions,
): Promise<CommandResult<Order>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'collectOrderFiles',
    { 'print.order.id': input.orderId, 'print.order.revision': input.revision },
    async (span) => {
      const result = await printApi.markCollected(input.orderId, { revision: input.revision }, pre);
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('print_order.files_collected', {
        orderId: input.orderId,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
