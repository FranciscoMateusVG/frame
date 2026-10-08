//! Static assets, served same-origin so the CSP needs no inline script.
//!
//! The script sends every command to the JSON API with the session CSRF
//! token, the page's ETag as If-Match and an Idempotency-Key that is kept
//! in sessionStorage per (resource, action, ETag, intent). After a timeout,
//! 503 or expired session the same intent reuses the same key, so a retry
//! can never apply twice; a different intent gets a new key. Nothing is
//! retried automatically.
use axum::{
    http::{HeaderValue, header},
    response::{IntoResponse, Response},
};

pub const SCRIPT: &str = r#"(() => {
  'use strict';
  const $ = (sel, root) => (root || document).querySelector(sel);
  const csrf = () => ($('meta[name="csrf-token"]') || {}).content || '';
  const say = (el, text, kind) => { if (el) { el.textContent = text; el.className = kind || ''; } };
  const store = {
    get(k) { try { return JSON.parse(sessionStorage.getItem(k)); } catch (_) { return null; } },
    set(k, v) { try { sessionStorage.setItem(k, JSON.stringify(v)); } catch (_) {} },
    del(k) { try { sessionStorage.removeItem(k); } catch (_) {} },
  };
  async function problem(res) {
    try { const body = await res.json(); return (body && body.error) || {}; } catch (_) { return {}; }
  }

  // Same rule as the server's parse_brl: comma decimals, dot thousands.
  function parseBRL(raw) {
    const s = String(raw).trim().replace(/^R\$\s*/, '');
    const m = /^(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d{1,2}))?$/.exec(s);
    if (!m) return null;
    const digits = m[1].replace(/\./g, '');
    if (digits.length > 8) return null;
    const frac = m[2] ? (m[2].length === 1 ? m[2] + '0' : m[2]) : '00';
    const cents = Number(digits) * 100 + Number(frac);
    return cents >= 1 && cents <= 2147483647 ? cents : null;
  }

  const logout = $('#logout');
  if (logout) logout.addEventListener('click', async () => {
    try {
      await fetch('/api/session', { method: 'DELETE', credentials: 'same-origin', headers: { 'X-CSRF-Token': csrf() } });
    } catch (_) {}
    location.assign('/login');
  });

  const login = $('#login');
  if (login) login.addEventListener('submit', async (event) => {
    event.preventDefault();
    const out = $('#message');
    const button = $('button', login);
    button.disabled = true;
    try {
      const res = await fetch('/api/session', {
        method: 'POST', credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf() },
        body: JSON.stringify({ password: login.password.value }),
      });
      if (res.ok) { location.assign(login.dataset.next || '/orders'); return; }
      if (res.status === 401) say(out, 'Senha incorreta.', 'error');
      else if (res.status === 429) {
        const minutes = Math.max(1, Math.ceil(Number(res.headers.get('Retry-After') || '60') / 60));
        say(out, 'Muitas tentativas. Tente novamente em ' + minutes + ' min.', 'error');
      } else if (res.status === 403) say(out, 'A página de login expirou. Recarregue a página e tente de novo.', 'error');
      else say(out, 'Serviço indisponível. Tente novamente em instantes.', 'error');
    } catch (_) {
      say(out, 'Sem conexão com o portal. Tente novamente.', 'error');
    } finally {
      button.disabled = false;
      login.password.value = '';
    }
  });

  const box = $('#actions');
  if (!box) return;
  const out = $('#message', box);
  const recovery = $('.recovery', box);
  const scope = box.dataset.orderId || ('close-' + box.dataset.competence);
  // Intents of an older ETag can no longer apply: the page already reflects them.
  try {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const k = sessionStorage.key(i);
      if (k && k.startsWith('intent:' + scope + ':')) {
        const v = store.get(k);
        if (!v || v.etag !== box.dataset.etag) sessionStorage.removeItem(k);
      }
    }
  } catch (_) {}

  function intentKey(action, fingerprint) {
    const k = 'intent:' + scope + ':' + action;
    const prior = store.get(k);
    if (prior && prior.etag === box.dataset.etag && prior.fingerprint === fingerprint) return [k, prior.key];
    const key = crypto.randomUUID();
    store.set(k, { etag: box.dataset.etag, fingerprint, key });
    return [k, key];
  }

  function build(form) {
    const action = form.dataset.action;
    const id = box.dataset.orderId;
    const revision = Number(box.dataset.revision);
    if (action === 'collect') {
      return { url: '/api/print/v1/orders/' + id + '/collected', json: { revision }, fingerprint: 'collect' };
    }
    if (action === 'printed') {
      return { url: '/api/print/v1/orders/' + id + '/printed', json: { revision, quoteId: box.dataset.quoteId }, fingerprint: 'printed:' + box.dataset.quoteId };
    }
    const file = form.file.files[0];
    if (!file) return { error: 'Escolha o arquivo.' };
    if (file.size > 5 * 1024 * 1024) return { error: 'Arquivo acima de 5 MB.' };
    const amountField = action === 'quote' ? form.amount : form.declared;
    const cents = parseBRL(amountField.value);
    if (cents === null) return { error: 'Valor inválido. Use o formato 1.234,56.' };
    const data = new FormData();
    data.append('file', file, file.name);
    const fingerprint = [cents, file.name, file.size, file.lastModified].join(':');
    if (action === 'quote') {
      data.append('amountCents', String(cents));
      data.append('orderRevision', String(revision));
      return { url: '/api/print/v1/orders/' + id + '/quotes', form: data, fingerprint };
    }
    data.append('declaredTotalCents', String(cents));
    return { url: '/api/print/v1/monthly-closes/' + box.dataset.competence + '/invoice', form: data, fingerprint };
  }

  async function perform(form) {
    const request = build(form);
    if (request.error) { say(out, request.error, 'error'); return; }
    const [storageKey, key] = intentKey(form.dataset.action, request.fingerprint);
    const headers = { 'X-CSRF-Token': csrf(), 'If-Match': box.dataset.etag, 'Idempotency-Key': key };
    if (request.json) headers['Content-Type'] = 'application/json';
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 65000);
    recovery.hidden = true;
    say(out, 'Enviando…', '');
    let res;
    try {
      res = await fetch(request.url, {
        method: 'POST', credentials: 'same-origin', headers, signal: controller.signal,
        body: request.json ? JSON.stringify(request.json) : request.form,
      });
    } catch (_) {
      say(out, 'Sem confirmação do serviço.', 'error');
      recovery.hidden = false;
      return;
    } finally {
      clearTimeout(timer);
    }
    if (res.ok) {
      store.del(storageKey);
      say(out, 'Registrado. Atualizando…', 'ok');
      location.reload();
      return;
    }
    const err = await problem(res);
    if (res.status === 412) {
      store.del(storageKey);
      say(out, 'Pedido atualizado; confira novamente antes de repetir.', 'error');
      recovery.hidden = false;
      $('[data-retry]', recovery).hidden = true;
    } else if (res.status === 401) {
      say(out, 'Sua sessão expirou. Entre novamente e consulte o estado antes de repetir.', 'error');
      setTimeout(() => location.assign('/login?next=' + encodeURIComponent(location.pathname)), 2500);
    } else if (res.status === 403) {
      say(out, 'Requisição recusada. Recarregue a página.', 'error');
    } else if (res.status === 429 || res.status >= 500 || err.code === 'OPERATION_IN_PROGRESS') {
      say(out, err.message || 'Serviço indisponível.', 'error');
      recovery.hidden = false;
      $('[data-retry]', recovery).hidden = false;
    } else {
      store.del(storageKey);
      say(out, err.message || 'Operação recusada.', 'error');
    }
  }

  for (const form of box.querySelectorAll('form[data-action]')) {
    const submit = $('button[type="submit"]', form);
    const confirm = $('.confirm', form);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const request = build(form);
      if (request.error) { say(out, request.error, 'error'); return; }
      submit.hidden = true;
      confirm.hidden = false;
    });
    $('[data-cancel]', confirm).addEventListener('click', () => { confirm.hidden = true; submit.hidden = false; });
    $('[data-confirm]', confirm).addEventListener('click', async (event) => {
      event.target.disabled = true;
      try { await perform(form); } finally { event.target.disabled = false; }
    });
    const retry = $('[data-retry]', recovery);
    if (retry) retry.addEventListener('click', () => perform(form));
  }
})();
"#;

