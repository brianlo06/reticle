import Foundation

public struct PlayerState: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Which seat this player holds, counted from zero and held for as long as they are
    /// connected. It decides their colour, so it must not move: the scene used to colour
    /// reticles by leaderboard position, which meant your crosshair changed colour the
    /// instant you overtook somebody — during a round, while you were following it.
    public let seat: Int
    public var name: String
    public var reticle: Vec2
    public var score: Int = 0
    public var shots: Int = 0
    public var hits: Int = 0
    /// Consecutive hits. Resets on any miss.
    public var streak: Int = 0
    public var bestStreak: Int = 0
    /// Said they are ready to start. Meaningless outside the lobby and results screens.
    public var isReady: Bool = false
    /// Knocked out in a mode with a miss limit. Their reticle stays on screen, greyed.
    public var isEliminated: Bool = false

    public var accuracy: Double { shots == 0 ? 0 : Double(hits) / Double(shots) }

    public init(id: UUID, seat: Int, name: String, reticle: Vec2) {
        self.id = id
        self.seat = seat
        self.name = name
        self.reticle = reticle
    }
}

public enum ShotOutcome: Equatable, Sendable {
    case hit(targetID: UUID, points: Int, multiplier: Int)
    /// Shot something that should have been left alone. Distinct from a miss because the
    /// player did hit what they aimed at — the mistake was the decision, not the aim, and
    /// the scoreboard and the feedback should say so differently.
    case penalty(targetID: UUID, points: Int)
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
    public private(set) var phase: Phase = .lobby
    public private(set) var mode: Mode = .arcade
    /// Scores from the round that just finished, kept for the results screen after the
    /// live scores are cleared for the next one.
    public private(set) var lastResults: [PlayerState] = []

    public var settings: Settings

    /// A multiplier on the mode's aim gain, belonging to the room rather than to the mode.
    ///
    /// It lives here rather than in `Settings` precisely because `setMode` replaces those
    /// wholesale: a value somebody spent a round settling must not be silently undone by
    /// cycling to Precision and back. Clamped, because it is adjustable live and a
    /// mistyped sensitivity that puts the reticle in the corner cannot be corrected from
    /// the corner.
    public var sensitivity: Double = 1.0 {
        didSet {
            guard !sensitivity.isFinite || sensitivity < 0.25 || sensitivity > 4 else { return }
            sensitivity = sensitivity.isFinite ? min(max(sensitivity, 0.25), 4) : oldValue
        }
    }

    /// What a pixel of phone movement is actually worth right now.
    public var effectiveAimGain: Double { settings.aimGain * sensitivity }

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
        ///
        /// Above one, because this was inherited from a cursor remote and a gun is not a
        /// cursor: a remote wants a pointer that settles where you left it, a shooting
        /// gallery wants the whole arena reachable from a wrist flick. `Game.sensitivity`
        /// multiplies it, so a room that disagrees can say so without a rebuild.
        public var aimGain: Double = 1.6
        /// Streak multiplier is capped so a long run does not run away with the score.
        public var maxMultiplier = 5
        public var edgeInset: Double = 8

        /// Points per second a target drifts at. `0...0` keeps them still.
        public var targetSpeed: ClosedRange<Double> = 0...0
        /// Misses before a player is out for the round. Zero means unlimited.
        public var missesAllowed: Int = 0

        /// How often a spawn is a bonus or a penalty rather than an ordinary target.
        /// Zero for both makes a mode a pure aiming exercise, which is what Arcade was.
        public var bonusChance: Double = 0
        public var penaltyChance: Double = 0
        /// What a bonus target multiplies its points by, on top of the streak multiplier.
        public var bonusMultiplier: Int = 3
        /// What shooting a penalty target costs. Subtracted, never taken below zero — a
        /// negative scoreboard in a party game reads as a bug rather than as a rebuke.
        public var penaltyCost: Int = 150

        public var roundDuration: Double = 45
        public var countdownDuration: Double = 3
        public var resultsDuration: Double = 12

