import type { PrintApi } from '../adapters/print-api.js';
import type { Observability } from '../observability/observability.js';

/** Dependencies of the print-order and monthly-close use cases. */
export interface PrintDeps {
  readonly printApi: PrintApi;
  readonly observability: Observability;
}
