import { ListMusic, Music2, Search } from "lucide-react";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { animate, stagger } from "animejs";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import type { Leader } from "@/lib/leader";
import { reducedMotion } from "@/lib/motion";

export function LibrarySheet({ open, onOpenChange, leader, leaderName }: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  leader: Leader;
  leaderName: string;
}) {
  const { send, playlists, results, errors } = leader;
  const [pending, setPending] = useState<string | null>(null);

  // Music.app may have launched since we connected.
  useEffect(() => {
    if (open) send({ cmd: "playlists" });
  }, [open, send]);

  useEffect(() => {
    if (results && results.query === pending) setPending(null);
  }, [results, pending]);

  useEffect(() => setPending(null), [errors]);

  useEffect(() => {
    if (!pending) return;
    const giveUp = setTimeout(() => setPending(null), 8000);
    return () => clearTimeout(giveUp);
  }, [pending]);

  const play = (command: Parameters<Leader["send"]>[0]) => {
    send(command);
    onOpenChange(false);
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side="bottom"
        className="mx-auto max-h-[85dvh] w-full max-w-xl gap-3 rounded-t-2xl border-x pb-[max(env(safe-area-inset-bottom),12px)]"
      >
        <SheetHeader className="px-5 pt-5 pb-0">
          <SheetTitle className="text-lg font-semibold tracking-tight">Library</SheetTitle>
          <SheetDescription>Music.app on {leaderName}</SheetDescription>
        </SheetHeader>

        <form
          role="search"
          className="relative px-5"
          onSubmit={(event) => {
            event.preventDefault();
            const query = new FormData(event.currentTarget).get("q")?.toString().trim();
            if (!query) return;
            setPending(query);
            send({ cmd: "search", text: query });
          }}
        >
          <Search aria-hidden className="pointer-events-none absolute top-1/2 left-8 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            name="q"
            type="search"
            enterKeyHint="search"
            autoComplete="off"
            aria-label="Search your library"
            placeholder="Songs, artists, albums"
            className="h-11 rounded-lg pl-9 text-base md:text-base"
          />
        </form>

        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 pb-2">
          {pending ? (
            <Group title="Songs">
              {[0, 1, 2].map((i) => (
                <li key={i} className="flex h-14 flex-col justify-center gap-1.5 px-2">
                  <Skeleton className="h-3.5 w-2/5" />
                  <Skeleton className="h-3 w-3/5" />
                </li>
              ))}
            </Group>
          ) : results ? (
            <Group title={`Songs matching “${results.query}”`} animateKey={results}>
              {results.tracks.length === 0 ? (
                <li className="px-2 py-3 text-sm text-muted-foreground">No matches in your library.</li>
              ) : (
                results.tracks.map((track) => (
                  <Row
                    key={track.id}
                    icon={<Music2 />}
                    title={track.name}
                    detail={[track.artist, track.album].filter(Boolean).join(" — ")}
                    onClick={() => play({ cmd: "playTrack", text: track.id })}
                  />
                ))
              )}
            </Group>
          ) : null}

          <Group title="Playlists" animateKey={playlists}>
            {playlists == null ? (
              <li className="px-2 py-3 text-sm text-muted-foreground">Loading…</li>
            ) : playlists.length === 0 ? (
              <li className="px-2 py-3 text-sm text-muted-foreground">No playlists. Is Music.app running?</li>
            ) : (
              playlists.map((name) => (
                <Row key={name} icon={<ListMusic />} title={name} onClick={() => play({ cmd: "playPlaylist", text: name })} />
              ))
            )}
          </Group>
        </div>
      </SheetContent>
    </Sheet>
  );
}

function Group({ title, animateKey, children }: { title: string; animateKey?: unknown; children: ReactNode }) {
  const list = useRef<HTMLUListElement>(null);

  useEffect(() => {
    if (animateKey == null || reducedMotion() || !list.current) return;
    const rows = Array.from(list.current.children).slice(0, 12);
    const animation = animate(rows, { opacity: [0, 1], translateY: [4, 0], duration: 220, delay: stagger(25), ease: "outCubic" });
    return () => {
      animation.revert();
    };
  }, [animateKey]);

  return (
    <section className="pt-3">
      <h3 className="eyebrow px-2 pb-1">{title}</h3>
      <ul ref={list}>{children}</ul>
    </section>
  );
}

function Row({ icon, title, detail, onClick }: { icon: ReactNode; title: string; detail?: string; onClick: () => void }) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        className="flex min-h-12 w-full items-center gap-3 rounded-lg px-2 py-2 text-left transition-colors outline-none hover:bg-muted focus-visible:ring-3 focus-visible:ring-ring/50 [&_svg]:size-4 [&_svg]:shrink-0 [&_svg]:text-muted-foreground"
      >
        {icon}
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-medium">{title}</span>
          {detail ? <span className="block truncate text-xs text-muted-foreground">{detail}</span> : null}
        </span>
      </button>
    </li>
  );
}
