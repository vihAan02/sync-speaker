import type { Point, UIState } from "./types";

/** Top-down room map: speakers, listener, facing direction, and each speaker's delay/gain. */
export function drawRoom(canvas: HTMLCanvasElement, state: UIState) {
  const dpr = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth;
  const cssHeight = canvas.clientHeight;
  if (canvas.width !== Math.round(cssWidth * dpr) || canvas.height !== Math.round(cssHeight * dpr)) {
    canvas.width = Math.round(cssWidth * dpr);
    canvas.height = Math.round(cssHeight * dpr);
  }
  const ctx = canvas.getContext("2d")!;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssWidth, cssHeight);

  const css = getComputedStyle(document.documentElement);
  const color = (name: string) => css.getPropertyValue(name).trim();
  const { room } = state;

  const points: Point[] = Object.values(room.speakers).filter(Boolean) as Point[];
  if (room.head) points.push(room.head);
  if (room.listener) points.push(room.listener);
  if (points.length === 0) return;

  // Fit everything with a margin, keeping 1 m ≥ 40 px so a lone pair of speakers isn't huge.
  const xs = points.map((p) => p.x);
  const zs = points.map((p) => p.z);
  const minX = Math.min(...xs) - 0.8, maxX = Math.max(...xs) + 0.8;
  const minZ = Math.min(...zs) - 0.8, maxZ = Math.max(...zs) + 0.8;
  const scale = Math.min(cssWidth / (maxX - minX), cssHeight / (maxZ - minZ), 160);
  const cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
  const toScreen = (p: Point) => ({ x: cssWidth / 2 + (p.x - cx) * scale, y: cssHeight / 2 + (p.z - cz) * scale });

  // 1 m grid.
  ctx.strokeStyle = color("--grid");
  ctx.lineWidth = 1;
  for (let x = Math.floor(minX); x <= maxX; x++) {
    const s = toScreen({ x, z: 0 }).x;
    ctx.beginPath(); ctx.moveTo(s, 0); ctx.lineTo(s, cssHeight); ctx.stroke();
  }
  for (let z = Math.floor(minZ); z <= maxZ; z++) {
    const s = toScreen({ x: 0, z }).y;
    ctx.beginPath(); ctx.moveTo(0, s); ctx.lineTo(cssWidth, s); ctx.stroke();
  }

  const head = room.head ?? room.listener;
  const accent = color("--accent");
  const text = color("--text");
  const muted = color("--muted");

  // Sound paths from each speaker to the listener's head.
  if (head && state.spatialMode === "sweetSpot") {
    ctx.setLineDash([4, 6]);
    ctx.strokeStyle = muted;
    for (const p of Object.values(room.speakers)) {
      if (!p) continue;
      const a = toScreen(p), b = toScreen(head);
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
    }
    ctx.setLineDash([]);
  }

  ctx.font = "600 13px ui-sans-serif, system-ui, -apple-system, sans-serif";
  ctx.textAlign = "center";
  for (const node of state.nodes) {
    const p = room.speakers[node.speaker];
    if (!p) continue;
    const s = toScreen(p);
    ctx.fillStyle = node.connected ? text : muted;
    roundRect(ctx, s.x - 22, s.y - 13, 44, 26, 6);
    ctx.fill();
    ctx.fillStyle = color("--bg");
    ctx.fillText(`${node.speaker} · ${node.target.channel}`, s.x, s.y + 4.5);
    ctx.font = "12px ui-sans-serif, system-ui, -apple-system, sans-serif";
    label(ctx, `${(node.target.delaySeconds * 1000).toFixed(1)} ms · ${gainDb(node.target.gain)}`, s.x, s.y + 30,
      muted, color("--surface"));
    ctx.font = "600 13px ui-sans-serif, system-ui, -apple-system, sans-serif";
  }
  // Speakers without a node yet (follower not connected).
  for (const id of ["A", "B"] as const) {
    const p = room.speakers[id];
    if (!p || state.nodes.some((n) => n.speaker === id)) continue;
    const s = toScreen(p);
    ctx.strokeStyle = muted;
    roundRect(ctx, s.x - 22, s.y - 13, 44, 26, 6);
    ctx.stroke();
    ctx.fillStyle = muted;
    ctx.fillText(id, s.x, s.y + 4.5);
  }

  if (room.listener && room.head && !room.locked) {
    const phone = toScreen(room.listener);
    ctx.fillStyle = muted;
    ctx.beginPath(); ctx.arc(phone.x, phone.y, 3, 0, Math.PI * 2); ctx.fill();
  }
  if (head) {
    const h = toScreen(head);
    if (room.forward) {
      const len = 26;
      ctx.strokeStyle = accent;
      ctx.lineWidth = 3;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(h.x, h.y);
      ctx.lineTo(h.x + room.forward.x * len, h.y + room.forward.z * len);
      ctx.stroke();
    }
    ctx.fillStyle = accent;
    ctx.beginPath(); ctx.arc(h.x, h.y, 9, 0, Math.PI * 2); ctx.fill();
    ctx.font = "12px ui-sans-serif, system-ui, -apple-system, sans-serif";
    // Below the head: the facing arrow and the held phone are in front of it.
    const behind = room.forward ? { x: -room.forward.x, z: -room.forward.z } : { x: 0, z: 1 };
    label(ctx, room.locked ? "you (locked)" : "you", h.x + behind.x * 24, h.y + behind.z * 24 + 4, muted, color("--surface"));
  }
}

/** Text on a small background so paths and grid lines never cross it. */
function label(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, fg: string, bg: string) {
  const w = ctx.measureText(text).width + 8;
  ctx.fillStyle = bg;
  ctx.fillRect(x - w / 2, y - 12, w, 16);
  ctx.fillStyle = fg;
  ctx.fillText(text, x, y);
}

function gainDb(gain: number) {
  const db = 20 * Math.log10(Math.max(gain, 1e-4));
  return `${db > -0.05 ? "0.0" : db.toFixed(1)} dB`;
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
