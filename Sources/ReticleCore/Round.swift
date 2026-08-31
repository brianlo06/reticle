import Foundation

/// Where a match is in its lifecycle.
///
/// Phases carry their own deadline rather than the game holding a separate timer, so
/// `tick(at:)` can advance everything from the current time alone and a whole match replays
/// deterministically in a test.
public enum Phase: Equatable, Sendable {
    /// Waiting for players to say they are ready.
    case lobby
    /// Everyone is ready; the round begins at `startsAt`.
    case countdown(startsAt: TimeInterval)
    case playing(endsAt: TimeInterval)
    /// Final scores are on screen until `until`, then back to the lobby.
    case results(until: TimeInterval)

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var acceptsShots: Bool { isPlaying }
}

/// What a trigger pull did, given the phase. The phone's button always means "the player
/// pressed the trigger"; what that *means* depends on where the match is, which is exactly
/// the kind of decision that belongs in the rules rather than in the controller.
public enum TriggerResult: Equatable, Sendable {
    case shot(ShotOutcome)
    /// Toggled readiness in the lobby, or asked for another round from the results screen.
    case readied(Bool)
    /// Pressed during the countdown, which does nothing on purpose.
    case ignored
    case noSuchPlayer
}

public extension Game.Settings {
    /// Defaults for a living-room round: long enough to get into it, short enough that
    /// nobody is waiting to take a turn.
    static var arcade: Game.Settings {
        var settings = Game.Settings()
        settings.roundDuration = 45
        settings.countdownDuration = 3
        settings.resultsDuration = 12
        return settings
    }
}
