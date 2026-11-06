"use strict";

// ---------------------------------------------------------------------------
// herdr dashboard — frontend
// ---------------------------------------------------------------------------

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

const REFRESH_MS = 3000;
const PANE_REFRESH_MS = 2000;

const STATUS = {
  working: { label: "arbeitet", rank: 1 },
  blocked: { label: "wartet", rank: 0 },
  done: { label: "fertig", rank: 2 },
  idle: { label: "bereit", rank: 3 },
  unknown: { label: "unbekannt", rank: 4 },
};

const SERVICE_LABELS = {
  herdr: "herdr server",
  ttyd: "Web-Terminal",
  "herdr-dashboard": "Dashboard",
};

const state = {
  data: null,
  agents: [],
  filter: "all",
  collapsed: new Set(),
  selectedPane: null,
  promptPane: null,
  drawerTimer: null,
  drawerLoading: false,
  snapshotLoading: false,
  lastSuccess: 0,
  offlineNotified: false,
  errors: 0,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  const digits = value >= 100 || index === 0 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${units[index]}`;
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  const total = Math.floor(seconds);
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function percent(part, total) {
  if (!total) return 0;
  return Math.min(100, Math.max(0, (part / total) * 100));
}

function setBar(name, usedPercent, valueText, noteText) {
  const row = document.querySelector(`.bar-row[data-bar="${name}"]`);
  const bar = $(`#${name}Bar`);
  const value = $(`#${name}Value`);
  const note = $(`#${name}Note`);
  if (!row || !bar) return;
  const clamped = Math.min(100, Math.max(0, usedPercent));
  bar.style.width = `${clamped.toFixed(1)}%`;
  value.textContent = valueText;
  if (note) note.textContent = noteText;
  row.classList.toggle("is-warn", clamped >= 70 && clamped < 90);
  row.classList.toggle("is-critical", clamped >= 90);
}

function statusKey(value) {
  return STATUS[value] ? value : "unknown";
}

function statusLabel(value) {
  return STATUS[statusKey(value)].label;
}

