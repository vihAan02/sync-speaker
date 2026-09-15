import { animate } from "animejs";
import { AlertCircle, Pause, Play, Search, SkipBack, SkipForward, Volume1, Volume2 } from "lucide-react";
import { useEffect, useRef } from "react";
import { Cover } from "@/components/cover";
import { usePressSpring } from "@/components/motion-widgets";
import { useDraft } from "@/components/use-draft";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Slider } from "@/components/ui/slider";
import { clamp, clock } from "@/lib/format";
import type { Leader } from "@/lib/leader";
import { ms, useReveal } from "@/lib/motion";
import { cn } from "@/lib/utils";
import type { UIState } from "@/types";

export function PlayView({ state, send, onOpenLibrary }: {
  state: UIState;
  send: Leader["send"];
  onOpenLibrary: () => void;
}) {
  const root = useRef<HTMLDivElement>(null);
  useReveal(root, []);

  const { music, capture } = state;
  const hasTrack = music.running && !!music.name;
  const streaming = capture.active && capture.levelDb > -55;
  const musicPlaying = music.running && music.state === "playing";
  const title = hasTrack ? music.name! : streaming ? "Streaming audio" : "Nothing playing";
  const subtitle = hasTrack
    ? [music.artist, music.album].filter(Boolean).join(" — ")
    : streaming
      ? `AirPlay or system audio on ${state.leaderName}`
      : `AirPlay to ${state.leaderName}, or pick something from your library.`;
  const status = musicPlaying ? "Now playing" : hasTrack ? "Paused" : streaming ? "Live input" : "Idle";

  const [playRef, press] = usePressSpring<HTMLButtonElement>();
  const volume = useDraft(state.masterVolume, { onChange: (v) => send({ cmd: "masterVolume", value: v }) });

  return (
    <div ref={root} className="flex flex-col gap-6">
      <div data-reveal>
        <Cover
          seed={title}
          active={hasTrack || streaming}
          playing={musicPlaying || streaming}
          levelDb={capture.levelDb}
          className="aspect-[4/3] w-full sm:aspect-[16/9]"
        />
      </div>

      <section data-reveal aria-label="Now playing" className="-mt-1 flex flex-col gap-1">
        <p className="eyebrow">{status}</p>
        <h2 className="truncate text-2xl leading-8 font-semibold tracking-tight">{title}</h2>
        <p className={cn("text-sm text-muted-foreground", hasTrack ? "truncate" : "text-pretty")}>{subtitle}</p>
      </section>

      {hasTrack && music.duration ? (
        <div data-reveal>
          <Progress position={music.position ?? 0} duration={music.duration} playing={musicPlaying} />
        </div>
      ) : null}

      <div data-reveal className="flex items-center justify-center gap-5">
        <Button
          variant="ghost"
          size="icon"
          className="size-12 rounded-full [&_svg:not([class*='size-'])]:size-5"
          aria-label="Previous track"
          onClick={() => send({ cmd: "music", action: "previous" })}
        >
          <SkipBack fill="currentColor" />
        </Button>
        <Button
          ref={playRef}
          size="icon"
          className="size-16 rounded-full transition-colors active:not-aria-[haspopup]:translate-y-0 [&_svg:not([class*='size-'])]:size-6"
          aria-label={musicPlaying ? "Pause" : "Play"}
          onClick={() => send({ cmd: "music", action: "playpause" })}
          {...press}
        >
          {musicPlaying ? <Pause fill="currentColor" /> : <Play fill="currentColor" className="translate-x-0.5" />}
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="size-12 rounded-full [&_svg:not([class*='size-'])]:size-5"
          aria-label="Next track"
          onClick={() => send({ cmd: "music", action: "next" })}
        >
          <SkipForward fill="currentColor" />
        </Button>
      </div>

      <div data-reveal className="flex items-center gap-3 text-muted-foreground">
        <Volume1 aria-hidden className="size-4 shrink-0" />
        <Slider min={0} max={1} step={0.01} aria-label="Speaker volume" {...volume} />
        <Volume2 aria-hidden className="size-4 shrink-0" />
        <span className="num w-8 text-right text-xs">{Math.round(volume.value[0] * 100)}</span>
      </div>

      <Button
        data-reveal
        variant="outline"
        className="h-11 justify-start gap-2.5 rounded-lg px-3 text-muted-foreground shadow-card"
        onClick={onOpenLibrary}
      >
        <Search aria-hidden />
        <span className="flex-1 text-left">Search library and playlists</span>
      </Button>

      {capture.error ? (
        <Alert data-reveal variant="destructive">
          <AlertCircle aria-hidden />
          <AlertTitle>Capture stopped</AlertTitle>
          <AlertDescription>{capture.error}</AlertDescription>
        </Alert>
      ) : null}
    </div>
  );
}

/** Track position. The leader polls Music.app once a second, so the bar glides linearly between polls. */
function Progress({ position, duration, playing }: { position: number; duration: number; playing: boolean }) {
  const bar = useRef<HTMLDivElement>(null);
  const last = useRef<number | null>(null);

  useEffect(() => {
    const fraction = clamp(position / duration, 0, 1);
    const previous = last.current;
    last.current = position;
    // Seeks, track changes and pauses snap; steady playback glides over the next poll interval.
    const steady = playing && previous != null && position >= previous && position - previous < 2.5;
    animate(bar.current!, steady
      ? { scaleX: fraction, duration: ms(1000), ease: "linear" }
      : { scaleX: fraction, duration: ms(160), ease: "outQuad" });
  }, [position, duration, playing]);

  return (
    <div className="flex flex-col gap-2">
      <div
        role="progressbar"
        aria-label="Track position"
        aria-valuemin={0}
        aria-valuemax={Math.round(duration)}
        aria-valuenow={Math.round(position)}
        aria-valuetext={`${clock(position)} of ${clock(duration)}`}
        className="h-1 overflow-hidden rounded-full bg-foreground/10"
      >
        <div ref={bar} className="h-full w-full origin-left rounded-full bg-foreground" style={{ transform: "scaleX(0)" }} />
      </div>
      <div className="num flex justify-between text-[11px] text-muted-foreground">
        <span>{clock(position)}</span>
        <span>-{clock(Math.max(0, duration - position))}</span>
      </div>
    </div>
  );
}
