import XCTest
@testable import ReticleCore

final class MovingTargetTests: XCTestCase {

    private let arena = Arena(width: 1000, height: 600)

    func testAStationaryTargetDoesNotMove() {
        var target = Target(center: Vec2(x: 500, y: 300), radius: 20, spawnedAt: 0, lifetime: 4)
        target.advance(by: 1, in: arena)
        XCTAssertEqual(target.center, Vec2(x: 500, y: 300))
    }

    func testATargetDriftsAtItsVelocity() {
        var target = Target(center: Vec2(x: 500, y: 300), radius: 20, spawnedAt: 0,
                            lifetime: 4, velocity: Vec2(x: 100, y: -50))
        target.advance(by: 0.5, in: arena)
        XCTAssertEqual(target.center.x, 550, accuracy: 1e-9)
        XCTAssertEqual(target.center.y, 275, accuracy: 1e-9)
    }

    /// Reflection, not wrapping: a target that teleports across the arena cannot be
    /// tracked, and tracking is the entire reason for making them move.
    func testATargetBouncesOffAWallRatherThanWrapping() {
        var target = Target(center: Vec2(x: 970, y: 300), radius: 20, spawnedAt: 0,
                            lifetime: 4, velocity: Vec2(x: 100, y: 0))
        target.advance(by: 0.5, in: arena)
        XCTAssertLessThan(target.velocity.x, 0, "it must turn around")
        XCTAssertLessThanOrEqual(target.center.x + target.radius, arena.width)
        XCTAssertGreaterThan(target.center.x, arena.width / 2, "and not jump to the far side")
    }

    func testATargetNeverLeavesTheArena() {
        var target = Target(center: Vec2(x: 500, y: 300), radius: 25, spawnedAt: 0,
                            lifetime: 60, velocity: Vec2(x: 400, y: -330))
        for _ in 0..<600 {
            target.advance(by: 1.0 / 60, in: arena)
            XCTAssertGreaterThanOrEqual(target.center.x - target.radius, -0.001)
            XCTAssertGreaterThanOrEqual(target.center.y - target.radius, -0.001)
            XCTAssertLessThanOrEqual(target.center.x + target.radius, arena.width + 0.001)
            XCTAssertLessThanOrEqual(target.center.y + target.radius, arena.height + 0.001)
        }
    }
}

final class ModeTests: XCTestCase {

    private func makeGame(_ mode: Mode) -> Game {
        let game = Game(arena: Arena(width: 1000, height: 600),
                        settings: mode.settings,
                        rng: SeededGenerator(seed: 0x5E7C1E00))
        game.setMode(mode)
        return game
    }

    private func startRound(_ game: Game, at now: TimeInterval = 100) -> UUID {
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        _ = game.pullTrigger(player: id, at: now)
        game.tick(at: now)
        game.tick(at: now + game.settings.countdownDuration)
        return id
    }

