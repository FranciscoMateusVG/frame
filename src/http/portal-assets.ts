/**
 * Static assets served from memory at /assets/*. Kept in code so the
 * production artifact is a single bundle with no file lookups (and no path
 * traversal surface).
 */

export const PORTAL_CSS = `
:root{--bg:#f6f5f2;--card:#fff;--ink:#1d1d1b;--muted:#5d5b55;--line:#dcd8cf;--accent:#1f5f8b;--accent-ink:#fff;--ok:#1e6b3a;--ok-bg:#e5f3ea;--err:#a1281c;--err-bg:#fbe9e6;--info:#6a4b00;--info-bg:#fdf3d8}
@media (prefers-color-scheme:dark){:root{--bg:#171715;--card:#22221f;--ink:#ecebe6;--muted:#a9a69c;--line:#3a3934;--accent:#6fb3e0;--accent-ink:#0d1a24;--ok:#8fd6a6;--ok-bg:#1d3324;--err:#f19a8f;--err-bg:#3a1f1b;--info:#f0cf7a;--info-bg:#352c14}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.top{display:flex;flex-wrap:wrap;gap:.5rem 1.5rem;align-items:center;justify-content:space-between;padding:.75rem 1rem;background:var(--card);border-bottom:1px solid var(--line)}
.brand{font-weight:700}
.top nav{display:flex;gap:1rem;align-items:center;flex-wrap:wrap}
.top nav a[aria-current]{font-weight:700;text-decoration:underline}
main{max-width:960px;margin:0 auto;padding:1rem}
a{color:var(--accent)}
h1{font-size:1.5rem;margin:.5rem 0 1rem}h2{font-size:1.2rem;margin-top:2rem}h3{font-size:1.05rem;margin:.25rem 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:1.25rem}
.narrow{max-width:420px;margin:2rem auto}
label{display:block;font-weight:600;margin:.75rem 0 .25rem}
label.check{font-weight:400;display:flex;gap:.5rem;align-items:center}
input,select{font:inherit;padding:.5rem;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--ink);max-width:100%}
input[type=password],input[inputmode]{width:100%;max-width:320px}
button,.button{display:inline-block;font:inherit;padding:.5rem 1rem;border-radius:6px;border:1px solid var(--accent);background:var(--accent);color:var(--accent-ink);cursor:pointer;text-decoration:none;margin-top:.75rem}
.secondary{background:transparent;color:var(--accent)}
.disabled{opacity:.45;pointer-events:none}
button.link{background:none;border:none;color:var(--accent);padding:0;margin:0;text-decoration:underline}
form.inline{display:inline}
.filters{display:flex;flex-wrap:wrap;gap:.5rem;align-items:end}.filters label{margin:0}.filters button{margin:0}
.pager{display:flex;gap:.5rem;margin:1rem 0}
table.orders{width:100%;border-collapse:collapse;background:var(--card);margin-top:1rem}
table.orders th,table.orders td{border-bottom:1px solid var(--line);padding:.5rem;text-align:left;vertical-align:top}
table.orders td .button{margin:0}
.status{display:inline-block;padding:.1rem .5rem;border-radius:999px;background:var(--info-bg);color:var(--info);font-size:.9rem}
.status.printed,.status.quote_approved,.status.close-accepted{background:var(--ok-bg);color:var(--ok)}
.status.cancelled,.status.quote_rejected,.status.close-rejected{background:var(--err-bg);color:var(--err)}
.banner{padding:.75rem 1rem;border-radius:6px;margin:1rem 0}
.banner.error{background:var(--err-bg);color:var(--err)}.banner.success{background:var(--ok-bg);color:var(--ok)}.banner.info{background:var(--info-bg);color:var(--info)}
.empty{padding:1rem;background:var(--card);border:1px dashed var(--line);border-radius:6px}
.empty.unavailable{border-color:var(--err);color:var(--err)}
.facts{display:grid;grid-template-columns:max-content 1fr;gap:.25rem 1rem}.facts dt{color:var(--muted)}.facts dd{margin:0}
.divergent{color:var(--err);font-weight:700}
.jobs{padding-left:1.25rem}.job{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:1rem;margin-bottom:1rem}
.instructions{white-space:pre-wrap;background:var(--bg);padding:.5rem;border-radius:4px}
.file{display:flex;flex-wrap:wrap;gap:.25rem 1rem;align-items:center}.file .button{margin:0}
.meta,.hint{color:var(--muted);font-size:.9rem}
.sha{font-size:.75rem;color:var(--muted);word-break:break-all}
.action{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:1rem;margin-top:1rem}
.banner.warning{background:var(--info-bg);color:var(--info);border-left:4px solid var(--info);font-weight:600}
.progress{display:flex;flex-wrap:wrap;gap:.25rem;list-style:none;padding:0;margin:1rem 0;counter-reset:step}
.progress li{flex:1 1 8rem;padding:.4rem .6rem;border-radius:6px;background:var(--card);border:1px solid var(--line);color:var(--muted);font-size:.9rem}
.progress li.done{background:var(--ok-bg);color:var(--ok);border-color:transparent}
.progress li.current{background:var(--accent);color:var(--accent-ink);border-color:var(--accent);font-weight:700}
.request{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:1rem;margin-top:1.5rem}
.request h2{margin-top:0;overflow-wrap:anywhere}
.cards{list-style:none;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(16rem,1fr));gap:1rem}
.file-card{border:1px solid var(--line);border-radius:8px;padding:1rem;background:var(--bg);display:flex;flex-direction:column;gap:.25rem}
.file-card p{margin:0}.file-card .button{align-self:flex-start}
.filename{font-weight:600;overflow-wrap:anywhere}
.general{margin-top:1rem}
dialog.confirm{border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);max-width:min(420px,calc(100vw - 2rem))}
dialog.confirm .actions{display:flex;gap:.5rem;flex-wrap:wrap}
@media (max-width:640px){
 table.orders thead{display:none}
 table.orders tr{display:block;border-bottom:1px solid var(--line);padding:.5rem 0}
 table.orders td{display:flex;justify-content:space-between;gap:1rem;border:none;padding:.25rem .5rem}
 table.orders td[data-label]::before{content:attr(data-label);color:var(--muted)}
 .facts{grid-template-columns:1fr}
 .cards{grid-template-columns:1fr}
 .progress li{flex-basis:100%}
}
`;

/**
 * Confirmation step for every command form: the first submit opens the
 * form's <dialog>; only its "Confirmar …" button really submits. Without
 * JavaScript the form submits directly (the server enforces every rule).
 */
export const PORTAL_JS = `
document.addEventListener('submit', function (event) {
  var form = event.target;
  var id = form.getAttribute('data-confirm');
  if (!id) return;
  var submitter = event.submitter;
  if (submitter && submitter.hasAttribute('data-confirmed')) {
    form.querySelectorAll('button[type=submit]').forEach(function (b) { b.disabled = true; });
    var flag = document.createElement('input');
    flag.type = 'hidden'; flag.name = 'confirmed'; flag.value = '1';
    form.appendChild(flag);
    return;
  }
  var dialog = document.getElementById(id);
  if (!dialog || typeof dialog.showModal !== 'function') return;
  event.preventDefault();
  dialog.showModal();
});
document.addEventListener('click', function (event) {
  var target = event.target;
  if (target && target.hasAttribute && target.hasAttribute('data-close')) {
    var dialog = target.closest('dialog');
    if (dialog) dialog.close();
  }
});
`;
