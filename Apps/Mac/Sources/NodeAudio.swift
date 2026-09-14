import AudioIO
import AVFoundation
import Calibration
import Foundation
import Playout
import SyncProtocol

/// Per-node audio: playout engine, output device, microphone.
final class NodeAudio: @unchecked Sendable {
    let engine = PlayoutEngine()
    let output: OutputRenderer
    let mic = MicRecorder()
    private(set) var lastError: String?

    init() {
        output = OutputRenderer(playout: engine.rendererPointer)
    }

    func start() throws {
        let latency = try output.start()
        engine.setOutputLatency(seconds: latency)
        lastError = nil
    }

    func stop() {
        output.stop()
    }

    /// Restarts output when the user switches the default device or its sample rate.
    func restartIfDeviceChanged() {
        guard output.deviceChanged() else { return }
        output.stop()
        do {
            try start()
        } catch {
            lastError = "\(error)"
        }
    }

    var outputSampleRate: Double { output.sampleRate > 0 ? output.sampleRate : 48_000 }
}

/// Plays this node's chirp at its scheduled cluster time and reports arrival times in its own recording.
enum CalibrationProcedure {
    static let staggerSeconds = 0.25
    static let recordSeconds = 1.0

    static func command(id: UInt64, nowClusterNs: Int64) -> CalibrationCommand {
        let recordStart = nowClusterNs + 900_000_000
        let chirpA = recordStart + 300_000_000
        return CalibrationCommand(
            id: id,
            recordStartClusterNs: recordStart,
            recordSeconds: recordSeconds,
            chirpStartClusterNs: [.a: chirpA, .b: chirpA + Int64(staggerSeconds * 1e9)]
        )
    }

    static func perform(_ command: CalibrationCommand, as speaker: SpeakerID, audio: NodeAudio,
                        toLocalNs: (Int64) -> Int64) async -> CalibrationReport {
        guard let chirpStart = command.chirpStartClusterNs[speaker] else {
            return CalibrationReport(id: command.id, speaker: speaker, arrivals: [:], error: "no chirp scheduled")
        }
        let rate = audio.outputSampleRate
        let chirp = Chirp.samples(up: speaker == .a, sampleRate: rate, amplitude: 0.35)
        audio.engine.scheduleOverlay(chirp, sampleRate: rate, startClusterNs: chirpStart)
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return CalibrationReport(id: command.id, speaker: speaker, arrivals: [:], error: "microphone access denied")
        }
        do {
            let recording = try await audio.mic.record(startHostNs: toLocalNs(command.recordStartClusterNs),
                                                       seconds: command.recordSeconds)
            let fs = recording.sampleRate
            guard let up = MatchedFilter.detect(template: Chirp.samples(up: true, sampleRate: fs), in: recording.samples, sampleRate: fs),
                  let down = MatchedFilter.detect(template: Chirp.samples(up: false, sampleRate: fs), in: recording.samples, sampleRate: fs)
            else {
                return CalibrationReport(id: command.id, speaker: speaker, arrivals: [:], error: "no chirps detected")
            }
            guard up.snr > 8, down.snr > 8 else {
                return CalibrationReport(id: command.id, speaker: speaker, arrivals: [:],
                                         error: String(format: "chirps too quiet (SNR %.0f / %.0f)", up.snr, down.snr))
            }
            return CalibrationReport(id: command.id, speaker: speaker, arrivals: [.a: up.time, .b: down.time])
        } catch {
            return CalibrationReport(id: command.id, speaker: speaker, arrivals: [:], error: "\(error)")
        }
    }
}
