import AppKit
import SpriteKit
import RemoteServer
import ReticleCore

/// Draws the arena. Owns no rules — it reads `Game` each frame and renders what it finds,
/// so the interesting logic stays testable without a window server.
final class GameScene: SKScene {

    private let game: Game
    private var targetNodes: [UUID: SKShapeNode] = [:]
    private var reticleNodes: [UUID: SKNode] = [:]
    private var scoreLabels: [UUID: SKLabelNode] = [:]

    private let hud = SKNode()
    private let joinPanel = SKNode()
    private let qrNode = SKSpriteNode()
    private let qrBacking = SKShapeNode(rectOf: CGSize(width: 288, height: 288), cornerRadius: 12)
    private let joinURLLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let joinCodeLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let statusLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let phaseLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let timerLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let resultsLabel = SKLabelNode(fontNamed: "Menlo-Bold")

    /// Distinct colours per seat, so players can tell their reticles apart at TV distance.
    /// The spacing is `SeatPalette`'s problem, and it is checked there.
    private static func color(seat: Int) -> NSColor {
        let (hue, saturation, brightness) = SeatPalette.color(seat: seat)
        return NSColor(calibratedHue: CGFloat(hue), saturation: CGFloat(saturation),
                       brightness: CGFloat(brightness), alpha: 1)
    }

    var joinHint: String = "" {
        didSet { statusLabel.text = joinHint }
    }

    /// How to join, shown on the television itself.
    ///
    /// The terminal is invisible when the game is fullscreen on a TV, which is exactly when
    /// people need to join. Putting the code where everyone is already looking removes the
    /// only step that required someone to walk to the Mac.
    func showJoinCode(url: String, address: String, code: String) {
        joinURLText = "https://\(address)"
        joinCodeText = code
        guard let image = QRCode.cgImage(for: url) else { return }
        let texture = SKTexture(cgImage: image)
        // Nearest-neighbour: smoothing a QR code is the quickest way to make it unscannable.
        texture.filteringMode = .nearest
        qrNode.texture = texture
        qrNode.size = CGSize(width: 260, height: 260)
    }

    private var joinURLText = ""
    private var joinCodeText = ""

    /// Called once per frame so the host can narrate phase changes to the terminal.
    var onFrame: (() -> Void)?
    /// Flips the sound and reports the new state, or `nil` if this Mac has no sound to
    /// flip. Bound to M, because the one person near the keyboard is usually the one being
    /// asked to turn it down.
    var onToggleMute: (() -> Bool?)?
    /// Nudges the aim multiplier and reports the new value. Bound to `[` and `]`.
    var onAdjustSensitivity: ((Double) -> Double?)?

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

        // A white backing plate, because a QR code rendered straight onto a near-black
        // background has no quiet zone to speak of and scans badly.
        qrBacking.fillColor = .white
        qrBacking.strokeColor = .clear
        qrBacking.zPosition = 50
        joinPanel.addChild(qrBacking)

        qrNode.zPosition = 51
        joinPanel.addChild(qrNode)

        joinURLLabel.fontSize = 20
        joinURLLabel.fontColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        joinURLLabel.horizontalAlignmentMode = .center
        joinURLLabel.zPosition = 51
        joinPanel.addChild(joinURLLabel)

        joinCodeLabel.fontSize = 34
        joinCodeLabel.fontColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        joinCodeLabel.horizontalAlignmentMode = .center
        joinCodeLabel.zPosition = 51
        joinPanel.addChild(joinCodeLabel)

        joinPanel.zPosition = 50
        addChild(joinPanel)

