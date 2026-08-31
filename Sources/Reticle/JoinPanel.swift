import AppKit
import SpriteKit
import RemoteServer

/// How to join, shown on the television itself.
///
/// The terminal is invisible when the game is fullscreen on a TV, which is exactly when
/// people need to join. Putting the code where everyone is already looking removes the only
/// step that required somebody to walk over to the Mac.
final class JoinPanel: SKNode {

    private let backing = SKShapeNode(rectOf: CGSize(width: 288, height: 288), cornerRadius: 12)
    private let code = SKSpriteNode()
    private let addressLabel = SceneStyle.label(size: 20, color: NSColor(calibratedWhite: 0.8, alpha: 1))
    private let codeLabel = SceneStyle.label(size: 34, color: NSColor(calibratedWhite: 0.95, alpha: 1))

    override init() {
        super.init()
        zPosition = 50

        // A white backing plate, because a QR code rendered straight onto a near-black
        // background has no quiet zone to speak of and scans badly.
        backing.fillColor = .white
        backing.strokeColor = .clear
        backing.zPosition = 50
        addChild(backing)

        code.zPosition = 51
        addChild(code)

        addressLabel.horizontalAlignmentMode = .center
        addressLabel.zPosition = 51
        addChild(addressLabel)

        codeLabel.horizontalAlignmentMode = .center
        codeLabel.zPosition = 51
        addChild(codeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(url: String, address: String, pairingCode: String) {
        addressLabel.text = "https://\(address)"
        codeLabel.text = pairingCode.isEmpty ? "" : "code \(pairingCode)"
        guard let image = QRCode.cgImage(for: url) else { return }
        let texture = SKTexture(cgImage: image)
        // Nearest-neighbour: smoothing a QR code is the quickest way to make it unscannable.
        texture.filteringMode = .nearest
        code.texture = texture
        code.size = CGSize(width: 260, height: 260)
    }

    /// In the lobby this panel is the point of the screen, so it takes the middle and the
    /// prompts sit under it. Everywhere else the middle belongs to the game.
    func layout(in size: CGSize) {
        let centerY = size.height * 0.58
        backing.position = CGPoint(x: size.width / 2, y: centerY)
        code.position = backing.position
        addressLabel.position = CGPoint(x: size.width / 2, y: centerY - 176)
        codeLabel.position = CGPoint(x: size.width / 2, y: centerY - 218)
    }
}
