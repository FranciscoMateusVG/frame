/**
 * Server-rendered HTML for the print-shop portal (spec §7). Every dynamic
 * value goes through hono/html's escaping template; nothing is marked raw
 * except the constant markup below. No inline scripts or styles (CSP).
 */
import { html } from 'hono/html';
import type { HtmlEscapedString } from 'hono/utils/html';
import { formatCents } from '../domain/money.js';
import {
  CLOSE_STATE_LABELS,
  canSubmitInvoice,
  type MonthlyClose,
  nextCompetence,
  previousCompetence,
} from '../domain/monthly-close.js';
import {
  availableAction,
  BATCH_PROGRESS_STEPS,
  BATCH_STATUS_LABELS,
  type Batch,
  type BatchItem,
  type BatchPage,
  fileCount,
  itemFiles,
  type PrintFile,
  type PrintJob,
  progressStep,
  totalCopies,
  waitingMessage,
} from '../domain/print-batch.js';

type Html = HtmlEscapedString | Promise<HtmlEscapedString>;

export interface Banner {
  readonly kind: 'error' | 'info' | 'success';
  readonly text: string;
}

function layout(title: string, body: Html, nav?: { csrfToken: string; active: string }): Html {
  return html`<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} · Portal da gráfica</title>
<link rel="stylesheet" href="/assets/portal.css">
<script src="/assets/portal.js" defer></script>
</head>
<body>
<header class="top">
  <span class="brand">Portal da gráfica</span>
  ${
    nav
      ? html`<nav>
    <a href="/"${nav.active === 'home' ? html` aria-current="page"` : ''}>Lote atual</a>
    <a href="/batches"${nav.active === 'history' ? html` aria-current="page"` : ''}>Lotes anteriores</a>
    <a href="/invoices"${nav.active === 'invoices' ? html` aria-current="page"` : ''}>Notas fiscais</a>
    <form method="post" action="/logout" class="inline">
      <input type="hidden" name="_csrf" value="${nav.csrfToken}">
      <button type="submit" class="link">Sair</button>
    </form>
  </nav>`
      : ''
  }
</header>
<main>
${body}
</main>
</body>
</html>`;
}

function banner(b: Banner | undefined): Html | string {
  if (!b) return '';
  return html`<p class="banner ${b.kind}" role="${b.kind === 'error' ? 'alert' : 'status'}">${b.text}</p>`;
}

function dateTime(iso: string | null): string {
  if (!iso) return '—';
  return new Intl.DateTimeFormat('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    dateStyle: 'short',
    timeStyle: 'short',
  }).format(new Date(iso));
}

function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace('.', ',')} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1).replace('.', ',')} MB`;
}

// ── login ──

export function loginPage(csrfToken: string, b?: Banner): Html {
  return layout(
    'Entrar',
    html`<section class="card narrow">
  <h1>Entrar</h1>
  ${banner(b)}
  <form method="post" action="/login">
    <input type="hidden" name="_csrf" value="${csrfToken}">
    <label for="password">Senha</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required maxlength="1024">
    <button type="submit">Entrar</button>
  </form>
</section>`,
  );
}

// ── batch (home, history detail) ──

/** Form state for an action: reused verbatim after an ambiguous failure. */
export interface ActionForm {
  readonly idempotencyKey: string;
  readonly etag: string;
  readonly amountText?: string;
}

function plural(count: number, one: string, many: string): string {
  return `${count} ${count === 1 ? one : many}`;
}

function fileLine(href: string, file: PrintFile, label: string): Html {
  return html`<div class="file">
  <a class="button" href="${href}" download>${label}</a>
  <span class="filename">${file.name}</span>
  <span class="meta">${file.mime} · ${fileSize(file.bytes)}</span>
  <code class="sha" title="SHA-256">${file.sha256}</code>
</div>`;
}

function batchApi(batch: Batch): string {
  return `/api/print/v2/batches/${encodeURIComponent(batch.id)}`;
}

function progressBar(batch: Batch): Html | string {
  const reached = progressStep(batch.status);
  if (reached < 0) return '';
  return html`<ol class="progress" data-ttp="progress" aria-label="Andamento do lote">
  ${BATCH_PROGRESS_STEPS.map(
    (step, i) =>
      html`<li class="${i < reached ? 'done' : i === reached ? 'current' : 'todo'}"${i === reached ? html` aria-current="step"` : ''}>${step}</li>
`,
  )}
