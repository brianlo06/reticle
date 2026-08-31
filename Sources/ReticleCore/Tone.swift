import Foundation
import RemoteKit

/// A single synthesised note: what to play, when, and for how long.
///
/// Deliberately data rather than audio. The rendering needs AVFoundation and a sound card,
/// but *which note a hit makes* is a design decision like any other in this package, and it
/// is asserted in tests rather than listened for.
public struct Tone: Equatable, Sendable {
    public enum Waveform: Sendable, Equatable {
        case sine, square, triangle, sawtooth
        /// White noise. The percussive part of a gunshot is not a pitch.
        case noise
    }

    /// Hertz at the start of the note.
    public var frequency: Double
    /// Ratio to slide to by the end. `1` holds the pitch, `1.3` rises, `0.8` falls.
    public var bend: Double
    public var duration: Double
    public var waveform: Waveform
    /// Peak amplitude, 0...1.
    public var gain: Double
    /// Seconds after the cue arrives that this note starts, so a fanfare is three notes
    /// rather than three cues.
    public var delay: Double

    public init(frequency: Double, bend: Double = 1, duration: Double,
                waveform: Waveform = .square, gain: Double = 0.2, delay: Double = 0) {
        self.frequency = max(20, min(frequency, 18_000))
        self.bend = max(0.1, min(bend, 10))
        self.duration = max(0.005, min(duration, 2))
        self.waveform = waveform
        self.gain = max(0, min(gain, 1))
        self.delay = max(0, min(delay, 2))
    }

    /// When this note has finished sounding.
    public var end: Double { delay + duration }
}

/// What the television plays when a cue is raised.
///
/// The Mac renders the same cue vocabulary the phone does — `success` at some intensity,
/// never `targetDestroyed` — so it is another client of the host's meaning rather than a
/// second copy of the rules. What differs is the presentation: the phone has a vibration
/// motor and a speaker the size of a coin, the television has the room.
public enum Sound {

    /// The longest a cue may sound for. A game noise that outlives the moment it was for is
    /// worse than silence, and it also bounds the buffer the renderer has to allocate.
    public static let maximumDuration: Double = 0.8

    public static func notes(for cue: CuePayload) -> [Tone] {
        notes(kind: cue.kind, intensity: cue.intensity)
    }

    public static func notes(kind: CuePayload.Kind, intensity: Double) -> [Tone] {
        let strength = max(0, min(intensity.isFinite ? intensity : 0.6, 1))
        // Every cue is louder when it matters more, which is the whole point of carrying an
        // intensity in the protocol instead of a bare event name.
        let level = 0.10 + 0.22 * strength

        switch kind {
        case .success:
            // A hit is a click and a rising note, and the note climbs with the streak. Two
            // layers because a pure tone reads as a beep and a shooting gallery wants a
            // report — the noise burst is the percussion, the tone is the reward.
            return [
                Tone(frequency: 2_400, bend: 0.4, duration: 0.035,
                     waveform: .noise, gain: level * 0.7),
                Tone(frequency: 660 * (1 + strength * 0.75), bend: 1.35, duration: 0.09,
                     waveform: .square, gain: level, delay: 0.01),
            ]

        case .failure:
            // Low and falling. A miss should sit under the music, not on top of it.
            return [Tone(frequency: 190, bend: 0.72, duration: 0.13,
                         waveform: .sawtooth, gain: level * 0.8)]

        case .warning:
            // Two beats, because one beep is indistinguishable from a tick and this one
            // means the round is nearly over.
            return [
                Tone(frequency: 520, duration: 0.055, waveform: .square, gain: level),
                Tone(frequency: 520, duration: 0.055, waveform: .square, gain: level,
                     delay: 0.09),
            ]

        case .start:
            // A rising third. The one moment in a round worth a fanfare.
            return [
                Tone(frequency: 660, duration: 0.10, waveform: .square, gain: level),
                Tone(frequency: 880, duration: 0.10, waveform: .square, gain: level,
                     delay: 0.11),
                Tone(frequency: 1_320, bend: 1.02, duration: 0.20, waveform: .square,
                     gain: level, delay: 0.22),
            ]

        case .finish:
            // The same interval falling, so the end of a round answers its beginning.
            return [
                Tone(frequency: 440, duration: 0.16, waveform: .triangle, gain: level),
                Tone(frequency: 330, bend: 0.98, duration: 0.34, waveform: .triangle,
                     gain: level, delay: 0.17),
            ]

        case .tick:
            return [Tone(frequency: 740, duration: 0.05, waveform: .square, gain: level)]

        case .info:
            // Neutral acknowledgement: quiet, short, easy to ignore. It fires for things
            // like readying up, which happens often enough to become irritating otherwise.
            return [Tone(frequency: 520, duration: 0.05, waveform: .sine, gain: level * 0.6)]
        }
    }

