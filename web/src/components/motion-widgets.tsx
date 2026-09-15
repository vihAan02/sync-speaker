import { animate, createAnimatable, createSpring, stagger, type AnimatableObject } from "animejs";
import { useEffect, useRef, type ComponentProps } from "react";
import { cn } from "@/lib/utils";
import { levelFraction } from "@/lib/format";
import { ms, reducedMotion } from "@/lib/motion";

/** Horizontal meter for a dBFS level; follows 5 Hz updates with a short glide instead of jumping. */
export function LevelMeter({ db, className }: { db: number; className?: string }) {
  const bar = useRef<HTMLDivElement>(null);
  const meter = useRef<AnimatableObject | null>(null);

  useEffect(() => {
    meter.current = createAnimatable(bar.current!, { scaleX: 180, ease: "linear" });
    return () => {
      meter.current?.revert();
    };
  }, []);

  useEffect(() => {
    meter.current?.scaleX(levelFraction(db), ms(180));
  }, [db]);

  return (
    <div aria-hidden className={cn("h-1 overflow-hidden rounded-full bg-foreground/10", className)}>
      <div ref={bar} className="h-full w-full origin-left rounded-full bg-foreground" style={{ transform: "scaleX(0)" }} />
    </div>
  );
}

/** Three bars that pulse while something is listening or measuring. Static under reduced motion. */
export function PulseBars({ className }: { className?: string }) {
  const root = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (reducedMotion()) return;
    const bars = root.current!.children;
    const animation = animate(bars, {
      scaleY: [0.35, 1],
      duration: 450,
      delay: stagger(120),
      alternate: true,
      loop: true,
      ease: "inOutSine",
    });
    return () => {
      animation.revert();
    };
  }, []);

  return (
    <span ref={root} aria-hidden className={cn("inline-flex h-3.5 items-center gap-[3px]", className)}>
      {[0, 1, 2].map((i) => (
        <span key={i} className="h-full w-[3px] rounded-full bg-current" />
      ))}
    </span>
  );
}

const pressSpring = createSpring({ stiffness: 420, damping: 16 });

/** Spring press feedback for a button: squeeze on pointer down, spring back on release. */
export function usePressSpring<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const handlers: Pick<ComponentProps<"button">, "onPointerDown" | "onPointerUp" | "onPointerLeave" | "onPointerCancel"> = {
    onPointerDown: () => {
      if (!reducedMotion() && ref.current) animate(ref.current, { scale: 0.92, duration: 110, ease: "outQuad" });
    },
    onPointerUp: () => release(),
    onPointerLeave: () => release(),
    onPointerCancel: () => release(),
  };
  function release() {
    if (!reducedMotion() && ref.current) animate(ref.current, { scale: 1, ease: pressSpring });
  }
  return [ref, handlers] as const;
}
