import XCTest
@testable import ReticleCore

/// Bonus and penalty targets: the difference between an aiming exercise and a game where
/// you have to decide whether to shoot.
final class TargetKindTests: XCTestCase {

    private func startedGame(_ settings: Game.Settings = .init()) -> (Game, UUID) {
        let game = Game(arena: Arena(width: 1000, height: 800), settings: settings)
        let id = UUID()
        game.addPlayer(id: id, name: "P")
        _ = game.pullTrigger(player: id, at: 0)
        game.tick(at: 0)
        game.tick(at: settings.countdownDuration)
        XCTAssertTrue(game.phase.isPlaying)
        game.clearTargets()
        return (game, id)
    }

    private func plant(_ game: Game, _ kind: Target.Kind, under id: UUID,
                       at now: TimeInterval, radius: Double = 40) {
        game.place(Target(center: game.players[id]!.reticle, radius: radius,
                          spawnedAt: now, lifetime: 5, kind: kind))
    }

    // MARK: - Scoring

    func testABonusTargetIsWorthAMultipleOfAnOrdinaryOne() {
        var settings = Game.Settings()
        settings.bonusMultiplier = 3
        let (plain, plainID) = startedGame(settings)
        let (gold, goldID) = startedGame(settings)
        plant(plain, .standard, under: plainID, at: 1)
        plant(gold, .bonus, under: goldID, at: 1)

        guard case .hit(_, let ordinary, _) = plain.fire(player: plainID, at: 1),
              case .hit(_, let bonus, _) = gold.fire(player: goldID, at: 1) else {
            return XCTFail("both should have been hits")
        }
        XCTAssertEqual(bonus, ordinary * 3)
    }

    func testShootingAPenaltyTargetCostsPointsAndIsNotAHit() {
        var settings = Game.Settings()
        settings.penaltyCost = 150
        let (game, id) = startedGame(settings)

        plant(game, .standard, under: id, at: 1)
        _ = game.fire(player: id, at: 1)
        let earned = game.players[id]!.score
        XCTAssertGreaterThan(earned, 0)

        plant(game, .penalty, under: id, at: 2)
        guard case .penalty(_, let points) = game.fire(player: id, at: 2) else {
            return XCTFail("expected a penalty, not a hit or a miss")
        }
        XCTAssertEqual(points, -150)
        XCTAssertEqual(game.players[id]!.score, max(0, earned - 150))
        XCTAssertEqual(game.players[id]!.hits, 1, "the wrong target is not a hit")
        XCTAssertEqual(game.players[id]!.shots, 2, "but it was still a shot")
    }

    /// A negative scoreboard in a party game reads as a bug rather than as a rebuke.
    func testAPenaltyCannotDriveAScoreBelowZero() {
        var settings = Game.Settings()
        settings.penaltyCost = 10_000
        let (game, id) = startedGame(settings)
        plant(game, .penalty, under: id, at: 1)
        _ = game.fire(player: id, at: 1)
        XCTAssertEqual(game.players[id]!.score, 0)
    }

    func testAPenaltyBreaksTheStreakItTookToBuild() {
        let (game, id) = startedGame()
        for time in [1.0, 2.0, 3.0] {
            plant(game, .standard, under: id, at: time)
            _ = game.fire(player: id, at: time)
        }
        XCTAssertEqual(game.players[id]!.streak, 3)

        plant(game, .penalty, under: id, at: 4)
        _ = game.fire(player: id, at: 4)
        XCTAssertEqual(game.players[id]!.streak, 0)
        XCTAssertEqual(game.players[id]!.bestStreak, 3, "what was earned is still recorded")
    }

    func testAPenaltyCountsTowardBeingKnockedOut() {
        var settings = Game.Settings()
        settings.missesAllowed = 2
        let (game, id) = startedGame(settings)
        for time in [1.0, 2.0] {
            plant(game, .penalty, under: id, at: time)
            _ = game.fire(player: id, at: time)
        }
        XCTAssertTrue(game.players[id]!.isEliminated,
                      "shooting the wrong thing twice is two mistakes")
    }

