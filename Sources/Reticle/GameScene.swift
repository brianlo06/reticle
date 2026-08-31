import AppKit
import SpriteKit
import ReticleCore

/// Draws the arena. Owns no rules — it reads `Game` each frame and renders what it finds,
/// so the interesting logic stays testable without a window server.
final class GameScene: SKScene {

    private let game: Game
    private var targetNodes: [UUID: SKShapeNode] = [:]
    private var reticleNodes: [UUID: SKNode] = [:]
    private var scoreLabels: [UUID: SKLabelNode] = [:]

    private let hud = SKNode()
    private let statusLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let phaseLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let timerLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let resultsLabel = SKLabelNode(fontNamed: "Menlo-Bold")

    /// Distinct colours per seat, so two players can tell their reticles apart at TV distance.
    private static let seatColors: [NSColor] = [
        NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.50, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.28, alpha: 1),
    ]

    var joinHint: String = "" {
        didSet { statusLabel.text = joinHint }
    }

    /// Called once per frame so the host can narrate phase changes to the terminal.
    var onFrame: (() -> Void)?

    init(game: Game, size: CGSize) {
        self.game = game
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        addChild(hud)
        statusLabel.fontSize = 15
        statusLabel.fontColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        statusLabel.horizontalAlignmentMode = .center
        statusLabel.verticalAlignmentMode = .bottom
        hud.addChild(statusLabel)

        // The centre of the screen carries whatever the players need to know right now:
        // who is not ready, the countdown, or the final scores. At television distance a
        // small corner indicator is invisible.
        phaseLabel.fontSize = 44
        phaseLabel.fontColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        phaseLabel.horizontalAlignmentMode = .center
        phaseLabel.verticalAlignmentMode = .center
        phaseLabel.zPosition = 40
        hud.addChild(phaseLabel)

        resultsLabel.fontSize = 22
        resultsLabel.fontColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        resultsLabel.horizontalAlignmentMode = .center
        resultsLabel.verticalAlignmentMode = .top
        resultsLabel.numberOfLines = 0
        resultsLabel.zPosition = 40
        hud.addChild(resultsLabel)

        timerLabel.fontSize = 26
        timerLabel.fontColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        timerLabel.horizontalAlignmentMode = .right
        timerLabel.verticalAlignmentMode = .top
        timerLabel.zPosition = 20
        hud.addChild(timerLabel)

        layoutHUD()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        game.resize(to: Arena(width: size.width, height: size.height))
        layoutHUD()
    }

    private func layoutHUD() {
        statusLabel.position = CGPoint(x: size.width / 2, y: 18)
        phaseLabel.position = CGPoint(x: size.width / 2, y: size.height / 2)
        resultsLabel.position = CGPoint(x: size.width / 2, y: size.height / 2 - 40)
        timerLabel.position = CGPoint(x: size.width - 20, y: size.height - 30)
    }

    override func update(_ currentTime: TimeInterval) {
        let now = Date().timeIntervalSince1970
        for expired in game.tick(at: now) {
            // A target that timed out fades rather than vanishing, so the player can see
            // what they missed instead of wondering whether it was ever there.
            if let node = targetNodes.removeValue(forKey: expired.id) {
                node.run(.sequence([
                    .group([.fadeOut(withDuration: 0.18), .scale(to: 0.6, duration: 0.18)]),
                    .removeFromParent(),
                ]))
            }
        }
        syncTargets(now: now)
        syncPlayers()
        syncPhase(now: now)
        onFrame?()
    }

    private func syncPhase(now: TimeInterval) {
        let remaining = game.remaining(at: now)

        switch game.phase {
        case .lobby:
            let waiting = game.players.values.filter { !$0.isReady }.count
            phaseLabel.fontSize = 34
            phaseLabel.text = game.players.isEmpty
                ? "Scan the code to join"
                : (waiting == 0 ? "Starting…" : "Press FIRE when ready  ·  waiting for \(waiting)")
            resultsLabel.text = ""
            timerLabel.text = ""

        case .countdown:
            phaseLabel.fontSize = 96
            phaseLabel.text = "\(Int(ceil(remaining ?? 0)))"
            resultsLabel.text = ""
            timerLabel.text = ""

        case .playing:
            phaseLabel.text = ""
            resultsLabel.text = ""
            let left = Int(ceil(remaining ?? 0))
            timerLabel.text = String(format: "%d:%02d", left / 60, left % 60)
            // The last ten seconds turn red, because a timer you have to read is a timer
            // you will not read while aiming.
            timerLabel.fontColor = left <= 10
                ? NSColor(calibratedRed: 1, green: 0.35, blue: 0.3, alpha: 1)
                : NSColor(calibratedWhite: 0.7, alpha: 1)

        case .results:
            phaseLabel.fontSize = 40
            phaseLabel.text = "Round over"
            let lines = game.lastResults.enumerated().map { index, player in
                String(format: "%d.  %@   %d   %.0f%%  ·  best streak %d",
                       index + 1, player.name, player.score, player.accuracy * 100, player.bestStreak)
            }
            resultsLabel.text = (lines.isEmpty ? ["No shots fired"] : lines)
                .joined(separator: "\n") + "\n\nPress FIRE for another round"
            timerLabel.text = "\(Int(ceil(remaining ?? 0)))"
            timerLabel.fontColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        }
    }

    private func syncTargets(now: TimeInterval) {
        let live = Set(game.targets.map(\.id))
        for (id, node) in targetNodes where !live.contains(id) {
            node.removeFromParent()
            targetNodes.removeValue(forKey: id)
        }

        for target in game.targets {
            let node = targetNodes[target.id] ?? makeTargetNode(radius: target.radius, id: target.id)
            node.position = CGPoint(x: target.center.x, y: target.center.y)
            // Targets dim as they age, which is the only cue that they are about to leave.
            let remaining = target.remainingFraction(at: now)
            node.alpha = 0.35 + 0.65 * remaining
            node.strokeColor = NSColor(calibratedRed: 1, green: 0.35 + 0.5 * remaining,
                                       blue: 0.3, alpha: 1)
        }
    }

    private func makeTargetNode(radius: Double, id: UUID) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.lineWidth = 3
        node.fillColor = NSColor(calibratedRed: 0.25, green: 0.06, blue: 0.06, alpha: 0.85)
        node.strokeColor = .systemRed

        let inner = SKShapeNode(circleOfRadius: radius * 0.45)
        inner.lineWidth = 2
        inner.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.5)
        inner.fillColor = .clear
        node.addChild(inner)

        node.setScale(0.2)
        node.run(.scale(to: 1, duration: 0.12))
        addChild(node)
        targetNodes[id] = node
        return node
    }

    private func syncPlayers() {
        let seats = game.leaderboard
        let live = Set(seats.map(\.id))

        for (id, node) in reticleNodes where !live.contains(id) {
            node.removeFromParent()
            reticleNodes.removeValue(forKey: id)
            scoreLabels.removeValue(forKey: id)?.removeFromParent()
        }

        for (index, player) in seats.enumerated() {
            let color = Self.seatColors[index % Self.seatColors.count]
            let node = reticleNodes[player.id] ?? makeReticleNode(for: player.id, color: color)
            node.position = CGPoint(x: player.reticle.x, y: player.reticle.y)

            let label = scoreLabels[player.id] ?? makeScoreLabel(for: player.id, color: color)
            label.text = "\(player.name)   \(player.score)"
                + (player.streak >= 3 ? "   x\(min(1 + (player.streak - 1) / 3, game.settings.maxMultiplier))" : "")
            label.position = CGPoint(x: 20, y: size.height - 30 - CGFloat(index) * 26)
        }
    }

    private func makeReticleNode(for id: UUID, color: NSColor) -> SKNode {
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
        reticleNodes[id] = node
        return node
    }

    private func makeScoreLabel(for id: UUID, color: NSColor) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.fontSize = 18
        label.fontColor = color
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .top
        label.zPosition = 20
        hud.addChild(label)
        scoreLabels[id] = label
        return label
    }

    // MARK: - Feedback

    func showTrigger(player id: UUID, result: TriggerResult) {
        switch result {
        case .shot(let outcome):
            showShot(player: id, outcome: outcome)
        case .readied(let ready):
            guard let reticle = reticleNodes[id] else { return }
            reticle.run(.sequence([.scale(to: ready ? 1.5 : 0.7, duration: 0.08),
                                   .scale(to: 1, duration: 0.12)]))
            floatText(ready ? "READY" : "not ready", at: reticle.position,
                      color: ready ? .systemGreen : NSColor(calibratedWhite: 0.6, alpha: 1))
        case .ignored, .noSuchPlayer:
            break
        }
    }

    private func showShot(player id: UUID, outcome: ShotOutcome) {
        guard let reticle = reticleNodes[id] else { return }
        switch outcome {
        case .hit(_, let points, let multiplier):
            reticle.run(.sequence([.scale(to: 1.35, duration: 0.05), .scale(to: 1, duration: 0.1)]))
            floatText("+\(points)" + (multiplier > 1 ? " x\(multiplier)" : ""),
                      at: reticle.position, color: .systemGreen)
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

    private func floatText(_ text: String, at point: CGPoint, color: NSColor) {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = text
        label.fontSize = 20
        label.fontColor = color
        label.position = CGPoint(x: point.x, y: point.y + 30)
        label.zPosition = 30
        addChild(label)
        label.run(.sequence([
            .group([.moveBy(x: 0, y: 40, duration: 0.5), .fadeOut(withDuration: 0.5)]),
            .removeFromParent(),
        ]))
    }
}
