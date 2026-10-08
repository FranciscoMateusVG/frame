import type { Download } from '../adapters/print-api.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/** Stream the latest NF proposal of a competence. */
export function downloadInvoice(deps: PrintDeps, competence: string): Promise<Download> {
  return inSpan(
    deps.observability.tracer,
    'downloadInvoice',
    { 'print.close.competence': competence },
    async (span) => {
      const download = await deps.printApi.downloadInvoice(competence);
      span.setAttribute('print.file.size', download.size);
      return download;
    },
  );
}