</ol>`;
}

function batchFacts(batch: Batch): Html {
  const row = (label: string, value: string | null) =>
    value === null ? '' : html`<dt>${label}</dt><dd>${dateTime(value)}</dd>`;
  return html`<dl class="facts">
  <dt>Status</dt><dd><span class="status ${batch.status}">${BATCH_STATUS_LABELS[batch.status]}</span></dd>
  ${row('Criado em', batch.createdAt)}
  ${row('Retirado em', batch.collectedAt)}
  ${row('Impresso em', batch.printedAt)}
  ${row('Recebido em', batch.receivedAt)}
  ${batch.approvedAmountCents === null ? '' : html`<dt>Valor aprovado</dt><dd>${formatCents(batch.approvedAmountCents)}</dd>`}
</dl>`;
}

function quoteBlock(batch: Batch): Html | string {
  const quote = batch.currentQuote;
  if (!quote) return '';
  const href = `${batchApi(batch)}/quotes/${encodeURIComponent(quote.id)}/file`;
  const rejected =
    quote.decision === 'rejected' && quote.rejectionReason
      ? html`<p class="banner error">Orçamento rejeitado. Motivo: ${quote.rejectionReason}</p>`
      : '';
  return html`<div class="quote">
  <h3>Orçamento ${quote.revision}</h3>
  <p>Valor total: <strong>${formatCents(quote.amountCents)}</strong> · enviado em ${dateTime(quote.submittedAt)}</p>
  ${rejected}
  ${fileLine(href, quote.document, 'Baixar orçamento')}
</div>`;
}

function hiddenCommon(csrfToken: string, form: ActionForm): Html {
  return html`<input type="hidden" name="_csrf" value="${csrfToken}">
  <input type="hidden" name="idempotencyKey" value="${form.idempotencyKey}">
  <input type="hidden" name="etag" value="${form.etag}">`;
}

/** Confirmation dialog inside a form; portal.js intercepts the first submit. */
function confirmDialog(id: string, question: string, confirmLabel: string): Html {
  return html`<dialog id="${id}" class="confirm">
  <p>${question}</p>
  <div class="actions">
    <button type="submit" name="confirmed" value="1" data-confirmed>${confirmLabel}</button>
    <button type="button" class="secondary" data-close>Voltar</button>
  </div>
</dialog>`;
}

function collectForm(view: CurrentBatchView, base: string): Html {
  const { batch } = view;
  const files = plural(fileCount(batch), 'arquivo', 'arquivos');
  const requests = plural(batch.items.length, 'solicitação', 'solicitações');
  return html`<form method="post" action="${base}/collected" class="action" data-confirm="confirm-collect">
  ${hiddenCommon(view.csrfToken, view.form)}
  <label class="check"><input type="checkbox" name="checked" value="1" required> Conferi todos os arquivos</label>
  <button type="submit" data-ttp="action" data-action="collect">Retirei os arquivos</button>
  ${confirmDialog('confirm-collect', `Confirmar a retirada dos ${files} de ${requests} do lote ${batch.reference}?`, 'Confirmar retirada')}
</form>`;
}

function quoteForm(view: CurrentBatchView, base: string): Html {
  const { batch } = view;
  return html`${quoteBlock(batch)}
<form method="post" action="${base}/quotes" enctype="multipart/form-data" class="action" data-confirm="confirm-quote">
  <h3>Orçamento do lote</h3>
  ${hiddenCommon(view.csrfToken, view.form)}
  <label for="amount">Valor total do orçamento (R$)</label>
  <input id="amount" name="amount" inputmode="decimal" placeholder="R$ 0,00" required value="${view.form.amountText ?? ''}">
  <label for="quote-file">Arquivo do orçamento</label>
  <input id="quote-file" name="file" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required>
  <p class="hint">Um orçamento para o lote inteiro. PDF, JPEG, PNG ou WebP, até 5 MB.</p>
  <button type="submit" data-ttp="action" data-action="upload-quote">Enviar orçamento</button>
  ${confirmDialog('confirm-quote', `Confirmar o envio do orçamento do lote ${batch.reference} ao Financeiro?`, 'Confirmar envio')}
