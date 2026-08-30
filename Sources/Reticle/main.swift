import AppKit
import SpriteKit
import Foundation
import RemoteKit
import RemoteServer
import ReticleCore

// MARK: - Configuration

struct Options {
    var port: UInt16 = 8444          // one above AirPoint, so both can run at once
    var stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Reticle", isDirectory: true)
    }()
    var maxPlayers = 4
    var autoApprove = false
    var logLevel: Log.Level = .info
    var fullscreen = false

    static let usage = """
    reticle — a phone-aimed shooting gallery for your TV

    USAGE: reticle [options]

      --port <n>          TLS port (default 8444)
      --players <n>       Seats, 1-4 (default 4)
      --state-dir <path>  TLS identity and trusted devices
      --auto-approve      Skip the approval prompt. Testing only.
      --fullscreen        Start filling the screen
      --log-level <l>     debug | info | warn | error
      -h, --help          This help

    Needs no operating-system permissions: the game draws its own reticles rather
    than moving the system cursor, so there is nothing to grant.
    """

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch flag {
            case "--port":
                if let raw = value(), let port = UInt16(raw), port >= 1024 { options.port = port }
            case "--players":
                if let raw = value(), let count = Int(raw) { options.maxPlayers = min(max(count, 1), 4) }
            case "--state-dir":
                if let raw = value() { options.stateDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
            case "--auto-approve":
                options.autoApprove = true
            case "--fullscreen":
                options.fullscreen = true
            case "--log-level":
                switch value()?.lowercased() {
                case "debug": options.logLevel = .debug
                case "warn": options.logLevel = .warn
                case "error": options.logLevel = .error
                default: options.logLevel = .info
                }
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                FileHandle.standardError.write(Data("reticle: unknown flag '\(flag)'\n\n\(usage)\n".utf8))
                exit(2)
            }
            index += 1
        }
        return options
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
Log.minimumLevel = options.logLevel

// MARK: - Window

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let initialSize = CGSize(width: 1280, height: 760)
let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: initialSize),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Reticle"
window.center()
window.collectionBehavior = [.fullScreenPrimary]

let game = Game(arena: Arena(width: initialSize.width, height: initialSize.height))
let scene = GameScene(game: game, size: initialSize)
let skView = SKView(frame: NSRect(origin: .zero, size: initialSize))
skView.presentScene(scene)
window.contentView = skView
window.makeKeyAndOrderFront(nil)
if options.fullscreen { window.toggleFullScreen(nil) }

// MARK: - Server

let host = GameHost(game: game)
host.onShot = { [weak scene] id, outcome in scene?.showShot(player: id, outcome: outcome) }

var subjectNames = NetworkInterfaces.privateIPv4Addresses()
if let localName = NetworkInterfaces.localHostName() { subjectNames.append(localName) }
subjectNames.append(contentsOf: ["localhost", "127.0.0.1"])
subjectNames = Array(NSOrderedSet(array: subjectNames)) as? [String] ?? subjectNames

func fail(_ message: String) -> Never {
    Log.error(message)
    exit(1)
}

let secrets: SecretStore
let deviceSecrets: SecretStore
do {
    secrets = try SecretStoreFactory.make(useKeychain: false,
                                          stateDirectory: options.stateDirectory,
                                          service: "com.reticle", purpose: "tls")
    deviceSecrets = try SecretStoreFactory.make(useKeychain: false,
                                                stateDirectory: options.stateDirectory,
                                                service: "com.reticle", purpose: "devices")
} catch {
    fail("\(error)")
}

let identity: TLSIdentity.Loaded
do {
    identity = try TLSIdentity.loadOrCreate(stateDirectory: options.stateDirectory,
                                            subjectNames: subjectNames,
                                            secrets: secrets)
} catch {
    fail("\(error)")
}

let pairing = PairingService(trustStore: TrustStore(secrets: deviceSecrets),
                             approver: ConsoleApprover(autoApprove: options.autoApprove))

let serverConfig = ServerConfig(
    port: options.port,
    stateDirectory: options.stateDirectory,
    serviceName: "Reticle on \(ProcessInfo.processInfo.hostName)",
    serviceType: "_reticle._tcp",
    serverVersion: Reticle.version,
    expectedClientVersion: Reticle.controllerVersion,
    // The one line that separates a game from a remote: a seat per player rather than a
    // single device fighting for one cursor.
    maxConcurrentSessions: options.maxPlayers,
    staticContent: .webController(bundle: Bundle.module)
)

let server = Server(config: serverConfig, handler: host, pairing: pairing,
                    identity: identity, subjectNames: subjectNames)
do {
    try server.start()
} catch {
    fail("\(error)")
}

// MARK: - Join instructions

let secret = pairing.currentSecret()
let primaryHost = subjectNames.first ?? "127.0.0.1"
let joinURL = secret.pairingURL(host: primaryHost, port: options.port,
                                fingerprint: identity.certificateFingerprint)

scene.joinHint = "Join at https://\(primaryHost):\(options.port)   ·   code \(secret.displayCode)"

var banner = """

┌──────────────────────────────────────────────────────────────┐
│  Reticle — aim your phone at the screen and pull the trigger  │
└──────────────────────────────────────────────────────────────┘

  On each player's phone, open:

      https://\(primaryHost):\(options.port)

  Pairing code:  \(secret.displayCode)   (valid \(secret.remainingSeconds())s)
  Seats:         \(options.maxPlayers)


"""
if let qr = QRCode.terminalString(for: joinURL) { banner += qr + "\n\n" }
banner += """
  Safari will warn that the certificate is untrusted. That is expected — the game
  signs its own, because it runs on this machine rather than a public server, and
  the phone's motion sensors are unavailable without TLS.

  Approve each player in this terminal.


"""
FileHandle.standardError.write(Data(banner.utf8))

// MARK: - Shutdown

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        server.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

app.run()
