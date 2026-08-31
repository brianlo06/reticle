import XCTest
import RemoteKit
@testable import ReticleCore

/// The feel rules: what the phone should do, given what just happened.
final class FeedbackTests: XCTestCase {

    func testAHitFeelsLikeSuccessAndCarriesTheScore() {
        let cue = Feedback.cue(for: .shot(.hit(targetID: UUID(), points: 120, multiplier: 1)))
        XCTAssertEqual(cue?.kind, .success)
        XCTAssertEqual(cue?.text, "+120")
    }

    func testALongerStreakFeelsStronger() {
        let first = Feedback.cue(for: .shot(.hit(targetID: UUID(), points: 100, multiplier: 1)))
        let fifth = Feedback.cue(for: .shot(.hit(targetID: UUID(), points: 100, multiplier: 5)))
        XCTAssertGreaterThan(fifth!.intensity, first!.intensity,
                             "a streak should be felt, not read")
        XCTAssertEqual(fifth?.text, "+100 x5")
        XCTAssertLessThanOrEqual(fifth!.intensity, 1.0, "intensity must stay in range")
    }

    func testAMissFeelsWeakerThanAHit() {
        let hit = Feedback.cue(for: .shot(.hit(targetID: UUID(), points: 100, multiplier: 1)))
        let miss = Feedback.cue(for: .shot(.miss))
        XCTAssertEqual(miss?.kind, .failure)
        XCTAssertLessThan(miss!.intensity, hit!.intensity)
    }

    /// The rule that matters most for feel: a shot the game refused never happened, so
    /// buzzing would teach the player that the cooldown punishes them.
    func testARefusedShotIsNotFelt() {
        XCTAssertNil(Feedback.cue(for: .shot(.tooSoon)))
        XCTAssertNil(Feedback.cue(for: .ignored))
        XCTAssertNil(Feedback.cue(for: .noSuchPlayer))
        XCTAssertNil(Feedback.cue(for: .shot(.noSuchPlayer)))
    }

    func testReadyingUpIsAcknowledged() {
        XCTAssertEqual(Feedback.cue(for: .readied(true))?.text, "Ready")
        XCTAssertEqual(Feedback.cue(for: .readied(false))?.text, "Not ready")
        XCTAssertGreaterThan(Feedback.cue(for: .readied(true))!.intensity,
                             Feedback.cue(for: .readied(false))!.intensity)
    }

    func testPhaseChangesAreFeltOnceAndOnlyWhenTheyChange() {
        XCTAssertNil(Feedback.cue(movingTo: .playing(endsAt: 1), from: .playing(endsAt: 1)),
                     "an unchanged phase must not fire a cue every frame")
        XCTAssertEqual(Feedback.cue(movingTo: .playing(endsAt: 1), from: .countdown(startsAt: 0))?.kind,
                       .start)
        XCTAssertEqual(Feedback.cue(movingTo: .results(until: 1), from: .playing(endsAt: 0))?.kind,
                       .finish)
    }

    func testStartingIsTheStrongestCue() {
        let start = Feedback.cue(movingTo: .playing(endsAt: 1), from: .countdown(startsAt: 0))!
        let ready = Feedback.cue(movingTo: .countdown(startsAt: 1), from: .lobby)!
        XCTAssertGreaterThan(start.intensity, ready.intensity)
    }

    func testTheFirstPhaseSeenIsNotAnnounced() {
        XCTAssertNil(Feedback.cue(movingTo: .lobby, from: nil),
                     "connecting into an idle lobby is not an event")
    }

    func testCountdownBeatsOnlyFireForThreeTwoOne() {
        XCTAssertEqual(Feedback.countdownTick(secondsLeft: 3)?.text, "3")
        XCTAssertEqual(Feedback.countdownTick(secondsLeft: 1)?.text, "1")
        XCTAssertNil(Feedback.countdownTick(secondsLeft: 0))
        XCTAssertNil(Feedback.countdownTick(secondsLeft: 4))
    }

    func testRoundEndingBeatsWarnWithoutText() {
        let cue = Feedback.roundEndingTick(secondsLeft: 2)
        XCTAssertEqual(cue?.kind, .warning)
        XCTAssertNil(cue?.text, "the last seconds should be felt, not read")
        XCTAssertNil(Feedback.roundEndingTick(secondsLeft: 20))
    }

    func testIntensityIsAlwaysWithinRange() {
        let cues: [CuePayload?] = [
            Feedback.cue(for: .shot(.hit(targetID: UUID(), points: 9999, multiplier: 99))),
            Feedback.cue(for: .shot(.miss)),
            Feedback.cue(movingTo: .playing(endsAt: 1), from: .lobby),
            Feedback.countdownTick(secondsLeft: 3),
        ]
        for cue in cues.compactMap({ $0 }) {
            XCTAssertGreaterThanOrEqual(cue.intensity, 0)
            XCTAssertLessThanOrEqual(cue.intensity, 1)
        }
    }
}
