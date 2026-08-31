import AVFoundation
import Foundation
import RemoteKit
import ReticleCore

/// The television's half of the feedback.
///
/// The phone kicks in your hand; this is what the room hears. Both render the same cue
/// vocabulary the host raises, so the Mac is another client of the host's meaning rather
/// than a second copy of the rules — `Sound.notes(for:)` decides what a cue sounds like and
/// is tested; this file only turns notes into samples.
///
/// Tones are synthesised at launch rather than loaded, exactly as on the phone: no audio
/// assets to ship, nothing to find at runtime, and no failure mode where the sound arrives
/// after the moment it was for.
final class GameAudio {

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    /// A pool, because two players hit at once and one node plays one buffer at a time.
    private var voices: [AVAudioPlayerNode] = []
    /// When each voice frees up, so a shot is dropped rather than queued behind another.
    /// A late sound is worse than a missing one when it is meant to mean "you hit that".
    private var voiceFreeAt: [TimeInterval]
    private var buffers: [BufferKey: AVAudioPCMBuffer] = [:]
    private var lastPlayed: [CuePayload.Kind: TimeInterval] = [:]

    private static let voiceCount = 12

    /// Silent, but still alive: muting must not tear down the engine, or unmuting would
    /// have to rebuild it at the exact moment somebody wants to hear something.
    var isMuted: Bool = false

    private struct BufferKey: Hashable {
        let kind: CuePayload.Kind
        /// Intensity in twentieths. A hit at 0.62 and one at 0.64 are the same sound, and
        /// caching by the raw double would render a new buffer for every shot.
        let step: Int
    }

    /// Starts the audio engine. Returns `nil` if the machine will not give us one — a Mac
    /// with no output device, or a test host. Sound is a bonus here, never a requirement,
    /// so failing to get it must never stop the game from running.
    init?(muted: Bool = false) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            return nil
        }
        self.format = format
        self.isMuted = muted
        self.voiceFreeAt = Array(repeating: 0, count: Self.voiceCount)

        let mixer = engine.mainMixerNode
        for _ in 0..<Self.voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: mixer, format: format)
            voices.append(node)
        }

        do {
            try engine.start()
        } catch {
            Log.warn("sound unavailable: \(error.localizedDescription)")
            return nil
        }
        voices.forEach { $0.play() }

        // Plugging the Mac into the television is an output-device change, which stops the
        // engine — precisely the moment this game is being set up. Without this the sound
        // works on the desk and is silent on the TV, which is the wrong way round.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    private func restart() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            voices.forEach { $0.play() }
            Log.info("audio output changed — sound restarted")
        } catch {
            Log.warn("sound stopped: \(error.localizedDescription)")
        }
    }

    /// Play a cue. Main queue only, like everything else that touches the game.
    func play(_ cue: CuePayload) {
        guard !isMuted, engine.isRunning else { return }
        let now = CACurrentMediaTime()

        // Four players sharing one pair of speakers can land two dozen shots a second
        // between them. Repeats inside the retrigger window are dropped, not queued.
        let gap = Sound.retriggerInterval(for: cue.kind)
        if gap > 0, let last = lastPlayed[cue.kind], now - last < gap { return }

        let key = BufferKey(kind: cue.kind, step: Int((cue.intensity * 20).rounded()))
        let buffer: AVAudioPCMBuffer
        if let cached = buffers[key] {
            buffer = cached
        } else {
            let notes = Sound.notes(kind: cue.kind, intensity: Double(key.step) / 20)
            guard let rendered = render(notes) else { return }
            buffers[key] = rendered
            buffer = rendered
        }

        guard let index = voiceFreeAt.firstIndex(where: { $0 <= now }) else { return }
        let seconds = Double(buffer.frameLength) / format.sampleRate
        voiceFreeAt[index] = now + seconds
        lastPlayed[cue.kind] = now
        voices[index].scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    // MARK: - Buffers

    /// Copies a cue's samples into a buffer the engine can play. The arithmetic that makes
    /// the sound lives in `ReticleCore`, where it is tested; this is only plumbing.
    private func render(_ notes: [Tone]) -> AVAudioPCMBuffer? {
        let samples = Sound.samples(for: notes, sampleRate: format.sampleRate)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        // Mono material, played to both ears: a shot belongs to a player, not to a side of
        // the room, and there is no sensible panning for four people on one sofa.
        for channel in 0..<Int(format.channelCount) {
            samples.withUnsafeBufferPointer { channels[channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }
}