</form>`;
}

function printForm(view: CurrentBatchView, base: string): Html {
  const { batch } = view;
  const amount =
    batch.approvedAmountCents !== null
      ? html`: <strong>${formatCents(batch.approvedAmountCents)}</strong>`
      : '';
  return html`${quoteBlock(batch)}
<p class="banner success">Orçamento aprovado${amount}.</p>
<form method="post" action="${base}/printed" class="action" data-confirm="confirm-print">
  ${hiddenCommon(view.csrfToken, view.form)}
  <input type="hidden" name="quoteId" value="${batch.currentQuote?.id ?? ''}">
  <button type="submit" data-ttp="action" data-action="mark-printed">Marcar como impresso</button>
  ${confirmDialog('confirm-print', `Confirmar que todo o lote ${batch.reference} foi impresso?`, 'Confirmar impressão')}
</form>`;
}

/** The single action allowed in the batch's state, or its waiting message. */
function batchAction(view: CurrentBatchView): Html | string {
  const base = `/batches/${encodeURIComponent(view.batch.id)}`;
  switch (availableAction(view.batch)) {
    case 'collect':
      return collectForm(view, base);
    case 'upload-quote':
      return quoteForm(view, base);
    case 'mark-printed':
      return printForm(view, base);
    default: {
      const waiting = waitingMessage(view.batch.status);
      return html`${quoteBlock(view.batch)}${waiting ? html`<p class="banner info" data-ttp="status-message">${waiting}</p>` : ''}`;
    }
  }
}

function fileCard(batch: Batch, item: BatchItem, file: PrintFile, job: PrintJob | null): Html {
  const href = `${batchApi(batch)}/orders/${encodeURIComponent(item.orderId)}/files/${encodeURIComponent(file.id)}`;
  const details = job
    ? html`<h3>${job.title}</h3>
    <p class="filename" data-ttp="file-name">${file.name}</p>
    <p class="meta"><span data-ttp="file-size" data-bytes="${file.bytes}">${fileSize(file.bytes)}</span> · ${file.mime}</p>
    <p><strong>Cópias:</strong> <span data-ttp="copies">${job.copies}</span></p>
    <p><strong>Instruções de impressão:</strong></p>
    <p class="instructions" data-ttp="instructions">${job.instructions}</p>`
    : html`<h3>Não identificadas</h3>
    <p class="filename" data-ttp="file-name">${file.name}</p>
    <p class="meta"><span data-ttp="file-size" data-bytes="${file.bytes}">${fileSize(file.bytes)}</span> · ${file.mime}</p>
    <p class="hint">Sem vínculo seguro — consulte instruções gerais</p>`;
  return html`<li class="file-card" data-ttp="file" data-file-id="${file.id}">
    ${details}
    <a class="button" data-ttp="download" href="${href}" download>Baixar arquivo</a>
  </li>`;
}

function requestBlock(batch: Batch, item: BatchItem): Html {
  const general = item.generalInstructions;
  return html`<article class="request" data-ttp="item" data-order-id="${item.orderId}">
  <h2><span data-ttp="item-reference">${item.reference}</span> · ${item.title}</h2>
  ${item.previouslyCancelledIn ? html`<p class="banner warning" data-ttp="previously-cancelled">Este item esteve no lote ${item.previouslyCancelledIn}, cancelado — confira antes de imprimir</p>` : ''}
  <ol class="cards">
  ${itemFiles(item).map(({ file, job }) => fileCard(batch, item, file, job))}
  </ol>
  ${
    general
      ? html`<section class="general">
    <h3>Instruções gerais</h3>
    <p class="hint">Instruções desta solicitação sem vínculo seguro com um arquivo.</p>
    <p class="instructions" data-ttp="general-instructions">${general.text}</p>
  </section>`
      : ''
  }
