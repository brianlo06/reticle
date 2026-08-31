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
        case .arcade: return "45s · mixed targets · drifting · gold is worth triple"
        case .precision: return "45s · small and slow · leave the blue diamonds alone"
        case .survival: return "fast · three mistakes and you are out"
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
            settings.bonusChance = 0.12
        case .precision:
            // Small and long-lived: the challenge is holding still, not reacting.
            settings.targetRadius = 14...26
            settings.targetLifetime = 3.5...5.5
            settings.spawnInterval = 1.1
            settings.targetSpeed = 0...25
            settings.shotCooldown = 0.28
            // Slower aim as well as slower targets. A mode about holding still is one
            // where a twitch should not cross the arena.
            settings.aimGain = 1.15
            // The mode about choosing your shot is the one where the wrong shot costs.
            settings.bonusChance = 0.15
            settings.penaltyChance = 0.2
        case .survival:
            settings.targetRadius = 18...40
            settings.targetLifetime = 1.4...2.4
            settings.spawnInterval = 0.5
            settings.targetSpeed = 60...190
            settings.missesAllowed = 3
            // Fast targets need a gun that can catch them.
            settings.aimGain = 1.9
            // A penalty counts toward the three that end your round, so under this much
            // time pressure a fifth of the field being off-limits is plenty.
            settings.bonusChance = 0.1
            settings.penaltyChance = 0.18
            // No fixed length: it ends when everyone is out.
            settings.roundDuration = 300
        }
        return settings
    }
}
