import XCTest
import RemoteKit
@testable import ReticleCore

/// What the television plays, given what the host just said happened.
///
/// The rendering needs a sound card and cannot be asserted; the design can. These are the
/// claims the README makes about the audio, written down where they can fail.
final class SoundTests: XCTestCase {

    private let allKinds: [CuePayload.Kind] = [.success, .failure, .warning, .start,
                                               .finish, .tick, .info]

    func testEveryCueMakesASound() {
        for kind in allKinds {
            XCTAssertFalse(Sound.notes(kind: kind, intensity: 0.6).isEmpty,
                           "\(kind) is part of the vocabulary, so it needs a voice")
        }
    }

    /// A game noise that outlives the moment it was for is worse than silence — and the
    /// renderer sizes its buffer from this, so an unbounded cue would be an unbounded
    /// allocation.
    func testNothingOutlastsTheMomentItIsFor() {
        for kind in allKinds {
            for intensity in stride(from: 0.0, through: 1.0, by: 0.1) {
                let end = Sound.notes(kind: kind, intensity: intensity).map(\.end).max() ?? 0
                XCTAssertLessThanOrEqual(end, Sound.maximumDuration,
                                         "\(kind) at \(intensity) runs long")
            }
        }
    }

    func testALongStreakIsLouderAndHigherThanAFirstHit() {
        let first = Sound.notes(kind: .success, intensity: 0.5)
        let fifth = Sound.notes(kind: .success, intensity: 1.0)
        XCTAssertGreaterThan(fifth.map(\.gain).max()!, first.map(\.gain).max()!)
        // The pitched layer is what climbs; the click stays a click.
        let pitch = { (notes: [Tone]) in notes.first { $0.waveform != .noise }!.frequency }
        XCTAssertGreaterThan(pitch(fifth), pitch(first),
                             "a streak should be heard climbing, not read off the screen")
    }

    /// A miss has to sit under the hits rather than on top of them, or missing becomes the
    /// loudest thing in the room.
    func testAMissIsLowerAndQuieterThanAHit() {
        let hit = Sound.notes(kind: .success, intensity: 0.5)
        let miss = Sound.notes(kind: .failure, intensity: 0.35)
        XCTAssertLessThan(miss.map(\.frequency).max()!, hit.map(\.frequency).max()!)
        XCTAssertLessThan(miss.map(\.gain).max()!, hit.map(\.gain).max()!)
    }

    func testTheRoundStartsRisingAndEndsFalling() {
        let start = Sound.notes(kind: .start, intensity: 0.9).sorted { $0.delay < $1.delay }
        XCTAssertGreaterThan(start.count, 1, "the one moment worth a fanfare")
        XCTAssertEqual(start, start.sorted { $0.frequency < $1.frequency },
                       "a fanfare rises")

        let finish = Sound.notes(kind: .finish, intensity: 0.8).sorted { $0.delay < $1.delay }
        XCTAssertEqual(finish, finish.sorted { $0.frequency > $1.frequency },
                       "the end of a round answers its beginning")
    }

    /// Four players at a 0.16s cooldown can land two dozen shots a second between them.
    /// Played faithfully that is a buzz, not feedback.
    func testShotsCoalesceButTheClockNeverDoes() {
        XCTAssertGreaterThan(Sound.retriggerInterval(for: .success), 0)
        XCTAssertGreaterThan(Sound.retriggerInterval(for: .failure), 0)
        for kind in [CuePayload.Kind.tick, .warning, .start, .finish] {
            XCTAssertEqual(Sound.retriggerInterval(for: kind), 0,
                           "\(kind) happens once; dropping one would hide a bug upstream")
        }
    }

    func testACueDrivesTheSoundDirectly() {
        // The Mac is another client of the host's cue vocabulary, not a second copy of the
        // rules, so a `CuePayload` is all it should ever need.
        let cue = Feedback.cue(for: .shot(.hit(targetID: UUID(), points: 90, multiplier: 4)))!
        XCTAssertEqual(Sound.notes(for: cue), Sound.notes(kind: .success, intensity: cue.intensity))
    }

    func testAToneRefusesValuesTheRendererCannotPlay() {
        let silly = Tone(frequency: -100, bend: 0, duration: 900, gain: 40, delay: -3)
        XCTAssertGreaterThan(silly.frequency, 0)
        XCTAssertGreaterThan(silly.bend, 0)
        XCTAssertLessThanOrEqual(silly.duration, 2)
        XCTAssertLessThanOrEqual(silly.gain, 1)
        XCTAssertEqual(silly.delay, 0)
    }