function timeAgo(timestamp) {
  if (!timestamp) return "—";
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
  if (seconds < 5) return "gerade eben";
  if (seconds < 60) return `vor ${seconds}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `vor ${minutes}m`;
  const hours = Math.round(minutes / 60);
  return `vor ${hours}h`;
}

function errorMessage(error) {
  if (!error) return "Unbekannter Fehler";
  if (error.code && error.code !== "http_error") {
    return `${error.code}: ${error.message || ""}`.trim();
  }
  return error.message || String(error);
}

async function api(url, options = {}) {
  const { headers, ...rest } = options;
  const response = await fetch(url, {
    credentials: "same-origin",
    cache: "no-store",
    ...rest,
    headers: { Accept: "application/json", ...(headers || {}) },
  });

  let payload = null;
  try {
    payload = await response.json();
  } catch {
    payload = null;
  }

  if (!response.ok || (payload && payload.ok === false)) {
    const detail = payload && payload.error ? payload.error : {};
    const error = new Error(detail.message || `HTTP ${response.status}`);
    error.code = detail.code || "http_error";
    error.status = response.status;
    throw error;
  }
  return payload;
}

// ---------------------------------------------------------------------------
// Toasts
// ---------------------------------------------------------------------------

function toast(title, message = "", kind = "info") {
  const host = $("#toasts");
  if (!host) return;
  while (host.children.length >= 3) host.firstElementChild.remove();

  const node = document.createElement("div");
  node.className = `toast is-${kind}`;
  node.innerHTML = `
    <span class="toast-dot"></span>
    <div class="toast-body">
      <b>${escapeHtml(title)}</b>
      ${message ? `<span>${escapeHtml(message)}</span>` : ""}
    </div>`;
  host.appendChild(node);
  window.setTimeout(() => {
    node.style.opacity = "0";
    node.style.transform = "translateY(6px)";
    node.style.transition = "opacity .2s ease, transform .2s ease";
    window.setTimeout(() => node.remove(), 220);
  }, 4400);
}

// ---------------------------------------------------------------------------
// Snapshot loading
// ---------------------------------------------------------------------------

async function loadSnapshot({ silent = false } = {}) {
  if (state.snapshotLoading) return;
  state.snapshotLoading = true;

  try {
    const payload = await api("/api/snapshot");
    state.data = payload;
    state.agents = Array.isArray(payload.snapshot?.agents) ? payload.snapshot.agents : [];
    state.lastSuccess = Date.now();
    state.errors = 0;
    state.offlineNotified = false;
    setConnection("live", "live");
    renderAll();
  } catch (error) {
    state.errors += 1;
    setConnection("offline", "offline");
    if (!silent && !state.data) {
      toast("Dashboard nicht erreichbar", errorMessage(error), "error");
    } else if (!state.offlineNotified) {
      state.offlineNotified = true;
      toast("Verbindung verloren", errorMessage(error), "error");
    }
    renderOffline(error);
  } finally {
    state.snapshotLoading = false;
    updateUpdated();
  }
}

function setConnection(mode, text) {
  const pill = $("#connection");
  const label = $("#connectionText");
  if (!pill || !label) return;
  pill.classList.toggle("live", mode === "live");
  pill.classList.toggle("offline", mode === "offline");
  pill.classList.toggle("loading", mode === "loading");
  label.textContent = text;
}

function updateUpdated() {
  const node = $("#updated");
  if (!node) return;
  node.textContent = state.lastSuccess ? `aktualisiert ${timeAgo(state.lastSuccess)}` : "—";
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

function renderAll() {
  renderVersions();
  renderMetrics();
  renderAgents();
  renderWorkspaces();
  renderSystem();
  renderServices();
}

function renderVersions() {
  const data = state.data;
  if (!data) return;
  const version = data.herdr?.version || "?";
  $("#version").textContent = `herdr ${version}`;
  $("#footerVersion").textContent = `v${data.dashboard?.version || "?"}`;
  $("#footerMeta").textContent = `herdr ${version} · protocol ${data.herdr?.protocol ?? "?"}`;
  $("#hostname").textContent = data.system?.hostname || "—";
  $("#socketPath").textContent = data.herdr?.socket || "—";
  $("#socketPath").title = data.herdr?.socket || "";
}

function renderMetrics() {
  const data = state.data;
  if (!data) return;
  const snapshot = data.snapshot || {};
  const agents = state.agents;
  const panes = snapshot.panes || [];
  const workspaces = snapshot.workspaces || [];
  const tabs = snapshot.tabs || [];
  const working = agents.filter((agent) => agent.agent_status === "working").length;
  const blocked = agents.filter((agent) => agent.agent_status === "blocked").length;
  const load = data.system?.load || {};

  $("#metricAgents").textContent = String(agents.length);
  $("#metricAgentsNote").textContent = working ? `${working} aktiv` : "keine aktiv";

  $("#metricBlocked").textContent = String(blocked);
  $("#metricBlockedNote").textContent = blocked ? "Antwort nötig" : "alles ruhig";
  $("#metricBlocked").closest(".metric").classList.toggle("has-alert", blocked > 0);

  $("#metricPanes").textContent = String(panes.length);
  $("#metricPanesNote").textContent = `${workspaces.length} Spaces · ${tabs.length} Tabs`;

  $("#metricLoad").textContent = String(load.one ?? "—");
  $("#metricLoadNote").textContent = `${data.system?.cpus || "?"} vCPU · 5m ${load.five ?? "—"}`;

  const counts = {
    all: agents.length,
    working,
    blocked,
    idle: agents.filter((agent) => ["idle", "done", "unknown"].includes(agent.agent_status)).length,
  };
  $("#countAll").textContent = counts.all;
  $("#countWorking").textContent = counts.working;
  $("#countBlocked").textContent = counts.blocked;
  $("#countIdle").textContent = counts.idle;

  $("#agentsSub").textContent = agents.length
    ? `${working} arbeitet · ${blocked} wartet · ${agents.length - working - blocked} bereit`
    : "Keine Agents aktiv";
}

function sortAgents(agents) {
  return [...agents].sort((a, b) => {
    const rankA = STATUS[statusKey(a.agent_status)].rank;
    const rankB = STATUS[statusKey(b.agent_status)].rank;
    if (rankA !== rankB) return rankA - rankB;
    const nameA = (a.display_agent || a.agent || a.name || "").toLowerCase();
    const nameB = (b.display_agent || b.agent || b.name || "").toLowerCase();
    return nameA.localeCompare(nameB);
  });
}

function agentMatchesFilter(agent) {
  if (state.filter === "all") return true;
  if (state.filter === "idle") {
    return ["idle", "done", "unknown"].includes(agent.agent_status);
  }
  return agent.agent_status === state.filter;
}

function renderAgents() {
  const grid = $("#agentGrid");
  const empty = $("#agentEmpty");
  if (!grid) return;

  const snapshot = state.data?.snapshot || {};
  const workspaces = new Map((snapshot.workspaces || []).map((ws) => [ws.workspace_id, ws]));
  const tabs = new Map((snapshot.tabs || []).map((tab) => [tab.tab_id, tab]));
  const panes = new Map((snapshot.panes || []).map((pane) => [pane.pane_id, pane]));

  const agents = sortAgents(state.agents).filter(agentMatchesFilter);

  grid.innerHTML = agents
    .map((agent) => {
      const status = statusKey(agent.agent_status);
      const pane = panes.get(agent.pane_id);
      const workspace = workspaces.get(agent.workspace_id);
      const tab = tabs.get(agent.tab_id);
      const name =
        agent.display_agent || agent.agent || agent.name || pane?.label || "Agent";
      const title =
        agent.terminal_title_stripped ||
        agent.title ||
        agent.terminal_title ||
        pane?.terminal_title_stripped ||
        pane?.title ||
        "Keine Terminal-Titel";
      const cwd = agent.foreground_cwd || agent.cwd || pane?.foreground_cwd || pane?.cwd || "";
      const workspaceLabel = workspace?.label || agent.workspace_id || "Workspace";
      const tabLabel = tab?.label || agent.tab_id || "Tab";

      return `
        <article class="agent-card status-${status}" data-agent-pane="${escapeHtml(agent.pane_id)}">
          <div class="agent-top">
            <div class="agent-avatar">
              <svg><use href="#i-agents"/></svg>
              <span class="agent-dot"></span>
            </div>
            <div class="agent-id">
              <div class="agent-name">${escapeHtml(name)}</div>
              <div class="agent-title" title="${escapeHtml(title)}">${escapeHtml(title)}</div>
            </div>
            <span class="status-pill status-${status}">${statusLabel(status)}</span>
          </div>
          <div class="agent-meta">
            <span class="meta-tag"><svg><use href="#i-workspace"/></svg>${escapeHtml(workspaceLabel)}</span>
            <span class="meta-tag"><svg><use href="#i-tab"/></svg>${escapeHtml(tabLabel)}</span>
            <span class="meta-tag">${escapeHtml(agent.pane_id)}</span>
          </div>
          ${cwd ? `<div class="agent-cwd" title="${escapeHtml(cwd)}">${escapeHtml(cwd)}</div>` : ""}
          <div class="agent-actions">
            <button class="btn small" data-action="open-pane" data-pane-id="${escapeHtml(agent.pane_id)}">
              Ansehen
            </button>
            <button class="btn small" data-action="prompt-pane" data-pane-id="${escapeHtml(agent.pane_id)}">
              <svg><use href="#i-send"/></svg>Prompt
            </button>
            <button class="btn small icon" data-action="focus-pane" data-pane-id="${escapeHtml(agent.pane_id)}"
              title="In herdr fokussieren" aria-label="In herdr fokussieren">
              <svg><use href="#i-bolt"/></svg>
            </button>
          </div>
        </article>`;
    })
    .join("");

  if (empty) {
    empty.hidden = agents.length > 0;
    if (!agents.length) {
      const hasAgents = state.agents.length > 0;
      $("#agentEmptyTitle").textContent = hasAgents
        ? "Kein Agent in diesem Filter"
        : "Keine Agents gefunden";
      $("#agentEmptyText").textContent = hasAgents
        ? "Wähle einen anderen Status oder „Alle“."
        : "Starte einen Agent in einem Pane — er erscheint hier automatisch.";
    }
  }
}

function renderWorkspaces() {
  const tree = $("#workspaceTree");
  const empty = $("#workspaceEmpty");
  if (!tree) return;

  const snapshot = state.data?.snapshot || {};
  const workspaces = [...(snapshot.workspaces || [])].sort((a, b) => a.number - b.number);
  const tabs = [...(snapshot.tabs || [])].sort((a, b) => a.number - b.number);
  const panes = snapshot.panes || [];

  if (empty) empty.hidden = workspaces.length > 0;
  $("#workspacesSub").textContent = workspaces.length
    ? `${workspaces.length} Workspaces · ${panes.length} Panes`
    : "Struktur, Tabs und Panes";

  tree.innerHTML = workspaces
    .map((workspace) => {
      const workspaceTabs = tabs.filter((tab) => tab.workspace_id === workspace.workspace_id);
      const workspacePanes = panes.filter(
        (pane) => pane.workspace_id === workspace.workspace_id
      );
      const isOpen = !state.collapsed.has(workspace.workspace_id);
      const status = statusKey(workspace.agent_status);

      const tabMarkup = workspaceTabs
        .map((tab) => {
          const tabPanes = workspacePanes.filter((pane) => pane.tab_id === tab.tab_id);
          return `
            <div class="tab">
              <div class="tab-head">
                <span class="tab-icon"><svg><use href="#i-tab"/></svg></span>
                <span class="tab-label">${escapeHtml(tab.label || `Tab ${tab.number}`)}</span>
                <span class="ws-id">${escapeHtml(tab.tab_id)}</span>
                <span class="tab-spacer"></span>
                <span class="status-pill status-${statusKey(tab.agent_status)}">${statusLabel(tab.agent_status)}</span>
                <span class="pane-id">${tabPanes.length} pane${tabPanes.length === 1 ? "" : "s"}</span>
              </div>
              <div class="tab-body">
                ${tabPanes
                  .map((pane) => {
                    const paneStatus = statusKey(pane.agent_status);
                    const label =
                      pane.label ||
                      pane.terminal_title_stripped ||
                      pane.terminal_title ||
                      pane.title ||
                      pane.pane_id;
                    const agent = pane.display_agent || pane.agent;
                    return `
                      <div class="pane-row status-${paneStatus} ${pane.focused ? "is-focused" : ""}"
                           data-action="open-pane" data-pane-id="${escapeHtml(pane.pane_id)}"
                           role="button" tabindex="0">
                        <span class="pane-dot"></span>
                        <span class="pane-label">
                          ${agent ? `<span class="pane-agent">${escapeHtml(agent)}</span> · ` : ""}
                          ${escapeHtml(label)}
                        </span>
                        <span class="pane-id">${escapeHtml(pane.pane_id)}</span>
                        ${pane.focused ? `<span class="meta-tag">fokus</span>` : ""}
                        <button class="pane-open" type="button" tabindex="-1"
                          data-action="open-pane" data-pane-id="${escapeHtml(pane.pane_id)}"
                          title="Pane ansehen" aria-label="Pane ${escapeHtml(pane.pane_id)} ansehen">
                          <svg><use href="#i-external"/></svg>
                        </button>
                      </div>`;
                  })
                  .join("")}
              </div>
            </div>`;
        })
        .join("");

      return `
        <div class="ws ${isOpen ? "is-open" : ""}" data-workspace-id="${escapeHtml(workspace.workspace_id)}">
          <button class="ws-head" type="button" data-action="toggle-workspace"
            data-workspace-id="${escapeHtml(workspace.workspace_id)}" aria-expanded="${isOpen}">
            <span class="ws-chevron"><svg><use href="#i-chevron"/></svg></span>
            <span class="ws-icon"><svg><use href="#i-workspace"/></svg></span>
            <span class="ws-label">${escapeHtml(workspace.label || `Workspace ${workspace.number}`)}</span>
            <span class="ws-id">${escapeHtml(workspace.workspace_id)}</span>
            <span class="ws-spacer"></span>
            <span class="status-pill status-${status}">${statusLabel(workspace.agent_status)}</span>
            <span class="pane-id">${workspace.pane_count} pane${workspace.pane_count === 1 ? "" : "s"} · ${workspace.tab_count} tab${workspace.tab_count === 1 ? "" : "s"}</span>
          </button>
          <div class="ws-body">${tabMarkup || `<p class="pane-id">Keine Tabs</p>`}</div>
        </div>`;
    })
    .join("");
}

function renderSystem() {
  const system = state.data?.system;
  if (!system) return;

  const loadPercent = percent((system.load?.one || 0) * 100, 100 * (system.cpus || 1));
  setBar(
    "cpu",
    loadPercent,
    `${system.load?.one ?? "—"}`,
    `${system.cpus} vCPU · 5m ${system.load?.five ?? "—"} · 15m ${system.load?.fifteen ?? "—"}`
  );

  const mem = system.memory || { used: 0, total: 0 };
  setBar(
    "ram",
    percent(mem.used, mem.total),
    `${formatBytes(mem.used)} / ${formatBytes(mem.total)}`,
    `${percent(mem.used, mem.total).toFixed(0)}% belegt · ${formatBytes(mem.available || 0)} frei`
  );

  const disk = system.disk || { used: 0, total: 0 };
  setBar(
    "disk",
    percent(disk.used, disk.total),
    `${formatBytes(disk.used)} / ${formatBytes(disk.total)}`,
    `${percent(disk.used, disk.total).toFixed(0)}% belegt · ${formatBytes(disk.free || 0)} frei`
  );

  $("#uptime").textContent = formatDuration(system.uptime_seconds);
}

function renderServices() {
  const list = $("#services");
  if (!list) return;
  const services = state.data?.services || {};
  list.innerHTML = Object.entries(SERVICE_LABELS)
    .map(([name, label]) => {
      const value = services[name] || "unknown";
      const cls = value === "active" ? "is-active" : value === "failed" ? "is-failed" : "";
      return `
        <li class="service ${cls}">
          <span class="service-dot"></span>
          <span class="service-name">${escapeHtml(label)}</span>
          <span class="service-state">${escapeHtml(value === "active" ? "active" : value)}</span>
        </li>`;
    })
    .join("");
}

function renderOffline(error) {
  if (state.data) {
    updateUpdated();
    return;
  }

  $("#metricAgents").textContent = "—";
  $("#metricBlocked").textContent = "—";
  $("#metricPanes").textContent = "—";
  $("#metricLoad").textContent = "—";
  $("#agentsSub").textContent = "Server nicht erreichbar";
  $("#workspaceTree").innerHTML = "";
  $("#workspaceEmpty").hidden = false;
  $("#workspaceEmpty").innerHTML = `
    <p><b>Keine Verbindung zum herdr-Server.</b><br>
    ${escapeHtml(errorMessage(error))}</p>`;
  $("#agentEmpty").hidden = false;
  $("#agentEmptyTitle").textContent = "Server nicht erreichbar";
  $("#agentEmptyText").textContent =
    "Prüfe im Container: systemctl status herdr herdr-dashboard";
}

// ---------------------------------------------------------------------------
// Pane drawer
// ---------------------------------------------------------------------------

function findPane(paneId) {
  return (state.data?.snapshot?.panes || []).find((pane) => pane.pane_id === paneId) || null;
}

function openPane(paneId) {
  const pane = findPane(paneId);
  state.selectedPane = paneId;

  $("#drawerPaneId").textContent = paneId;
  $("#drawerTitle").textContent =
    pane?.label || pane?.terminal_title_stripped || pane?.terminal_title || paneId;
  $("#drawerMeta").textContent = pane
    ? `${pane.display_agent || pane.agent || "Shell"} · ${pane.cwd || pane.foreground_cwd || "—"}`
    : "Pane";

  const status = statusKey(pane?.agent_status);
  const statusNode = $("#drawerStatus");
  statusNode.className = `status-pill status-${status}`;
  statusNode.textContent = statusLabel(status);

  $("#drawerWrap").hidden = false;
  document.body.style.overflow = "hidden";
  loadPaneOutput();
  schedulePaneRefresh();
  $("#paneOutput").focus({ preventScroll: true });
}

function closePane() {
  $("#drawerWrap").hidden = true;
  document.body.style.overflow = "";
  state.selectedPane = null;
  if (state.drawerTimer) {
    window.clearInterval(state.drawerTimer);
    state.drawerTimer = null;
  }
}

function schedulePaneRefresh() {
  if (state.drawerTimer) window.clearInterval(state.drawerTimer);
  state.drawerTimer = window.setInterval(() => {
    if (!document.hidden && $("#autoRefresh").checked) loadPaneOutput(true);
  }, PANE_REFRESH_MS);
}

async function loadPaneOutput(silent = false) {
  const paneId = state.selectedPane;
  if (!paneId || state.drawerLoading) return;
  state.drawerLoading = true;

  const output = $("#paneOutput");
  const source = $("#readSource").value;
  const lines = $("#readLines").value;
  const atBottom =
    output.scrollTop + output.clientHeight >= output.scrollHeight - 48;

  try {
    const payload = await api(
      `/api/pane?pane_id=${encodeURIComponent(paneId)}&source=${encodeURIComponent(source)}&lines=${encodeURIComponent(lines)}`
    );
    const pane = payload.pane || {};
    output.textContent = pane.text || "(leer)";
    if (atBottom) output.scrollTop = output.scrollHeight;

    $("#drawerFoot").textContent = [
      `Quelle ${pane.source || source}`,
      `${(pane.text || "").split("\n").length} Zeilen`,
      pane.truncated ? "gekürzt" : null,
      `rev ${pane.revision ?? "?"}`,
      `aktualisiert ${new Date().toLocaleTimeString("de-DE")}`,
    ]
      .filter(Boolean)
      .join(" · ");
  } catch (error) {
    if (!silent) {
      output.textContent = `Fehler beim Lesen des Panes:\n\n${errorMessage(error)}`;
      toast("Pane konnte nicht gelesen werden", errorMessage(error), "error");
    }
  } finally {
    state.drawerLoading = false;
  }
}

async function copyPane() {
  const text = $("#paneOutput").textContent || "";
  try {
    await navigator.clipboard.writeText(text);
    toast("Kopiert", "Pane-Ausgabe liegt in der Zwischenablage.", "success");
  } catch {
    const helper = document.createElement("textarea");
    helper.value = text;
    helper.style.position = "fixed";
    helper.style.opacity = "0";
    document.body.appendChild(helper);
    helper.select();
    document.execCommand("copy");
    helper.remove();
    toast("Kopiert", "Pane-Ausgabe liegt in der Zwischenablage.", "success");
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

async function runAction(action, payload = {}, options = {}) {
  try {
    const result = await api("/api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action, ...payload }),
    });
    if (options.successTitle) {
      toast(options.successTitle, options.successMessage || "", "success");
    }
    if (options.refresh !== false) loadSnapshot({ silent: true });
    return result;
  } catch (error) {
    toast(options.errorTitle || "Aktion fehlgeschlagen", errorMessage(error), "error");
    throw error;
  }
}

async function focusPane(paneId) {
  await runAction("pane.focus", { pane_id: paneId }, {
    successTitle: "Fokus gesetzt",
    successMessage: `herdr fokussiert ${paneId}.`,
  });
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

function openPrompt(paneId) {
  const pane = findPane(paneId);
  state.promptPane = paneId;
  $("#promptTitle").textContent =
    pane?.display_agent || pane?.agent || pane?.label || paneId;
  $("#promptMeta").textContent = `${paneId} · ${pane?.cwd || "—"}`;
  $("#promptText").value = "";
  const dialog = $("#promptDialog");
  dialog.showModal();
  window.setTimeout(() => $("#promptText").focus(), 30);
}

function openWorkspaceDialog() {
  $("#workspaceForm").reset();
  $("#workspaceCwd").value = "/root";
  $("#workspaceDialog").showModal();
  window.setTimeout(() => $("#workspaceLabel").focus(), 30);
}

function openHelp() {
  const protocol = window.location.protocol;
  const hostname = window.location.hostname;
  const ttydPort = state.data?.links?.ttyd_port || 7681;
  const terminalUrl = `${protocol}//${hostname}:${ttydPort}/`;
  $("#helpDashboard").textContent = window.location.origin;
  $("#helpTerminal").textContent = terminalUrl;
  $("#helpSsh").textContent = `root@${hostname}`;
  $("#helpDialog").showModal();
}

