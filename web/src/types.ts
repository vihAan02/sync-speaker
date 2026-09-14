// Mirrors Sources/SyncProtocol/UIState.swift (Swift Codable JSON).

export type SpeakerID = "A" | "B";

export interface ClockStats {
  offsetMs: number;
  jitterMs: number;
  rttMs: number;
  skewPpm: number;
  samples: number;
}

export interface PlayoutStats {
  locked: boolean;
  errorMs: number;
  ratioPpm: number;
  bufferMs: number;
  delayMs: number;
  gain: number;
  mixL: number;
  mixR: number;
  peakDb: number;
  underruns: number;
  resyncs: number;
  outputLatencyMs: number;
  trimMs: number;
}

export interface SpeakerRender {
  delaySeconds: number;
  gain: number;
  channel: "L" | "R" | "mono";
}

export interface NodeState {
  speaker: SpeakerID;
  name: string;
  role: "leader" | "follower";
  connected: boolean;
  clock: ClockStats;
  playout: PlayoutStats;
  target: SpeakerRender;
}

export interface Point {
  x: number;
  z: number;
}

export interface Room {
  speakers: Partial<Record<SpeakerID, Point>>;
  listener?: Point;
  head?: Point;
  forward?: Point;
  locked: boolean;
  tracking: string;
  poseAgeMs?: number;
  anchored: boolean;
}

export interface Music {
  running: boolean;
  state: string;
  name?: string;
  artist?: string;
  album?: string;
  duration?: number;
  position?: number;
  volume?: number;
}

export interface UIState {
  leaderName: string;
  nodes: NodeState[];
  room: Room;
  spatialMode: "off" | "sweetSpot";
  playoutLatencyMs: number;
  masterVolume: number;
  music: Music;
  capture: { active: boolean; sampleRate: number; levelDb: number; dropped: number; error?: string };
  calibration: { status: string; message?: string; baselineMeters?: number; residualMs?: number };
}

export interface LibraryTrack {
  id: string;
  name: string;
  artist: string;
  album: string;
}

// Swift encodes enum cases with unlabeled associated values as {"case": {"_0": value}}.
export type UIReply =
  | { playlists: { _0: string[] } }
  | { searchResults: { query: string; tracks: LibraryTrack[] } }
  | { error: { _0: string } };

export interface UICommand {
  cmd: string;
  action?: string;
  value?: number;
  text?: string;
}