    // MARK: - Synthesis

    /// Sums a cue's notes into one run of samples, in -1...1.
    ///
    /// Pure arithmetic, so it lives with the rules rather than with the audio engine: a
    /// note that ends on a click or a mix that clips is a bug like any other, and neither
    /// should need a sound card to catch. The caller's only job is to hand the result to
    /// the hardware.
    ///
    /// One buffer for the whole cue means a three-note fanfare costs one voice, not three.
    public static func samples(for notes: [Tone], sampleRate: Double) -> [Float] {
        // Nothing to play is not the same as a moment of silence to play: a buffer of
        // zeroes would still occupy a voice and hold off the next shot.
        guard sampleRate > 0, !notes.isEmpty else { return [] }
        // A short tail so every envelope has room to reach silence. Landing on a non-zero
        // sample is an audible click, and a click on every note is what makes synthesised
        // game audio sound cheap.
        let total = min(notes.map(\.end).max()! + 0.02, maximumDuration + 0.02)
        let count = Int(total * sampleRate)
        guard count > 0 else { return [] }
        var mix = [Double](repeating: 0, count: count)

        for note in notes {
            var phase = 0.0
            // One-pole lowpass state, which gives the noise burst a body instead of a hiss.
            var filtered = 0.0
            // Seeded from the note rather than the system, so a given cue sounds the same
            // every time. A click that is subtly different on every shot reads as a fault.
            var noise = Noise(seed: UInt64(note.frequency * 1_000) &+ UInt64(note.delay * 1_000) &+ 1)
            let start = Int(note.delay * sampleRate)
            let length = Int(note.duration * sampleRate)
            guard length > 0 else { continue }

            for i in 0..<length {
                let index = start + i
                guard index < count else { break }
                let progress = Double(i) / Double(length)
                // Exponential glide, so a bend of 1.35 is the same musical interval
                // wherever it starts from.
                let frequency = note.frequency * pow(note.bend, progress)

                let sample: Double
                if note.waveform == .noise {
                    // Cutoff follows the sweep: the click opens bright and closes dark.
                    let alpha = min(1, 2 * .pi * frequency / sampleRate)
                    filtered += alpha * (noise.next() - filtered)
                    sample = filtered
                } else {
                    phase += 2 * .pi * frequency / sampleRate
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    sample = wave(note.waveform, phase: phase)
                }

                mix[index] += sample * note.gain * envelope(at: progress)
            }
        }

        // Soft clip rather than hard: four players hitting at once should get louder and
        // then stop getting louder, not tear.
        return mix.map { Float(tanh($0)) }
    }

    private static func wave(_ waveform: Tone.Waveform, phase: Double) -> Double {
        let turns = phase / (2 * .pi)
        switch waveform {
        case .sine: return sin(phase)
        // Trimmed against the sine, because a square wave at the same peak amplitude is
        // markedly louder and the mix would be all edges.
        case .square: return sin(phase) >= 0 ? 0.7 : -0.7
        case .triangle: return 4 * abs(turns - 0.5) - 1
        case .sawtooth: return (2 * turns - 1) * 0.7
        case .noise: return 0   // handled by the filtered path, which needs state
        }
    }

    /// A short attack and an exponential decay, forced to zero at the end.
    private static func envelope(at progress: Double) -> Double {
        let attack = 0.06
        if progress < attack { return progress / attack }
        let decay = (progress - attack) / (1 - attack)
        // The linear term is what guarantees silence at the end; the exponential is what
        // makes it sound like a struck thing rather than a fade.
        return exp(-4 * decay) * (1 - decay)
    }

    /// A tiny deterministic generator, so the same cue renders to the same samples.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed | 1 }
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 20_001) / 10_000 - 1
        }
    }

    // MARK: - Pacing

    /// The shortest gap between two cues of the same kind that the room can tell apart.
    ///
    /// Four players share one pair of speakers, and at a 0.16s cooldown they can between
    /// them land two dozen shots a second. Played faithfully that is not feedback, it is a
    /// buzz — and summing that many copies of the same note clips the output. Repeats
    /// inside this window are dropped rather than queued, because a late duplicate is worse
    /// than a missing one.
    public static func retriggerInterval(for kind: CuePayload.Kind) -> Double {
        switch kind {
        // Shots are the ones that stack, and they are also the ones where a listener hears
        // two near-simultaneous hits as a single louder event anyway.
        case .success, .failure: return 0.045
        case .info: return 0.08
        // A countdown beat, a fanfare or a round ending happens once. If two arrive
        // together something is wrong upstream, and swallowing one would hide it.
        case .tick, .warning, .start, .finish: return 0
        }
    }
}
