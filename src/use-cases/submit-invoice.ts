import type { CommandResult, Preconditions, Upload } from '../adapters/print-api.js';
import type { MonthlyClose } from '../domain/monthly-close.js';
import { inSpan } from './in-span.js';
import type { PrintDeps } from './print-deps.js';

/**
 * Submit the monthly NF proposal (declared total + document). A proposal
 * only: Financeiro decides, and nothing contábil changes until then.
 */
export function submitInvoice(
  deps: PrintDeps,
  input: {
    readonly competence: string;
    readonly declaredTotalCents: number;
    readonly file: Upload;
  },
  pre: Preconditions,
): Promise<CommandResult<MonthlyClose>> {
  const { printApi, observability } = deps;
  return inSpan(
    observability.tracer,
    'submitInvoice',
    {
      'print.close.competence': input.competence,
      'print.document.size': input.file.bytes.byteLength,
    },
    async (span) => {
      const result = await printApi.submitInvoice(
        input.competence,
        { declaredTotalCents: input.declaredTotalCents, file: input.file },
        pre,
      );
      span.setAttribute('print.command.replayed', result.replayed);
      observability.logger.info('monthly_close.invoice_submitted', {
        competence: input.competence,
        replayed: result.replayed,
      });
      return result;
    },
  );
}
