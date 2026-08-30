import XCTest
@testable import ReticleCore

/// Deterministic so a whole round replays identically.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

final class ArenaTests: XCTestCase {

    private let arena = Arena(width: 1000, height: 600)

    func testClampKeepsTheReticleOnScreen() {
        XCTAssertEqual(arena.clamp(Vec2(x: -50, y: 900), inset: 10), Vec2(x: 10, y: 590))
        XCTAssertEqual(arena.clamp(Vec2(x: 500, y: 300), inset: 10), Vec2(x: 500, y: 300))
    }

    func testClampSurvivesAnInsetLargerThanTheArena() {
        let tiny = Arena(width: 20, height: 20)
        let point = tiny.clamp(Vec2(x: 100, y: 100), inset: 500)
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
        XCTAssertLessThanOrEqual(point.x, tiny.width)
    }

    func testArenaCannotBeDegenerate() {
        let zero = Arena(width: 0, height: -5)
        XCTAssertGreaterThan(zero.width, 0)
        XCTAssertGreaterThan(zero.height, 0)
    }

    func testTargetLifetimeFraction() {
        let target = Target(center: .zero, radius: 10, spawnedAt: 100, lifetime: 4)
        XCTAssertEqual(target.remainingFraction(at: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(target.remainingFraction(at: 102), 0.5, accuracy: 1e-9)
        XCTAssertEqual(target.remainingFraction(at: 105), 0, accuracy: 1e-9)
        XCTAssertTrue(target.hasExpired(at: 104))
    }
}

final class GameTests: XCTestCase {

    private func makeGame(maxTargets: Int = 6) -> Game {
        var settings = Game.Settings()
        settings.maxTargets = maxTargets
        return Game(arena: Arena(width: 1000, height: 600),
                    settings: settings,
                    rng: SeededGenerator(seed: 0x5E7C1E00))
    }

    // MARK: Aiming

    func testAimMovesTheReticleAndInvertsY() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        let start = game.players[id]!.reticle

        // The phone reports screen-space deltas: +dy means downward.
        game.aim(player: id, dx: 40, dy: 25)
        let moved = game.players[id]!.reticle
        XCTAssertEqual(moved.x, start.x + 40, accuracy: 1e-9)
        XCTAssertEqual(moved.y, start.y - 25, accuracy: 1e-9,
                       "screen-down must become arena-down, or aiming is inverted")
    }

    func testAimIsClampedToTheArena() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        for _ in 0..<200 { game.aim(player: id, dx: 500, dy: -500) }
        let reticle = game.players[id]!.reticle
        XCTAssertLessThanOrEqual(reticle.x, game.arena.width)
        XCTAssertLessThanOrEqual(reticle.y, game.arena.height)
    }

