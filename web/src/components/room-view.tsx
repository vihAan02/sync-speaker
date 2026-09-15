import { animate, type JSAnimation } from "animejs";
import { useCallback, useEffect, useRef } from "react";
import { StatusBadge, type Tone } from "@/components/status-badge";
import { Card } from "@/components/ui/card";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { gainDb } from "@/lib/format";
import type { Leader } from "@/lib/leader";
import { reducedMotion, useReveal } from "@/lib/motion";
import { drawRoom, type RoomScene } from "@/room";
import type { Point, SpeakerID, UIState } from "@/types";

export function RoomView({ state, send }: { state: UIState; send: Leader["send"] }) {
  const root = useRef<HTMLDivElement>(null);
  useReveal(root, []);
  const { room } = state;
  const placed = Object.keys(room.speakers).length > 0;
  const tracking = trackingStatus(state);

  return (
    <div ref={root} className="flex flex-col gap-6">
      <Card data-reveal className="relative gap-0 p-0 py-0 shadow-card">
        <RoomMap state={state} />
        <div className="pointer-events-none absolute inset-x-3 top-3 flex items-center justify-between gap-2">
          <StatusBadge tone={tracking.tone}>{tracking.label}</StatusBadge>
          {placed ? (
            <span className="eyebrow rounded bg-card/85 px-1.5 py-0.5">{room.anchored ? "Placed with ARKit" : "Estimated"}</span>
          ) : null}
        </div>
        {!placed ? (
          <div className="absolute inset-0 grid place-items-center p-8 text-center">
            <div className="max-w-64 space-y-1">
              <p className="font-medium">No room yet</p>
              <p className="text-sm text-muted-foreground">
                In the SyncSpeaker iPhone app, touch the phone to each MacBook to place the speakers.
              </p>
            </div>
          </div>
        ) : null}
      </Card>

      <section data-reveal className="flex flex-col gap-3" aria-labelledby="spatial-heading">
        <h2 id="spatial-heading" className="text-sm font-medium">Spatial mode</h2>
        <ToggleGroup
          type="single"
          spacing={1}
          value={state.spatialMode}
          onValueChange={(mode) => mode && send({ cmd: "spatialMode", text: mode })}
          className="grid w-full grid-cols-2 bg-muted p-1"
          aria-label="Spatial mode"
        >
          {(["off", "sweetSpot"] as const).map((mode) => (
            <ToggleGroupItem
              key={mode}
              value={mode}
              className="h-10 rounded-md text-muted-foreground hover:bg-transparent data-[state=on]:bg-card data-[state=on]:text-foreground data-[state=on]:shadow-card dark:data-[state=on]:bg-white/12"
            >
              {mode === "off" ? "Off" : "Sweet spot"}
            </ToggleGroupItem>
          ))}
        </ToggleGroup>
        <p className="text-sm text-pretty text-muted-foreground">
          {state.spatialMode === "sweetSpot"
            ? "Each MacBook is delayed and leveled so both reach you together, and left/right stays on the correct side as you move."
            : "Both MacBooks play in lockstep with fixed channels. Turn on Sweet spot to follow where you are."}
        </p>
      </section>
    </div>
  );
}

function trackingStatus({ room }: UIState): { tone: Tone; label: string } {
  if (room.locked) return { tone: "success", label: "Position locked" };
  if (room.tracking === "disconnected") return { tone: "neutral", label: "No phone" };
  if (room.poseAgeMs != null && room.poseAgeMs > 2000) return { tone: "warning", label: "Phone idle" };
  if (room.tracking === "normal") return { tone: "success", label: "Tracking" };
  if (room.tracking === "waiting") return { tone: "warning", label: "Waiting for phone" };
  if (room.tracking === "limited") return { tone: "warning", label: "Tracking limited" };
  return { tone: "warning", label: "Tracking unavailable" };
}

type Tweened = Record<string, number>;

