import AppKit
import SpriteKit
import ReticleCore

/// Draws the field. Owns the nodes for the live targets and nothing else.
///
/// Nodes keep the z-positions they always had rather than inheriting one from this layer,
/// so grouping them changed where they live in the tree and not what is drawn over what.
final class TargetLayer: SKNode {

    private var nodes: [UUID: SKShapeNode] = [:]

    /// Colour and fill per kind. The *shape* is what actually distinguishes them — see
    /// `Target.Kind.sides` — because a player who cannot rely on colour still has to know
    /// which one not to shoot, and at television distance so does everyone else.
    private static func palette(for kind: Target.Kind) -> (stroke: NSColor, fill: NSColor) {
        switch kind {
        case .standard:
            return (.systemRed, NSColor(calibratedRed: 0.25, green: 0.06, blue: 0.06, alpha: 0.85))
        case .bonus:
            return (NSColor(calibratedRed: 1, green: 0.85, blue: 0.25, alpha: 1),
                    NSColor(calibratedRed: 0.28, green: 0.22, blue: 0.03, alpha: 0.85))
        case .penalty:
            return (NSColor(calibratedRed: 0.45, green: 0.72, blue: 1, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.13, blue: 0.26, alpha: 0.9))
        }
    }

    /// A circle for `sides == 0`, otherwise a regular polygon of that many sides.
    private static func outline(radius: Double, sides: Int) -> CGPath {
        guard sides >= 3 else {
            return CGPath(ellipseIn: CGRect(x: -radius, y: -radius,
                                            width: radius * 2, height: radius * 2),
                          transform: nil)
        }
        let path = CGMutablePath()
        for corner in 0..<sides {
            // Rotated so a square sits on a corner rather than on an edge: a diamond is
            // unmistakably not a circle at a glance, and an axis-aligned square is not.
            let angle = .pi / 2 + Double(corner) * 2 * .pi / Double(sides)
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            corner == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// A target that timed out fades rather than vanishing, so the player can see what they
    /// missed instead of wondering whether it was ever there.
    func retire(_ expired: [Target]) {
        for target in expired {
            guard let node = nodes.removeValue(forKey: target.id) else { continue }
            node.run(.sequence([
                .group([.fadeOut(withDuration: 0.18), .scale(to: 0.6, duration: 0.18)]),
                .removeFromParent(),
            ]))
        }
    }

    func sync(_ targets: [Target], at now: TimeInterval) {
        let live = Set(targets.map(\.id))
        for (id, node) in nodes where !live.contains(id) {
            node.removeFromParent()
            nodes.removeValue(forKey: id)
        }

        for target in targets {
            let node = nodes[target.id] ?? make(target)
            node.position = CGPoint(x: target.center.x, y: target.center.y)
            // Targets dim as they age, which is the only cue that they are about to leave.
            let remaining = target.remainingFraction(at: now)
            node.alpha = 0.35 + 0.65 * remaining
            if target.kind == .standard {
                node.strokeColor = NSColor(calibratedRed: 1, green: 0.35 + 0.5 * remaining,
                                           blue: 0.3, alpha: 1)
            }
        }
    }

    private func make(_ target: Target) -> SKShapeNode {
        let kind = target.kind
        let colors = Self.palette(for: kind)
        let node = SKShapeNode(path: Self.outline(radius: target.radius, sides: kind.sides))
        node.lineWidth = kind == .standard ? 3 : 4
        node.fillColor = colors.fill
        node.strokeColor = colors.stroke

        let inner = SKShapeNode(path: Self.outline(radius: target.radius * 0.45, sides: kind.sides))
        inner.lineWidth = 2
        inner.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.5)
        inner.fillColor = .clear
        node.addChild(inner)

        // A bonus is worth noticing and is gone sooner, so it asks to be noticed. It pulses
        // in size rather than in opacity, because opacity is already spoken for: every
        // target fades as it ages, and two meanings on one channel is neither.
        if kind == .bonus {
            node.run(.sequence([
                .wait(forDuration: 0.12),
                .repeatForever(.sequence([.scale(to: 1.12, duration: 0.3),
                                          .scale(to: 0.94, duration: 0.3)])),
            ]))
        }

        node.setScale(0.2)
        node.run(.scale(to: 1, duration: 0.12))
        addChild(node)
        nodes[target.id] = node
        return node
    }
}
