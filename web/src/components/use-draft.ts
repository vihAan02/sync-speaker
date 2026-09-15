import { useEffect, useRef, useState } from "react";

/**
 * Slider value that tracks the leader's state, except while the user is dragging (and briefly after) so incoming
 * snapshots don't yank the thumb back. `onChange` is throttled to `every` ms; `onCommit` runs on release.
 */
export function useDraft(server: number, { onChange, onCommit, every = 80 }: {
  onChange?: (value: number) => void;
  onCommit?: (value: number) => void;
  every?: number;
}) {
  const [draft, setDraft] = useState<number | null>(null);
  const release = useRef<ReturnType<typeof setTimeout>>(undefined);
  const lastSent = useRef(0);
  const trailing = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => () => {
    clearTimeout(release.current);
    clearTimeout(trailing.current);
  }, []);

  return {
    value: [draft ?? server],
    onValueChange: ([value]: number[]) => {
      clearTimeout(release.current);
      setDraft(value);
      if (!onChange) return;
      clearTimeout(trailing.current);
      const wait = every - (performance.now() - lastSent.current);
      const fire = () => {
        lastSent.current = performance.now();
        onChange(value);
      };
      if (wait <= 0) fire();
      else trailing.current = setTimeout(fire, wait);
    },
    onValueCommit: ([value]: number[]) => {
      clearTimeout(trailing.current);
      (onCommit ?? onChange)?.(value);
      release.current = setTimeout(() => setDraft(null), 800);
    },
  };
}
