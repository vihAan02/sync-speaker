import { animate, utils, type JSAnimation } from "animejs";
import { useEffect, useRef } from "react";
import { LevelMeter } from "@/components/motion-widgets";
import { cn } from "@/lib/utils";
import { ms, reducedMotion } from "@/lib/motion";

// Vercel's mesh-gradient stops: develop, preview, ship.
const STOPS = ["#007cf0", "#00dfd8", "#7928ca", "#ff0080", "#ff4d4d", "#f9cb28"];

function seeded(text: string) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return () => {
    h = Math.imul(h ^ (h >>> 15), 2246822507);
    h = Math.imul(h ^ (h >>> 13), 3266489909);
    return ((h ^= h >>> 16) >>> 0) / 4294967296;
  };
}

/**
 * The Play screen's cover: a mesh gradient seeded by the track, drifting while audio plays and holding still when
 * paused. There's no artwork in the leader's state, so this stands in for it.
 */
export function Cover({ seed, active, playing, levelDb, className }: {
  seed: string;
  active: boolean;
  playing: boolean;
  levelDb: number;
  className?: string;
}) {
  const layer = useRef<HTMLDivElement>(null);
  const drifts = useRef<JSAnimation[]>([]);

  // Arrange the blobs for this track; glide there when the track changes.
  useEffect(() => {
    const rand = seeded(seed);
    const offset = Math.floor(rand() * STOPS.length);
    const anchors = layer.current!.querySelectorAll<HTMLElement>("[data-anchor]");
    anchors.forEach((anchor, i) => {
      const blob = anchor.firstElementChild as HTMLElement;
      blob.style.backgroundColor = STOPS[(offset + i * 2) % STOPS.length];
      animate(anchor, {
        translateX: `${(rand() - 0.5) * 90}%`,
        translateY: `${(rand() - 0.5) * 70}%`,
        scale: 0.8 + rand() * 0.5,
        duration: ms(900),
        ease: "inOutQuad",
      });
    });
  }, [seed]);

  // Slow drift loops, created once and paused or resumed with playback.
  useEffect(() => {
    if (reducedMotion()) return;
    const blobs = layer.current!.querySelectorAll<HTMLElement>("[data-blob]");
    drifts.current = Array.from(blobs, (blob, i) =>
      animate(blob, {
        translateX: [`${-14 + i * 4}%`, `${14 - i * 3}%`],
        translateY: [`${10 - i * 5}%`, `${-10 + i * 2}%`],
        duration: 7000 + i * 1300,
        alternate: true,
        loop: true,
        ease: "inOutSine",
        autoplay: false,
      }),
    );
    return () => {
      drifts.current.forEach((d) => d.revert());
      drifts.current = [];
    };
  }, []);

  useEffect(() => {
    drifts.current.forEach((d) => (playing ? d.resume() : d.pause()));
  }, [playing]);

  useEffect(() => {
    const el = layer.current!;
    const to = { opacity: active ? 1 : 0.35, filter: active ? "saturate(1)" : "saturate(0)" };
    if (reducedMotion()) utils.set(el, to);
    else animate(el, { ...to, duration: 600, ease: "outQuad" });
  }, [active]);

  return (
    <div
      aria-hidden
      className={cn("relative isolate overflow-hidden rounded-xl bg-card ring-1 ring-foreground/10 shadow-card", className)}
    >
      <div ref={layer} className="absolute inset-0">
        {[0, 1, 2, 3].map((i) => (
          <div key={i} data-anchor className="absolute inset-[12%] will-change-transform">
            <div data-blob className="size-full rounded-full opacity-80 blur-3xl will-change-transform dark:opacity-70" />
          </div>
        ))}
      </div>
      <LevelMeter db={active ? levelDb : -120} className="absolute inset-x-4 bottom-4 h-[3px] bg-black/10 dark:bg-white/20 [&>div]:bg-black/70 dark:[&>div]:bg-white/90" />
    </div>
  );
}
