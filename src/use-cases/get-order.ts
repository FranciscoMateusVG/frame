import type { Tagged } from '../adapters/print-api.js';
import type { Order } from '../domain/print-order.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** One order with its jobs and current quote, plus its ETag. */
export function getOrder(deps: PrintDeps, orderId: string): Promise<Tagged<Order>> {
  return inSpan(deps.observability.tracer, 'getOrder', { 'print.order.id': orderId }, () =>
    deps.printApi.getOrder(orderId),
  );
}
