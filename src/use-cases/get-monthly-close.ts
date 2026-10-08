import type { Tagged } from '../adapters/print-api.js';
import type { MonthlyClose } from '../domain/monthly-close.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** The supplier's close for a competence (virtual and empty if nothing was printed). */
export function getMonthlyClose(
  deps: PrintDeps,
  competence: string,
): Promise<Tagged<MonthlyClose>> {
  return inSpan(
    deps.observability.tracer,
    'getMonthlyClose',
    { 'print.close.competence': competence },
    () => deps.printApi.getMonthlyClose(competence),
  );
}
