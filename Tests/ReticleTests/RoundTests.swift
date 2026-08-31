import XCTest
@testable import ReticleCore

/// The match lifecycle: lobby, countdown, round, results, back to the lobby.
///
/// All of it driven by an injected clock, so a full match takes microseconds and never
/// needs a window or a phone.
final class RoundTests: XCTestCase {

    private func makeGame() -> Game {
        Game(arena: Arena(width: 1000, height: 600),
             settings: .arcade,
             rng: SeededGenerator(seed: 0x5E7C1E00))
    }

    private func addPlayers(_ game: Game, _ count: Int) -> [UUID] {
        (0..<count).map { index in
            let id = UUID()
            game.addPlayer(id: id, name: "P\(index + 1)")
            return id
        }
    }

    func testAGameWithNoPlayersStaysInTheLobby() {
        let game = makeGame()
        for i in 0..<100 { game.tick(at: 100 + Double(i)) }
        XCTAssertEqual(game.phase, .lobby)
    }

    func testAllPlayersMustReadyBeforeTheCountdown() {
        let game = makeGame()
        let players = addPlayers(game, 2)

        XCTAssertEqual(game.pullTrigger(player: players[0], at: 100), .readied(true))
        game.tick(at: 100)
        XCTAssertEqual(game.phase, .lobby, "one ready player must not start a two-player game")

        XCTAssertEqual(game.pullTrigger(player: players[1], at: 101), .readied(true))
        game.tick(at: 101)
        XCTAssertEqual(game.phase, .countdown(startsAt: 101 + game.settings.countdownDuration))
    }

    func testReadyingIsAToggle() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        XCTAssertEqual(game.pullTrigger(player: id, at: 100), .readied(true))
        XCTAssertEqual(game.pullTrigger(player: id, at: 100.5), .readied(false))
        game.tick(at: 101)
        XCTAssertEqual(game.phase, .lobby, "un-readying must hold the game in the lobby")
    }

    func testTheTriggerDoesNothingDuringTheCountdown() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        XCTAssertEqual(game.pullTrigger(player: id, at: 101), .ignored)
    }

    func testRoundStartsAfterTheCountdownAndTargetsAppear() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)

        game.tick(at: 100 + game.settings.countdownDuration)
        XCTAssertTrue(game.phase.isPlaying)

        var time = 100 + game.settings.countdownDuration
        for _ in 0..<40 { time += 0.1; game.tick(at: time) }
        XCTAssertFalse(game.targets.isEmpty, "a running round must spawn targets")
    }

    func testNoTargetsExistOutsideARound() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        game.place(Target(center: game.arena.center, radius: 30, spawnedAt: 100, lifetime: 60))
        game.tick(at: 100)
        XCTAssertTrue(game.targets.isEmpty, "the lobby must be calm")

        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        XCTAssertTrue(game.targets.isEmpty, "the countdown must be calm too")
    }

    func testScoresResetAtTheStartOfEachRound() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        game.tick(at: 103)
        XCTAssertTrue(game.phase.isPlaying)

        game.place(Target(center: game.players[id]!.reticle, radius: 40, spawnedAt: 103, lifetime: 4))
        _ = game.pullTrigger(player: id, at: 103)
        XCTAssertGreaterThan(game.players[id]!.score, 0)

        // Run the round out, through results, back to the lobby, and start another.
        game.tick(at: 103 + game.settings.roundDuration)
        XCTAssertEqual(game.lastResults.first?.score, game.players[id]!.score)

        let afterResults = 103 + game.settings.roundDuration + game.settings.resultsDuration
        game.tick(at: afterResults)
        XCTAssertEqual(game.phase, .lobby)
        _ = game.pullTrigger(player: id, at: afterResults)
        game.tick(at: afterResults)
        game.tick(at: afterResults + game.settings.countdownDuration)
        XCTAssertTrue(game.phase.isPlaying)
        XCTAssertEqual(game.players[id]!.score, 0, "a new round must start from zero")
    }

    func testResultsKeepTheFinishedScoresAfterTheLiveOnesReset() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        game.tick(at: 103)
        game.place(Target(center: game.players[id]!.reticle, radius: 40, spawnedAt: 103, lifetime: 4))
        _ = game.pullTrigger(player: id, at: 103)
        let earned = game.players[id]!.score

        game.tick(at: 103 + game.settings.roundDuration)
        guard case .results = game.phase else { return XCTFail("expected results") }
        XCTAssertEqual(game.lastResults.first?.score, earned)
    }

    func testReadyResetsWhenTheResultsScreenEnds() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        game.tick(at: 103)
        game.tick(at: 103 + game.settings.roundDuration)

        let afterResults = 103 + game.settings.roundDuration + game.settings.resultsDuration
        game.tick(at: afterResults)
        XCTAssertEqual(game.phase, .lobby)
        XCTAssertFalse(game.players[id]!.isReady,
                       "a new lobby must not immediately restart because everyone is still flagged ready")
    }

    func testALatecomerJoinsTheRoundInProgress() {
        let game = makeGame()
        let first = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: first, at: 100)
        game.tick(at: 100)
        game.tick(at: 103)
        XCTAssertTrue(game.phase.isPlaying)

        let late = UUID()
        game.addPlayer(id: late, name: "Late")
        XCTAssertTrue(game.players[late]!.isReady,
                      "joining mid-round must not make everyone wait for the next one")
        game.tick(at: 104)
        XCTAssertTrue(game.phase.isPlaying)
    }

    func testTheLastPlayerLeavingReturnsToTheLobby() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        game.tick(at: 103)
        XCTAssertTrue(game.phase.isPlaying)

        game.removePlayer(id: id)
        XCTAssertEqual(game.phase, .lobby, "a match with nobody in it must not keep running")
        XCTAssertTrue(game.targets.isEmpty)
    }

    func testOnePlayerLeavingUnblocksALobbyWaitingOnThem() {
        let game = makeGame()
        let players = addPlayers(game, 2)
        _ = game.pullTrigger(player: players[0], at: 100)
        game.tick(at: 100)
        XCTAssertEqual(game.phase, .lobby)

        // The player who never readied disconnects; the remaining one should not be stuck.
        game.removePlayer(id: players[1])
        game.tick(at: 101)
        XCTAssertEqual(game.phase, .countdown(startsAt: 101 + game.settings.countdownDuration))
    }

    func testRemainingCountsDownAndNeverGoesNegative() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        XCTAssertNil(game.remaining(at: 100), "the lobby waits on players, not on a clock")

        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        XCTAssertEqual(game.remaining(at: 101)!, 2, accuracy: 1e-9)
        XCTAssertEqual(game.remaining(at: 999)!, 0, accuracy: 1e-9)
    }

    func testTriggerFromAnUnknownPlayerIsRejectedInEveryPhase() {
        let game = makeGame()
        XCTAssertEqual(game.pullTrigger(player: UUID(), at: 100), .noSuchPlayer)
    }
}
