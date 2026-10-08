/**
 * Monthly invoice close (spec print-portal §3.5, §4.2 `Close`).
 *
 * Competence is `YYYY-MM` in America/Sao_Paulo. Only a closed period
 * (after the end of the month) accepts an invoice; the current month can be
 * consulted but not closed.
 */

export const CLOSE_STATES = ['open', 'submitted', 'rejected', 'accepted'] as const;
export type CloseState = (typeof CLOSE_STATES)[number];

export interface CloseItem {
  readonly orderId: string;
  readonly reference: string;
  readonly quoteId: string;
  readonly amountCents: number;
  readonly printedAt: string;
}

export interface CloseDocument {
  readonly id: string;
  readonly name: string;
  readonly mime: string;
  readonly bytes: number;
  readonly sha256: string;
}

export interface MonthlyClose {
  readonly id: string | null;
  readonly competence: string;
  readonly version: number;
  readonly state: CloseState;
  readonly periodClosed: boolean;
  readonly items: readonly CloseItem[];
  readonly expectedTotalCents: number;
  readonly declaredTotalCents: number | null;
  readonly document: CloseDocument | null;
  readonly rejectionReason: string | null;
  readonly submittedAt: string | null;
  readonly acceptedAt: string | null;
}

export const CLOSE_STATE_LABELS: Readonly<Record<CloseState, string>> = {
  open: 'Aberto',
  submitted: 'Aguardando conferência',
  rejected: 'NF rejeitada',
  accepted: 'NF aceita',
};

const COMPETENCE = /^(\d{4})-(0[1-9]|1[0-2])$/;

export function isValidCompetence(value: string): boolean {
  const match = COMPETENCE.exec(value);
  return match !== null && Number(match[1]) >= 2000;
}

/** Competence (`YYYY-MM`) containing `instant`, in America/Sao_Paulo. */
export function competenceOf(instant: Date): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
  }).formatToParts(instant);
  const year = parts.find((p) => p.type === 'year')?.value ?? '0000';
  const month = parts.find((p) => p.type === 'month')?.value ?? '00';
  return `${year}-${month}`;
}

/** The competence immediately before `competence`. */
export function previousCompetence(competence: string): string {
  const [year = 0, month = 1] = competence.split('-').map(Number);
  return month === 1 ? `${year - 1}-12` : `${year}-${String(month - 1).padStart(2, '0')}`;
}

/** The competence immediately after `competence`. */
export function nextCompetence(competence: string): string {
  const [year = 0, month = 1] = competence.split('-').map(Number);
  return month === 12 ? `${year + 1}-01` : `${year}-${String(month + 1).padStart(2, '0')}`;
}

/** Whether the UI may offer the invoice upload for this close. */
export function canSubmitInvoice(close: MonthlyClose): boolean {
  return (
    close.periodClosed &&
    close.items.length > 0 &&
    (close.state === 'open' || close.state === 'rejected')
  );
}
