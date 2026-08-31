import XCTest
@testable import ReticleCore

/// What the television says. These used to live inside a SpriteKit switch where nothing
/// could reach them.
final class ScoreboardTests: XCTestCase {

    private func makeGame(_ mode: Mode = .arcade) -> Game {
        let game = Game(arena: Arena(width: 1000, height: 800), settings: mode.settings)
        game.setMode(mode)
        return game
    }

    private func started(_ game: Game) -> UUID {
        let id = UUID()
        game.addPlayer(id: id, name: "Ada")
        _ = game.pullTrigger(player: id, at: 0)
        game.tick(at: 0)
        game.tick(at: game.settings.countdownDuration)
        XCTAssertTrue(game.phase.isPlaying)
        return id
    }

    // MARK: - The lobby

    func testAnEmptyLobbyTellsYouHowToJoin() {
        let screen = Scoreboard.screen(for: makeGame(), at: 0)
        XCTAssertEqual(screen.headline, "Scan with your phone's camera to join")
        XCTAssertTrue(screen.showsJoinPanel)
    }

    func testTheLobbyCountsWhoIsNotReadyYet() {
        let game = makeGame()
        for name in ["A", "B", "C"] { game.addPlayer(id: UUID(), name: name) }
        _ = game.pullTrigger(player: game.leaderboard[0].id, at: 0)
        XCTAssertEqual(Scoreboard.screen(for: game, at: 0).headline,
                       "Press FIRE when ready  ·  waiting for 2")
    }

    func testTheLobbySaysTheModeItWouldPlay() {
        let game = makeGame(.survival)
        game.addPlayer(id: UUID(), name: "A")
        let body = Scoreboard.screen(for: game, at: 0).body
        XCTAssertTrue(body.contains("SURVIVAL"), body)
        XCTAssertTrue(body.contains(Mode.survival.summary), body)
    }

    // MARK: - The clock

    /// The join panel is only useful before a round. During one it would cover the arena,
    /// and its code is stale the moment somebody has used it anyway.
    func testTheJoinPanelIsHiddenOnceThingsAreUnderWay() {
        let game = makeGame()
        let id = started(game)
        XCTAssertFalse(Scoreboard.screen(for: game, at: 1).showsJoinPanel)
        _ = id
    }

    func testTheClockReadsAsMinutesAndSeconds() {
        let game = makeGame()
        _ = started(game)
        let start = game.settings.countdownDuration
        XCTAssertEqual(Scoreboard.screen(for: game, at: start).clock, "0:45")
        XCTAssertEqual(Scoreboard.screen(for: game, at: start + 20).clock, "0:25")
    }

    func testTheClockOnlyInsistsInTheLastSeconds() {
        let game = makeGame()
        _ = started(game)
        let end = game.settings.countdownDuration + game.settings.roundDuration
        XCTAssertFalse(Scoreboard.screen(for: game, at: end - 11).isUrgent)
        XCTAssertTrue(Scoreboard.screen(for: game, at: end - 9).isUrgent)
    }

    func testTheCountdownIsASingleDigit() {
        let game = makeGame()
        game.addPlayer(id: UUID(), name: "A")
        _ = game.pullTrigger(player: game.leaderboard[0].id, at: 0)
        game.tick(at: 0)
        let screen = Scoreboard.screen(for: game, at: 1)
        XCTAssertEqual(screen.headline, "2")
        XCTAssertEqual(screen.emphasis, .countdown, "it has to be legible across a room")
    }

    // MARK: - Results

    /// A player who never pulled the trigger is still on the table, at zero. Leaving them
    /// off would make a quiet round look like a broken one.
    func testAPlayerWhoFiredNothingIsStillListed() {
        let game = makeGame()
        _ = started(game)
        game.tick(at: game.settings.countdownDuration + game.settings.roundDuration + 1)
        let screen = Scoreboard.screen(for: game, at: 0)
        XCTAssertTrue(screen.body.contains("1.  Ada   0   0%"), screen.body)
        XCTAssertTrue(screen.body.contains("Press FIRE for another round"))
        XCTAssertEqual(screen.emphasis, .verdict)
        XCTAssertEqual(screen.headline, "Arcade over")
    }

    func testResultsAreNumberedInLeaderboardOrder() {
        let game = makeGame()
        let ada = UUID(), bo = UUID()
        game.addPlayer(id: ada, name: "Ada")
        game.addPlayer(id: bo, name: "Bo")
        _ = game.pullTrigger(player: ada, at: 0)
        _ = game.pullTrigger(player: bo, at: 0)
        game.tick(at: 0)
        game.tick(at: 3)

        game.recenter(player: bo)
        game.place(Target(center: game.players[bo]!.reticle, radius: 40, spawnedAt: 3, lifetime: 5))
        _ = game.pullTrigger(player: bo, at: 3.5)
        game.tick(at: 3 + game.settings.roundDuration + 1)

        let lines = Scoreboard.screen(for: game, at: 0).body.split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("1.  Bo"), String(lines[0]))
        XCTAssertTrue(lines[1].hasPrefix("2.  Ada"), String(lines[1]))
    }

    // MARK: - The corner list

    func testAScoreRowIsJustANameAndANumberUntilThereIsMoreToSay() {
        var player = PlayerState(id: UUID(), seat: 0, name: "Ada", reticle: .zero)
        player.score = 40
        XCTAssertEqual(Scoreboard.row(for: player, settings: .init()), "Ada   40")
    }

    func testAScoreRowShowsAMultiplierOnlyOnceItIsWorthTheWidth() {
        var player = PlayerState(id: UUID(), seat: 0, name: "Ada", reticle: .zero)
        player.streak = 2
        XCTAssertFalse(Scoreboard.row(for: player, settings: .init()).contains("x"))
        player.streak = 4
        XCTAssertTrue(Scoreboard.row(for: player, settings: .init()).contains("x2"))
    }

    func testAKnockedOutPlayerIsMarkedAsSuch() {
        var player = PlayerState(id: UUID(), seat: 0, name: "Ada", reticle: .zero)
        player.isEliminated = true
        XCTAssertTrue(Scoreboard.row(for: player, settings: .init()).contains("OUT"))
    }

    /// The number on screen has to be the number being applied, not a second opinion.
    func testTheDisplayedMultiplierIsTheOneTheScoringUses() {
        var settings = Game.Settings()
        settings.maxMultiplier = 5
        XCTAssertEqual(Scoreboard.multiplier(forStreak: 1, settings: settings), 1)
        XCTAssertEqual(Scoreboard.multiplier(forStreak: 4, settings: settings), 2)
        XCTAssertEqual(Scoreboard.multiplier(forStreak: 99, settings: settings), 5)

        let game = makeGame()
        let id = started(game)
        for shot in 1...4 {
            let now = Double(game.settings.countdownDuration) + Double(shot)
            game.recenter(player: id)
            game.place(Target(center: game.players[id]!.reticle, radius: 40,
                              spawnedAt: now, lifetime: 5))
            let outcome = game.fire(player: id, at: now)
            guard case .hit(_, _, let applied) = outcome else { return XCTFail("expected a hit") }
            XCTAssertEqual(applied,
                           Scoreboard.multiplier(forStreak: game.players[id]!.streak,
                                                 settings: game.settings))
        }
    }
}
