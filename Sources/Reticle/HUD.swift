import AppKit
import SpriteKit
import ReticleCore

/// Everything written over the arena: what the room should be doing, the clock, and the
/// running scores.
///
/// It takes its wording from `Scoreboard` rather than deciding any of it, so what the
/// screen says is testable and only how it is set lives here.
final class HUD: SKNode {

    private let status = SceneStyle.label(size: 15, color: NSColor(calibratedWhite: 0.55, alpha: 1))
    private let headline = SceneStyle.label(size: 44, color: NSColor(calibratedWhite: 0.95, alpha: 1))
    private let body = SceneStyle.label(size: 22, color: NSColor(calibratedWhite: 0.75, alpha: 1))
    private let clock = SceneStyle.label(size: 26, color: HUD.calm)
    private var scores: [UUID: SKLabelNode] = [:]

    private static let calm = NSColor(calibratedWhite: 0.7, alpha: 1)
    private static let urgent = NSColor(calibratedRed: 1, green: 0.35, blue: 0.3, alpha: 1)

    var hint: String = "" {
        didSet { status.text = hint }
    }

    override init() {
        super.init()
        status.horizontalAlignmentMode = .center
        status.verticalAlignmentMode = .bottom
        addChild(status)

        // The centre of the screen carries whatever the players need to know right now: who
        // is not ready, the countdown, or the final scores. At television distance a small
        // corner indicator is invisible.
        headline.horizontalAlignmentMode = .center
        headline.verticalAlignmentMode = .center
        headline.zPosition = 40
        addChild(headline)

        body.horizontalAlignmentMode = .center
        body.verticalAlignmentMode = .top
        body.numberOfLines = 0
        body.zPosition = 40
        addChild(body)

        clock.horizontalAlignmentMode = .right
        clock.verticalAlignmentMode = .top
        clock.zPosition = 20
        addChild(clock)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func layout(in size: CGSize) {
        status.position = CGPoint(x: size.width / 2, y: 18)
        clock.position = CGPoint(x: size.width - 20, y: size.height - 30)
        headline.position = CGPoint(x: size.width / 2, y: size.height * 0.26)
        body.position = CGPoint(x: size.width / 2, y: size.height * 0.22)
    }

    func update(_ screen: Scoreboard.Screen) {
        headline.text = screen.headline
        switch screen.emphasis {
        case .prompt: headline.fontSize = 30
        case .countdown: headline.fontSize = 96
        case .verdict: headline.fontSize = 40
        case .silent: break   // nothing is being said, so there is nothing to size
        }
        body.text = screen.body
        clock.text = screen.clock
        // A timer you have to read is a timer you will not read while aiming, so the last
        // of the round changes colour rather than asking for attention.
        clock.fontColor = screen.isUrgent ? Self.urgent : Self.calm
    }

    /// The corner list: colour by seat, order by rank.
    func update(scores leaderboard: [PlayerState], settings: Game.Settings, in size: CGSize) {
        let live = Set(leaderboard.map(\.id))
        for (id, label) in scores where !live.contains(id) {
            label.removeFromParent()
            scores.removeValue(forKey: id)
        }

        for (rank, player) in leaderboard.enumerated() {
            let label = scores[player.id] ?? make(player.id, color: SceneStyle.color(seat: player.seat))
            label.alpha = player.isEliminated ? 0.4 : 1
            label.text = Scoreboard.row(for: player, settings: settings)
            label.position = CGPoint(x: 20, y: size.height - 30 - CGFloat(rank) * 26)
        }
    }

    private func make(_ id: UUID, color: NSColor) -> SKLabelNode {
        let label = SceneStyle.label(size: 18, color: color)
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .top
        label.zPosition = 20
        addChild(label)
        scores[id] = label
        return label
    }
}
