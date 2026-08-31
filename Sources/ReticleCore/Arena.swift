import Foundation

/// A point in arena space: origin bottom-left, matching SpriteKit rather than screen space.
public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Vec2(x: 0, y: 0)

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Vec2) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

/// The playfield. Deliberately not a `CGSize`: the rules should not depend on CoreGraphics,
/// so they can be tested without a window server.
public struct Arena: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    public var center: Vec2 { Vec2(x: width / 2, y: height / 2) }

    /// Keeps a point inside the playfield.
    ///
    /// Clamping rather than wrapping is what makes relative aiming workable in a shooter:
    /// the phone reports deltas, not an absolute heading, so without a hard boundary the
    /// reticle would drift off-screen and be unrecoverable without a recentre.
    public func clamp(_ point: Vec2, inset: Double = 0) -> Vec2 {
        let limit = min(inset, min(width, height) / 2)
        return Vec2(x: min(max(point.x, limit), width - limit),
                    y: min(max(point.y, limit), height - limit))
    }
}

/// A shootable target.
public struct Target: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var center: Vec2
    public var radius: Double
    public let spawnedAt: TimeInterval
    public let lifetime: TimeInterval
    /// Points per second. Zero for a stationary target.
    public var velocity: Vec2

    public init(id: UUID = UUID(), center: Vec2, radius: Double,
                spawnedAt: TimeInterval, lifetime: TimeInterval,
                velocity: Vec2 = .zero) {
        self.id = id
        self.center = center
        self.radius = radius
        self.spawnedAt = spawnedAt
        self.lifetime = lifetime
        self.velocity = velocity
    }

    /// Advances the target, bouncing off the walls.
    ///
    /// Reflection rather than wrapping: a target that teleports from one edge to the other
    /// cannot be tracked, and tracking is the whole point of making them move.
    public mutating func advance(by dt: Double, in arena: Arena) {
        guard dt > 0, velocity != .zero else { return }
        var next = Vec2(x: center.x + velocity.x * dt, y: center.y + velocity.y * dt)

        if next.x - radius < 0 || next.x + radius > arena.width {
            velocity.x = -velocity.x
            next.x = min(max(next.x, radius), arena.width - radius)
        }
        if next.y - radius < 0 || next.y + radius > arena.height {
            velocity.y = -velocity.y
            next.y = min(max(next.y, radius), arena.height - radius)
        }
        center = next
    }

    public func contains(_ point: Vec2) -> Bool {
        center.distance(to: point) <= radius
    }

    /// 1 at spawn, falling to 0 at expiry.
    public func remainingFraction(at now: TimeInterval) -> Double {
        guard lifetime > 0 else { return 0 }
        return min(max(1 - (now - spawnedAt) / lifetime, 0), 1)
    }

    public func hasExpired(at now: TimeInterval) -> Bool {
        now - spawnedAt >= lifetime
    }
}
