import { WTerm } from "@wterm/dom";
import { GhosttyCore } from "@wterm/ghostty";
import "bootstrap/dist/css/bootstrap.min.css";
import "@wterm/dom/css";
import "./style.css";
import init, { ZukoClient, type ZukoSession } from "./wasm/zuko_web.js";
import { BrowserStore, type SavedHost } from "./storage";

const encoder = new TextEncoder();
const store = new BrowserStore();
const themeMedia = window.matchMedia("(prefers-color-scheme: dark)");
const themeOrder = ["auto", "light", "dark"] as const;
const terminalFont = '14px "DejaVu Mono"';
const terminalFontSample = "W│─┌┐└┘┬┴├┤┼█▉▊▋▌▍▎▏◆●✓⚠";
const themeIcons = {
  auto: `
    <svg viewBox="0 0 16 16" role="img" focusable="false">
      <path d="M8 15A7 7 0 1 0 8 1v14Zm0-1.2V2.2a5.8 5.8 0 0 1 0 11.6Z" fill="currentColor"/>
    </svg>`,
  light: `
    <svg viewBox="0 0 16 16" role="img" focusable="false">
      <path d="M8 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm0-10.5a.75.75 0 0 0 .75-.75v-.5a.75.75 0 0 0-1.5 0v.5A.75.75 0 0 0 8 1.5Zm0 13a.75.75 0 0 0-.75.75v.5a.75.75 0 0 0 1.5 0v-.5A.75.75 0 0 0 8 14.5ZM14.5 8a.75.75 0 0 0 .75.75h.5a.75.75 0 0 0 0-1.5h-.5A.75.75 0 0 0 14.5 8ZM.25 8.75h.5a.75.75 0 0 0 0-1.5h-.5a.75.75 0 0 0 0 1.5Zm11.28-5.03a.75.75 0 0 0 .53-.22l.36-.35a.75.75 0 0 0-1.06-1.06l-.35.35a.75.75 0 0 0 .52 1.28ZM3.58 12.86l-.35.35a.75.75 0 0 0 1.06 1.06l.35-.35a.75.75 0 0 0-1.06-1.06Zm8.84 0a.75.75 0 0 0-1.06 1.06l.35.35a.75.75 0 1 0 1.06-1.06l-.35-.35ZM3.58 3.14a.75.75 0 1 0 1.06-1.06l-.35-.35a.75.75 0 1 0-1.06 1.06l.35.35Z" fill="currentColor"/>
    </svg>`,
  dark: `
    <svg viewBox="0 0 16 16" role="img" focusable="false">
      <path d="M13.47 10.79A6.5 6.5 0 0 1 5.21 2.53 6.5 6.5 0 1 0 13.47 10.8Z" fill="currentColor"/>
    </svg>`,
} satisfies Record<ThemePreference, string>;
let themeToggleEl: HTMLButtonElement | null = null;
let themePreference = readThemePreference();
applyTheme(themePreference);

document.querySelector<HTMLDivElement>("#app")!.innerHTML = `
  <header class="navbar navbar-expand border-bottom bg-body-tertiary px-3">
    <h1 class="navbar-brand mb-0">zuko web</h1>
    <span class="navbar-text d-none d-md-inline">Iroh WASM + Ghostty terminal core</span>
    <button id="theme-toggle" class="btn btn-outline-secondary btn-sm icon-button ms-auto" type="button"></button>
    <a class="btn btn-outline-secondary btn-sm ms-2" href="../">Docs</a>
  </header>
  <main class="container-fluid p-0">
    <div class="row g-0 app-grid">
      <aside class="col-12 col-lg-4 col-xl-3 border-end bg-body-tertiary sidebar">
        <section class="card m-3 shadow-sm">
          <div class="card-body">
            <h2 class="h5 card-title">Pair</h2>
            <p class="card-text small text-secondary">Run <code>zuko share</code> on the host, then claim the one-time code here.</p>
            <form id="claim-form" class="vstack gap-3">
              <label class="form-label mb-0">Share code
                <input class="form-control mt-1" name="code" autocomplete="one-time-code" placeholder="iridescent-hilton" required />
              </label>
              <label class="form-label mb-0">Save as
                <input class="form-control mt-1" name="name" placeholder="home" />
              </label>
              <button class="btn btn-primary" type="submit">Claim host</button>
            </form>
          </div>
        </section>
        <section class="card m-3 shadow-sm">
          <div class="card-body">
            <h2 class="h5 card-title">Saved hosts</h2>
            <div id="hosts" class="list-group list-group-flush"></div>
          </div>
        </section>
        <section class="card m-3 shadow-sm">
          <div class="card-body">
            <h2 class="h5 card-title">Status</h2>
            <pre id="status" class="small text-info-emphasis mb-0">loading…</pre>
          </div>
        </section>
      </aside>
      <section class="col terminal-shell">
        <div id="terminal" aria-label="zuko terminal"></div>
      </section>
    </div>
  </main>
`;