    func testEveryModeProducesAUsableConfiguration() {
        for mode in Mode.allCases {
            let settings = mode.settings
            XCTAssertGreaterThan(settings.targetRadius.lowerBound, 0, "\(mode) radius")
            XCTAssertGreaterThan(settings.targetLifetime.lowerBound, 0, "\(mode) lifetime")
            XCTAssertGreaterThan(settings.spawnInterval, 0, "\(mode) spawn")
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.summary.isEmpty)
        }
    }

    func testPrecisionTargetsAreSmallerAndCalmerThanArcade() {
        XCTAssertLessThan(Mode.precision.settings.targetRadius.upperBound,
                          Mode.arcade.settings.targetRadius.upperBound)
        XCTAssertLessThan(Mode.precision.settings.targetSpeed.upperBound,
                          Mode.arcade.settings.targetSpeed.upperBound)
        XCTAssertGreaterThan(Mode.precision.settings.targetLifetime.lowerBound,
                             Mode.arcade.settings.targetLifetime.lowerBound)
    }

    func testSurvivalIsFasterAndHasAMissLimit() {
        XCTAssertGreaterThan(Mode.survival.settings.targetSpeed.upperBound,
                             Mode.arcade.settings.targetSpeed.upperBound)
        XCTAssertEqual(Mode.survival.settings.missesAllowed, 3)
        XCTAssertEqual(Mode.arcade.settings.missesAllowed, 0, "arcade must not eliminate anyone")
    }

    func testModeCannotChangeMidRound() {
        let game = makeGame(.arcade)
        _ = startRound(game)
        XCTAssertFalse(game.setMode(.survival),
                       "changing the rules under a running match would invalidate its scores")
        XCTAssertEqual(game.mode, .arcade)
    }

    func testModeCanChangeInTheLobby() {
        let game = makeGame(.arcade)
        XCTAssertTrue(game.setMode(.precision))
        XCTAssertEqual(game.mode, .precision)
        XCTAssertEqual(game.settings.missesAllowed, Mode.precision.settings.missesAllowed)
    }

    func testSurvivalEliminatesAfterTheMissLimit() {
        let game = makeGame(.survival)
        let id = startRound(game)
        var time = 103.0

        // Three misses, spaced past the cooldown.
        for _ in 0..<3 {
            game.clearTargets()
            XCTAssertEqual(game.fire(player: id, at: time), .miss)
            time += 0.5
        }
        XCTAssertTrue(game.players[id]!.isEliminated)
        XCTAssertEqual(game.fire(player: id, at: time), .tooSoon,
                       "an eliminated player's trigger must do nothing")
    }

    func testSurvivalEndsTheRoundWhenEveryoneIsOut() {
        let game = makeGame(.survival)
        let id = startRound(game)
        var time = 103.0
        for _ in 0..<3 {
            game.clearTargets()
            _ = game.fire(player: id, at: time)
            time += 0.5
        }
        game.tick(at: time)
        guard case .results = game.phase else {
            return XCTFail("a survival round with nobody left should end, not run its clock out")
        }
    }

    func testArcadeNeverEliminates() {
        let game = makeGame(.arcade)
        let id = startRound(game)
        var time = 103.0
        for _ in 0..<20 {
            game.clearTargets()
            _ = game.fire(player: id, at: time)
            time += 0.5
        }
        XCTAssertFalse(game.players[id]!.isEliminated)
    }

    func testSpawnedTargetsMoveInModesThatAskForIt() {
        let game = makeGame(.survival)
        startRound(game)
        var time = 103.0
        for _ in 0..<40 { time += 0.05; game.tick(at: time) }
        XCTAssertFalse(game.targets.isEmpty)
        XCTAssertTrue(game.targets.contains { $0.velocity.length > 0 })
    }

    /// A gap means the window was occluded or the machine slept. Moving targets by that
    /// much would teleport them across the arena.
    ///
    /// Compared by identity, not by position in the array: across a long enough stall every
    /// target expires and is replaced, so an index-wise comparison measures two different
    /// targets and always fails.
    func testAStallDoesNotTeleportTargets() {
        let game = makeGame(.survival)
        startRound(game)
        var time = 103.0
        for _ in 0..<20 { time += 0.05; game.tick(at: time) }

        let before = Dictionary(uniqueKeysWithValues: game.targets.map { ($0.id, $0.center) })
        XCTAssertFalse(before.isEmpty)

        // Half a second is well past the 0.25 s movement guard but short enough that the
        // targets are still alive to be compared.
        game.tick(at: time + 0.5)

        var survivors = 0
        for target in game.targets {
            guard let previous = before[target.id] else { continue }
            survivors += 1
            XCTAssertEqual(target.center.distance(to: previous), 0, accuracy: 1e-9,
                           "a target must not move across a stall")
        }
        XCTAssertGreaterThan(survivors, 0, "the test needs surviving targets to be meaningful")
    }
}
