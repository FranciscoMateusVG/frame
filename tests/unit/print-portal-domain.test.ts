import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { sniffDocumentMime } from '../../src/domain/document-type.js';
import {
  formatCents,
  MAX_CENTS,
  parseBrlToCents,
  parseCentsString,
} from '../../src/domain/money.js';
import {
  canSubmitInvoice,
  competenceOf,
  isValidCompetence,
  type MonthlyClose,
  nextCompetence,
  previousCompetence,
} from '../../src/domain/monthly-close.js';
import {
  DEFAULT_SESSION_POLICY,
  isSessionExpired,
  sessionExpiresAt,
} from '../../src/domain/portal-session.js';
import {
  availableAction,
  BATCH_PROGRESS_STEPS,
  BATCH_STATUSES,
  fileCount,
  isBatchStatus,
  itemFiles,
  progressStep,
  totalCopies,
  waitingMessage,
} from '../../src/domain/print-batch.js';
import { PDF_BYTES, PNG_BYTES } from '../helpers/print-fixtures.js';
import { fixtureBatch } from '../helpers/print-v2-fixture.js';

describe('money', () => {
  it.each([
    ['1234', 123_400],
    ['1234,5', 123_450],
    ['1234,56', 123_456],
    ['1.234,56', 123_456],
    ['R$ 1.234,56', 123_456],
    ['r$1,00', 100],
    ['  0,01 ', 1],
    ['21.474.836,47', MAX_CENTS],
  ])('parses %s', (input, cents) => {
    expect(parseBrlToCents(input)).toBe(cents);
  });

  it.each([
    '',
    '0',
    '0,00',
    '-1',
    '12.34',
    '1,234.56',
    '1.23,45',
    '1,234',
    '12,345',
    'abc',
    '21.474.836,48',
    '1e3',
  ])('rejects %s', (input) => {
    expect(parseBrlToCents(input)).toBeNull();
  });

  it('formatCents ∘ parseBrlToCents is the identity on valid cents', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: MAX_CENTS }), (cents) => {
        expect(parseBrlToCents(formatCents(cents))).toBe(cents);
      }),
    );
  });

  it('formats negative and small values', () => {
    expect(formatCents(5)).toBe('R$ 0,05');
    expect(formatCents(-123_456)).toBe('-R$ 1.234,56');
  });

  it('parseCentsString accepts only canonical positive integers within range', () => {
    expect(parseCentsString('45900')).toBe(45_900);
    for (const bad of ['0', '01', '1.5', '-1', '2147483648', '', ' 1']) {
      expect(parseCentsString(bad)).toBeNull();
    }
  });
});

describe('monthly close', () => {
  it('competence is the São Paulo month', () => {
    expect(competenceOf(new Date('2026-10-01T02:59:59Z'))).toBe('2026-09');
    expect(competenceOf(new Date('2026-10-01T03:00:00Z'))).toBe('2026-10');
  });

  it('validates and steps competences', () => {
    expect(isValidCompetence('2026-09')).toBe(true);
    for (const bad of ['2026-13', '2026-00', '2026-9', '1999-12', 'x'])
      expect(isValidCompetence(bad)).toBe(false);
    expect(previousCompetence('2026-01')).toBe('2025-12');
    expect(previousCompetence('2026-10')).toBe('2026-09');
    expect(nextCompetence('2026-12')).toBe('2027-01');
    expect(nextCompetence('2026-09')).toBe('2026-10');
  });

  it('offers the invoice only for a closed, non-empty, open/rejected close', () => {
    const base: MonthlyClose = {
      id: null,
      competence: '2026-09',
      version: 1,
      state: 'open',
      periodClosed: true,
      items: [
        {
          kind: 'batch',
          batchId: 'b',
          reference: 'LOT-0001',
          quoteId: 'q',
          amountCents: 1,
          printedAt: '2026-09-01T00:00:00Z',
        },
      ],
      expectedTotalCents: 1,
      declaredTotalCents: null,
      document: null,
      rejectionReason: null,
      submittedAt: null,
      acceptedAt: null,
    };
    expect(canSubmitInvoice(base)).toBe(true);
    expect(canSubmitInvoice({ ...base, state: 'rejected' })).toBe(true);
    expect(canSubmitInvoice({ ...base, state: 'submitted' })).toBe(false);
    expect(canSubmitInvoice({ ...base, periodClosed: false })).toBe(false);
    expect(canSubmitInvoice({ ...base, items: [] })).toBe(false);
  });
});

