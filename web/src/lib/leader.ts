import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import type { LibraryTrack, UICommand, UIReply, UIState } from "@/types";

export type ConnectionStatus = "connecting" | "live" | "offline";

export interface Leader {
  state?: UIState;
  status: ConnectionStatus;
  playlists?: string[];
  results?: { query: string; tracks: LibraryTrack[] };
  /** Bumped on every error reply, so views waiting on a reply can stop waiting. */
  errors: number;
  send: (command: UICommand) => void;
}

/** One `/ws/ui` connection to the leader: pushed state, per-client replies, and reconnect with backoff. */
export function useLeader(): Leader {
  const [state, setState] = useState<UIState>();
  const [status, setStatus] = useState<ConnectionStatus>("connecting");
  const [playlists, setPlaylists] = useState<string[]>();
  const [results, setResults] = useState<Leader["results"]>();
  const [errors, setErrors] = useState(0);
  const socket = useRef<WebSocket | null>(null);

  useEffect(() => {
    let disposed = false;
    let retry: ReturnType<typeof setTimeout> | undefined;
    let delay = 500;

    const connect = () => {
      const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws/ui`);
      socket.current = ws;
      ws.onopen = () => {
        delay = 500;
        setStatus("live");
        ws.send(JSON.stringify({ cmd: "playlists" } satisfies UICommand));
      };
      ws.onmessage = (event) => {
        const message = JSON.parse(event.data) as { state?: UIState; reply?: UIReply };
        if (message.state) setState(message.state);
        const reply = message.reply;
        if (!reply) return;
        if ("playlists" in reply) setPlaylists(reply.playlists._0);
        else if ("searchResults" in reply) setResults(reply.searchResults);
        else if ("error" in reply) {
          setErrors((n) => n + 1);
          toast.error(reply.error._0);
        }
      };
      ws.onclose = () => {
        if (disposed) return;
        setStatus("offline");
        retry = setTimeout(connect, delay);
        delay = Math.min(delay * 2, 5000);
      };
    };
    connect();

    return () => {
      disposed = true;
      clearTimeout(retry);
      socket.current?.close();
    };
  }, []);

  const send = useCallback((command: UICommand) => {
    const ws = socket.current;
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(command));
  }, []);

  return { state, status, playlists, results, errors, send };
}
