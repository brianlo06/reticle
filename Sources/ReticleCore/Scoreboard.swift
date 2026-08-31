import Foundation

/// What the screen says, as opposed to how it is drawn.
///
/// Choosing between "waiting for 2" and "Starting…", numbering a results table, deciding
/// that ten seconds left is when the clock turns urgent — these are decisions, and they
/// were living inside a SpriteKit switch where nothing could reach them. The rendering
/// still belongs to the scene; the wording belongs here, with the rules and the tests.
public enum Scoreboard {

    /// How loudly the headline should be set. The scene owns the point sizes — this only
    /// says what kind of thing is being said.
    public enum Emphasis: Equatable, Sendable {
        /// An instruction to the room, read from a sofa.
        case prompt
        /// A single digit that has to be legible from across it.
        case countdown
        /// The verdict at the end of a round.
        case verdict
        /// Nothing is being said, so there is nothing to size.
        case silent
    }

    public struct Screen: Equatable, Sendable {
        public var headline: String
        public var emphasis: Emphasis
        public var body: String
        public var clock: String
        /// The last of the round, when the clock should stop being furniture.
        public var isUrgent: Bool
        /// The join panel is only useful before a round. During one it would cover the
        /// arena, and its code is stale the moment somebody has used it anyway.
        public var showsJoinPanel: Bool
    }

    /// Seconds at which the clock starts insisting. A timer you have to read is a timer you
    /// will not read while aiming, so it changes colour rather than asking for attention.
    public static let urgentSeconds = 10

    public static func screen(for game: Game, at now: TimeInterval) -> Screen {
        let remaining = game.remaining(at: now)
        let left = Int(ceil(remaining ?? 0))

        switch game.phase {
        case .lobby:
            let waiting = game.players.values.filter { !$0.isReady }.count
            let headline: String
            if game.players.isEmpty {
                headline = "Scan with your phone's camera to join"
            } else if waiting == 0 {
                headline = "Starting…"
            } else {
                headline = "Press FIRE when ready  ·  waiting for \(waiting)"
            }
            return Screen(headline: headline, emphasis: .prompt,
                          body: "\(game.mode.title.uppercased())  ·  \(game.mode.summary)"
                              + "\n\nRight-click on your phone to change mode",
                          clock: "", isUrgent: false, showsJoinPanel: true)

        case .countdown:
            return Screen(headline: "\(left)", emphasis: .countdown, body: "",
                          clock: "", isUrgent: false, showsJoinPanel: false)

        case .playing:
            return Screen(headline: "", emphasis: .silent, body: "",
                          clock: String(format: "%d:%02d", left / 60, left % 60),
                          isUrgent: left <= urgentSeconds, showsJoinPanel: false)

        case .results:
            // There is always at least one row. A round cannot end with nobody in it: the
            // last player to leave one drops the game back to the lobby rather than
            // finishing the round, which `RoundTests.testTheLastPlayerLeavingReturnsToTheLobby`
            // is what holds. This used to carry a "No shots fired" fallback for a state the
            // rules do not allow — a quiet round still lists everybody, at zero.
            let lines = game.lastResults.enumerated().map { index, player in
                String(format: "%d.  %@   %d   %.0f%%  ·  best streak %d",
                       index + 1, player.name, player.score,
                       player.accuracy * 100, player.bestStreak)
            }
            return Screen(headline: "\(game.mode.title) over", emphasis: .verdict,
                          body: lines.joined(separator: "\n")
                              + "\n\nPress FIRE for another round",
                          clock: "\(left)", isUrgent: false, showsJoinPanel: true)
        }
    }

    /// One player's line in the corner list: name, score, and only the state worth the
    /// width. A multiplier below two is not news, and neither is not being out.
    public static func row(for player: PlayerState, settings: Game.Settings) -> String {
        var row = "\(player.name)   \(player.score)"
        if player.isEliminated { row += "   OUT" }
        if player.streak >= 3 {
            row += "   x\(multiplier(forStreak: player.streak, settings: settings))"
        }
        return row
    }

    /// The streak multiplier, capped. Shared with the scoring so the number on screen is
    /// the number being applied rather than a second opinion about it.
    public static func multiplier(forStreak streak: Int, settings: Game.Settings) -> Int {
        min(1 + (max(streak, 1) - 1) / 3, settings.maxMultiplier)
    }
}