describe('batch rules', () => {
  it('maps status to the single supplier action or a waiting message, never both', () => {
    const approved = { decision: 'approved' } as never;
    expect(availableAction({ status: 'open', currentQuote: null })).toBe('collect');
    expect(availableAction({ status: 'files_collected', currentQuote: null })).toBe('upload-quote');
    expect(availableAction({ status: 'quote_rejected', currentQuote: null })).toBe('upload-quote');
    expect(availableAction({ status: 'quote_approved', currentQuote: approved })).toBe(
      'mark-printed',
    );
    expect(availableAction({ status: 'quote_approved', currentQuote: null })).toBeNull();
    for (const s of ['quote_pending', 'printed', 'received', 'cancelled'] as const) {
      expect(availableAction({ status: s, currentQuote: null })).toBeNull();
    }
    expect(waitingMessage('quote_pending')).toBe('Aguardando aprovação do Financeiro');
    expect(waitingMessage('printed')).toBe('Aguardando recebimento');
    for (const s of BATCH_STATUSES) {
      if (availableAction({ status: s, currentQuote: approved })) {
        expect(waitingMessage(s)).toBeNull();
      }
    }
    expect(BATCH_STATUSES.every(isBatchStatus)).toBe(true);
    expect(isBatchStatus('ready')).toBe(false);
  });

  it('progress: one step per stage; history-only states have none', () => {
    expect(BATCH_PROGRESS_STEPS).toHaveLength(5);
    expect(progressStep('open')).toBe(0);
    expect(progressStep('files_collected')).toBe(1);
    expect(progressStep('quote_pending')).toBe(2);
    expect(progressStep('quote_rejected')).toBe(2);
    expect(progressStep('quote_approved')).toBe(3);
    expect(progressStep('printed')).toBe(4);
    expect(progressStep('received')).toBe(-1);
    expect(progressStep('cancelled')).toBe(-1);
  });

  it('files: jobs first then residual files; copies only from paired jobs', () => {
    const batch = fixtureBatch('open');
    const item = batch.items[0];
    expect(item && itemFiles(item).map((f) => [f.file.id, f.job?.copies ?? null])).toEqual([
      ['00000000-0000-4000-8000-00000000000b', 24],
      ['00000000-0000-4000-8000-00000000000c', 12],
      ['00000000-0000-4000-8000-00000000000d', null],
    ]);
    expect(fileCount(batch)).toBe(3);
    expect(totalCopies(batch)).toBe(36);
  });
});

describe('session expiry', () => {
  it('expires at the earlier of idle and absolute', () => {
    const t0 = new Date('2026-10-08T00:00:00Z');
    const fresh = { id: 'a', csrfToken: 'b', authenticated: true, createdAt: t0, lastSeenAt: t0 };
    expect(sessionExpiresAt(fresh, DEFAULT_SESSION_POLICY).toISOString()).toBe(
      '2026-10-08T00:30:00.000Z',
    );
    const busy = { ...fresh, lastSeenAt: new Date('2026-10-08T07:50:00Z') };
    expect(sessionExpiresAt(busy, DEFAULT_SESSION_POLICY).toISOString()).toBe(
      '2026-10-08T08:00:00.000Z',
    );
    expect(isSessionExpired(busy, DEFAULT_SESSION_POLICY, new Date('2026-10-08T08:00:00Z'))).toBe(
      true,
    );
    expect(isSessionExpired(busy, DEFAULT_SESSION_POLICY, new Date('2026-10-08T07:59:59Z'))).toBe(
      false,
    );
  });
});

describe('document type', () => {
  it('sniffs the accepted document types from their magic bytes only', () => {
    expect(sniffDocumentMime(PDF_BYTES)).toBe('application/pdf');
    expect(sniffDocumentMime(PNG_BYTES)).toBe('image/png');
    expect(sniffDocumentMime(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))).toBe('image/jpeg');
    expect(sniffDocumentMime(new TextEncoder().encode('RIFF\0\0\0\0WEBPVP8 '))).toBe('image/webp');
    for (const other of ['', '<html>', '%PD', 'RIFF\0\0\0\0WAVE']) {
      expect(sniffDocumentMime(new TextEncoder().encode(other)), other).toBeNull();
    }
  });
});