    func testEveryNoteIsPlayable() {
        for kind in allKinds {
            for note in Sound.notes(kind: kind, intensity: 1.0) {
                XCTAssertGreaterThan(note.duration, 0)
                XCTAssertGreaterThan(note.gain, 0, "a note nobody can hear is not a note")
                XCTAssertLessThanOrEqual(note.gain, 1)
                // Above this the television is reproducing something only the dog enjoys.
                XCTAssertLessThan(note.frequency * max(note.bend, 1), 12_000.0)
            }
        }
    }

    // MARK: - Synthesis

    func testACueRendersToAudibleSamples() {
        for kind in allKinds {
            let samples = Sound.samples(for: Sound.notes(kind: kind, intensity: 0.8),
                                        sampleRate: 44_100)
            XCTAssertFalse(samples.isEmpty, "\(kind) rendered nothing")
            let peak = samples.map(abs).max()!
            XCTAssertGreaterThan(peak, 0.02, "\(kind) is inaudible")
            XCTAssertLessThanOrEqual(peak, 1.0, "\(kind) would clip the output")
            XCTAssertFalse(samples.contains { !$0.isFinite })
        }
    }

    /// A buffer that starts or ends on a non-zero sample clicks, and a click on every note
    /// is exactly what makes synthesised game audio sound cheap.
    func testEveryCueStartsAndEndsInSilence() {
        for kind in allKinds {
            let samples = Sound.samples(for: Sound.notes(kind: kind, intensity: 1.0),
                                        sampleRate: 44_100)
            XCTAssertLessThan(abs(samples.first!), 0.01, "\(kind) clicks in")
            XCTAssertLessThan(abs(samples.last!), 0.01, "\(kind) clicks out")
        }
    }

    func testLouderCuesRenderLouder() {
        let quiet = Sound.samples(for: Sound.notes(kind: .success, intensity: 0.2),
                                  sampleRate: 44_100).map(abs).max()!
        let loud = Sound.samples(for: Sound.notes(kind: .success, intensity: 1.0),
                                 sampleRate: 44_100).map(abs).max()!
        XCTAssertGreaterThan(loud, quiet)
    }

    /// Simultaneous hits should get louder and then stop getting louder, not tear.
    func testStackedNotesAreSoftClippedRatherThanAllowedToTear() {
        let deafening = (0..<8).map { _ in Tone(frequency: 440, duration: 0.2, gain: 1) }
        let samples = Sound.samples(for: deafening, sampleRate: 44_100)
        XCTAssertLessThanOrEqual(samples.map(abs).max()!, 1.0)
    }

    /// A click that is subtly different on every shot reads as a fault rather than as a gun.
    func testTheSameCueAlwaysSoundsTheSame() {
        let notes = Sound.notes(kind: .success, intensity: 0.7)
        XCTAssertEqual(Sound.samples(for: notes, sampleRate: 44_100),
                       Sound.samples(for: notes, sampleRate: 44_100))
    }

    func testTheBufferIsAsLongAsTheCueAndNoLonger() {
        let rate = 44_100.0
        for kind in allKinds {
            let notes = Sound.notes(kind: kind, intensity: 0.6)
            let seconds = Double(Sound.samples(for: notes, sampleRate: rate).count) / rate
            let expected = notes.map(\.end).max()!
            XCTAssertGreaterThan(seconds, expected)
            XCTAssertLessThan(seconds, expected + 0.05)
        }
    }

    func testAnEmptyCueOrAnAbsurdRateRendersNothingRatherThanCrashing() {
        XCTAssertTrue(Sound.samples(for: [], sampleRate: 44_100).isEmpty)
        XCTAssertTrue(Sound.samples(for: Sound.notes(kind: .tick, intensity: 1), sampleRate: 0).isEmpty)
        XCTAssertTrue(Sound.samples(for: Sound.notes(kind: .tick, intensity: 1), sampleRate: -5).isEmpty)
    }

    func testAnOutOfRangeIntensityIsClampedRatherThanTrusted() {
        // Intensity arrives from the same place the phones' does, and the renderer keys its
        // buffer cache on it. A silent NaN here would be a division by nothing downstream.
        for intensity in [Double.nan, -5, 12, .infinity] {
            let notes = Sound.notes(kind: .success, intensity: intensity)
            XCTAssertFalse(notes.isEmpty)
            for note in notes {
                XCTAssertTrue(note.gain.isFinite && note.frequency.isFinite)
                XCTAssertLessThanOrEqual(note.gain, 1)
            }
        }
    }
}
