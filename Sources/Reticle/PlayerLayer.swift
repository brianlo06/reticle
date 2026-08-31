import AppKit
import SpriteKit
import ReticleCore

/// Draws the crosshairs, and whatever each shot did.
///
/// Score labels are not here: those are text in a corner and belong to the HUD. What lives
/// in the arena is the reticle and the number that jumps off it.
final class PlayerLayer: SKNode {

    private var reticles: [UUID: SKNode] = [:]

    func sync(_ leaderboard: [PlayerState]) {
        let live = Set(leaderboard.map(\.id))
        for (id, node) in reticles where !live.contains(id) {
            node.removeFromParent()
            reticles.removeValue(forKey: id)
        }

        for player in leaderboard {
            // Colour comes from the seat, never from the rank. Tying it to the leaderboard
            // meant a player's crosshair changed colour the moment they overtook somebody —
            // mid-round, while they were following it.
            let node = reticles[player.id] ?? make(player.id, color: SceneStyle.color(seat: player.seat))
            node.position = CGPoint(x: player.reticle.x, y: player.reticle.y)
            // An eliminated player keeps their reticle so they can watch, but it stops
            // looking live.
            node.alpha = player.isEliminated ? 0.25 : 1
        }
    }

    private func make(_ id: UUID, color: NSColor) -> SKNode {
        let node = SKNode()
        let ring = SKShapeNode(circleOfRadius: 20)
        ring.lineWidth = 3
        ring.strokeColor = color
        ring.fillColor = .clear
        node.addChild(ring)

        // Cross-hairs with a gap in the middle, so the reticle never hides what it is over.
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            let arm = SKShapeNode(rectOf: CGSize(width: dx == 0 ? 3 : 12,
                                                 height: dx == 0 ? 12 : 3))
            arm.fillColor = color
            arm.strokeColor = .clear
            arm.position = CGPoint(x: dx * 28, y: dy * 28)
            node.addChild(arm)
        }
        node.zPosition = 10
        addChild(node)
        reticles[id] = node
        return node
    }

    // MARK: - Feedback

    func show(_ result: TriggerResult, for id: UUID) {
        guard let reticle = reticles[id] else { return }
        switch result {
        case .shot(let outcome):
            show(outcome, at: reticle)
        case .readied(let ready):
            reticle.run(.sequence([.scale(to: ready ? 1.5 : 0.7, duration: 0.08),
                                   .scale(to: 1, duration: 0.12)]))
            floatText(ready ? "READY" : "not ready", at: reticle.position,
                      color: ready ? .systemGreen : NSColor(calibratedWhite: 0.6, alpha: 1))
        case .ignored, .noSuchPlayer:
            break
        }
    }

    private func show(_ outcome: ShotOutcome, at reticle: SKNode) {
        switch outcome {
        case .hit(_, let points, let multiplier):
            reticle.run(.sequence([.scale(to: 1.35, duration: 0.05), .scale(to: 1, duration: 0.1)]))
            floatText("+\(points)" + (multiplier > 1 ? " x\(multiplier)" : ""),
                      at: reticle.position, color: .systemGreen)
        case .penalty(_, let points):
            // The same shake as a miss, harder and longer: the mistake was worse, and it
            // has to read as a mistake from the other side of the room.
            reticle.run(.sequence([
                .moveBy(x: 12, y: 0, duration: 0.04),
                .moveBy(x: -24, y: 0, duration: 0.08),
                .moveBy(x: 24, y: 0, duration: 0.08),
                .moveBy(x: -12, y: 0, duration: 0.04),
            ]))
            floatText("\(points)", at: reticle.position, color: .systemRed)
        case .miss:
            reticle.run(.sequence([
                .moveBy(x: 6, y: 0, duration: 0.03),
                .moveBy(x: -12, y: 0, duration: 0.06),
                .moveBy(x: 6, y: 0, duration: 0.03),
            ]))
        case .tooSoon, .noSuchPlayer:
            break   // deliberately silent; nothing happened
        }
    }
}
