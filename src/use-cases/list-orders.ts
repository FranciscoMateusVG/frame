import type { ListOrdersQuery } from '../adapters/print-api.js';
import type { OrderPage } from '../domain/print-order.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** The print shop's order queue, oldest first, keyset-paginated upstream. */
export function listOrders(deps: PrintDeps, query: ListOrdersQuery): Promise<OrderPage> {
  return inSpan(
    deps.observability.tracer,
    'listOrders',
    { 'print.list.limit': query.limit, 'print.list.status': query.status ?? 'all' },
    async (span) => {
      const page = await deps.printApi.listOrders(query);
      span.setAttribute('print.list.count', page.items.length);
      return page;
    },
  );
}
