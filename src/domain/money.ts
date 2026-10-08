/**
 * BRL money as integer cents (spec §4: no floats, max 2,147,483,647).
 *
 * The print shop types amounts the Brazilian way ("1.234,56"); the API
 * speaks integer cents. Parsing is strict: anything ambiguous is rejected
 * rather than guessed.
 */

export const MAX_CENTS = 2_147_483_647;

/** A positive integer number of cents, as accepted by the service API. */
export function isValidCents(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= MAX_CENTS;
}

/** Decimal string of a positive integer cents value ("12345"), or null. */
export function parseCentsString(raw: string): number | null {
  if (!/^[1-9][0-9]{0,9}$/.test(raw)) return null;
  const value = Number(raw);
  return isValidCents(value) ? value : null;
}

/**
 * Parse a BRL amount typed by a person into cents.
 *
 * Accepted: "1234", "1234,5", "1234,56", "1.234,56", "R$ 1.234,56".
 * Rejected: "1,234.56", "12.34" (dot is a thousands separator in pt-BR),
 * misplaced thousands groups, more than two decimals, zero, negatives.
 */
export function parseBrlToCents(input: string): number | null {
  const text = input
    .trim()
    .replace(/^R\$\s*/i, '')
    .trim();
  const match = /^(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d{1,2}))?$/.exec(text);
  if (!match) return null;
  const [, integerPart = '', decimals = ''] = match;
  const digits = integerPart.replaceAll('.', '');
  if (digits.length > 10) return null;
  const cents = Number(digits) * 100 + Number(decimals.padEnd(2, '0'));
  return isValidCents(cents) ? cents : null;
}

/** Format cents as "R$ 1.234,56". */
export function formatCents(cents: number): string {
  const negative = cents < 0;
  const abs = Math.abs(Math.trunc(cents));
  const reais = Math.floor(abs / 100)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  const centavos = (abs % 100).toString().padStart(2, '0');
  return `${negative ? '-' : ''}R$ ${reais},${centavos}`;
}
