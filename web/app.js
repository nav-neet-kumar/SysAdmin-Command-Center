"use strict";
/* Command Center UI. Everything is rendered with textContent / text nodes (never innerHTML),
   so saved names, URLs or command output can never inject markup or script. */

const TOKEN = document.querySelector('meta[name="cc-token"]').content;
const $ = (s, r = document) => r.querySelector(s);

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  let value;
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v == null) continue;
    if (k === "class") el.className = v;
    else if (k === "value") value = v;
    else if (k === "checked") el.checked = !!v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  if (value !== undefined) el.value = value;
  return el;
}

class ApiError extends Error {
  constructor(status, data) {
    const d = data && data.detail;
    super(typeof d === "string" ? d : (d && d.message) || "Request failed (" + status + ")");
    this.status = status; this.data = data;
  }
}
async function api(path, method = "GET", body) {
  const headers = { "X-CC-Token": TOKEN };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  let res;
  try {
    res = await fetch("/api" + path, { method, headers, cache: "no-store", body: body !== undefined ? JSON.stringify(body) : undefined });
  } catch (_) { setAlive(false); throw new ApiError(0, { detail: "The helper is not running. Open CommandCenter.html to start it." }); }
  setAlive(true);
  let data = {};
  try { data = await res.json(); } catch (_) { /* empty */ }
  if (!res.ok) throw new ApiError(res.status, data);
  return data;
}
function setAlive(on) { $("#dot").classList.toggle("off", !on); }

function toast(msg, kind = "") {
  const t = h("div", { class: kind }, msg);
  $("#toast").append(t); setTimeout(() => t.remove(), 4500);
}
const fail = e => toast(e.message || String(e), "err");

function dialog(title, body, buttons) {
  return new Promise(resolve => {
    const dlg = $("#dlg");
    const done = v => { dlg.onclose = null; dlg.close(); resolve(v); };
    dlg.replaceChildren(h("h3", {}, title), body,
      h("div", { class: "row" }, buttons.map(b => h("button", { class: "btn" + (b.primary ? " primary" : ""), onclick: () => done(b.value) }, b.label))));
    dlg.onclose = () => resolve(null);
    dlg.showModal();
  });
}
const confirmDlg = (title, lines, ok) =>
  dialog(title, Array.isArray(lines) ? h("ul", {}, lines.map(l => h("li", {}, l))) : h("p", {}, lines),
    [{ label: ok, value: true, primary: true }, { label: "Cancel", value: false }]).then(v => v === true);

// ---------------------------------------------------------------- state
const S = { cfg: { sites: [], monitors: [], apps: [], rdp: [] }, status: {}, timers: [] };
const every = (fn, ms) => S.timers.push(setInterval(fn, ms));
const clearTimers = () => { S.timers.forEach(clearInterval); S.timers = []; };

async function saveList(kind, items) {
  const res = await api("/items/" + kind, "PUT", { items });
  S.cfg[kind] = res.items;
  return res.items;
}
async function refreshStatus() {
  try { const r = await api("/status"); S.status = Object.fromEntries(r.results.map(x => [x.id, x])); } catch (_) { /* shown by dot */ }
}
const stateOf = id => (S.status[id] ? S.status[id].status : "unknown");
function detailOf(id) {
  const s = S.status[id];
  if (!s) return "checking…";
  if (s.status === "offline") return "down" + (s.error ? " · " + s.error : s.code ? " · HTTP " + s.code : "");
  return (s.code ? "HTTP " + s.code + " · " : "") + (s.ms != null ? s.ms + " ms" : "up");
}

// ---------------------------------------------------------------- Terminal
const T = { lines: [], cursor: 0, busy: false, cwd: "", hist: [], hpos: 0, timer: null, built: false };

