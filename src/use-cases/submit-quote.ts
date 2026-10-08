import type { CommandResult, Preconditions, Upload } from '../adapters/print-api.js';
import type { Order } from '../domain/print-order.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Submit a quote (amount + document) for the order's current revision. */
export function submitQuote(
  deps: PrintDeps,
  input: {
    readonly orderId: string;
    readonly orderRevision: number;
    readonly amountCents: number;
    readonly file: Upload;
  },
  pre: Preconditions,
): Promise<CommandResult<Order>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'submitQuote',
    {
      'print.order.id': input.orderId,
      'print.order.revision': input.orderRevision,
      'print.document.size': input.file.bytes.byteLength,
    },
    async (span) => {
      const result = await printApi.submitQuote(
        input.orderId,
        { amountCents: input.amountCents, orderRevision: input.orderRevision, file: input.file },
        pre,
      );
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('print_order.quote_submitted', {
        orderId: input.orderId,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