    /// The cooldown rule has to keep holding: a refused shot never happened, so it cannot
    /// cost anybody a hundred and fifty points.
    func testARefusedShotCannotTriggerAPenalty() {
        let (game, id) = startedGame()
        plant(game, .penalty, under: id, at: 1)
        _ = game.fire(player: id, at: 1)
        let score = game.players[id]!.score
        plant(game, .penalty, under: id, at: 1.01)
        XCTAssertEqual(game.fire(player: id, at: 1.01), .tooSoon)
        XCTAssertEqual(game.players[id]!.score, score)
    }

    // MARK: - Spawning

    func testAModeWithNoSpecialTargetsSpawnsNoneOfThem() {
        var settings = Game.Settings()
        settings.spawnInterval = 0.01
        settings.maxTargets = 200
        let (game, _) = startedGame(settings)
        for i in 1...300 { game.tick(at: 1 + Double(i) * 0.02) }
        XCTAssertFalse(game.targets.isEmpty)
        XCTAssertTrue(game.targets.allSatisfy { $0.kind == .standard })
    }

    func testBothKindsTurnUpWhenAModeAsksForThem() {
        var settings = Game.Settings()
        settings.spawnInterval = 0.01
        settings.maxTargets = 400
        settings.targetLifetime = 1000...1001
        settings.bonusChance = 0.3
        settings.penaltyChance = 0.3
        let (game, _) = startedGame(settings)
        for i in 1...400 { game.tick(at: 1 + Double(i) * 0.02) }

        let kinds = Set(game.targets.map(\.kind))
        XCTAssertEqual(kinds, Set(Target.Kind.allCases),
                       "over four hundred spawns all three should appear")
    }

    /// Rolled once rather than twice, so two generous chances cannot between them starve
    /// out the ordinary targets the game is mostly made of.
    func testChancesBeyondCertaintyDoNotOverflow() {
        var settings = Game.Settings()
        settings.spawnInterval = 0.01
        settings.maxTargets = 300
        settings.targetLifetime = 1000...1001
        settings.bonusChance = 5
        settings.penaltyChance = 5
        let (game, _) = startedGame(settings)
        for i in 1...300 { game.tick(at: 1 + Double(i) * 0.02) }
        XCTAssertFalse(game.targets.isEmpty)
        let bonuses = game.targets.filter { $0.kind == .bonus }.count
        XCTAssertGreaterThan(bonuses, 0)
        XCTAssertLessThan(bonuses, game.targets.count, "penalties should still appear")
    }

    func testABonusIsGoneSoonerThanAnOrdinaryTarget() {
        var settings = Game.Settings()
        settings.spawnInterval = 0.01
        settings.maxTargets = 300
        settings.targetLifetime = 4...4
        settings.bonusChance = 0.5
        let (game, _) = startedGame(settings)
        for i in 1...200 { game.tick(at: 1 + Double(i) * 0.02) }

        for target in game.targets where target.kind == .bonus {
            XCTAssertLessThan(target.lifetime, 4, "a reward for noticing has to be missable")
        }
    }

    // MARK: - Telling them apart

    /// Colour alone is not enough: about one player in twelve cannot rely on it, and a
    /// television across a room is unkind to everybody else.
    func testEachKindHasItsOwnShape() {
        let shapes = Target.Kind.allCases.map(\.sides)
        XCTAssertEqual(Set(shapes).count, Target.Kind.allCases.count)
    }

    func testEveryModeThatPenalisesAlsoRewards() {
        for mode in Mode.allCases where mode.settings.penaltyChance > 0 {
            XCTAssertGreaterThan(mode.settings.bonusChance, 0,
                                 "\(mode) only ever punishes noticing")
        }
    }
}
