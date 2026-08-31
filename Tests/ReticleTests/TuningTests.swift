import XCTest
@testable import ReticleCore

/// How the gun feels in your hand, as opposed to how hard the game is.
final class TuningTests: XCTestCase {

    private func game(_ mode: Mode = .arcade) -> Game {
        let game = Game(arena: Arena(width: 1000, height: 800), settings: mode.settings)
        game.setMode(mode)
        return game
    }

    /// The reason sensitivity is not part of `Settings`: `setMode` replaces those
    /// wholesale, so a value somebody spent a round settling would be silently undone by
    /// cycling to Precision and back from the sofa.
    func testSensitivitySurvivesAModeChange() {
        let game = self.game()
        game.sensitivity = 1.5
        for mode in Mode.allCases + [.arcade] {
            XCTAssertTrue(game.setMode(mode))
            XCTAssertEqual(game.sensitivity, 1.5, "\(mode) reset the room's aim")
        }
    }

    func testSensitivityScalesHowFarTheReticleTravels() {
        let slow = game()
        let fast = game()
        slow.sensitivity = 0.5
        fast.sensitivity = 2.0
        let id = UUID()
        for g in [slow, fast] {
            g.addPlayer(id: id, name: "P")
            g.recenter(player: id)
            g.aim(player: id, dx: 40, dy: 0)
        }
        let origin = slow.arena.center.x
        XCTAssertEqual(fast.players[id]!.reticle.x - origin,
                       (slow.players[id]!.reticle.x - origin) * 4, accuracy: 0.001)
    }

    /// It is adjustable live, and a mistyped sensitivity that flings the reticle into a
    /// corner cannot be corrected from that corner.
    func testSensitivityIsClampedToSomethingRecoverable() {
        let game = self.game()
        game.sensitivity = 99
        XCTAssertEqual(game.sensitivity, 4)
        game.sensitivity = 0
        XCTAssertEqual(game.sensitivity, 0.25)
        game.sensitivity = -3
        XCTAssertEqual(game.sensitivity, 0.25)
    }

    func testANonsenseSensitivityKeepsTheLastGoodOne() {
        let game = self.game()
        game.sensitivity = 1.4
        game.sensitivity = .nan
        XCTAssertEqual(game.sensitivity, 1.4)
        game.sensitivity = .infinity
        XCTAssertEqual(game.sensitivity, 1.4)
    }

    /// The README's standing complaint was that the game inherited a cursor remote's aim
    /// unchanged. A gun is not a cursor.
    func testAimIsTwitchierThanACursorRemote() {
        XCTAssertGreaterThan(Game.Settings().aimGain, 1.0)
    }

    func testEachModeAimsToSuitItsTargets() {
        let gains = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, $0.settings.aimGain) })
        for (mode, gain) in gains {
            XCTAssertGreaterThan(gain, 0, "\(mode) would freeze the reticle")
        }
        XCTAssertLessThan(gains[.precision]!, gains[.arcade]!,
                          "a mode about holding still should not cross the arena on a twitch")
        XCTAssertGreaterThan(gains[.survival]!, gains[.arcade]!,
                             "fast targets need a gun that can catch them")
    }

    func testEffectiveGainCombinesTheModeAndTheRoom() {
        let game = self.game(.precision)
        game.sensitivity = 2
        XCTAssertEqual(game.effectiveAimGain, Mode.precision.settings.aimGain * 2, accuracy: 0.0001)
    }
}