/** Flattens the positions the map draws into numbers anime.js can tween. */
function targets({ room }: UIState): Tweened {
  const out: Tweened = {};
  const put = (key: string, p?: Point) => {
    if (!p) return;
    out[`${key}x`] = p.x;
    out[`${key}z`] = p.z;
  };
  put("A", room.speakers.A);
  put("B", room.speakers.B);
  put("h", room.head ?? room.listener);
  put("p", room.head ? room.listener : undefined);
  put("f", room.forward);
  return out;
}

function sceneFrom(state: UIState, t: Tweened): RoomScene {
  const { room } = state;
  const at = (key: string) => (t[`${key}x`] == null ? undefined : { x: t[`${key}x`], z: t[`${key}z`] });
  const speakers = (["A", "B"] as SpeakerID[]).flatMap((id) => {
    const p = room.speakers[id] && at(id);
    if (!p) return [];
    const node = state.nodes.find((n) => n.speaker === id);
    return [{
      id,
      at: p,
      online: !!node?.connected,
      channel: node?.target.channel,
      delayMs: node ? node.target.delaySeconds * 1000 : undefined,
      gain: node?.target.gain,
    }];
  });
  return {
    speakers,
    head: room.head || room.listener ? at("h") : undefined,
    phone: room.head && room.listener ? at("p") : undefined,
    forward: room.forward ? at("f") : undefined,
    locked: room.locked,
    paths: state.spatialMode === "sweetSpot",
  };
}

function describe(state: UIState) {
  const { room } = state;
  const parts = state.nodes.map((n) => {
    const p = room.speakers[n.speaker];
    const where = p ? ` at ${p.x.toFixed(1)}, ${p.z.toFixed(1)} m` : "";
    return `Speaker ${n.speaker}${where}, ${n.target.channel}, ${(n.target.delaySeconds * 1000).toFixed(1)} ms, ${gainDb(n.target.gain)}`;
  });
  const head = room.head ?? room.listener;
  if (head) parts.push(`You at ${head.x.toFixed(1)}, ${head.z.toFixed(1)} m${room.locked ? ", locked" : ""}`);
  return `Room map. ${parts.join(". ")}.`;
}

/** Canvas map whose positions glide between the leader's 5 Hz snapshots. */
function RoomMap({ state }: { state: UIState }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const shown = useRef<Tweened>({});
  const latest = useRef(state);
  const frame = useRef(0);
  const tween = useRef<JSAnimation | null>(null);
  const previousKeys = useRef<Tweened>({});
  latest.current = state;

  const draw = useCallback(() => {
    cancelAnimationFrame(frame.current);
    frame.current = requestAnimationFrame(() => {
      if (canvas.current) drawRoom(canvas.current, sceneFrom(latest.current, shown.current));
    });
  }, []);

  useEffect(() => {
    const next = targets(state);
    const moving: Tweened = {};
    for (const [key, value] of Object.entries(next)) {
      // Things that just appeared (or reappeared) snap into place; everything else glides.
      if (shown.current[key] == null || !(key in previousKeys.current)) shown.current[key] = value;
      else if (shown.current[key] !== value) moving[key] = value;
    }
    previousKeys.current = next;
    if (Object.keys(moving).length && !reducedMotion()) {
      tween.current = animate(shown.current, { ...moving, duration: 240, ease: "outQuad", onUpdate: draw });
    } else {
      Object.assign(shown.current, moving);
    }
    draw();
  }, [state, draw]);

  useEffect(() => {
    const el = canvas.current!;
    const observer = new ResizeObserver(draw);
    observer.observe(el);
    const scheme = matchMedia("(prefers-color-scheme: dark)");
    scheme.addEventListener("change", draw);
    document.fonts?.ready.then(draw);
    return () => {
      observer.disconnect();
      scheme.removeEventListener("change", draw);
      cancelAnimationFrame(frame.current);
      tween.current?.cancel();
    };
  }, [draw]);

  return <canvas ref={canvas} role="img" aria-label={describe(state)} className="block h-[min(52dvh,420px)] w-full" />;
}
