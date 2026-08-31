import Foundation

/// How a round is played.
///
/// Each mode is a named set of `Game.Settings`, so a mode is data rather than a branch in
/// the rules. That keeps every mode covered by the same tests and makes adding one a matter
/// of choosing numbers, not writing logic.
public enum Mode: String, CaseIterable, Sendable {
    /// The default: mixed sizes, gentle drift.
    case arcade
    /// Small, slow, long-lived targets. Rewards a steady hand over a fast one.
    case precision
    /// Fast and small, and three misses end your round.
    case survival

    public var title: String {
        switch self {
        case .arcade: return "Arcade"
        case .precision: return "Precision"
        case .survival: return "Survival"
        }
    }

    public var summary: String {
        switch self {
        case .arcade: return "45s · mixed targets · drifting"
        case .precision: return "45s · small and slow · no time pressure"
        case .survival: return "fast · three misses and you are out"
        }
    }

    public var settings: Game.Settings {
        var settings = Game.Settings()
        switch self {
        case .arcade:
            settings.targetRadius = 26...58
            settings.targetLifetime = 2.2...4.0
            settings.spawnInterval = 0.75
            settings.targetSpeed = 0...70
        case .precision:
            // Small and long-lived: the challenge is holding still, not reacting.
            settings.targetRadius = 14...26
            settings.targetLifetime = 3.5...5.5
            settings.spawnInterval = 1.1
            settings.targetSpeed = 0...25
            settings.shotCooldown = 0.28
        case .survival:
            settings.targetRadius = 18...40
            settings.targetLifetime = 1.4...2.4
            settings.spawnInterval = 0.5
            settings.targetSpeed = 60...190
            settings.missesAllowed = 3
            // No fixed length: it ends when everyone is out.
            settings.roundDuration = 300
        }
        return settings
    }
}
