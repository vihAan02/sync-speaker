import { ChevronDown, RotateCcw } from "lucide-react";
import { useRef } from "react";
import { LevelMeter, PulseBars } from "@/components/motion-widgets";
import { StatusBadge, type Tone } from "@/components/status-badge";
import { useDraft } from "@/components/use-draft";
import { Button } from "@/components/ui/button";
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { Separator } from "@/components/ui/separator";
import { Slider } from "@/components/ui/slider";
import { fixed } from "@/lib/format";
import type { Leader } from "@/lib/leader";
import { useReveal } from "@/lib/motion";
import { cn } from "@/lib/utils";
import type { NodeState, UIState } from "@/types";

export function SpeakersView({ state, send }: { state: UIState; send: Leader["send"] }) {
  const root = useRef<HTMLDivElement>(null);
  useReveal(root, []);

  return (
    <div ref={root} className="flex flex-col gap-4">
      <div data-reveal>
        <SyncSummary nodes={state.nodes} />
      </div>
      {state.nodes.map((node) => (
        <div data-reveal key={node.speaker}>
          <NodeCard node={node} />
        </div>
      ))}
      {state.nodes.length < 2 ? (
        <div data-reveal className="rounded-xl border border-dashed p-4">
          <p className="font-medium">Speaker B isn’t connected</p>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Open SyncSpeaker on the second MacBook and choose Follower (B). It finds the leader on its own.
          </p>
        </div>
      ) : null}
      <div data-reveal>
        <CalibrationCard state={state} send={send} />
      </div>
      <div data-reveal>
        <OutputCard state={state} send={send} />
      </div>
    </div>
  );
}

function SyncSummary({ nodes }: { nodes: NodeState[] }) {
  const worst = Math.max(0, ...nodes.filter((n) => n.playout.locked).map((n) => Math.abs(n.playout.errorMs)));
  const allLocked = nodes.length > 0 && nodes.every((n) => n.playout.locked);
  const [label, tone]: [string, Tone] =
    nodes.length < 2 ? ["One speaker", "warning"]
      : !allLocked ? ["Locking…", "warning"]
        : worst < 1 ? ["In sync", "success"]
          : ["Drifting", "destructive"];

  return (
    <div className="flex items-end justify-between gap-4 pt-1">
      <div>
        <p className="eyebrow">Playback sync</p>
        <p role="status" className="mt-1 flex items-center gap-2 text-2xl leading-8 font-semibold tracking-tight">
          <span aria-hidden className={cn("size-2 rounded-full", {
            success: "bg-success",
            warning: "bg-warning",
            destructive: "bg-destructive",
            neutral: "bg-muted-foreground",
          }[tone])} />
          {label}
        </p>
      </div>
      {allLocked && nodes.length >= 2 ? (
        <p className="text-right">
          <span className="num text-2xl leading-8 font-medium">{worst.toFixed(2)}</span>
          <span className="num ml-1 text-xs text-muted-foreground">ms worst</span>
        </p>
      ) : null}
    </div>
  );
}

function Stat({ label, value, tone }: { label: string; value: string; tone?: Tone }) {
  return (
    <div className="min-w-0">
      <dt className="truncate text-xs text-muted-foreground">{label}</dt>
      <dd className={cn("num truncate text-sm font-medium", tone === "destructive" && "text-destructive", tone === "warning" && "text-warning")}>
        {value}
      </dd>
    </div>
  );
}

function NodeCard({ node }: { node: NodeState }) {
  const p = node.playout;
  const c = node.clock;
  const leader = node.role === "leader";
  const [badgeTone, badge]: [Tone, string] = !node.connected
    ? ["neutral", "Offline"]
    : !p.locked
      ? ["warning", "Waiting"]
      : [Math.abs(p.errorMs) < 1 ? "success" : "destructive", `${p.errorMs.toFixed(2)} ms`];

  return (
    <Card className="gap-3 shadow-card">
      <CardHeader className="gap-0.5">
        <p className="eyebrow">Speaker {node.speaker} · {node.role}</p>
        <CardTitle className="truncate font-semibold tracking-tight">{node.name}</CardTitle>
        <CardAction>
          <StatusBadge tone={badgeTone} mono={p.locked}>
            <span className="sr-only">Sync error </span>{badge}
          </StatusBadge>
        </CardAction>
      </CardHeader>
      <CardContent>
        <Collapsible>
          <dl className="grid grid-cols-3 gap-3">
            <Stat label="Buffer" value={fixed(p.bufferMs, 0, "ms")} />
            {leader
              ? <Stat label="Clock" value="reference" />
              : <Stat label="Clock jitter" value={fixed(c.jitterMs, 3, "ms")} tone={c.jitterMs > 0.5 ? "warning" : undefined} />}
            <Stat label="Underruns" value={String(p.underruns)} />
          </dl>
          <CollapsibleContent className="data-open:animate-in data-open:fade-in-0 data-closed:animate-out data-closed:fade-out-0">
            <Separator className="my-3" />
            <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
              {!leader && <Stat label="Round trip" value={fixed(c.rttMs, 1, "ms")} />}
              {!leader && <Stat label="Clock skew" value={fixed(c.skewPpm, 1, "ppm")} />}
              <Stat label="Drift correction" value={fixed(p.ratioPpm, 0, "ppm")} />
              <Stat label="Output latency" value={fixed(p.outputLatencyMs, 1, "ms")} />
              <Stat label="Calibration trim" value={fixed(p.trimMs, 2, "ms")} />
              <Stat label="Spatial delay" value={fixed(p.delayMs, 2, "ms")} />
              <Stat label="Channel" value={node.target.channel} />
              <Stat label="Resyncs" value={String(p.resyncs)} />
              <Stat label="Peak" value={fixed(p.peakDb, 0, "dB")} />
            </dl>
          </CollapsibleContent>
          <CollapsibleTrigger asChild>
            <Button variant="ghost" size="sm" className="group/details -mx-2 mt-2 h-9 gap-1 px-2 text-muted-foreground">
              <span className="group-data-[state=open]/details:hidden">Details</span>
              <span className="hidden group-data-[state=open]/details:inline">Less</span>
              <ChevronDown aria-hidden className="transition-transform group-data-[state=open]/details:rotate-180" />
            </Button>
          </CollapsibleTrigger>
        </Collapsible>
      </CardContent>
    </Card>
  );
}

