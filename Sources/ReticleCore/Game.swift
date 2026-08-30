import Foundation

public struct PlayerState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var reticle: Vec2
    public var score: Int = 0
    public var shots: Int = 0
    public var hits: Int = 0
    /// Consecutive hits. Resets on any miss.
    public var streak: Int = 0
    public var bestStreak: Int = 0

    public var accuracy: Double { shots == 0 ? 0 : Double(hits) / Double(shots) }

    public init(id: UUID, name: String, reticle: Vec2) {
        self.id = id
        self.name = name
        self.reticle = reticle
    }
}

public enum ShotOutcome: Equatable, Sendable {
    case hit(targetID: UUID, points: Int, multiplier: Int)
    case miss
    /// Fired faster than the weapon allows. Not a miss — it should not break a streak.
    case tooSoon
    case noSuchPlayer
}

/// Everything the game does, with no rendering, no network and no clock of its own.
///
/// Time is passed in rather than read, and randomness is injected, so a whole round can be
/// replayed deterministically in a test. That matters more here than in most games: the
/// interesting behaviour is scoring and spawn pacing, and neither should require a window
/// or a phone to verify.
public final class Game {

    public private(set) var arena: Arena
    public private(set) var players: [UUID: PlayerState] = [:]
    public private(set) var targets: [Target] = []

    public var settings: Settings

    public struct Settings: Sendable {
        /// Pixels per second at which a target shrinks. Smaller targets score more.
        public var targetRadius: ClosedRange<Double> = 26...58
        public var targetLifetime: ClosedRange<Double> = 2.2...4.0
        public var maxTargets = 6
        public var spawnInterval: Double = 0.75
        /// Minimum gap between shots, so holding the trigger is not free.
        public var shotCooldown: Double = 0.16
        /// Reticle travel per pixel of phone delta. The phone already applies its own
        /// sensitivity, so this is a game-feel trim on top of it.
        public var aimGain: Double = 1.0
        /// Streak multiplier is capped so a long run does not run away with the score.
        public var maxMultiplier = 5
        public var edgeInset: Double = 8

        public init() {}
    }

    private var rng: RandomNumberGenerator
    private var lastSpawnAt: TimeInterval = -.infinity
    private var lastShotAt: [UUID: TimeInterval] = [:]

    public init(arena: Arena, settings: Settings = Settings(),
                rng: RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.arena = arena
        self.settings = settings
        self.rng = rng
    }

    public func resize(to arena: Arena) {
        self.arena = arena
        // Read the reticle out before writing it back: a subscript read nested inside a
        // subscript write is an overlapping access to the same dictionary.
        for (id, player) in players {
            var updated = player
            updated.reticle = arena.clamp(player.reticle, inset: settings.edgeInset)
            players[id] = updated
        }
        targets = targets.filter { $0.center.x <= arena.width && $0.center.y <= arena.height }
    }

    // MARK: - Players

    @discardableResult
    public func addPlayer(id: UUID, name: String) -> PlayerState {
        let player = PlayerState(id: id, name: name, reticle: arena.center)
        players[id] = player
        return player
    }

    public func removePlayer(id: UUID) {
        players.removeValue(forKey: id)
        lastShotAt.removeValue(forKey: id)
    }

    /// Moves a reticle by a delta from the phone.
    ///
    /// `dy` is negated because the phone reports screen-space deltas (y grows downward,
    /// matching a cursor) while the arena is bottom-left origin like SpriteKit. Getting
    /// this wrong inverts aiming, which is exactly the sort of thing that is obvious on
    /// hardware and invisible in code review.
    public func aim(player id: UUID, dx: Double, dy: Double) {
        guard var player = players[id], dx.isFinite, dy.isFinite else { return }
        let moved = Vec2(x: player.reticle.x + dx * settings.aimGain,
                         y: player.reticle.y - dy * settings.aimGain)
        player.reticle = arena.clamp(moved, inset: settings.edgeInset)
        players[id] = player
    }

    public func recenter(player id: UUID) {
        players[id]?.reticle = arena.center
    }

    /// Places a target directly, bypassing the spawner.
    ///
    /// A real capability rather than a test hatch: scripted waves and a practice mode both
    /// need to arrange the field deliberately. Keeping `targets` read-only from outside and
    /// offering this instead means nothing can corrupt the field's invariants by assigning
    /// to it wholesale.
    public func place(_ target: Target) {
        targets.append(target)
    }

    /// Removes everything on the field, e.g. between rounds.
    public func clearTargets() {
        targets.removeAll()
    }

    // MARK: - Shooting

    public func fire(player id: UUID, at now: TimeInterval) -> ShotOutcome {
        guard var player = players[id] else { return .noSuchPlayer }
        if let last = lastShotAt[id], now - last < settings.shotCooldown { return .tooSoon }
        lastShotAt[id] = now

        player.shots += 1

        // Nearest hit wins when targets overlap, so aiming at the middle of a cluster does
        // not award an arbitrary one.
        let hitIndex = targets.enumerated()
            .filter { $0.element.contains(player.reticle) }
            .min { $0.element.center.distance(to: player.reticle) < $1.element.center.distance(to: player.reticle) }?
            .offset

        guard let hitIndex else {
            player.streak = 0
            players[id] = player
            return .miss
        }

        let target = targets.remove(at: hitIndex)
        player.hits += 1
        player.streak += 1
        player.bestStreak = max(player.bestStreak, player.streak)

        let multiplier = min(1 + (player.streak - 1) / 3, settings.maxMultiplier)
        let points = Self.points(for: target, at: now, settings: settings) * multiplier
        player.score += points
        players[id] = player
        return .hit(targetID: target.id, points: points, multiplier: multiplier)
    }

    /// Small targets and quick reactions are worth more.
    static func points(for target: Target, at now: TimeInterval, settings: Settings) -> Int {
        let span = settings.targetRadius.upperBound - settings.targetRadius.lowerBound
        let sizeFactor = span > 0
            ? 1 - (target.radius - settings.targetRadius.lowerBound) / span   // 1 = smallest
            : 0.5
        let speedFactor = target.remainingFraction(at: now)                    // 1 = instant
        return Int((30 + 70 * sizeFactor + 50 * speedFactor).rounded())
    }

    // MARK: - Simulation

    /// Advances the world. Returns the targets that expired, for effects.
    @discardableResult
    public func tick(at now: TimeInterval) -> [Target] {
        let expired = targets.filter { $0.hasExpired(at: now) }
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.id))
            targets.removeAll { expiredIDs.contains($0.id) }
        }

        // No spawning without players, so an idle game does not fill the screen while
        // everyone is still scanning the QR code.
        guard !players.isEmpty else { return expired }
        if now - lastSpawnAt >= settings.spawnInterval && targets.count < settings.maxTargets {
            lastSpawnAt = now
            targets.append(makeTarget(at: now))
        }
        return expired
    }

    private func makeTarget(at now: TimeInterval) -> Target {
        let radius = Double.random(in: settings.targetRadius, using: &rng)
        let margin = radius + settings.edgeInset
        let x = Double.random(in: margin...(max(arena.width - margin, margin + 1)), using: &rng)
        let y = Double.random(in: margin...(max(arena.height - margin, margin + 1)), using: &rng)
        return Target(center: Vec2(x: x, y: y),
                      radius: radius,
                      spawnedAt: now,
                      lifetime: Double.random(in: settings.targetLifetime, using: &rng))
    }

    /// Highest score first; ties broken by accuracy so a careful player beats a spammer.
    public var leaderboard: [PlayerState] {
        players.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.accuracy > $1.accuracy
        }
    }
}
