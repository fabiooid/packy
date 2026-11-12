// Read-only web dashboard. Served by the API server so it shares the same login and origin.
// No inline script: the page loads /admin/app.js, which the CSP below allows and nothing else.

export const ADMIN_CSP = [
  "default-src 'none'", "script-src 'self'", "style-src 'unsafe-inline'", "connect-src 'self'",
  "img-src 'self'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
].join('; ');

export const ADMIN_HTML = `<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Packy · Ordini imballati</title>
<link rel="icon" href="/admin/favicon.ico" sizes="32x32">
<link rel="icon" type="image/png" href="/admin/favicon.png" sizes="32x32">
<style>
:root { --ground:#F4F3EF; --card:#FFFFFF; --ink:#16181D; --muted:#5C6068; --line:#E4E2DC; --divider:#EEEDE8; --accent:#4251E4; --success:#0B7A47; --success-soft:#E3F3EA; --danger:#C1232B; --warn-bg:#FDEFD9; --warn:#8A4500; }
* { box-sizing: border-box; }
body { margin:0; background:var(--ground); color:var(--ink); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", system-ui, sans-serif; }
main { max-width: 880px; margin: 0 auto; padding: 32px 16px 48px; }
h1 { font-size: 28px; letter-spacing: -0.01em; margin: 0; }
.muted { color: var(--muted); }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 18px; }
[hidden] { display: none !important; }
#login { max-width: 380px; margin: 12vh auto 0; padding: 28px 24px; display: flex; flex-direction: column; gap: 14px; }
label { display: flex; flex-direction: column; gap: 6px; font-weight: 600; font-size: 14px; }
input { height: 48px; border-radius: 12px; border: 1.5px solid var(--line); padding: 0 14px; font: inherit; font-weight: 400; }
input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
button { height: 48px; border: none; border-radius: 14px; background: var(--accent); color: #fff; font: inherit; font-weight: 600; cursor: pointer; }
button.link { height: auto; background: none; color: var(--muted); padding: 8px 4px; }
.error { color: var(--danger); font-size: 14px; min-height: 1em; }
.mark { display: block; height: auto; }
#login .mark { width: 72px; margin-bottom: 8px; }
.brand { display: flex; align-items: center; gap: 12px; min-width: 0; }
.brand .mark { width: 36px; flex: none; }
header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 20px; }
.banner { background: var(--warn-bg); color: var(--warn); border-radius: 14px; padding: 10px 14px; margin-bottom: 16px; font-weight: 600; font-size: 14px; }
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 20px; }
.stat { padding: 16px; }
.stat b { display: block; font-size: 30px; letter-spacing: -0.01em; }
.stat span { color: var(--muted); font-size: 13px; }
.day { margin: 18px 4px 8px; font-weight: 600; color: var(--muted); font-size: 14px; }
.row { display: grid; grid-template-columns: 36px 1fr auto; gap: 14px; align-items: center; padding: 14px 16px; border-bottom: 1px solid var(--divider); }
.check { width: 36px; height: 36px; border-radius: 18px; background: var(--success); display: flex; align-items: center; justify-content: center; }
.check svg { width: 20px; height: 20px; }
.status.partial { background: var(--warn-bg); color: var(--warn); }
.status.partial::before { background: var(--warn); }
.status { display: inline-flex; align-items: center; gap: 6px; background: var(--success-soft); color: var(--success); border-radius: 999px; padding: 4px 10px; font-size: 13px; font-weight: 700; white-space: nowrap; }
.status::before { content: ""; width: 7px; height: 7px; border-radius: 4px; background: var(--success); }
.right { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; }
.row:last-child { border-bottom: none; }
.time { font-variant-numeric: tabular-nums; }
.who { font-weight: 600; }
.ref { color: var(--muted); font-size: 13px; }
.by { text-align: right; font-size: 13px; color: var(--muted); }
.stat.done b { color: var(--success); }
.by b { color: var(--ink); font-weight: 600; }
.empty { padding: 28px 16px; text-align: center; color: var(--muted); }
.pager { display: flex; align-items: center; justify-content: center; gap: 16px; margin-top: 16px; }
.pager button:disabled { color: var(--muted); cursor: default; }
@media (max-width: 560px) {
  .stats { grid-template-columns: 1fr 1fr; }
  .stat:last-child { grid-column: span 2; }
  .row { grid-template-columns: 36px 1fr; }
  .right { grid-column: 2; flex-direction: row; align-items: center; justify-content: space-between; }
}
</style>
</head>
<body>
<main>
  <form id="login" class="card" hidden>
    <div>
      <img class="mark" src="/admin/logo.png" alt="Packy" width="72" height="65">
      <h1>Packy</h1>
      <p class="muted" style="margin:4px 0 0">Ordini imballati. Accedi con lo stesso account dell'app.</p>
    </div>
    <label>Nome utente <input id="username" autocomplete="username" required></label>
    <label>Password <input id="password" type="password" autocomplete="current-password" required></label>
    <div id="login-error" class="error" role="alert"></div>
    <button type="submit">Accedi</button>
  </form>

  <section id="dash" hidden>
    <header>
      <div class="brand">
        <img class="mark" src="/admin/logo.png" alt="Packy" width="36" height="32">
        <div>
          <h1>Ordini imballati</h1>
          <div class="muted" id="updated"></div>
        </div>
      </div>
      <button id="logout" class="link" type="button">Esci</button>
    </header>
    <div id="fixture" class="banner" hidden>Ordini di prova per test locali. Non sono dati reali dei clienti.</div>
    <div class="stats">
      <div class="card stat done"><b id="s-today">0</b><span>Oggi</span></div>
      <div class="card stat"><b id="s-week">0</b><span>Ultimi 7 giorni</span></div>
      <div class="card stat"><b id="s-month">0</b><span>Ultimi 30 giorni</span></div>
    </div>
    <div id="list"></div>
    <div id="pager" class="pager" hidden>
      <button id="prev" class="link" type="button">Precedente</button>
      <span id="page-label" class="muted"></span>
      <button id="next" class="link" type="button">Successivo</button>
    </div>
    <div id="dash-error" class="error" role="alert"></div>
  </section>
</main>
<script src="/admin/app.js"></script>
</body>
</html>`;

