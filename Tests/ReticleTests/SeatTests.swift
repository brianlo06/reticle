import XCTest
@testable import ReticleCore

/// Which colour a player is, and why it must not move.
final class SeatTests: XCTestCase {

    private func makeGame() -> Game { Game(arena: Arena(width: 1000, height: 800)) }

    func testSeatsAreHandedOutInOrder() {
        let game = makeGame()
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(game.addPlayer(id: id, name: "P\(index)").seat, index)
        }
    }

    /// The bug this exists to prevent: the scene coloured reticles by leaderboard
    /// position, so your crosshair changed colour the instant you overtook somebody —
    /// during a round, while you were following it across the screen.
    func testASeatDoesNotMoveWhenTheScoresDo() {
        let game = makeGame()
        let trailing = UUID(), leading = UUID()
        game.addPlayer(id: trailing, name: "A")
        game.addPlayer(id: leading, name: "B")
        let seats = game.players.mapValues(\.seat)

        _ = game.pullTrigger(player: leading, at: 0)   // ready up
        _ = game.pullTrigger(player: trailing, at: 0)
        game.tick(at: 0)                                // the countdown begins
        game.tick(at: 4)                                // and elapses
        XCTAssertTrue(game.phase.isPlaying)

        game.recenter(player: leading)
        game.place(Target(center: game.players[leading]!.reticle, radius: 40,
                          spawnedAt: 4, lifetime: 5))
        _ = game.pullTrigger(player: leading, at: 4.5)

        XCTAssertEqual(game.leaderboard.first?.id, leading, "the test needs the order to change")
        XCTAssertEqual(game.players.mapValues(\.seat), seats,
                       "a seat is not a ranking")
    }

    /// Four players who have cycled through a dozen sessions between them should still be
    /// holding seats zero to three, not drifting off the end of the palette.
    func testALeftSeatIsHandedToTheNextPlayer() {
        let game = makeGame()
        let first = UUID(), second = UUID(), third = UUID()
        game.addPlayer(id: first, name: "A")
        game.addPlayer(id: second, name: "B")
        game.removePlayer(id: first)
        XCTAssertEqual(game.addPlayer(id: third, name: "C").seat, 0)
        XCTAssertEqual(game.players[second]?.seat, 1, "B did not move")
    }

    func testAReconnectingPlayerKeepsTheirColour() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: UUID(), name: "A")
        let seat = game.addPlayer(id: id, name: "B").seat
        XCTAssertEqual(game.addPlayer(id: id, name: "B").seat, seat)
    }

    func testASeatSurvivesTheRoundItIsPlaying() {
        let game = makeGame()
        let id = UUID()
        let seat = game.addPlayer(id: id, name: "A").seat
        _ = game.pullTrigger(player: id, at: 0)
        game.tick(at: 0)
        game.tick(at: 5)
        XCTAssertTrue(game.phase.isPlaying)
        XCTAssertEqual(game.players[id]?.seat, seat, "a new round is not a new player")
    }

    // MARK: - Palette

    func testEverySeatGetsItsOwnColour() {
        let hues = (0..<SeatPalette.capacity).map { SeatPalette.color(seat: $0).hue }
        XCTAssertEqual(Set(hues).count, SeatPalette.capacity)
    }

    /// The claim the palette exists to make: these are telling-apart colours, across a
    /// living room, on a television.
    func testColoursStayApartAtEverySeatCount() {
        for count in 2...SeatPalette.capacity {
            // A full house of eight still leaves 30 degrees of hue between neighbours.
            XCTAssertGreaterThan(SeatPalette.minimumHueSeparation(seats: count), 0.08,
                                 "\(count) players would be looking at similar crosshairs")
        }
    }

    /// Spread by the golden angle rather than divided by the seat count, so a player who
    /// joins does not recolour everyone already playing.
    func testJoiningDoesNotRecolourAnybodyElse() {
        let before = (0..<3).map { SeatPalette.color(seat: $0).hue }
        let after = (0..<4).map { SeatPalette.color(seat: $0).hue }
        XCTAssertEqual(before, Array(after.prefix(3)))
    }

    func testAnAbsurdSeatStillGetsAColourRatherThanCrashing() {
        for seat in [-1, 0, 99, Int.max] {
            let colour = SeatPalette.color(seat: seat)
            XCTAssertTrue((0...1).contains(colour.hue))
            XCTAssertGreaterThan(colour.brightness, 0)
        }
    }
}