pub const STYLE: &str = r#":root {
  --bg: #f5f6f8; --card: #fff; --ink: #1d2433; --muted: #5b6475; --line: #dde1e8;
  --accent: #1f5fbf; --accent-ink: #fff; --ok: #1e7a46; --ok-bg: #e7f5ec; --err: #a3261c; --err-bg: #fbeceb;
  --warn-bg: #fff6e0;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: var(--ink);
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #12151b; --card: #1b2029; --ink: #e8ebf1; --muted: #a2aaba; --line: #2d3442;
    --accent: #6ea2ff; --accent-ink: #0b1324; --ok: #7fd6a2; --ok-bg: #173324; --err: #ff9a8f; --err-bg: #3a1c1a; --warn-bg: #3a3218; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); line-height: 1.45; }
header.top { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between;
  padding: 12px 16px; background: var(--card); border-bottom: 1px solid var(--line); }
.brand { font-weight: 700; }
header nav { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
header nav a { color: var(--ink); text-decoration: none; padding: 6px 10px; border-radius: 6px; }
header nav a:hover { background: var(--bg); }
main { max-width: 980px; margin: 0 auto; padding: 16px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 16px; margin-bottom: 16px; }
.card.narrow { max-width: 420px; margin: 48px auto; }
h1 { font-size: 1.35rem; margin: 0 0 8px; } h2 { font-size: 1.1rem; margin: 0 0 12px; } h3 { font-size: 1rem; margin: 0 0 6px; }
.row { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
.muted { color: var(--muted); font-size: .9rem; }
label { display: block; font-weight: 600; margin: 10px 0 4px; }
label.check { display: flex; gap: 8px; align-items: center; font-weight: 500; }
input, select { font: inherit; padding: 8px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--card); color: var(--ink); max-width: 100%; }
input[type=password], input[inputmode] { width: 100%; max-width: 320px; }
button, .button { display: inline-block; font: inherit; font-weight: 600; padding: 8px 14px; border-radius: 6px; border: 1px solid var(--accent);
  background: var(--accent); color: var(--accent-ink); cursor: pointer; text-decoration: none; margin: 8px 8px 0 0; }
button.secondary, .button.secondary { background: transparent; color: var(--accent); }
button:disabled { opacity: .6; cursor: progress; }
.filters { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0 16px; }
.filters label { margin: 0; }
.filters button, .filters .button { margin: 0; }
table.list { width: 100%; border-collapse: collapse; }
table.list th, table.list td { text-align: left; padding: 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: .85rem; background: var(--bg); border: 1px solid var(--line); }
.badge.quote_approved, .badge.printed { background: var(--ok-bg); color: var(--ok); }
.badge.quote_rejected, .badge.cancelled { background: var(--err-bg); color: var(--err); }
.badge.quote_pending { background: var(--warn-bg); }
.notice { padding: 10px 12px; border-radius: 8px; background: var(--warn-bg); margin: 8px 0; }
.notice.ok { background: var(--ok-bg); color: var(--ok); }
.notice.error { background: var(--err-bg); color: var(--err); }
.notice p { margin: 4px 0; }
.empty { padding: 24px; text-align: center; color: var(--muted); }
.pager { display: flex; gap: 8px; }
dl.facts { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; margin: 8px 0; }
dl.facts dt { color: var(--muted); } dl.facts dd { margin: 0; }
dd.total { font-weight: 700; } dd.diverges { color: var(--err); font-weight: 700; }
article.job { border-top: 1px solid var(--line); padding: 12px 0; }
article.job:first-of-type { border-top: 0; }
.instructions { white-space: pre-wrap; background: var(--bg); padding: 8px 10px; border-radius: 6px; }
.confirm, .recovery { margin-top: 12px; padding: 12px; border: 1px dashed var(--accent); border-radius: 8px; }
#message.error { color: var(--err); } #message.ok { color: var(--ok); }
[hidden] { display: none !important; }
@media (max-width: 640px) {
  table.list thead { display: none; }
  table.list tr { display: block; border-bottom: 1px solid var(--line); padding: 8px 0; }
  table.list td { display: block; border: 0; padding: 2px 0; }
  table.list td[data-label]::before { content: attr(data-label) ": "; color: var(--muted); }
  dl.facts { grid-template-columns: 1fr; }
}
"#;

fn asset(body: &'static str, mime: &'static str) -> Response {
    let mut response = body.into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(mime));
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=300"),
    );
    response
}

pub async fn script() -> Response {
    asset(SCRIPT, "text/javascript; charset=utf-8")
}

pub async fn style() -> Response {
    asset(STYLE, "text/css; charset=utf-8")
}
