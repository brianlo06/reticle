import AppKit
import SpriteKit
import ReticleCore

/// Puts the game on the television.
///
/// Owns no rules — it reads `Game` each frame and hands what it finds to the four things
/// that draw: the HUD, the join panel, the field and the crosshairs. Keeping this type down
/// to arranging them is what stops the next feature from landing in a six-hundred-line
/// file, which is where the last four went.
final class GameScene: SKScene {

    private let game: Game
    private let hud = HUD()
    private let joinPanel = JoinPanel()
    private let targets = TargetLayer()
    private let players = PlayerLayer()

    /// Called once per frame so the host can narrate phase changes to the terminal.
    var onFrame: (() -> Void)?
    /// Flips the sound and reports the new state, or `nil` if this Mac has no sound to
    /// flip. Bound to M, because the one person near the keyboard is usually the one being
    /// asked to turn it down.
    var onToggleMute: (() -> Bool?)?
    /// Nudges the aim multiplier and reports the new value. Bound to `[` and `]`.
    var onAdjustSensitivity: ((Double) -> Double?)?

    var joinHint: String = "" {
        didSet { hud.hint = joinHint }
    }

    init(game: Game, size: CGSize) {
        self.game = game
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        // Added before the arena, so that where two things share a z-position the game is
        // drawn over the text rather than under it.
        addChild(hud)
        addChild(joinPanel)
        addChild(targets)
        addChild(players)
        layout()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        game.resize(to: Arena(width: size.width, height: size.height))
        layout()
    }

    private func layout() {
        hud.layout(in: size)
        joinPanel.layout(in: size)
    }

    func showJoinCode(url: String, address: String, code: String) {
        joinPanel.show(url: url, address: address, pairingCode: code)
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
        targets.retire(game.tick(at: now))
        targets.sync(game.targets, at: now)

        let leaderboard = game.leaderboard
        players.sync(leaderboard)
        hud.update(scores: leaderboard, settings: game.settings, in: size)

        let screen = Scoreboard.screen(for: game, at: now)
        hud.update(screen)
        joinPanel.isHidden = !screen.showsJoinPanel

        onFrame?()
    }

    func showTrigger(player id: UUID, result: TriggerResult) {
        players.show(result, for: id)
    }

    // MARK: - The keyboard

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
}