function termView(root) {
  const screen = h("div", { class: "screen", tabindex: "-1" });
  const ps = h("span", { class: "ps" }, "PS " + (T.cwd || "~") + ">");
  const input = h("input", { type: "text", autocomplete: "off", spellcheck: "false", maxlength: "4000", "aria-label": "PowerShell command" });
  const stopBtn = h("button", { class: "btn sm", onclick: stop }, "Stop (Ctrl+C)");
  const status = h("span", {}, "");

  function paint() {
    screen.replaceChildren(...T.lines.map(l => h("div", { class: l.t }, l.s || " ")));
    ps.textContent = "PS " + (T.cwd || "~") + ">";
    status.textContent = T.busy ? "running…" : "ready";
    stopBtn.disabled = !T.busy;
    screen.scrollTop = screen.scrollHeight;
  }
  T.paint = paint;

  async function stop() { try { await api("/term/stop", "POST"); } catch (e) { fail(e); } }
  async function poll() {
    try {
      const r = await api("/term/poll?cursor=" + T.cursor);
      T.cursor = r.cursor; T.cwd = r.cwd;
      for (const s of r.lines) T.lines.push({ t: "", s: String(s).replace(/\r/g, "") });
      if (T.lines.length > 5000) T.lines.splice(0, T.lines.length - 5000);
      const wasBusy = T.busy; T.busy = r.busy;
      paint();
      if (T.busy) T.timer = setTimeout(poll, 150); else { T.timer = null; if (wasBusy) input.focus(); }
    } catch (e) { T.busy = false; T.timer = null; paint(); fail(e); }
  }
  async function run(cmd, confirm = false) {
    try {
      await api("/term/run", "POST", { command: cmd, confirm });
      T.lines.push({ t: "cmdline", s: "PS " + T.cwd + "> " + cmd });
      T.cursor = 0; T.busy = true; paint();
      if (T.timer) clearTimeout(T.timer);
      poll();
    } catch (e) {
      if (e.status === 409 && e.data.detail && e.data.detail.needs_confirm) {
        const ok = await confirmDlg("This command may change the system", e.data.detail.reasons.map(r => "It " + r + "."), "Run it anyway");
        if (ok) return run(cmd, true);
        T.lines.push({ t: "note", s: "Cancelled: " + cmd }); paint(); return;
      }
      if (e.status === 409) { fail(e); return; }
      T.lines.push({ t: "err", s: e.message }); paint();
    }
  }
  async function clear() { T.lines = []; paint(); }
  async function reset() {
    if (!await confirmDlg("Reset terminal?", "This starts a fresh PowerShell session in your home folder and clears variables.", "Reset")) return;
    try { const r = await api("/term/reset", "POST"); T.cwd = r.cwd; T.lines = [{ t: "note", s: "New session started." }]; T.cursor = 0; T.busy = false; paint(); } catch (e) { fail(e); }
  }

  input.addEventListener("keydown", e => {
    if (e.key === "Enter") {
      const cmd = input.value; if (!cmd.trim()) return;
      if (T.busy) { toast("A command is still running. Press Ctrl+C to stop it.", "err"); return; }
      T.hist.push(cmd); T.hpos = T.hist.length; input.value = ""; run(cmd);
    } else if (e.key === "ArrowUp") { if (T.hpos > 0) { T.hpos--; input.value = T.hist[T.hpos]; } e.preventDefault(); }
    else if (e.key === "ArrowDown") { if (T.hpos < T.hist.length - 1) { T.hpos++; input.value = T.hist[T.hpos]; } else { T.hpos = T.hist.length; input.value = ""; } e.preventDefault(); }
    else if (e.key.toLowerCase() === "c" && e.ctrlKey && !window.getSelection().toString()) { e.preventDefault(); if (T.busy) stop(); else input.value = ""; }
    else if (e.key.toLowerCase() === "l" && e.ctrlKey) { e.preventDefault(); clear(); }
  });
  screen.addEventListener("click", () => { if (!window.getSelection().toString()) input.focus(); });

  root.append(h("div", { class: "term" },
    h("div", { class: "termbar" }, h("span", {}, "PowerShell · runs on this laptop as your account"), h("span", { class: "sp" }), status, stopBtn,
      h("button", { class: "btn sm", onclick: clear }, "Clear"), h("button", { class: "btn sm", onclick: reset }, "Reset")),
    screen, h("div", { class: "inline" }, ps, input)));

  if (!T.built) { T.lines.push({ t: "note", s: "PowerShell session ready. cd, variables and history persist. Up/Down = history, Ctrl+C = stop, Ctrl+L = clear." }); T.built = true; }
  paint(); input.focus();
  api("/term/poll?cursor=" + T.cursor).then(r => { T.cwd = r.cwd; T.busy = r.busy; if (T.busy) poll(); else paint(); }).catch(() => { });
}