function closeDialog(name) {
  const map = {
    prompt: "#promptDialog",
    workspace: "#workspaceDialog",
    help: "#helpDialog",
  };
  const dialog = $(map[name]);
  if (dialog && dialog.open) dialog.close();
}

function closeOverlay(name) {
  if (name === "drawer") closePane();
  else closeDialog(name);
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

document.addEventListener("click", (event) => {
  const closer = event.target.closest("[data-close]");
  if (closer) {
    event.preventDefault();
    closeOverlay(closer.dataset.close);
    return;
  }

  const actionNode = event.target.closest("[data-action]");
  if (actionNode) {
    const action = actionNode.dataset.action;
    const paneId = actionNode.dataset.paneId;

    if (action === "toggle-workspace") {
      const workspaceId = actionNode.dataset.workspaceId;
      if (state.collapsed.has(workspaceId)) state.collapsed.delete(workspaceId);
      else state.collapsed.add(workspaceId);
      const ws = actionNode.closest(".ws");
      if (ws) {
        const isOpen = !state.collapsed.has(workspaceId);
        ws.classList.toggle("is-open", isOpen);
        actionNode.setAttribute("aria-expanded", String(isOpen));
      }
      return;
    }

    if (action === "open-pane" && paneId) {
      event.preventDefault();
      openPane(paneId);
      return;
    }

    if (action === "prompt-pane" && paneId) {
      event.preventDefault();
      openPrompt(paneId);
      return;
    }

    if (action === "focus-pane" && paneId) {
      event.preventDefault();
      focusPane(paneId);
      return;
    }
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && event.target.closest(".pane-row[data-action]")) {
    event.preventDefault();
    openPane(event.target.closest(".pane-row").dataset.paneId);
    return;
  }

  const typing =
    event.target.closest("input, textarea, select, [contenteditable='true']") ||
    document.querySelector("dialog[open]");
  if (typing) return;

  if (event.key === "Escape") {
    if (!$("#drawerWrap").hidden) closePane();
    return;
  }

  if (event.key === "r" || event.key === "R") {
    event.preventDefault();
    loadSnapshot();
    return;
  }

  if (event.key === "t" || event.key === "T") {
    event.preventDefault();
    window.open("/terminal", "_blank", "noopener");
    return;
  }

  if (event.key === "?" || (event.key === "/" && event.shiftKey)) {
    event.preventDefault();
    openHelp();
    return;
  }

  if (["1", "2", "3", "4"].includes(event.key)) {
    event.preventDefault();
    const filters = ["all", "working", "blocked", "idle"];
    selectFilter(filters[Number(event.key) - 1]);
  }
});

// Filter chips
$("#agentFilters")?.addEventListener("click", (event) => {
  const chip = event.target.closest("[data-filter]");
  if (chip) selectFilter(chip.dataset.filter);
});

function selectFilter(filter) {
  state.filter = filter;
  $$("#agentFilters [data-filter]").forEach((chip) => {
    const active = chip.dataset.filter === filter;
    chip.classList.toggle("is-active", active);
    chip.setAttribute("aria-selected", String(active));
  });
  renderAgents();
}

// Dialog forms
$("#promptForm")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const paneId = state.promptPane;
  const text = $("#promptText").value;
  if (!paneId || !text.trim()) return;

  const button = $("#promptSubmit");
  button.disabled = true;
  try {
    await runAction("pane.prompt", { pane_id: paneId, text }, { refresh: false });
    $("#promptDialog").close();
    toast("Prompt gesendet", `an ${paneId}`, "success");
    loadSnapshot({ silent: true });
    if (state.selectedPane === paneId && !$("#drawerWrap").hidden) {
      window.setTimeout(() => loadPaneOutput(true), 400);
    }
  } finally {
    button.disabled = false;
  }
});