const statusEl = document.querySelector<HTMLPreElement>("#status")!;
const hostsEl = document.querySelector<HTMLDivElement>("#hosts")!;
const terminalEl = document.querySelector<HTMLDivElement>("#terminal")!;
const claimForm = document.querySelector<HTMLFormElement>("#claim-form")!;
const themeToggleButton = document.querySelector<HTMLButtonElement>("#theme-toggle")!;
themeToggleEl = themeToggleButton;
applyTheme(themePreference);

let client: ZukoClient | null = null;
let session: ZukoSession | null = null;
let term: WTerm | null = null;
let pendingResize: { cols: number; rows: number } | null = null;
let resizeTimer: number | null = null;
let remoteChunks: Uint8Array[] = [];
let remoteWriteFrame: number | null = null;

themeToggleButton.addEventListener("click", () => {
  const index = themeOrder.indexOf(themePreference);
  themePreference = themeOrder[(index + 1) % themeOrder.length];
  writeThemePreference(themePreference);
  applyTheme(themePreference);
});

themeMedia.addEventListener("change", () => applyTheme(themePreference));

await boot();

async function boot(): Promise<void> {
  status("loading terminal font…");
  await loadTerminalFonts();
  await nextFrame();

  const core = await GhosttyCore.load();
  term = new WTerm(terminalEl, {
    core,
    cursorBlink: true,
    onData: (data) => {
      if (session) {
        void sendToSession(encoder.encode(data));
      } else {
        term?.write(data);
      }
    },
    onResize: (cols, rows) => scheduleResize(cols, rows),
  });
  await term.init();
  term.write("\x1b[1;36mzuko web\x1b[0m — Ghostty terminal core loaded\r\n");

  await init();
  const key = await store.clientKey();
  client = await ZukoClient.spawn(key);
  status(`ready\nendpoint: ${client.endpoint_id()}\nstorage: IndexedDB (${location.origin})`);
  await renderHosts();
}

claimForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void claim(new FormData(claimForm));
});

async function claim(form: FormData): Promise<void> {
  if (!client) return;
  const code = String(form.get("code") ?? "").trim();
  const name = String(form.get("name") ?? "").trim();
  if (!code) return;

  status(`claiming ${code}…`);
  const result = await client.claim(
    code,
    navigator.userAgentData?.platform ?? navigator.platform ?? "browser",
    60n,
  );
  const saveName = sanitizeName(name || result.label || "host");
  await store.upsertHost({
    name: saveName,
    label: result.label,
    ticket: result.ticket,
    tokenHex: result.tokenHex,
  });
  status(`claimed ${result.label}\nsaved as ${saveName}`);
  claimForm.reset();
  await renderHosts();
}

async function renderHosts(): Promise<void> {
  const hosts = await store.hosts();
  hostsEl.replaceChildren();
  if (hosts.length === 0) {
    hostsEl.innerHTML = `<p class="text-secondary mb-0">No saved hosts yet.</p>`;
    return;
  }
  for (const host of hosts) {
    const row = document.createElement("article");
    row.className = "list-group-item bg-transparent px-0";
    const label = document.createElement("button");
    label.type = "button";
    label.className = "btn btn-link p-0 text-start fw-semibold host-name";
    label.textContent = host.name;
    label.onclick = () => void connect(host);
    const meta = document.createElement("div");
    meta.className = "small text-secondary text-truncate";
    meta.textContent = host.label;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "btn btn-outline-secondary btn-sm mt-2";
    remove.textContent = "remove";
    remove.onclick = async () => {
      await store.removeHost(host.name);
      await renderHosts();
    };
    row.append(label, meta, remove);
    hostsEl.append(row);
  }
}

async function connect(host: SavedHost): Promise<void> {
  if (!client || !term) return;
  session?.close();
  term.write(`\r\n\x1b[1;33mconnecting to ${host.name}…\x1b[0m\r\n`);
  status(`connecting ${host.name}…`);
  const key = await store.clientKey();
  const pixels = terminalPixels(term.cols, term.rows);
  session = await client.connect(host.ticket, key, term.cols, term.rows, pixels.width, pixels.height);
  status(`connected ${host.name}`);

  const reader = session.events().getReader();
  void (async () => {
    while (true) {
      const { done, value } = await reader.read();
      if (done || !value) break;
      if (value.type === "data") {
        writeRemote(new Uint8Array(value.bytes));
      } else if (value.type === "attached") {
        await store.upsertHost({ ...host, tokenHex: value.tokenHex });
      } else if (value.type === "error") {
        term.write(`\r\n\x1b[1;31mhost rejected: ${value.message}\x1b[0m\r\n`);
        status(`host rejected ${host.name}: ${value.message}`);
        session = null;
      } else if (value.type === "closed") {
        status(value.error ? `closed: ${value.error}` : `closed ${host.name}`);
        session = null;
      }
    }
  })();
}

function writeRemote(bytes: Uint8Array): void {
  remoteChunks.push(bytes);
  if (remoteWriteFrame !== null) return;
  remoteWriteFrame = requestAnimationFrame(() => {
    remoteWriteFrame = null;
    if (!term || remoteChunks.length === 0) return;
    const chunks = remoteChunks;
    remoteChunks = [];
    const size = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    const merged = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      merged.set(chunk, offset);
      offset += chunk.length;
    }
    term.write(merged);
  });
}