// ---------------------------------------------------------------- Sites
function sitesView(root) {
  const name = h("input", { type: "text", placeholder: "Name (e.g. Office portal)", maxlength: "60", class: "grow" });
  const url = h("input", { type: "text", placeholder: "https://example.com", maxlength: "2048", class: "grow" });
  const grid = h("div", { class: "grid" });
  async function add() {
    let u = url.value.trim();
    if (u && !/^[a-z][a-z0-9+.-]*:/i.test(u)) u = "https://" + u;
    try { await saveList("sites", [...S.cfg.sites, { name: name.value || u.replace(/^https?:\/\//, "").split("/")[0], url: u }]); name.value = ""; url.value = ""; toast("Added", "ok"); await refreshStatus(); draw(); } catch (e) { fail(e); }
  }
  async function remove(s) { try { await saveList("sites", S.cfg.sites.filter(x => x.id !== s.id)); draw(); } catch (e) { fail(e); } }
  function draw() {
    grid.replaceChildren(...(S.cfg.sites.length ? S.cfg.sites.map(s =>
      h("div", { class: "tile", title: s.url, onclick: () => window.open(s.url, "_blank", "noopener,noreferrer") },
        h("span", { class: "sdot " + stateOf(s.id) }),
        h("div", { class: "txt" }, h("div", { class: "nm" }, s.name), h("div", { class: "sub" }, detailOf(s.id))),
        h("button", { class: "btn sm danger x", title: "Remove", onclick: ev => { ev.stopPropagation(); remove(s); } }, "✕")))
      : [h("div", { class: "empty" }, "No websites yet. Add one above.")]));
  }
  url.addEventListener("keydown", e => { if (e.key === "Enter") add(); });
  root.append(h("h2", {}, "Websites"), h("div", { class: "form" }, name, url, h("button", { class: "btn primary", onclick: add }, "Add website")), grid,
    h("p", { class: "muted" }, "Green = up, red = down. Click a site to open it in a new tab. Checked automatically every 60 seconds."));
  draw(); refreshStatus().then(draw);
  every(async () => { await refreshStatus(); draw(); }, 8000);
}

// ---------------------------------------------------------------- Monitor
function monitorView(root) {
  const name = h("input", { type: "text", placeholder: "Name (e.g. File server)", maxlength: "60", class: "grow" });
  const target = h("input", { type: "text", placeholder: "IP, host, host:port or https://url", maxlength: "2048", class: "grow" });
  const body = h("tbody");
  async function add() {
    const t = target.value.trim();
    try { await saveList("monitors", [...S.cfg.monitors, { name: name.value || t, target: t }]); name.value = ""; target.value = ""; toast("Added", "ok"); await refreshStatus(); draw(); } catch (e) { fail(e); }
  }
  async function remove(m) { try { await saveList("monitors", S.cfg.monitors.filter(x => x.id !== m.id)); draw(); } catch (e) { fail(e); } }
  function kindOf(t) { return /^https?:\/\//i.test(t) ? "URL" : /:\d+$/.test(t) && !/^[0-9a-f:]+$/i.test(t) ? "TCP port" : "Ping"; }
  function draw() {
    body.replaceChildren(...(S.cfg.monitors.length ? S.cfg.monitors.map(m => {
      const st = stateOf(m.id), s = S.status[m.id];
      return h("tr", {}, h("td", {}, m.name), h("td", { class: "muted" }, m.target), h("td", {}, kindOf(m.target)),
        h("td", {}, h("span", { class: "pill " + st }, st === "unknown" ? "checking" : st === "online" ? "reachable" : st === "degraded" ? "responding (error)" : "not reachable")),
        h("td", {}, s ? (s.ms != null ? s.ms + " ms" : s.error || "—") : "—"), h("td", { class: "muted" }, s ? s.at : "—"),
        h("td", {}, h("button", { class: "btn sm danger", onclick: () => remove(m) }, "Remove")));
    }) : [h("tr", {}, h("td", { colspan: "7" }, h("div", { class: "empty" }, "Nothing monitored yet. Add an IP address or URL above.")))]));
  }
  target.addEventListener("keydown", e => { if (e.key === "Enter") add(); });
  root.append(h("h2", {}, "Monitor an IP or URL"),
    h("div", { class: "form" }, name, target, h("button", { class: "btn primary", onclick: add }, "Add monitor"),
      h("button", { class: "btn", onclick: async () => { try { await api("/status/refresh", "POST"); toast("Checking now…"); setTimeout(async () => { await refreshStatus(); draw(); }, 2500); } catch (e) { fail(e); } } }, "Check now")),
    h("table", {}, h("thead", {}, h("tr", {}, ["Name", "Target", "Type", "Status", "Response", "Checked", ""].map(x => h("th", {}, x)))), body),
    h("p", { class: "muted" }, "IP or host = ping. host:port (e.g. 10.0.0.5:443) = TCP port check. https://… = web request. Checked every 60 seconds."));
  draw(); refreshStatus().then(draw);
  every(async () => { await refreshStatus(); draw(); }, 8000);
}

// ---------------------------------------------------------------- Applications
function appsView(root) {
  const name = h("input", { type: "text", placeholder: "Name", maxlength: "60" });
  const path = h("input", { type: "text", placeholder: "C:\\Program Files\\App\\app.exe  or  notepad.exe", maxlength: "260", class: "grow wide" });
  const args = h("input", { type: "text", placeholder: "Arguments (optional)", maxlength: "500" });
  const admin = h("input", { type: "checkbox", id: "admin-new" });
  const grid = h("div", { class: "grid" });

  async function add() {
    const p = path.value.trim();
    const nm = name.value.trim() || p.split(/[\\/]/).pop().replace(/\.[^.]+$/, "");
    try { await saveList("apps", [...S.cfg.apps, { name: nm, path: p, args: args.value, admin: admin.checked }]); name.value = path.value = args.value = ""; admin.checked = false; toast("Added", "ok"); draw(); } catch (e) { fail(e); }
  }
  async function launch(a) {
    try {
      if (a.admin && !await confirmDlg("Run as administrator?", ["Windows will show its UAC prompt for " + a.name + ".", "This cannot bypass your organisation's policies."], "Continue")) return;
      await api("/launch/app", "POST", { id: a.id }); toast("Launching " + a.name + (a.admin ? " as administrator" : ""), "ok");
    } catch (e) { fail(e); }
  }
  async function toggleAdmin(a, on) {
    try { await saveList("apps", S.cfg.apps.map(x => x.id === a.id ? { ...x, admin: on } : x)); draw(); } catch (e) { fail(e); }
  }
  async function remove(a) { try { await saveList("apps", S.cfg.apps.filter(x => x.id !== a.id)); draw(); } catch (e) { fail(e); } }

  async function browse() {
    try {
      await api("/pick", "POST");
      toast("Choose a program in the Windows file window…");
      for (let i = 0; i < 300; i++) {
        await new Promise(r => setTimeout(r, 1000));
        const r = await api("/pick");
        if (r.done) { if (r.path) { path.value = r.path; if (!name.value) name.value = r.path.split(/[\\/]/).pop().replace(/\.[^.]+$/, ""); } return; }
      }
    } catch (e) { fail(e); }
  }
  async function pickInstalled() {
    try {
      toast("Reading installed programs…");
      const r = await api("/apps/discover");
      if (!r.items.length) { toast("No installed programs found.", "err"); return; }
      const sel = h("select", { size: "10" }, r.items.map((a, i) => h("option", { value: String(i) }, a.name)));
      const v = await dialog("Installed programs", sel, [{ label: "Use this", value: "ok", primary: true }, { label: "Cancel", value: null }]);
      if (v === "ok" && sel.value !== "") { const a = r.items[+sel.value]; name.value = a.name; path.value = a.path; }
    } catch (e) { fail(e); }
  }

  function draw() {
    grid.replaceChildren(...(S.cfg.apps.length ? S.cfg.apps.map(a => {
      const cb = h("input", { type: "checkbox", checked: a.admin, "aria-label": "Run " + a.name + " as administrator", onclick: ev => ev.stopPropagation(), onchange: ev => toggleAdmin(a, ev.target.checked) });
      return h("div", { class: "tile app", title: a.path, onclick: () => launch(a) },
        h("div", { class: "txt" }, h("div", { class: "nm" }, a.name), h("div", { class: "sub" }, a.path + (a.args ? " " + a.args : ""))),
        h("button", { class: "btn sm danger x", title: "Remove", onclick: ev => { ev.stopPropagation(); remove(a); } }, "✕"),
        h("label", { class: "adm", onclick: ev => ev.stopPropagation() }, cb, "Run as admin"));
    }) : [h("div", { class: "empty" }, "No applications yet. Add one above.")]));
  }
  root.append(h("h2", {}, "Applications"),
    h("div", { class: "form" }, name, path,
      h("button", { class: "btn", onclick: browse }, "Browse…"), h("button", { class: "btn", onclick: pickInstalled }, "Installed programs…"), args,
      h("label", {}, admin, "Run as administrator"), h("button", { class: "btn primary", onclick: add }, "Add application")),
    grid, h("p", { class: "muted" }, "Click an application to launch it. Tick “Run as admin” on a card to switch it any time; Windows shows its normal UAC prompt."));
  draw();
}

// ---------------------------------------------------------------- Remote desktop
function rdpView(root) {
  const name = h("input", { type: "text", placeholder: "Name (e.g. App server)", maxlength: "60", class: "grow" });
  const host = h("input", { type: "text", placeholder: "IP or hostname (optional :port)", maxlength: "260", class: "grow" });
  const grid = h("div", { class: "grid" });
  async function add() {
    const hv = host.value.trim();
    try { await saveList("rdp", [...S.cfg.rdp, { name: name.value || hv, host: hv }]); name.value = host.value = ""; toast("Added", "ok"); draw(); } catch (e) { fail(e); }
  }
  async function connect(r) { try { await api("/launch/rdp", "POST", { id: r.id }); toast("Opening Remote Desktop to " + r.host, "ok"); } catch (e) { fail(e); } }
  async function remove(r) { try { await saveList("rdp", S.cfg.rdp.filter(x => x.id !== r.id)); draw(); } catch (e) { fail(e); } }
  function draw() {
    grid.replaceChildren(...(S.cfg.rdp.length ? S.cfg.rdp.map(r =>
      h("div", { class: "tile", title: "Connect to " + r.host, onclick: () => connect(r) },
        h("div", { class: "txt" }, h("div", { class: "nm" }, r.name), h("div", { class: "sub" }, r.host)),
        h("button", { class: "btn sm danger x", title: "Remove", onclick: ev => { ev.stopPropagation(); remove(r); } }, "✕")))
      : [h("div", { class: "empty" }, "No servers yet. Add an IP address above.")]));
  }
  host.addEventListener("keydown", e => { if (e.key === "Enter") add(); });
  root.append(h("h2", {}, "Remote Desktop"), h("div", { class: "form" }, name, host, h("button", { class: "btn primary", onclick: add }, "Add server")), grid,
    h("p", { class: "muted" }, "Click a server to open Remote Desktop (mstsc) with that address. Passwords are never stored; Windows asks for them."));
  draw();
}

// ---------------------------------------------------------------- shell
const TABS = [["terminal", "Terminal", termView], ["sites", "Websites", sitesView], ["monitor", "Monitor", monitorView], ["apps", "Applications", appsView], ["rdp", "Remote Desktop", rdpView]];

function go(id) {
  clearTimers();
  const tab = TABS.find(t => t[0] === id) || TABS[0];
  history.replaceState(null, "", "#" + tab[0]);
  $("#tabs").replaceChildren(...TABS.map(t => h("button", { class: t[0] === tab[0] ? "on" : "", onclick: () => go(t[0]) }, t[1])));
  const root = h("div"); $("#view").replaceChildren(root);
  tab[2](root);
}

$("#themeBtn").addEventListener("click", () => {
  const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem("cc-theme", next); } catch (_) { /* optional */ }
});
try { const t = localStorage.getItem("cc-theme"); if (t === "light" || t === "dark") document.documentElement.dataset.theme = t; } catch (_) { /* optional */ }

(async () => {
  try {
    const c = await api("/config");
    S.cfg = { sites: c.sites, monitors: c.monitors, apps: c.apps, rdp: c.rdp };
    $("#who").textContent = c.me.computer + " · " + c.me.user;
    await refreshStatus();
  } catch (e) { fail(e); }
  go(location.hash.slice(1));
})();
