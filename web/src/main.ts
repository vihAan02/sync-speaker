import { drawRoom } from "./room";
import type { LibraryTrack, NodeState, UICommand, UIReply, UIState } from "./types";

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

let socket: WebSocket | undefined;
let state: UIState | undefined;
let reconnectDelay = 500;
// Sliders being dragged shouldn't be overwritten by incoming state.
const editing = new Set<string>();

function connect() {
  const url = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws/ui`;
  const ws = new WebSocket(url);
  socket = ws;
  ws.onopen = () => {
    reconnectDelay = 500;
    setConnection("live", "good");
    send({ cmd: "playlists" });
  };
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data) as { state?: UIState; reply?: UIReply };
    if (message.state) {
      state = message.state;
      render(state);
    }
    if (message.reply) handleReply(message.reply);
  };
  ws.onclose = () => {
    setConnection("offline", "bad");
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 5000);
  };
}

function send(command: UICommand) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(command));
}

function setConnection(label: string, tone: "good" | "warn" | "bad") {
  const pill = $("conn");
  pill.textContent = label;
  pill.className = `pill ${tone}`;
}

// MARK: Rendering

function render(s: UIState) {
  $("subtitle").textContent = `Leader: ${s.leaderName}`;
  document.querySelectorAll(".leader-name").forEach((el) => (el.textContent = s.leaderName));
  renderMusic(s);
  renderRoom(s);
  renderNodes(s);
  renderSettings(s);
}

function renderMusic(s: UIState) {
  const m = s.music;
  $("track").textContent = m.running && m.name ? m.name : "Nothing playing in Music.app";
  $("artist").textContent = m.running ? [m.artist, m.album].filter(Boolean).join(" — ") : "AirPlay audio plays here too.";
  $("playpause").textContent = m.state === "playing" ? "⏸" : "▶";
  const pct = m.duration && m.position != null ? Math.min(100, (m.position / m.duration) * 100) : 0;
  $("progress-bar").style.width = `${pct}%`;
  if (!editing.has("music-volume") && m.volume != null) $<HTMLInputElement>("music-volume").value = String(m.volume);

  const c = s.capture;
  const level = Math.max(0, Math.min(1, (c.levelDb + 60) / 60));
  $("level").style.width = `${level * 100}%`;
  const status = $("capture-status");
  if (c.error) {
    status.textContent = c.error;
    status.className = "small error";
  } else {
    status.textContent = c.active ? `Capturing at ${(c.sampleRate / 1000).toFixed(1)} kHz · ${c.levelDb.toFixed(0)} dBFS` : "Capture off";
    status.className = "muted small";
  }
}

function renderRoom(s: UIState) {
  if (!$("tab-room").hidden) drawRoom($<HTMLCanvasElement>("room"), s);
  const tracking = $("tracking");
  const r = s.room;
  const stale = r.poseAgeMs != null && r.poseAgeMs > 2000 && !r.locked;
  tracking.textContent = r.locked ? "position locked" : r.tracking === "disconnected" ? "no phone" : stale ? "phone idle" : `tracking ${r.tracking}`;
  tracking.className = `pill ${r.locked || (r.tracking === "normal" && !stale) ? "good" : r.tracking === "disconnected" ? "" : "warn"}`;
  $("anchored").textContent = r.anchored ? "speakers placed with ARKit" : "speaker positions estimated";
  document.querySelectorAll<HTMLButtonElement>("#spatial-mode button").forEach((b) => {
    b.classList.toggle("active", b.dataset.mode === s.spatialMode);
  });
}

function renderNodes(s: UIState) {
  const container = $("nodes");
  const ids = s.nodes.map((n) => n.speaker).join();
  if (container.dataset.ids !== ids) {
    container.dataset.ids = ids;
    container.innerHTML = s.nodes.map((n) => `<div class="card" id="node-${n.speaker}"></div>`).join("") +
      (s.nodes.length < 2 ? `<div class="card muted">Speaker B not connected. Start SyncSpeaker on the second MacBook as Follower.</div>` : "");
  }
  for (const n of s.nodes) $(`node-${n.speaker}`).innerHTML = nodeCard(n);

  const c = s.calibration;
  const el = $("calibration");
  const parts = [c.message];
  if (c.baselineMeters != null) parts.push(`spacing ${c.baselineMeters.toFixed(2)} m`);
  if (c.residualMs != null) parts.push(`measured offset ${c.residualMs.toFixed(2)} ms`);
  el.textContent = parts.filter(Boolean).join(" · ");
  el.className = `small ${c.status === "failed" ? "error" : "muted"}`;
  $<HTMLButtonElement>("calibrate").disabled = c.status === "running" || s.nodes.length < 2;
}

function nodeCard(n: NodeState) {
  const p = n.playout;
  const syncTone = !p.locked ? "warn" : Math.abs(p.errorMs) < 1 ? "good" : "bad";
  const stat = (label: string, value: string) => `<div class="stat"><div class="label">${label}</div><div class="value">${value}</div></div>`;
  const clock = n.role === "leader"
    ? stat("Clock", "reference")
    : stat("Clock jitter", `${n.clock.jitterMs.toFixed(3)} ms`) + stat("Round trip", `${n.clock.rttMs.toFixed(1)} ms`) +
      stat("Clock skew", `${n.clock.skewPpm.toFixed(1)} ppm`);
  return `
    <div class="node-head">
      <div><p class="eyebrow">Speaker ${n.speaker} · ${n.role}</p><h2>${escapeHTML(n.name)}</h2></div>
      <span class="pill ${syncTone}">${p.locked ? `${p.errorMs.toFixed(2)} ms` : "waiting"}</span>
    </div>
    <div class="stats">
      ${clock}
      ${stat("Drift correction", `${p.ratioPpm.toFixed(0)} ppm`)}
      ${stat("Buffer", `${p.bufferMs.toFixed(0)} ms`)}
      ${stat("Output latency", `${p.outputLatencyMs.toFixed(1)} ms`)}
      ${stat("Calibration trim", `${p.trimMs.toFixed(2)} ms`)}
      ${stat("Spatial delay", `${p.delayMs.toFixed(2)} ms`)}
      ${stat("Channel", n.target.channel)}
      ${stat("Underruns", String(p.underruns))}
    </div>`;
}

function renderSettings(s: UIState) {
  if (!editing.has("master")) $<HTMLInputElement>("master").value = String(s.masterVolume);
  if (!editing.has("latency")) $<HTMLInputElement>("latency").value = String(s.playoutLatencyMs);
  $("latency-value").textContent = `${Math.round(s.playoutLatencyMs)} ms`;
}

// MARK: Replies

function handleReply(reply: UIReply) {
  if ("playlists" in reply) {
    $("playlists").innerHTML = reply.playlists._0
      .map((name) => `<li><button data-playlist="${escapeHTML(name)}">${escapeHTML(name)}</button></li>`)
      .join("") || `<li class="muted small">No playlists (is Music.app running?)</li>`;
  } else if ("searchResults" in reply) {
    renderResults(reply.searchResults.tracks);
  } else if ("error" in reply) {
    toast(reply.error._0);
  }
}

function renderResults(tracks: LibraryTrack[]) {
  $("results").innerHTML = tracks
    .map((t) => `<li><button data-track="${escapeHTML(t.id)}">${escapeHTML(t.name)}<span class="sub">${escapeHTML(t.artist)} — ${escapeHTML(t.album)}</span></button></li>`)
    .join("") || `<li class="muted small">No matches in your library.</li>`;
}

function toast(message: string) {
  const status = $("capture-status");
  status.textContent = message;
  status.className = "small error";
}

function escapeHTML(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

// MARK: Events

document.querySelectorAll<HTMLButtonElement>("[data-music]").forEach((b) =>
  b.addEventListener("click", () => send({ cmd: "music", action: b.dataset.music }))
);

document.querySelectorAll<HTMLButtonElement>("[data-go]").forEach((b) =>
  b.addEventListener("click", () => {
    document.querySelectorAll<HTMLElement>(".tab").forEach((t) => (t.hidden = t.dataset.tab !== b.dataset.go));
    document.querySelectorAll("[data-go]").forEach((x) => x.classList.toggle("active", x === b));
    if (state) render(state);
  })
);

document.querySelectorAll<HTMLButtonElement>("#spatial-mode button").forEach((b) =>
  b.addEventListener("click", () => send({ cmd: "spatialMode", text: b.dataset.mode }))
);

function bindSlider(id: string, onInput: (value: number) => void) {
  const input = $<HTMLInputElement>(id);
  input.addEventListener("pointerdown", () => editing.add(id));
  input.addEventListener("input", () => onInput(Number(input.value)));
  input.addEventListener("change", () => {
    onInput(Number(input.value));
    setTimeout(() => editing.delete(id), 600);
  });
}
bindSlider("music-volume", (v) => send({ cmd: "music", action: "volume", value: v }));
bindSlider("master", (v) => send({ cmd: "masterVolume", value: v }));
bindSlider("latency", (v) => {
  $("latency-value").textContent = `${v} ms`;
});
$<HTMLInputElement>("latency").addEventListener("change", (e) =>
  send({ cmd: "playoutLatency", value: Number((e.target as HTMLInputElement).value) })
);

$("search-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const query = $<HTMLInputElement>("search").value.trim();
  if (query) send({ cmd: "search", text: query });
});

document.addEventListener("click", (e) => {
  const target = (e.target as HTMLElement).closest<HTMLElement>("[data-track],[data-playlist]");
  if (!target) return;
  if (target.dataset.track) send({ cmd: "playTrack", text: target.dataset.track });
  if (target.dataset.playlist) send({ cmd: "playPlaylist", text: target.dataset.playlist });
});

$("calibrate").addEventListener("click", () => send({ cmd: "calibrateSync" }));
$("reset-trim").addEventListener("click", () => send({ cmd: "resetTrim" }));
window.addEventListener("resize", () => state && renderRoom(state));

connect();