$("#promptText")?.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    $("#promptForm").requestSubmit();
  }
});

$("#workspaceForm")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const label = $("#workspaceLabel").value.trim();
  const cwd = $("#workspaceCwd").value.trim();
  try {
    await runAction(
      "workspace.create",
      { label, cwd },
      {
        successTitle: "Workspace angelegt",
        successMessage: label ? `„${label}“ ist gestartet.` : "Neue Shell ist gestartet.",
      }
    );
    $("#workspaceDialog").close();
  } catch {
    /* toast already shown */
  }
});

// Toolbar / buttons
$("#refreshBtn")?.addEventListener("click", () => loadSnapshot());
$("#newWorkspaceBtn")?.addEventListener("click", openWorkspaceDialog);
$("#helpBtn")?.addEventListener("click", openHelp);
$("#quickHelp")?.addEventListener("click", openHelp);
$("#emptyTerminalBtn")?.addEventListener("click", () =>
  window.open("/terminal", "_blank", "noopener")
);

async function createTab() {
  try {
    await runAction("tab.create", {}, {
      successTitle: "Tab angelegt",
      successMessage: "Neuer Tab im fokussierten Workspace.",
    });
  } catch {
    /* toast already shown */
  }
}

$("#newTabBtn")?.addEventListener("click", createTab);
$("#quickNewTab")?.addEventListener("click", createTab);

$("#copyPaneBtn")?.addEventListener("click", copyPane);
$("#focusPaneBtn")?.addEventListener("click", () => {
  if (state.selectedPane) focusPane(state.selectedPane);
});
$("#promptFromDrawer")?.addEventListener("click", () => {
  if (state.selectedPane) openPrompt(state.selectedPane);
});
$("#readSource")?.addEventListener("change", () => loadPaneOutput());
$("#readLines")?.addEventListener("change", () => loadPaneOutput());

// Click outside a dialog closes it
["#promptDialog", "#workspaceDialog", "#helpDialog"].forEach((selector) => {
  $(selector)?.addEventListener("click", (event) => {
    if (event.target === event.currentTarget) event.currentTarget.close();
  });
});

// Refresh when the tab becomes visible again
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) loadSnapshot({ silent: true });
});

// Update relative timestamps once a second
window.setInterval(updateUpdated, 1000);

// Initial boot
setConnection("loading", "verbinde …");
loadSnapshot({ silent: true });
window.setInterval(() => {
  if (!document.hidden) loadSnapshot({ silent: true });
}, REFRESH_MS);