function CalibrationCard({ state, send }: { state: UIState; send: Leader["send"] }) {
  const c = state.calibration;
  const running = c.status === "running";
  const ready = state.nodes.length >= 2;

  return (
    <Card className="shadow-card">
      <CardHeader>
        <CardTitle className="font-semibold tracking-tight">Calibrate sync</CardTitle>
        <CardDescription className="text-pretty">
          Each MacBook plays a short chirp while both listen. Run it twice in a quiet room; the second offset should be
          under 0.5 ms.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {c.baselineMeters != null || c.residualMs != null ? (
          <dl className="grid grid-cols-2 gap-3 rounded-lg bg-muted/60 px-3 py-2.5">
            {c.baselineMeters != null && <Stat label="Spacing" value={fixed(c.baselineMeters, 2, "m")} />}
            {c.residualMs != null && (
              <Stat label="Measured offset" value={fixed(c.residualMs, 2, "ms")} tone={Math.abs(c.residualMs) >= 0.5 ? "warning" : undefined} />
            )}
          </dl>
        ) : null}
        {c.message ? (
          <p role="status" className={cn("text-sm", c.status === "failed" ? "text-destructive" : "text-muted-foreground")}>
            {c.message}
          </p>
        ) : null}
        <div className="flex flex-wrap gap-2">
          <Button className="h-11 min-w-36 flex-1 gap-2 sm:flex-none" disabled={running || !ready} onClick={() => send({ cmd: "calibrateSync" })}>
            {running ? <PulseBars /> : null}
            {running ? "Listening…" : "Calibrate"}
          </Button>
          <Button variant="outline" className="h-11 gap-2" disabled={running} onClick={() => send({ cmd: "resetTrim" })}>
            <RotateCcw aria-hidden />
            Reset trim
          </Button>
        </div>
        {!ready ? <p className="text-xs text-muted-foreground">Needs both speakers connected.</p> : null}
      </CardContent>
    </Card>
  );
}

function OutputCard({ state, send }: { state: UIState; send: Leader["send"] }) {
  const latency = useDraft(state.playoutLatencyMs, { onCommit: (v) => send({ cmd: "playoutLatency", value: v }) });
  const musicVolume = useDraft(state.music.volume ?? 0, {
    onChange: (v) => send({ cmd: "music", action: "volume", value: v }),
    every: 150,
  });
  const capture = state.capture;

  return (
    <Card className="shadow-card">
      <CardHeader>
        <CardTitle className="font-semibold tracking-tight">Output</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-5">
        <Field label="Playout latency" value={`${Math.round(latency.value[0])} ms`} hint="Higher survives weaker Wi-Fi. Changing it briefly re-syncs playback.">
          <Slider min={80} max={800} step={10} aria-label="Playout latency" {...latency} />
        </Field>
        {state.music.running && state.music.volume != null ? (
          <Field label="Music.app volume" value={String(Math.round(musicVolume.value[0]))}>
            <Slider min={0} max={100} step={1} aria-label="Music.app volume" {...musicVolume} />
          </Field>
        ) : null}
        <Separator />
        <div className="flex flex-col gap-2">
          <div className="flex items-baseline justify-between gap-3">
            <span className="text-sm font-medium">Source</span>
            <span className={cn("num text-xs", capture.error ? "text-destructive" : "text-muted-foreground")}>
              {capture.error ? "Error" : capture.active ? `${fixed(capture.sampleRate / 1000, 1, "kHz")} · ${fixed(capture.levelDb, 0, "dBFS")}` : "Off"}
            </span>
          </div>
          <LevelMeter db={capture.active ? capture.levelDb : -120} />
          <p className={cn("text-xs", capture.error ? "text-destructive" : "text-muted-foreground")}>
            {capture.error ?? (capture.dropped > 0 ? `${capture.dropped} blocks dropped` : "System audio tap on the leader, muted locally.")}
          </p>
        </div>
      </CardContent>
    </Card>
  );
}

function Field({ label, value, hint, children }: { label: string; value: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-sm font-medium">{label}</span>
        <span className="num text-xs text-muted-foreground">{value}</span>
      </div>
      {children}
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  );
}
