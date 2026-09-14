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

## Requirements

- Two MacBooks on macOS 15 or later (system audio taps need 14.4+), on the same Wi-Fi.
- Swift 6 toolchain (Command Line Tools are enough for the Mac app) and Node 18+ for the web UI.
- For the iPhone app: **Xcode** plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an ARKit-capable iPhone.

## Build and run

```bash
scripts/test.sh                 # unit tests
scripts/build-app.sh            # → build/SyncSpeaker.app (web UI bundled)
```

Copy `build/SyncSpeaker.app` to both MacBooks and open it. It lives in the menu bar.

1. **Mac 1:** choose **Leader (A)**. On first use macOS asks for *System Audio Recording*. Grant it, then pick Leader again.
2. **Mac 2:** choose **Follower (B)**. It finds the leader over Bonjour; you can also type the leader's host name.
3. **iPhone:** AirPlay Apple Music to the leader Mac. Enable *System Settings › General › AirDrop & Handoff › AirPlay Receiver* on the leader first. Only the synced playout is audible; the tap mutes the Mac's normal output.
4. Open `http://<leader>.local:8080` on your phone for the remote, or use the iPhone app.
5. **Speakers tab › Calibrate sync** in a quiet room. It trims the follower's playback offset and measures the spacing. Run it twice; the second "measured offset" should be under 0.5 ms.

Sign with your own identity to keep privacy grants across rebuilds:
`SIGN_ID="Apple Development: …" scripts/build-app.sh`.

### Headless / testing modes

```bash
B=.build/debug/SyncSpeaker
$B --capture-test 10 out.wav                      # does the tap hear AirPlay/Music? writes a WAV
$B --role leader --source tone --volume 0.2       # alternating L/R tone bursts instead of the tap
$B --role follower --leader-host MacBook.local
```

A leader with `--source tone` and a follower can run on the **same** Mac to exercise the full network, clock and playout path.

### iPhone app

```bash
brew install xcodegen
cd Apps/Phone && xcodegen && open SyncSpeakerPhone.xcodeproj
```

Set your signing team and run on the phone. **Room tab:** connect to the leader, hold the phone against MacBook A and tap *Phone is touching it*, then repeat for B. Walk around, or *Lock my spot* to put the phone down. **Remote tab:** the web UI.

## How it works

| Piece | Where | Notes |
|---|---|---|
| Capture | `Sources/AudioIO/SystemAudioTap.swift` | Global `CATapDescription` excluding our own process, muted, on a private aggregate device. The IO thread pushes into a lock-free block FIFO. |
| Timestamps | `Sources/Playout/StreamTimestamper.swift` | Least-squares fit of host time vs frame index recovers the capture rate; gaps advance the index. |
| Clock sync | `Sources/ClockSync`, `Sources/Transport/ClockService.swift` | NTP-style pings at 10 Hz. The lowest-RTT exchange per block feeds an RTT-weighted regression for offset and skew. |
| Playout | `Sources/CDSP/cdsp.c` | Real-time C kernel. A PI controller (±200 ppm) corrects device drift; jumps above 5 ms resync with a fade. Cubic interpolation also does sample-rate conversion. Spatial delay is slew-limited to 1 ms/s. |
| Calibration | `Sources/Calibration` | Up-chirp from A, down-chirp from B. Each node compares arrivals *inside its own recording*, so latencies and clocks cancel: `D = (xA−xB)/2`, `ℓB−ℓA = (xA+xB)/2 − S`. |
| Spatial v1 | `Sources/SpatialPlanner` | One-euro-smoothed head position. `delay = (r_max − r)/c`, `gain = r/r_max` (≥ −6 dB). L/R follows which speaker is on your left, with a mono zone and hysteresis. |
| Control | `Sources/ControlServer`, `Sources/MusicControl` | Hummingbird HTTP + WebSockets. Music.app via AppleScript. |

## Status

Verified on one Mac (Apple silicon, macOS 26.5):

- 29 unit tests pass: clock convergence under simulated Wi-Fi jitter (5 seeds), drift lock at 80 ppm, a 44.1↔48 kHz conversion, latency-step resync, delay slew, a synthetic chirp calibration recovering distance within 1 cm and latency within 0.1 ms, planner geometry and hysteresis, and protocol round trips.
- Leader (tone source) and follower on loopback: follower clock jitter about 9 µs, both nodes locked with about 0.06 ms playout error, 0 underruns.
- Simulated phone anchors and pose over `/ws/phone`: planner output matches hand-computed delay and gain, and the follower applies its plan. The web UI was checked at phone width.
- `scripts/build-app.sh` produces a signed, valid `.app`.

Not yet verified (needs hardware or tools this machine doesn't have):

- **Milestone 1 spike:** whether the global tap captures AirPlay Receiver audio. Run `--capture-test` while AirPlaying. Fallback: set BlackHole as the leader's output device.
- Two physical MacBooks over Wi-Fi, and acoustic calibration with real speakers and mics.
- **The iPhone app has not been compiled** (Xcode isn't installed here). Expect small fixes on first build.

## Known limitations

- Total latency is AirPlay's ~2 s plus 300 ms playout. That's fine for music, not for video.
- While the leader is in speaker mode, all of its other sounds are muted too.
- ARKit drifts over long sessions. Re-place the speakers if the map looks off.
- v2 ideas: 3D transaural rendering (HRTF + crosstalk cancellation), Opus transport, more than two nodes, leader election.