export const ADMIN_JS = `(() => {
  const KEY = 'packy.admin.token';
  const $ = (id) => document.getElementById(id);
  const store = {
    get() { try { return sessionStorage.getItem(KEY); } catch { return null; } },
    set(v) { try { v ? sessionStorage.setItem(KEY, v) : sessionStorage.removeItem(KEY); } catch {} },
  };
  const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const dayFmt = new Intl.DateTimeFormat('it-IT', { weekday: 'long', day: 'numeric', month: 'long' });
  const timeFmt = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' });
  const startOfDay = (t) => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };

  const SVG = 'http://www.w3.org/2000/svg';
  function checkIcon() {
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', 'M5 12.5l4.5 4.5L19 7.5');
    path.setAttribute('fill', 'none'); path.setAttribute('stroke', '#fff'); path.setAttribute('stroke-width', '3');
    path.setAttribute('stroke-linecap', 'round'); path.setAttribute('stroke-linejoin', 'round');
    svg.append(path);
    return svg;
  }

  function show(view) { $('login').hidden = view !== 'login'; $('dash').hidden = view !== 'dash'; }

  async function api(path, init = {}) {
    const token = store.get();
    const res = await fetch(path, { ...init, headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) } });
    const body = await res.json().catch(() => ({}));
    if (res.status === 401 && path !== '/v1/auth/login') { store.set(null); show('login'); throw new Error('unauthenticated'); }
    if (!res.ok) throw new Error((body.error && body.error.message) || 'Qualcosa è andato storto.');
    return body;
  }

  const PAGE = 15;
  let page = 0;
  let packed = [];

  function render(data) {
    $('fixture').hidden = !data.fixture;
    $('updated').textContent = 'Aggiornato alle ' + timeFmt.format(Date.now()) + ' · ' + data.total + ' in totale';
    const today = startOfDay(Date.now());
    const week = today - 6 * 86400000;
    packed = data.orders;
    $('s-today').textContent = packed.filter((o) => o.completedAt >= today).length;
    $('s-week').textContent = packed.filter((o) => o.completedAt >= week).length;
    $('s-month').textContent = packed.length;
    page = 0;
    drawList();
  }

  function drawList() {
    const list = $('list');
    const pager = $('pager');
    list.replaceChildren();
    if (!packed.length) {
      list.append(el('div', 'card empty', 'Nessun ordine imballato negli ultimi 30 giorni.'));
      pager.hidden = true;
      return;
    }
    const pages = Math.max(1, Math.ceil(packed.length / PAGE));
    if (page > pages - 1) page = pages - 1;
    if (page < 0) page = 0;
    const today = startOfDay(Date.now());
    let card = null, current = null;
    for (const o of packed.slice(page * PAGE, (page + 1) * PAGE)) {
      const day = startOfDay(o.completedAt);
      if (day !== current) {
        current = day;
        const label = day === today ? 'Oggi' : day === today - 86400000 ? 'Ieri' : dayFmt.format(o.completedAt);
        list.append(el('div', 'day', label.charAt(0).toUpperCase() + label.slice(1)));
        card = el('div', 'card'); list.append(card);
      }
      const row = el('div', 'row');
      const check = el('div', 'check');
      check.setAttribute('aria-hidden', 'true');
      check.append(checkIcon());
      row.append(check);
      const mid = el('div');
      mid.append(el('div', 'who', o.recipient || 'Cliente senza nome'));
      mid.append(el('div', 'ref', o.reference + ' · ' + o.units + (o.units === 1 ? ' pezzo' : ' pezzi') + (o.manualUnits ? ' · ' + o.manualUnits + ' a mano' : '')));
      row.append(mid);
      const right = el('div', 'right');
      right.append(o.shortUnits
        ? el('span', 'status partial', 'Parziale · ' + o.shortUnits + ' da spedire')
        : el('span', 'status', 'Imballato alle ' + timeFmt.format(o.completedAt)));
      const by = el('div', 'by', 'da '); by.append(el('b', null, o.completedByName)); right.append(by);
      row.append(right);
      card.append(row);
    }
    if (pages <= 1) { pager.hidden = true; return; }
    pager.hidden = false;
    $('prev').disabled = page === 0;
    $('next').disabled = page >= pages - 1;
    $('page-label').textContent = (page + 1) + ' di ' + pages;
  }

  async function load() {
    $('dash-error').textContent = '';
    try { render(await api('/v1/admin/completed')); show('dash'); }
    catch (e) { if (e.message !== 'unauthenticated') { show('dash'); $('dash-error').textContent = e.message; } }
  }

  $('login').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    $('login-error').textContent = '';
    try {
      const r = await api('/v1/auth/login', { method: 'POST', body: JSON.stringify({ username: $('username').value.trim(), password: $('password').value }) });
      store.set(r.token); $('password').value = ''; await load();
    } catch (e) { $('login-error').textContent = e.message; }
  });
  $('logout').addEventListener('click', async () => {
    try { await api('/v1/auth/logout', { method: 'POST', body: '{}' }); } catch {}
    store.set(null); show('login');
  });
  $('prev').addEventListener('click', () => { if (page > 0) { page -= 1; drawList(); } });
  $('next').addEventListener('click', () => { page += 1; drawList(); });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && store.get()) load(); });

  if (store.get()) load(); else show('login');
})();`;