        public init() {}
    }

    private var rng: RandomNumberGenerator
    private var lastSpawnAt: TimeInterval = -.infinity
    private var lastMovedAt: TimeInterval?
    private var lastShotAt: [UUID: TimeInterval] = [:]

    public init(arena: Arena, settings: Settings = Settings(),
                rng: RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.arena = arena
        self.settings = settings
        self.rng = rng
    }

    /// Switches mode. Refused mid-round, since changing the rules under a running match
    /// would invalidate the scores it is about to report.
    @discardableResult
    public func setMode(_ mode: Mode) -> Bool {
        guard !phase.isPlaying else { return false }
        self.mode = mode
        self.settings = mode.settings
        return true
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
        // Reuse the seat if this player is already in — a reconnect should not walk them
        // down the palette — otherwise take the lowest free one, so four players who have
        // cycled through eight sessions still hold seats 0 to 3.
        let seat = players[id]?.seat ?? lowestFreeSeat()
        var player = PlayerState(id: id, seat: seat, name: name, reticle: arena.center)
        // Someone arriving mid-round joins the round in progress rather than waiting it
        // out: a party game that makes a latecomer watch is a party game nobody finishes.
        player.isReady = phase.isPlaying
        players[id] = player
        return player
    }

    private func lowestFreeSeat() -> Int {
        let taken = Set(players.values.map(\.seat))
        var seat = 0
        while taken.contains(seat) { seat += 1 }
        return seat
    }

    public func removePlayer(id: UUID) {
        players.removeValue(forKey: id)
        lastShotAt.removeValue(forKey: id)
        // If the last player leaves mid-round, drop back to the lobby rather than running
        // a match nobody is in.
        if players.isEmpty, phase.isPlaying || phase == .lobby {
            targets.removeAll()
            phase = .lobby
        }
    }

    /// Moves a reticle by a delta from the phone.
    ///
    /// `dy` is negated because the phone reports screen-space deltas (y grows downward,
    /// matching a cursor) while the arena is bottom-left origin like SpriteKit. Getting
    /// this wrong inverts aiming, which is exactly the sort of thing that is obvious on
    /// hardware and invisible in code review.
    public func aim(player id: UUID, dx: Double, dy: Double) {
        guard var player = players[id], dx.isFinite, dy.isFinite else { return }
        let gain = effectiveAimGain
        let moved = Vec2(x: player.reticle.x + dx * gain,
                         y: player.reticle.y - dy * gain)
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

    /// A trigger pull, interpreted for the current phase.
    ///
    /// The controller sends the same event throughout; deciding what it means here keeps
    /// the phone dumb and means a stock AirPoint controller still works.
    public func pullTrigger(player id: UUID, at now: TimeInterval) -> TriggerResult {
        guard players[id] != nil else { return .noSuchPlayer }
        switch phase {
        case .playing:
            return .shot(fire(player: id, at: now))
        case .lobby, .results:
            let ready = !(players[id]?.isReady ?? false)
            players[id]?.isReady = ready
            return .readied(ready)
        case .countdown:
            return .ignored
        }
    }

    public func fire(player id: UUID, at now: TimeInterval) -> ShotOutcome {
        guard var player = players[id] else { return .noSuchPlayer }
        // An eliminated player's trigger does nothing until the next round.
        guard !player.isEliminated else { return .tooSoon }
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
            if settings.missesAllowed > 0,
               player.shots - player.hits >= settings.missesAllowed {
                player.isEliminated = true
            }
            players[id] = player
            return .miss
        }

        let target = targets.remove(at: hitIndex)

        if target.kind == .penalty {
            // Counted as a shot that found something, so it does not flatter accuracy, and
            // as a mistake, so it breaks the streak and counts toward elimination. It is
            // not recorded as a hit: hitting the thing you were supposed to avoid is not
            // marksmanship.
            player.streak = 0
            player.score = max(0, player.score - settings.penaltyCost)
            if settings.missesAllowed > 0,
               player.shots - player.hits >= settings.missesAllowed {
                player.isEliminated = true
            }
            players[id] = player
            return .penalty(targetID: target.id, points: -settings.penaltyCost)
        }

        player.hits += 1
        player.streak += 1
        player.bestStreak = max(player.bestStreak, player.streak)

        let multiplier = Scoreboard.multiplier(forStreak: player.streak, settings: settings)
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
        let base = Int((30 + 70 * sizeFactor + 50 * speedFactor).rounded())
        return target.kind == .bonus ? base * max(1, settings.bonusMultiplier) : base
    }

    // MARK: - Simulation

    /// Advances the world. Returns the targets that expired, for effects.
    @discardableResult
    public func tick(at now: TimeInterval) -> [Target] {
        advancePhase(at: now)
        guard phase.isPlaying else {
            // Nothing lives outside a round, so the lobby and the results screen are calm.
            if !targets.isEmpty { targets.removeAll() }
            return []
        }

        // Everyone out ends a survival round early; there is nothing left to watch.
        if settings.missesAllowed > 0, !players.isEmpty,
           players.values.allSatisfy(\.isEliminated) {
            endRound(at: now)
            return []
        }

        advanceTargets(to: now)
        let expired = targets.filter { $0.hasExpired(at: now) }
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.id))
            targets.removeAll { expiredIDs.contains($0.id) }
        }

        guard !players.isEmpty else { return expired }
        if now - lastSpawnAt >= settings.spawnInterval && targets.count < settings.maxTargets {
            lastSpawnAt = now
            targets.append(makeTarget(at: now))
        }
        return expired
    }

    private func advancePhase(at now: TimeInterval) {
        switch phase {
        case .lobby:
            // Everyone present has to agree. One player alone can start on their own.
            guard !players.isEmpty, players.values.allSatisfy(\.isReady) else { return }
            phase = .countdown(startsAt: now + settings.countdownDuration)

        case .countdown(let startsAt):
            guard now >= startsAt else { return }
            beginRound(at: now)

        case .playing(let endsAt):
            guard now >= endsAt else { return }
            endRound(at: now)

        case .results(let until):
            guard now >= until else { return }
            phase = .lobby
            for id in players.keys { players[id]?.isReady = false }
        }
    }

    private func beginRound(at now: TimeInterval) {
        targets.removeAll()
        lastSpawnAt = -.infinity
        lastShotAt.removeAll()
        for (id, player) in players {
            var fresh = PlayerState(id: id, seat: player.seat, name: player.name,
                                    reticle: arena.center)
            fresh.isReady = true
            players[id] = fresh
        }
        lastMovedAt = now
        phase = .playing(endsAt: now + settings.roundDuration)
    }

    private func endRound(at now: TimeInterval) {
        targets.removeAll()
        lastResults = leaderboard
        for id in players.keys { players[id]?.isReady = false }
        phase = .results(until: now + settings.resultsDuration)
    }

    /// Seconds left in whatever the current phase is counting down to, or nil in the lobby.
    public func remaining(at now: TimeInterval) -> Double? {
        switch phase {
        case .lobby: return nil
        case .countdown(let at): return max(at - now, 0)
        case .playing(let at): return max(at - now, 0)
        case .results(let at): return max(at - now, 0)
        }
    }

    private func advanceTargets(to now: TimeInterval) {
        defer { lastMovedAt = now }
        guard let last = lastMovedAt else { return }
        let dt = now - last
        // A long gap means the app was occluded or the machine slept; moving targets by
        // that much would teleport them across the arena.
        guard dt > 0, dt < 0.25 else { return }
        for index in targets.indices {
            targets[index].advance(by: dt, in: arena)
        }
    }

    private func makeTarget(at now: TimeInterval) -> Target {
        let radius = Double.random(in: settings.targetRadius, using: &rng)
        let margin = radius + settings.edgeInset
        let x = Double.random(in: margin...(max(arena.width - margin, margin + 1)), using: &rng)
        let y = Double.random(in: margin...(max(arena.height - margin, margin + 1)), using: &rng)
        var velocity = Vec2.zero
        if settings.targetSpeed.upperBound > 0 {
            let speed = Double.random(in: settings.targetSpeed, using: &rng)
            let heading = Double.random(in: 0...(2 * .pi), using: &rng)
            velocity = Vec2(x: cos(heading) * speed, y: sin(heading) * speed)
        }
        let kind = chooseKind()
        var lifetime = Double.random(in: settings.targetLifetime, using: &rng)
        // A bonus that sits there as long as anything else is not a reward for noticing,
        // it is just a bigger number. A penalty gets the full lifetime, because the player
        // has to be given time to decide *not* to shoot it.
        if kind == .bonus { lifetime *= 0.6 }
        return Target(center: Vec2(x: x, y: y),
                      radius: radius,
                      spawnedAt: now,
                      lifetime: lifetime,
                      velocity: velocity,
                      kind: kind)
    }

    /// Rolls once for the whole decision rather than twice, so the two chances cannot add
    /// up to more than every target and quietly starve out the ordinary ones.
    private func chooseKind() -> Target.Kind {
        let bonus = max(0, settings.bonusChance)
        let penalty = max(0, settings.penaltyChance)
        guard bonus + penalty > 0 else { return .standard }
        let roll = Double.random(in: 0..<1, using: &rng) * max(1, bonus + penalty)
        if roll < bonus { return .bonus }
        if roll < bonus + penalty { return .penalty }
        return .standard
    }

    /// Highest score first; ties broken by accuracy so a careful player beats a spammer,
    /// and then by seat.
    ///
    /// That last tiebreak is not cosmetic. Players sort out of a dictionary, so two of them
    /// level on both score and accuracy — which is everybody, in the lobby — had no defined
    /// order at all, and the scoreboard drew their names in whichever order the hashing
    /// happened to give. Seat is the one ordering that never moves.
    public var leaderboard: [PlayerState] {
        players.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.accuracy != $1.accuracy { return $0.accuracy > $1.accuracy }
            return $0.seat < $1.seat
        }
    }
}