function scheduleResize(cols: number, rows: number): void {
  pendingResize = { cols, rows };
  if (!session) return;
  if (resizeTimer !== null) clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(() => {
    resizeTimer = null;
    const next = pendingResize;
    pendingResize = null;
    if (next) void resizeSession(next.cols, next.rows);
  }, 80);
}

async function sendToSession(data: Uint8Array): Promise<void> {
  const active = session;
  if (!active) return;
  try {
    await active.send(data);
  } catch (err) {
    if (active === session) session = null;
    status(`closed: ${err instanceof Error ? err.message : String(err)}`);
  }
}

async function resizeSession(cols: number, rows: number): Promise<void> {
  const active = session;
  if (!active) return;
  try {
    const pixels = terminalPixels(cols, rows);
    await active.resize(cols, rows, pixels.width, pixels.height);
  } catch {
    if (active === session) session = null;
  }
}

function terminalPixels(cols: number, rows: number): { width: number; height: number } {
  const metrics = measureTerminalCell(cols, rows);
  return {
    width: clampU16(Math.round(metrics.charWidth * cols)),
    height: clampU16(Math.round(metrics.rowHeight * rows)),
  };
}

function measureTerminalCell(fallbackCols: number, fallbackRows: number): { charWidth: number; rowHeight: number } {
  const row = document.createElement("div");
  row.className = "term-row term-measure-probe";
  const probe = document.createElement("span");
  const probeText = "W".repeat(64);
  probe.textContent = probeText;
  row.append(probe);
  (terminalEl.querySelector(".term-grid") ?? terminalEl).append(row);
  const probeRect = probe.getBoundingClientRect();
  const rowRect = row.getBoundingClientRect();
  row.remove();

  const charWidth = probeRect.width / probeText.length || terminalEl.clientWidth / Math.max(fallbackCols, 1);
  const rowHeight = rowRect.height || probeRect.height || terminalEl.clientHeight / Math.max(fallbackRows, 1);
  return {
    charWidth,
    rowHeight,
  };
}

function clampU16(value: number): number {
  return Math.max(1, Math.min(65535, value));
}

function status(text: string): void {
  statusEl.textContent = text;
}

async function loadTerminalFonts(): Promise<void> {
  if (!("fonts" in document)) return;
  try {
    await Promise.all([
      document.fonts.load(`400 ${terminalFont}`, terminalFontSample),
      document.fonts.load(`italic 400 ${terminalFont}`, terminalFontSample),
      document.fonts.load(`700 ${terminalFont}`, terminalFontSample),
      document.fonts.load(`italic 700 ${terminalFont}`, terminalFontSample),
    ]);
    await document.fonts.ready;
  } catch {
    // If FontFaceSet is unavailable or blocked, wterm falls back to the CSS stack.
  }
}

function nextFrame(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

function applyTheme(preference: ThemePreference): void {
  const resolved = resolveTheme(preference);
  document.documentElement.dataset.bsTheme = resolved;
  document.documentElement.style.colorScheme = resolved;
  if (themeToggleEl) renderThemeToggle(preference, resolved);
}

function renderThemeToggle(preference: ThemePreference, resolved: ResolvedTheme): void {
  const next = themeOrder[(themeOrder.indexOf(preference) + 1) % themeOrder.length];
  const summary = preference === "auto" ? `auto (${resolved})` : preference;
  const label = `Theme: ${summary}. Switch to ${next}.`;
  if (!themeToggleEl) return;
  themeToggleEl.innerHTML = `${themeIcons[preference]}<span class="visually-hidden">${label}</span>`;
  themeToggleEl.setAttribute("aria-label", label);
  themeToggleEl.title = label;
}

function resolveTheme(preference: ThemePreference): ResolvedTheme {
  if (preference === "auto") return themeMedia.matches ? "dark" : "light";
  return preference;
}

function readThemePreference(): ThemePreference {
  try {
    const value = localStorage.getItem("zuko.theme");
    if (isThemePreference(value)) return value;
  } catch {
    // Storage can be disabled by browser privacy settings. Fall back to auto.
  }
  return "auto";
}

function writeThemePreference(preference: ThemePreference): void {
  try {
    if (preference === "auto") {
      localStorage.removeItem("zuko.theme");
    } else {
      localStorage.setItem("zuko.theme", preference);
    }
  } catch {
    // Ignore storage failures; the in-memory preference still applies now.
  }
}

function isThemePreference(value: string | null): value is ThemePreference {
  return value === "auto" || value === "light" || value === "dark";
}

function sanitizeName(value: string): string {
  const cleaned = value.trim().replace(/\s+/g, "-").replace(/^#+/, "");
  return cleaned || "host";
}

type ThemePreference = (typeof themeOrder)[number];
type ResolvedTheme = "light" | "dark";

declare global {
  interface Navigator {
    userAgentData?: { platform?: string };
  }
}
