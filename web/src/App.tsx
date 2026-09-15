import { animate } from "animejs";
import { AudioLines, Map as MapIcon, Play, WifiOff } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { LibrarySheet } from "@/components/library-sheet";
import { PlayView } from "@/components/play-view";
import { RoomView } from "@/components/room-view";
import { SpeakersView } from "@/components/speakers-view";
import { StatusBadge } from "@/components/status-badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Toaster } from "@/components/ui/sonner";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useLeader, type ConnectionStatus } from "@/lib/leader";
import { ms } from "@/lib/motion";
import { cn } from "@/lib/utils";

const TABS = [
  { value: "play", label: "Play", icon: Play },
  { value: "room", label: "Room", icon: MapIcon },
  { value: "speakers", label: "Speakers", icon: AudioLines },
] as const;
type Tab = (typeof TABS)[number]["value"];

function initialTab(): Tab {
  const hash = location.hash.slice(1);
  return TABS.some((t) => t.value === hash) ? (hash as Tab) : "play";
}

export function App() {
  const leader = useLeader();
  const { state, status, send } = leader;
  const [tab, setTab] = useState<Tab>(initialTab);
  const [libraryOpen, setLibraryOpen] = useState(false);

  useEffect(() => {
    history.replaceState(null, "", tab === "play" ? location.pathname : `#${tab}`);
  }, [tab]);

  return (
    <Tabs value={tab} onValueChange={(v) => setTab(v as Tab)} className="min-h-dvh gap-0">
      <header className="mx-auto flex w-full max-w-xl items-center justify-between gap-3 px-4 pt-[calc(env(safe-area-inset-top)+16px)] pb-4">
        <div className="flex min-w-0 items-center gap-2.5">
          <Mark />
          <div className="min-w-0">
            <h1 className="text-[15px] leading-5 font-semibold tracking-tight">SyncSpeaker</h1>
            <p className="truncate text-xs leading-4 text-muted-foreground">
              {!state ? "Finding the leader…" : status === "offline" ? `Reconnecting to ${state.leaderName}…` : state.leaderName}
            </p>
          </div>
        </div>
        <Connection status={status} />
      </header>

      <main
        className={cn(
          "mx-auto w-full max-w-xl px-4 pb-[calc(env(safe-area-inset-bottom)+104px)] transition-opacity",
          status === "offline" && "pointer-events-none opacity-50",
        )}
        aria-busy={!state}
      >
        {state ? (
          <>
            <TabsContent value="play">
              <PlayView state={state} send={send} onOpenLibrary={() => setLibraryOpen(true)} />
            </TabsContent>
            <TabsContent value="room">
              <RoomView state={state} send={send} />
            </TabsContent>
            <TabsContent value="speakers">
              <SpeakersView state={state} send={send} />
            </TabsContent>
            <LibrarySheet open={libraryOpen} onOpenChange={setLibraryOpen} leader={leader} leaderName={state.leaderName} />
          </>
        ) : (
          <Loading offline={status === "offline"} />
        )}
      </main>

      <Dock tab={tab} />
      <Toaster position="top-center" />
    </Tabs>
  );
}

/** Floating tab bar. The highlight slides to the active tab. */
function Dock({ tab }: { tab: Tab }) {
  const indicator = useRef<HTMLSpanElement>(null);
  const index = TABS.findIndex((t) => t.value === tab);
  const mounted = useRef(false);

  useLayoutEffect(() => {
    animate(indicator.current!, {
      translateX: `${index * 100}%`,
      duration: mounted.current ? ms(380) : 0,
      ease: "outExpo",
    });
    mounted.current = true;
  }, [index]);

  return (
    <nav
      aria-label="Sections"
      className="pointer-events-none fixed inset-x-0 bottom-0 z-40 flex justify-center px-4 pb-[calc(env(safe-area-inset-bottom)+12px)]"
    >
      <TabsList className="pointer-events-auto relative grid w-full max-w-80 grid-cols-3 rounded-full bg-card/85 p-1 shadow-dock ring-1 ring-foreground/10 backdrop-blur-md group-data-horizontal/tabs:h-auto">
        <span
          ref={indicator}
          aria-hidden
          className="absolute inset-y-1 left-1 w-[calc((100%-0.5rem)/3)] rounded-full bg-muted dark:bg-secondary"
        />
        {TABS.map(({ value, label, icon: Icon }) => (
          <TabsTrigger
            key={value}
            value={value}
            className="relative z-10 h-12 flex-col gap-0.5 rounded-full border-0 text-[11px] font-medium data-active:bg-transparent data-active:shadow-none dark:data-active:border-transparent dark:data-active:bg-transparent [&_svg:not([class*='size-'])]:size-[18px]"
          >
            <Icon aria-hidden />
            {label}
          </TabsTrigger>
        ))}
      </TabsList>
    </nav>
  );
}

function Connection({ status }: { status: ConnectionStatus }) {
  const tone = status === "live" ? "success" : status === "offline" ? "destructive" : "neutral";
  const label = status === "live" ? "Live" : status === "offline" ? "Offline" : "Connecting";
  return (
    <div role="status" aria-label={`Leader connection: ${label}`}>
      <StatusBadge tone={tone}>{label}</StatusBadge>
    </div>
  );
}

function Loading({ offline }: { offline: boolean }) {
  return (
    <div className="flex flex-col gap-6">
      <Skeleton className="aspect-[4/3] w-full rounded-xl sm:aspect-[16/9]" />
      <div className="space-y-2">
        <Skeleton className="h-3 w-20" />
        <Skeleton className="h-7 w-3/5" />
        <Skeleton className="h-4 w-2/5" />
      </div>
      {offline ? (
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          <WifiOff aria-hidden className="size-4" />
          Can’t reach the leader. Retrying…
        </p>
      ) : null}
    </div>
  );
}

/** Two speakers, one wave. */
function Mark() {
  return (
    <svg aria-hidden viewBox="0 0 28 28" className="size-7 shrink-0 rounded-lg bg-primary text-primary-foreground">
      <rect x="7" y="8" width="4" height="12" rx="2" fill="currentColor" />
      <rect x="17" y="8" width="4" height="12" rx="2" fill="currentColor" />
      <path d="M12.5 14h3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" opacity="0.6" />
    </svg>
  );
}