</article>`;
}

/** The batch with its header, progress, optional actions and every request/file card. */
function batchSection(batch: Batch, heading: 'h1' | 'h2', actions: Html | string): Html {
  const title = html`Lote <span data-ttp="batch-reference">${batch.reference}</span>`;
  const counts = [
    plural(batch.itemCount, 'solicitação', 'solicitações'),
    plural(fileCount(batch), 'arquivo', 'arquivos'),
    plural(totalCopies(batch), 'cópia', 'cópias'),
  ].join(' · ');
  const cancelled =
    batch.status === 'cancelled'
      ? html`<p class="banner error">Lote cancelado${batch.cancellationReason ? html`. Motivo: ${batch.cancellationReason}` : ''}.</p>`
      : '';
  return html`<section class="batch" data-ttp="batch" data-batch-id="${batch.id}" data-status="${batch.status}">
  ${heading === 'h1' ? html`<h1>${title}</h1>` : html`<h2>${title}</h2>`}
  <p class="meta">${counts}</p>
  ${progressBar(batch)}
  ${batchFacts(batch)}
  ${cancelled}
  ${actions}
  ${batch.items.map((item) => requestBlock(batch, item))}
</section>`;
}

export interface CurrentBatchView {
  readonly csrfToken: string;
  readonly batch: Batch;
  readonly form: ActionForm;
}

export interface HomeView {
  readonly csrfToken: string;
  /** null = no current batch; 'unavailable' = the upstream could not be read. */
  readonly current: CurrentBatchView | null | 'unavailable';
  readonly banner?: Banner;
}

export function homePage(view: HomeView): Html {
  const { current } = view;
  let content: Html;
  if (current === 'unavailable') {
    content = html`<h1>Lote atual</h1>
${banner(view.banner)}
<p><a class="button" href="/">Atualizar</a></p>`;
  } else if (current === null) {
    content = html`<h1>Lote atual</h1>
${banner(view.banner)}
<p class="empty" data-ttp="empty">Nenhum pedido aguardando</p>`;
  } else {
    content = html`${banner(view.banner)}
<p><a class="button secondary" href="/">Atualizar</a></p>
${batchSection(current.batch, 'h1', batchAction(current))}`;
  }
  return layout('Lote atual', html`<section>${content}</section>`, {
    csrfToken: view.csrfToken,
    active: 'home',
  });
}

/** Read-only detail of any batch (history), same cards, no actions. */
export function batchDetailPage(csrfToken: string, batch: Batch): Html {
  return layout(
    `Lote ${batch.reference}`,
    html`<section>
  <p><a href="/batches">← Lotes anteriores</a></p>
  ${batchSection(batch, 'h1', quoteBlock(batch))}
</section>`,
    { csrfToken, active: 'history' },
  );
}

// ── history ──

export interface HistoryView {
  readonly csrfToken: string;
  /** null when the upstream could not be reached. */
  readonly page: BatchPage | null;
  readonly cursor: string | undefined;
  readonly back: readonly string[];
}

function historyHref(cursor: string | undefined, back: readonly string[]): string {
  const params = new URLSearchParams();
  if (cursor) params.set('cursor', cursor);
  for (const b of back) params.append('back', b);
  const query = params.toString();
  return query ? `/batches?${query}` : '/batches';
}

export function historyPage(view: HistoryView): Html {
  const { page, cursor, back } = view;
  const previous =
    back.length > 0 ? historyHref(back[back.length - 1] || undefined, back.slice(0, -1)) : null;
  const next = page?.nextCursor ? historyHref(page.nextCursor, [...back, cursor ?? '']) : null;
  let content: Html;
  if (page === null) {
    content = html`<p class="empty unavailable" data-state="unavailable">Não foi possível consultar os lotes agora (serviço indisponível). Use <a href="/batches">Atualizar</a> para tentar de novo.</p>`;
  } else if (page.items.length === 0) {
    content = html`<p class="empty" data-state="empty">Nenhum lote anterior.</p>`;
  } else {
    content = html`<table class="orders">
  <thead><tr><th>Lote</th><th>Status</th><th>Criado em</th><th>Retirado em</th><th>Impresso em</th><th>Recebido em</th><th>Valor aprovado</th></tr></thead>
  <tbody>
  ${page.items.map(
    (b) => html`<tr data-ttp="history-batch" data-batch-id="${b.id}">
    <td data-label="Lote"><a href="/batches/${encodeURIComponent(b.id)}">${b.reference}</a></td>
    <td data-label="Status"><span class="status ${b.status}">${BATCH_STATUS_LABELS[b.status]}</span></td>
    <td data-label="Criado em">${dateTime(b.createdAt)}</td>
    <td data-label="Retirado em">${dateTime(b.collectedAt)}</td>
    <td data-label="Impresso em">${dateTime(b.printedAt)}</td>
    <td data-label="Recebido em">${dateTime(b.receivedAt)}</td>
    <td data-label="Valor aprovado">${b.approvedAmountCents === null ? '—' : formatCents(b.approvedAmountCents)}</td>
  </tr>`,
  )}
  </tbody>
