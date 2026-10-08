import type { CommandResult, Preconditions } from '../adapters/print-api.js';
import type { Order } from '../domain/print-order.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Confirm printing of an order whose exact current quote was approved. */
export function markOrderPrinted(
  deps: PrintDeps,
  input: { readonly orderId: string; readonly revision: number; readonly quoteId: string },
  pre: Preconditions,
): Promise<CommandResult<Order>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'markOrderPrinted',
    {
      'print.order.id': input.orderId,
      'print.order.revision': input.revision,
      'print.quote.id': input.quoteId,
    },
    async (span) => {
      const result = await printApi.markPrinted(
        input.orderId,
        { revision: input.revision, quoteId: input.quoteId },
        pre,
      );
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('print_order.printed', {
        orderId: input.orderId,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
