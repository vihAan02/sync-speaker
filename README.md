# SyncSpeaker

Two MacBooks act as one synchronized speaker pair for Apple Music. The pair adapts to where you are: an iPhone locates the speakers once with ARKit, then tracks you, and each MacBook's timing, level and left/right channel are adjusted so the sound reaches you together.

```
iPhone ──AirPlay──▶ LEADER Mac (Speaker A) ─────────────────────────▶ FOLLOWER Mac (Speaker B)
  │ Apple Music      system audio tap (muted) → 10 ms chunks + timestamps
  │                  UDP clock master ◀──────────── ping/pong ────────── ClockClient
  │                  TCP audio + render plans ─────────────────────────▶ PlayoutEngine → speakers
  │                  PlayoutEngine → speakers (same code path)
  ├─ ARKit app ── ws /ws/phone (anchors, pose) ─▶ RenderPlanner (20 Hz)
  └─ browser ──── http :8080, ws /ws/ui ────────▶ web remote + Music.app control
```

## Don't want to install it by hand?

Paste this into a coding agent (Claude Code, Codex, Cursor or similar) on **each** Mac:

```text
Set up SyncSpeaker (https://github.com/vihAan02/sync-speaker) on this Mac.

1. Check prerequisites: macOS 15 or later, the Xcode Command Line Tools
   (`xcode-select -p`), Swift 6 (`swift --version`) and Node 20.19 or later
   (`node --version`). If anything is missing, tell me what to install and
   wait for my OK before installing anything system-wide.
2. Clone the repo into ~/sync-speaker, or pull if it's already there.
3. Run `scripts/test.sh` and confirm the tests pass.
4. Run `scripts/build-app.sh` to build `build/SyncSpeaker.app`. If I have an
   Apple Development signing identity (`security find-identity -v -p codesigning`),
   ask whether to build with `SIGN_ID="<identity>"` so macOS keeps its
   permissions across rebuilds.
5. Copy the app to /Applications and open it. It lives in the menu bar, not the Dock.
6. Ask me whether this Mac is the leader (Mac A, receives AirPlay) or the
   follower (Mac B). Then walk me through the steps only I can do, following
   the README's Install section: turning on AirPlay Receiver (leader only),
   choosing the role from the menu-bar icon, and allowing System Audio
   Recording, Local Network and Microphone when macOS asks. Don't change
   system settings yourself.
7. Once both Macs are running, have me open the web remote at
   http://<leader>.local:8080 and run Calibrate sync twice from the Speakers tab.

Skip the iPhone app unless I ask for it (it needs Xcode). If a step fails,
show me the error and fix it before moving on. Only change the project's
source code if the build needs it, and tell me if you do.
```

## Requirements

- Two MacBooks on macOS 15 or later, on the same Wi-Fi network.
- An iPhone with Apple Music.
- To build: a Swift 6 toolchain (the Xcode Command Line Tools are enough) and Node 20.19 or later.
- The web remote needs Safari / iOS 16.4 or later.
- Optional, for listener tracking: an ARKit-capable iPhone, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Install

### 1. Build the Mac app

```bash
git clone https://github.com/vihAan02/sync-speaker.git
cd sync-speaker
scripts/build-app.sh            # → build/SyncSpeaker.app (web remote bundled)
```

Copy `build/SyncSpeaker.app` into Applications on both MacBooks and open it. It lives in the menu bar and has no Dock icon. If macOS says the app can't be opened, Control-click it and choose **Open**.

Without a signing identity the app is ad-hoc signed, so macOS asks for its privacy permissions again after every rebuild. To keep them, sign with your own identity:

```bash
SIGN_ID="Apple Development: …" scripts/build-app.sh
```

### 2. Mac A: the leader

1. Turn on **System Settings › General › AirDrop & Handoff › AirPlay Receiver**.
2. Click the SyncSpeaker menu-bar icon and choose **Leader (A)**.
3. Allow **System Audio Recording** and **Local Network** when asked. If you miss a prompt, turn it on under *Privacy & Security › Screen & System Audio Recording*, then choose **Off** and **Leader (A)** again.

While Mac A is the leader, its other sounds are muted. Only the synced playout is audible.

### 3. Mac B: the follower

Choose **Follower (B)** and allow Local Network. Mac B finds the leader over Bonjour, and within a few seconds the menu shows the link as connected and playout as locked. If it stays on "searching for leader…", type Mac A's local hostname (from *System Settings › General › Sharing*) into the **Leader host** field.

### 4. Play music

- **AirPlay:** in Apple Music on your iPhone, AirPlay to Mac A only, never to Mac B. Sound starts about 2 seconds after you press play.
- **Web remote:** open `http://<mac-a>.local:8080` in Safari, or click **Open Web UI** in Mac A's menu. It controls Music.app on Mac A: play, pause, skip, search and playlists.

### 5. Calibrate

In a quiet room, open the remote's **Speakers** tab and tap **Calibrate sync**. Both Macs ask for Microphone access the first time. Run it twice: the first run corrects the follower's offset, and the second should report a measured offset under 0.5 ms and roughly the real distance between the Macs.

### 6. iPhone app (optional)

The iPhone app tells the speakers where you are, so the sound stays centered on you as you move. Without it, set **Room › Spatial mode** to Off in the remote and sit between the Macs.

```bash
brew install xcodegen
cd Apps/Phone && xcodegen && open SyncSpeakerPhone.xcodeproj
```

Set your signing team and run it on the phone. Allow Camera and Local Network, and it connects to the leader by itself. The **Room** tab works in three steps:

