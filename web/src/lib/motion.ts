import { animate, stagger, utils } from "animejs";
import { useLayoutEffect, type DependencyList, type RefObject } from "react";

const reducedQuery = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : undefined;

/** True when the viewer asked for less motion. Read at call time so a settings change applies to the next animation. */
export function reducedMotion() {
  return reducedQuery?.matches ?? false;
}

/** Duration that collapses to 0 under reduced motion. */
export function ms(duration: number) {
  return reducedMotion() ? 0 : duration;
}

/**
 * Rises `[data-reveal]` children of `root` into place whenever `deps` change (e.g. a tab becoming visible).
 * Only opacity and transform are animated.
 */
export function useReveal(root: RefObject<HTMLElement | null>, deps: DependencyList) {
  useLayoutEffect(() => {
    const el = root.current;
    if (!el) return;
    const targets = el.querySelectorAll<HTMLElement>("[data-reveal]");
    if (targets.length === 0) return;
    if (reducedMotion()) {
      utils.set(targets, { opacity: 1, translateY: 0 });
      return;
    }
    // Hide first so later items in the stagger don't show at rest for a frame before their delay starts.
    utils.set(targets, { opacity: 0, translateY: 6 });
    const animation = animate(targets, {
      opacity: 1,
      translateY: 0,
      duration: 280,
      delay: stagger(40),
      ease: "outCubic",
    });
    return () => {
      animation.revert();
    };
  }, deps);
}