    func testAimIgnoresNonFiniteDeltas() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        let before = game.players[id]!.reticle
        game.aim(player: id, dx: .nan, dy: 10)
        game.aim(player: id, dx: 10, dy: .infinity)
        XCTAssertEqual(game.players[id]!.reticle, before)
    }

    func testRecenterReturnsToTheMiddle() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        game.aim(player: id, dx: 300, dy: 200)
        game.recenter(player: id)
        XCTAssertEqual(game.players[id]!.reticle, game.arena.center)
    }

    // MARK: Shooting

    /// Places a target exactly under the player's reticle.
    private func plantTarget(_ game: Game, under id: UUID, at now: TimeInterval,
                             radius: Double = 40, lifetime: Double = 4) -> Target {
        let target = Target(center: game.players[id]!.reticle, radius: radius,
                            spawnedAt: now, lifetime: lifetime)
        game.place(target)
        return target
    }

    func testHittingATargetScoresAndRemovesIt() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        let target = plantTarget(game, under: id, at: 100)

        guard case .hit(let hitID, let points, _) = game.fire(player: id, at: 100) else {
            return XCTFail("expected a hit")
        }
        XCTAssertEqual(hitID, target.id)
        XCTAssertGreaterThan(points, 0)
        XCTAssertTrue(game.targets.isEmpty, "a hit target must leave the field")
        XCTAssertEqual(game.players[id]!.hits, 1)
        XCTAssertEqual(game.players[id]!.score, points)
    }

    func testMissingBreaksTheStreakButStillCountsAsAShot() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        _ = plantTarget(game, under: id, at: 100)
        _ = game.fire(player: id, at: 100)
        XCTAssertEqual(game.players[id]!.streak, 1)

        XCTAssertEqual(game.fire(player: id, at: 101), .miss)
        XCTAssertEqual(game.players[id]!.streak, 0)
        XCTAssertEqual(game.players[id]!.shots, 2)
        XCTAssertEqual(game.players[id]!.hits, 1)
        XCTAssertEqual(game.players[id]!.bestStreak, 1)
    }

    func testCooldownRejectsTriggerSpamWithoutPunishingIt() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        _ = plantTarget(game, under: id, at: 100)
        _ = game.fire(player: id, at: 100)
        XCTAssertEqual(game.players[id]!.streak, 1)

        XCTAssertEqual(game.fire(player: id, at: 100.01), .tooSoon)
        XCTAssertEqual(game.players[id]!.shots, 1, "a rejected shot must not count")
        XCTAssertEqual(game.players[id]!.streak, 1,
                       "a rejected shot must not break a streak — it never happened")
    }

    func testStreakMultiplierGrowsAndIsCapped() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")

        var lastMultiplier = 0
        var time = 100.0
        for _ in 0..<40 {
            _ = plantTarget(game, under: id, at: time)
            guard case .hit(_, _, let multiplier) = game.fire(player: id, at: time) else {
                return XCTFail("expected a hit")
            }
            XCTAssertGreaterThanOrEqual(multiplier, lastMultiplier)
            lastMultiplier = multiplier
            time += 0.5
        }
        XCTAssertEqual(lastMultiplier, game.settings.maxMultiplier)
    }

    func testNearestTargetWinsWhenTwoOverlap() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        let reticle = game.players[id]!.reticle

        let far = Target(center: Vec2(x: reticle.x + 30, y: reticle.y), radius: 50,
                         spawnedAt: 100, lifetime: 4)
        let near = Target(center: Vec2(x: reticle.x + 2, y: reticle.y), radius: 50,
                          spawnedAt: 100, lifetime: 4)
        game.place(far)
        game.place(near)

        guard case .hit(let hitID, _, _) = game.fire(player: id, at: 100) else {
            return XCTFail("expected a hit")
        }
        XCTAssertEqual(hitID, near.id, "overlapping targets must resolve to the nearest")
        XCTAssertEqual(game.targets.count, 1)
    }

    func testSmallerAndFresherTargetsScoreMore() {
        let settings = Game.Settings()
        let small = Target(center: .zero, radius: settings.targetRadius.lowerBound,
                           spawnedAt: 100, lifetime: 4)
        let large = Target(center: .zero, radius: settings.targetRadius.upperBound,
                           spawnedAt: 100, lifetime: 4)
        XCTAssertGreaterThan(Game.points(for: small, at: 100, settings: settings),
                             Game.points(for: large, at: 100, settings: settings))
        XCTAssertGreaterThan(Game.points(for: small, at: 100, settings: settings),
                             Game.points(for: small, at: 103.5, settings: settings))
    }

    func testFiringAsAnUnknownPlayerIsRejected() {
        XCTAssertEqual(makeGame().fire(player: UUID(), at: 1), .noSuchPlayer)
    }

    // MARK: Simulation

    func testNoSpawningUntilSomeoneIsPlaying() {
        let game = makeGame()
        for i in 0..<100 { game.tick(at: 100 + Double(i)) }
        XCTAssertTrue(game.targets.isEmpty, "an empty game must not fill the screen")
    }

    func testTargetsSpawnUpToTheCap() {
        let game = makeGame(maxTargets: 4)
        game.addPlayer(id: UUID(), name: "P1")
        var time = 100.0
        for _ in 0..<200 {
            game.tick(at: time)
            time += 0.1
        }
        XCTAssertEqual(game.targets.count, 4)
    }

    func testExpiredTargetsAreReturnedAndRemoved() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        game.place(Target(center: game.arena.center, radius: 20, spawnedAt: 100, lifetime: 1))
        let expired = game.tick(at: 102)
        XCTAssertEqual(expired.count, 1)
        XCTAssertFalse(game.targets.contains { $0.id == expired[0].id })
    }

    func testSpawnedTargetsStayFullyInsideTheArena() {
        let game = makeGame(maxTargets: 40)
        game.addPlayer(id: UUID(), name: "P1")
        var time = 100.0
        for _ in 0..<400 { game.tick(at: time); time += 0.1 }
        XCTAssertFalse(game.targets.isEmpty)
        for target in game.targets {
            XCTAssertGreaterThanOrEqual(target.center.x - target.radius, 0)
            XCTAssertGreaterThanOrEqual(target.center.y - target.radius, 0)
            XCTAssertLessThanOrEqual(target.center.x + target.radius, game.arena.width)
            XCTAssertLessThanOrEqual(target.center.y + target.radius, game.arena.height)
        }
    }

    /// With a cap far above what the spawn rate can sustain, the population settles at
    /// roughly lifetime / spawnInterval. Worth pinning: it is the number that actually
    /// determines how busy the screen feels, and it is easy to change accidentally by
    /// adjusting either constant alone.
    func testTargetPopulationSettlesAtTheSpawnRateEquilibrium() {
        let game = makeGame(maxTargets: 40)
        game.addPlayer(id: UUID(), name: "P1")
        var time = 100.0
        for _ in 0..<600 { game.tick(at: time); time += 0.1 }

        let settings = game.settings
        let meanLifetime = (settings.targetLifetime.lowerBound + settings.targetLifetime.upperBound) / 2
        let expected = meanLifetime / settings.spawnInterval
        XCTAssertEqual(Double(game.targets.count), expected, accuracy: 2,
                       "population should track lifetime / spawnInterval, not the cap")
    }

    func testResizeKeepsReticlesInBounds() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        game.aim(player: id, dx: 400, dy: 0)
        game.resize(to: Arena(width: 300, height: 200))
        let reticle = game.players[id]!.reticle
        XCTAssertLessThanOrEqual(reticle.x, 300)
        XCTAssertLessThanOrEqual(reticle.y, 200)
    }

    func testLeaderboardRanksByScoreThenAccuracy() {
        let game = makeGame()
        let sharp = UUID(), spray = UUID()
        game.addPlayer(id: sharp, name: "Sharp")
        game.addPlayer(id: spray, name: "Spray")

        var time = 100.0
        for _ in 0..<3 {
            _ = plantTarget(game, under: sharp, at: time)
            _ = game.fire(player: sharp, at: time)
            _ = plantTarget(game, under: spray, at: time)
            _ = game.fire(player: spray, at: time)
            time += 0.5
        }
        // Same hits, but one of them also sprayed and missed.
        for _ in 0..<5 {
            _ = game.fire(player: spray, at: time)
            time += 0.5
        }
        XCTAssertEqual(game.leaderboard.first?.id, sharp,
                       "equal scores must break toward the more accurate player")
    }

    func testRemovingAPlayerClearsTheirCooldown() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "P1")
        _ = game.fire(player: id, at: 100)
        game.removePlayer(id: id)
        game.addPlayer(id: id, name: "P1 again")
        XCTAssertNotEqual(game.fire(player: id, at: 100.01), .tooSoon,
                          "a reconnecting player must not inherit a stale cooldown")
    }
}