        layoutHUD()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        game.resize(to: Arena(width: size.width, height: size.height))
        layoutHUD()
    }

    private func layoutHUD() {
        statusLabel.position = CGPoint(x: size.width / 2, y: 18)
        timerLabel.position = CGPoint(x: size.width - 20, y: size.height - 30)

        // In the lobby the join panel is the point of the screen, so it takes the middle and
        // the prompts sit under it. Everywhere else the middle belongs to the game.
        let panelCenterY = size.height * 0.58
        qrBacking.position = CGPoint(x: size.width / 2, y: panelCenterY)
        qrNode.position = qrBacking.position
        joinURLLabel.position = CGPoint(x: size.width / 2, y: panelCenterY - 176)
        joinCodeLabel.position = CGPoint(x: size.width / 2, y: panelCenterY - 218)

        phaseLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.26)
        resultsLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.22)
    }

    override func update(_ currentTime: TimeInterval) {
        advance()
    }

    /// Advances the game and redraws from what it finds.
    ///
    /// Separate from `update(_:)` because it is also driven by a timer while the window is
    /// occluded. Rendering may stop when nobody can see the screen; the round may not. A
    /// round is forty-five seconds of real time, and the players are listening to a
    /// countdown on their phones that must not stall because somebody brought another
    /// window in front of the television.
    func advance() {
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

        // The join panel is only useful before a round; during play it would cover the
        // arena, and its code is stale the moment somebody has used it anyway.
        joinPanel.isHidden = game.phase.isPlaying || {
            if case .countdown = game.phase { return true }
            return false
        }()
        joinURLLabel.text = joinURLText
        joinCodeLabel.text = joinCodeText.isEmpty ? "" : "code \(joinCodeText)"

        switch game.phase {
        case .lobby:
            let waiting = game.players.values.filter { !$0.isReady }.count
            phaseLabel.fontSize = 30
            phaseLabel.text = game.players.isEmpty
                ? "Scan with your phone's camera to join"
                : (waiting == 0 ? "Starting…" : "Press FIRE when ready  ·  waiting for \(waiting)")
            resultsLabel.text = "\(game.mode.title.uppercased())  ·  \(game.mode.summary)"
                + "\n\nRight-click on your phone to change mode"
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
            phaseLabel.text = "\(game.mode.title) over"
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
            let node = targetNodes[target.id]
                ?? makeTargetNode(radius: target.radius, kind: target.kind, id: target.id)
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

    private func makeTargetNode(radius: Double, kind: Target.Kind, id: UUID) -> SKShapeNode {
        let colors = Self.palette(for: kind)
        let node = SKShapeNode(path: Self.outline(radius: radius, sides: kind.sides))
        node.lineWidth = kind == .standard ? 3 : 4
        node.fillColor = colors.fill
        node.strokeColor = colors.stroke

        let inner = SKShapeNode(path: Self.outline(radius: radius * 0.45, sides: kind.sides))
        inner.lineWidth = 2
        inner.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.5)
        inner.fillColor = .clear
        node.addChild(inner)

        // A bonus is worth noticing and is gone sooner, so it asks to be noticed. It
        // pulses in size rather than in opacity, because opacity is already spoken for:
        // every target fades as it ages, and two meanings on one channel is neither.
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
            // Colour comes from the seat, position in the list from the score. Tying both
            // to the leaderboard meant a player's crosshair changed colour the moment they
            // overtook somebody — mid-round, while they were following it.
            let color = Self.color(seat: player.seat)
            let node = reticleNodes[player.id] ?? makeReticleNode(for: player.id, color: color)
            node.position = CGPoint(x: player.reticle.x, y: player.reticle.y)
            // An eliminated player keeps their reticle so they can watch, but it stops
            // looking live.
            node.alpha = player.isEliminated ? 0.25 : 1

            let label = scoreLabels[player.id] ?? makeScoreLabel(for: player.id, color: color)
            label.alpha = player.isEliminated ? 0.4 : 1
            label.text = "\(player.name)   \(player.score)"
                + (player.isEliminated ? "   OUT" : "")
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

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m":
            guard let muted = onToggleMute?() else { return }
            announce(muted ? "SOUND OFF" : "SOUND ON")
        // Aim is tuned by feel, which means tuning it during a round rather than between
        // launches. It is deliberately not refused mid-round the way a mode change is: a
        // mode change rewrites the rules the scores are being kept under, while this only
        // changes how far the gun swings, and it cannot be judged while standing still.
        case "[", "]":
            let step = event.charactersIgnoringModifiers == "[" ? -0.1 : 0.1
            guard let sensitivity = onAdjustSensitivity?(step) else { return }
            announce(String(format: "AIM %.2f×", sensitivity))
        default:
            super.keyDown(with: event)
        }
    }

    /// A short line in the middle of the screen, for the handful of things adjusted from
    /// the keyboard rather than from a phone.
    private func announce(_ text: String) {
        floatText(text, at: CGPoint(x: size.width / 2, y: size.height * 0.42),
                  color: NSColor(calibratedWhite: 0.8, alpha: 1))
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