</table>`;
  }
  return layout(
    'Lotes anteriores',
    html`<section>
  <h1>Lotes anteriores</h1>
  ${content}
  <nav class="pager">
    ${previous ? html`<a class="button secondary" href="${previous}">Anterior</a>` : html`<span class="button secondary disabled" aria-disabled="true">Anterior</span>`}
    ${next ? html`<a class="button secondary" href="${next}">Próxima</a>` : html`<span class="button secondary disabled" aria-disabled="true">Próxima</span>`}
  </nav>
</section>`,
    { csrfToken: view.csrfToken, active: 'history' },
  );
}

// ── invoices ──

export interface InvoicesView {
  readonly csrfToken: string;
  readonly competence: string;
  readonly currentCompetence: string;
  /** null = upstream route not available yet (or unreachable, see banner). */
  readonly close: MonthlyClose | null;
  readonly form: ActionForm | null;
  readonly unavailable?: 'not_deployed' | 'down';
  readonly banner?: Banner;
}

function lastDayLabel(competence: string): string {
  const [year = 0, month = 1] = competence.split('-').map(Number);
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return `${String(last).padStart(2, '0')}/${String(month).padStart(2, '0')}/${year}`;
}

function closeFacts(close: MonthlyClose): Html {
  const declared = close.declaredTotalCents;
  const divergent = declared !== null && declared !== close.expectedTotalCents;
  const declaredRow =
    declared === null
      ? ''
      : html`<dt>Valor declarado na NF</dt><dd${divergent ? html` class="divergent"` : ''}>${formatCents(declared)}${divergent ? ' — diverge do total calculado' : ''}</dd>`;
  return html`<dl class="facts">
  <dt>Situação</dt><dd><span class="status close-${close.state}">${CLOSE_STATE_LABELS[close.state]}</span></dd>
  <dt>Total calculado</dt><dd><strong>${formatCents(close.expectedTotalCents)}</strong></dd>
  ${declaredRow}
  ${close.submittedAt ? html`<dt>Enviada em</dt><dd>${dateTime(close.submittedAt)}</dd>` : ''}
  ${close.acceptedAt ? html`<dt>Aceita em</dt><dd>${dateTime(close.acceptedAt)}</dd>` : ''}
</dl>`;
}

function closeBanners(close: MonthlyClose): Html {
  const period = close.periodClosed
    ? ''
    : html`<p class="banner info">Competência em andamento: a NF só pode ser enviada depois do encerramento do mês (${lastDayLabel(close.competence)}).</p>`;
  const byState: Record<MonthlyClose['state'], Html | string> = {
    open: '',
    submitted: html`<p class="banner info">Aguardando conferência.</p>`,
    rejected: close.rejectionReason
      ? html`<p class="banner error">NF rejeitada. Motivo: ${close.rejectionReason}</p>`
      : '',
    accepted: html`<p class="banner success">NF aceita pelo Financeiro.</p>`,
  };
  return html`${period}${byState[close.state]}`;
}

function closeItems(close: MonthlyClose): Html {
  if (close.items.length === 0) {
    return html`<p class="empty" data-state="empty">Nenhum lote impresso nesta competência.</p>`;
  }
  return html`<table class="orders">
  <thead><tr><th>Referência</th><th>Impresso em</th><th>Valor aprovado</th></tr></thead>
  <tbody>${close.items.map(
    (i) =>
      html`<tr><td data-label="Referência">${i.kind === 'batch' ? html`<a href="/batches/${encodeURIComponent(i.batchId)}">${i.reference}</a>` : html`${i.reference} <span class="meta">(pedido individual)</span>`}</td><td data-label="Impresso em">${dateTime(i.printedAt)}</td><td data-label="Valor aprovado">${formatCents(i.amountCents)}</td></tr>`,
  )}</tbody>
  <tfoot><tr><th colspan="2">Total calculado</th><td>${formatCents(close.expectedTotalCents)}</td></tr></tfoot>
