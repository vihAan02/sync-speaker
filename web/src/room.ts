import { gainDb } from "@/lib/format";
import type { Point, SpeakerID } from "@/types";

export interface SceneSpeaker {
  id: SpeakerID;
  at: Point;
  /** Has a node reporting in (false: position known, Mac not connected). */
  online: boolean;
  channel?: string;
  delayMs?: number;
  gain?: number;
}

/** What the map shows, already smoothed by the caller. */
export interface RoomScene {
  speakers: SceneSpeaker[];
  head?: Point;
  phone?: Point;
  forward?: Point;
  locked: boolean;
  paths: boolean;
}

const SANS = '"Geist Variable", ui-sans-serif, system-ui, sans-serif';
const MONO = '"Geist Mono Variable", ui-monospace, Menlo, monospace';

/** Top-down room map: speakers, listener, facing direction, and each speaker's delay and gain. */
export function drawRoom(canvas: HTMLCanvasElement, scene: RoomScene) {
  const dpr = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
  }
  const ctx = canvas.getContext("2d")!;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const css = getComputedStyle(document.documentElement);
  const token = (name: string) => css.getPropertyValue(name).trim();
  const ink = token("--foreground");
  const muted = token("--muted-foreground");
  const surface = token("--card");
  const listener = token("--listener");

  const points = scene.speakers.map((s) => s.at);
  if (scene.head) points.push(scene.head);
  if (scene.phone) points.push(scene.phone);
  if (points.length === 0) return;

  // Fit everything with a margin, capping the scale so a lone pair of speakers isn't huge.
  const pad = 0.9;
  const minX = Math.min(...points.map((p) => p.x)) - pad;
  const maxX = Math.max(...points.map((p) => p.x)) + pad;
  const minZ = Math.min(...points.map((p) => p.z)) - pad;
  const maxZ = Math.max(...points.map((p) => p.z)) + pad;
  const scale = Math.min(width / (maxX - minX), height / (maxZ - minZ), 150);
  const cx = (minX + maxX) / 2;
  const cz = (minZ + maxZ) / 2;
  const toScreen = (p: Point) => ({ x: width / 2 + (p.x - cx) * scale, y: height / 2 + (p.z - cz) * scale });

  // Half-metre dot grid.
  const visibleMinX = cx - width / 2 / scale;
  const visibleMinZ = cz - height / 2 / scale;
  ctx.fillStyle = muted;
  ctx.globalAlpha = 0.28;
  for (let x = Math.floor(visibleMinX * 2) / 2; x <= cx + width / 2 / scale; x += 0.5) {
    for (let z = Math.floor(visibleMinZ * 2) / 2; z <= cz + height / 2 / scale; z += 0.5) {
      const s = toScreen({ x, z });
      ctx.beginPath();
      ctx.arc(s.x, s.y, Number.isInteger(x) && Number.isInteger(z) ? 1.4 : 0.8, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  ctx.globalAlpha = 1;

  // Sound paths from each speaker to the listener's head.
  if (scene.head && scene.paths) {
    const h = toScreen(scene.head);
    ctx.setLineDash([3, 5]);
    ctx.lineWidth = 1;
    ctx.strokeStyle = muted;
    ctx.globalAlpha = 0.6;
    for (const speaker of scene.speakers) {
      const a = toScreen(speaker.at);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(h.x, h.y);
      ctx.stroke();
    }
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
  }

  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const speaker of scene.speakers) {
    const s = toScreen(speaker.at);
    const text = speaker.channel && speaker.online ? `${speaker.id} · ${speaker.channel}` : speaker.id;
    ctx.font = `600 12px ${MONO}`;
    const w = Math.max(32, ctx.measureText(text).width + 18);
    roundRect(ctx, s.x - w / 2, s.y - 13, w, 26, 6);
    if (speaker.online) {
      ctx.fillStyle = ink;
      ctx.fill();
      ctx.fillStyle = surface;
    } else {
      ctx.fillStyle = surface;
      ctx.fill();
      ctx.setLineDash([3, 3]);
      ctx.strokeStyle = muted;
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = muted;
    }
    ctx.fillText(text, s.x, s.y + 0.5);
    if (speaker.online && speaker.delayMs != null && speaker.gain != null) {
      ctx.font = `400 11px ${MONO}`;
      label(ctx, `${speaker.delayMs.toFixed(1)} ms · ${gainDb(speaker.gain)}`, s.x, s.y + 28, muted, surface);
    }
  }

  if (scene.phone && scene.head && !scene.locked) {
    const phone = toScreen(scene.phone);
    ctx.fillStyle = muted;
    ctx.beginPath();
    ctx.arc(phone.x, phone.y, 2.5, 0, Math.PI * 2);
    ctx.fill();
  }

  if (scene.head) {
    const h = toScreen(scene.head);
    const f = scene.forward && Math.hypot(scene.forward.x, scene.forward.z) > 1e-3 ? normalize(scene.forward) : undefined;
    ctx.fillStyle = listener;
    ctx.globalAlpha = 0.16;
    ctx.beginPath();
    ctx.arc(h.x, h.y, 18, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    if (f) {
      ctx.strokeStyle = listener;
      ctx.lineWidth = 2.5;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(h.x + f.x * 10, h.y + f.z * 10);
      ctx.lineTo(h.x + f.x * 28, h.y + f.z * 28);
      ctx.stroke();
    }
    ctx.fillStyle = listener;
    ctx.beginPath();
    ctx.arc(h.x, h.y, 7, 0, Math.PI * 2);
    ctx.fill();
    // Behind the head: the facing arrow and the held phone are in front of it.
    const behind = f ? { x: -f.x, z: -f.z } : { x: 0, z: 1 };
    ctx.font = `500 12px ${SANS}`;
    label(ctx, scene.locked ? "You · locked" : "You", h.x + behind.x * 30, h.y + behind.z * 30, muted, surface);
  }
}

/** Text on a small plate so paths and grid never cross it. */
function label(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, fg: string, bg: string) {
  const w = ctx.measureText(text).width + 10;
  ctx.fillStyle = bg;
  roundRect(ctx, x - w / 2, y - 9, w, 18, 4);
  ctx.fill();
  ctx.fillStyle = fg;
  ctx.fillText(text, x, y + 0.5);
}

function normalize(p: Point): Point {
  const length = Math.hypot(p.x, p.z);
  return { x: p.x / length, z: p.z / length };
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
}