1. **Scan.** Sweep the phone slowly over the room, including both MacBooks. LiDAR iPhones draw a mesh colored by surface type (floor, wall, table, seat); other iPhones show detected planes. *Done* unlocks once ARKit has a usable map.
2. **Place.** Tap MacBook A where you see it in the camera view, then MacBook B. A virtual MacBook drops on each spot. To move one, tap its marker, then tap the right spot. For the most accurate position, hold the phone against the Mac and choose *Use phone position* from the ⋯ menu.
3. **Listen.** Walk around. Each MacBook shows your distance to it plus its delay, gain and channel. Turn *Follow me* off and on to hear the difference, or use *Lock spot* to put the phone down.

The map and speaker spots are saved on the phone, so next time you can choose *Restore saved room* instead of scanning. The **Remote** tab is the web remote.

### Everyday use

Both Macs remember their role and calibration. Open SyncSpeaker on both, in any order, then AirPlay to Mac A. To start it automatically, add it under *System Settings › General › Login Items* on both Macs. Choose **Off** or quit to get Mac A's normal sound back.

## Troubleshooting

| Problem | Fix |
|---|---|
| Mac A isn't in the AirPlay list | Check that AirPlay Receiver is on and set to *Anyone on the Same Network*, and that the iPhone is on the same Wi-Fi. |
| AirPlay connects but nothing plays | Confirm System Audio Recording is allowed, then choose **Off** and **Leader (A)** again. To check capture directly, run `SyncSpeaker.app/Contents/MacOS/SyncSpeaker --capture-test 10 test.wav` while AirPlaying. It reports the peak level it heard. |
| Mac B keeps searching for the leader | Allow Local Network on both Macs and type Mac A's hostname on Mac B. If the firewall is on, allow incoming connections for SyncSpeaker on Mac A. |
| Crackles or dropouts | In the remote's **Speakers** tab, raise *Playout latency* to 500 ms. 5 GHz Wi-Fi also helps. |
| Doubled or echoey sound | AirPlay to Mac A only, then run **Calibrate sync** twice. |
| Calibration says the chirps are too quiet | Turn both Macs' volume up, keep them within 5 m of each other with nothing in between, and try again somewhere quieter. |
| Speaker markers no longer sit on the Macs | ARKit drifts over long sessions. In the iPhone app, use *Move MacBooks* or *New scan*. |

## How it works

The leader taps the Mac's system audio (muted, so its own speakers stay silent), cuts it into 10 ms chunks stamped against a shared clock, and streams them to the follower over TCP. Both Macs run the same playout engine and play each chunk at the same moment on that clock, about 300 ms after capture. A UDP ping/pong exchange keeps the follower's clock locked to the leader's, and a one-time acoustic calibration measures any remaining offset plus the distance between the speakers. When the iPhone app reports where you are, the leader's planner sends each Mac a delay, gain and left/right channel 20 times a second, so the sound from both speakers reaches you together.

| Piece | Where | Notes |
|---|---|---|
| Capture | `Sources/AudioIO/SystemAudioTap.swift` | Global `CATapDescription` excluding our own process, muted, on a private aggregate device. The IO thread pushes into a lock-free block FIFO. |
| Timestamps | `Sources/Playout/StreamTimestamper.swift` | Least-squares fit of host time vs frame index recovers the capture rate; gaps advance the index. |
| Clock sync | `Sources/ClockSync`, `Sources/Transport/ClockService.swift` | NTP-style pings at 10 Hz. The lowest-RTT exchange per block feeds an RTT-weighted regression for offset and skew. |
| Playout | `Sources/CDSP/cdsp.c` | Real-time C kernel. A PI controller (±200 ppm) corrects device drift; jumps above 5 ms resync with a fade. Cubic interpolation also does sample-rate conversion. Spatial delay is slew-limited to 1 ms/s. |
| Calibration | `Sources/Calibration` | Up-chirp from A, down-chirp from B. Each node compares arrivals *inside its own recording*, so latencies and clocks cancel: `D = (xA−xB)/2`, `ℓB−ℓA = (xA+xB)/2 − S`. |
| Spatial rendering | `Sources/SpatialPlanner` | One-euro-smoothed head position. `delay = (r_max − r)/c`, `gain = r/r_max` (≥ −6 dB). L/R follows which speaker is on your left, with a mono zone and hysteresis. |
| Room mapping | `Apps/Phone/Sources/RoomTracker.swift`, `ARRoomView.swift`, `RoomScene.swift` | ARKit scene reconstruction: a classified mesh on LiDAR iPhones, planes otherwise. Taps hit-test the mesh and fall back to ARKit raycasts. Speaker spots are named `ARAnchor`s saved in an `ARWorldMap`; restoring the map puts the world back in the coordinates the leader already has. |
| Control | `Sources/ControlServer`, `Sources/MusicControl` | Hummingbird HTTP + WebSockets. Music.app via AppleScript. |
| Remote | `web/` | React + shadcn/ui + anime.js, built with Vite. Tabs: Play, Room, Speakers. |

## Development

```bash
scripts/test.sh                 # unit tests
swift build                     # debug build → .build/debug/SyncSpeaker
```

Headless modes, handy for testing without AirPlay:

```bash
B=.build/debug/SyncSpeaker
$B --capture-test 10 out.wav                      # record the system tap to a WAV
$B --role leader --source tone --volume 0.2       # alternating L/R tone bursts instead of the tap
$B --role follower --leader-host MacBook.local
```

A tone leader and a follower can run on the **same** Mac to exercise the full network, clock and playout path.

To work on the web remote, run `npm install && npm run dev` in `web/`. The Vite dev server proxies `/api` and `/ws` to a leader running on port 8080.

## Known limitations

- Total latency is AirPlay's ~2 s plus ~300 ms of playout. That's fine for music, not for video.
- While Mac A is the leader, all of its other sounds are muted too.
- Two speakers only.