</table>`;
}

function invoiceForm(view: InvoicesView, close: MonthlyClose): Html | string {
  if (!view.form || !canSubmitInvoice(close)) return '';
  const competence = close.competence;
  return html`<form method="post" action="/invoices/${encodeURIComponent(competence)}" enctype="multipart/form-data" class="action" data-confirm="confirm-invoice">
  <h2>${close.state === 'rejected' ? 'Enviar nova NF' : 'Enviar NF'}</h2>
  <input type="hidden" name="_csrf" value="${view.csrfToken}">
  <input type="hidden" name="idempotencyKey" value="${view.form.idempotencyKey}">
  <input type="hidden" name="etag" value="${view.form.etag}">
  <label for="declared">Valor total da NF</label>
  <input id="declared" name="amount" inputmode="decimal" placeholder="R$ 0,00" required value="${view.form.amountText ?? ''}">
  <label for="invoice-file">Arquivo da NF</label>
  <input id="invoice-file" name="file" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" required>
  <p class="hint">PDF, JPEG, PNG ou WebP, até 5 MB. O valor deve ser igual ao total calculado.</p>
  <button type="submit">Enviar NF</button>
  ${confirmDialog('confirm-invoice', `Confirmar o envio da NF de ${competence}?`, 'Confirmar envio')}
</form>`;
}

function closeContent(view: InvoicesView): Html {
  const { close } = view;
  if (view.unavailable === 'not_deployed') {
    return html`<p class="empty" data-state="unavailable">Notas fiscais ainda indisponíveis.</p>`;
  }
  if (!close) {
    return html`<p class="empty unavailable" data-state="unavailable">Não foi possível consultar o fechamento agora (serviço indisponível). Tente novamente.</p>`;
  }
  const api = `/api/print/v2/monthly-closes/${encodeURIComponent(close.competence)}`;
  return html`${closeFacts(close)}
${closeBanners(close)}
${close.document ? fileLine(`${api}/invoice`, close.document, 'Baixar NF') : ''}
<h2>Lotes e pedidos da competência</h2>
${closeItems(close)}
${invoiceForm(view, close)}`;
}

export function invoicesPage(view: InvoicesView): Html {
  const { competence } = view;
  const content = closeContent(view);
  return layout(
    'Notas fiscais',
    html`<section>
  <h1>Notas fiscais</h1>
  ${banner(view.banner)}
  <form method="get" action="/invoices" class="filters">
    <label for="competence">Competência</label>
    <input id="competence" name="competence" type="month" value="${competence}" max="${view.currentCompetence}" required>
    <button type="submit">Consultar</button>
  </form>
  <nav class="pager">
    <a class="button secondary" href="/invoices?competence=${previousCompetence(competence)}">Mês anterior</a>
    ${competence < view.currentCompetence ? html`<a class="button secondary" href="/invoices?competence=${nextCompetence(competence)}">Próximo mês</a>` : ''}
  </nav>
  ${content}
</section>`,
    { csrfToken: view.csrfToken, active: 'invoices' },
  );
}

export function errorPage(title: string, b: Banner, csrfToken?: string): Html {
  return layout(
    title,
    html`<section class="card narrow"><h1>${title}</h1>${banner(b)}<p><a href="/">Voltar ao lote atual</a></p></section>`,
    csrfToken ? { csrfToken, active: '' } : undefined,
  );
}
