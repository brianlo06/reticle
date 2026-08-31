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
    var bindHost: String?
    var autoApprove = false
    var logLevel: Log.Level = .info
    var fullscreen = false
    var mute = false

    static let usage = """
    reticle — a phone-aimed shooting gallery for your TV

    USAGE: reticle [options]

      --port <n>          TLS port (default 8444)
      --players <n>       Seats, 1-4 (default 4)
      --state-dir <path>  TLS identity and trusted devices
      --bind <host>       Interface to bind (default: all private interfaces)
      --auto-approve      Skip the approval prompt. Requires --bind 127.0.0.1.
      --fullscreen        Start filling the screen
      --mute              Start with the television silent (M toggles it)
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
            case "--bind":
                if let raw = value() { options.bindHost = raw }
            case "--auto-approve":
                options.autoApprove = true
            case "--fullscreen":
                options.fullscreen = true
            case "--mute":
                options.mute = true
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
        // Auto-approval means every device presenting the code gets in with no human
        // involved. On a LAN interface that is an open door for anyone who photographs the
        // screen. AirPoint has always refused this combination; the game lost the rule when
        // its option parsing was written separately, which is exactly how safety checks go
        // missing.
        if options.autoApprove,
           !["127.0.0.1", "::1", "localhost"].contains(options.bindHost ?? "") {
            FileHandle.standardError.write(Data("""
            reticle: --auto-approve requires --bind 127.0.0.1

              Approving players automatically on a network interface would let anyone who
              photographs the join code take a seat with nobody agreeing to it. It is a
              testing convenience, not a hosting mode.

            """.utf8))
            exit(2)
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

let game = Game(arena: Arena(width: initialSize.width, height: initialSize.height),
                settings: .arcade)
let scene = GameScene(game: game, size: initialSize)
let skView = SKView(frame: NSRect(origin: .zero, size: initialSize))
skView.presentScene(scene)
window.contentView = skView
window.makeKeyAndOrderFront(nil)
if options.fullscreen { window.toggleFullScreen(nil) }

// A fully occluded window stops being handed drawables, and SpriteKit complains once per
// frame. Pausing while hidden silences it, and stops burning a GPU on a window nobody can
// see — which during this session was most of the time, since the terminal was in front.
//
// Rendering is what stops, though, not the game. SpriteKit drives the clock from its frame
// loop, so pausing the view used to freeze the round mid-countdown: the phones went on
// beating out three, two, one and the round never started. A plain timer takes over while
// the window is hidden, because forty-five seconds is forty-five seconds whether or not
// anyone is looking at the screen.
var hiddenClock: Timer?
let occlusionObserver = NotificationCenter.default.addObserver(
    forName: NSWindow.didChangeOcclusionStateNotification,
    object: window, queue: .main
) { [weak skView, weak scene] _ in
    let visible = window.occlusionState.contains(.visible)
    skView?.isPaused = !visible

    hiddenClock?.invalidate()
    hiddenClock = nil
    guard !visible else { return }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak scene] _ in
        scene?.advance()
    }
    // Common mode, or the round would also stop for a menu being held open.
    RunLoop.main.add(timer, forMode: .common)
    hiddenClock = timer
}

// MARK: - Server

let host = GameHost(game: game)
host.onTrigger = { [weak scene] id, result in scene?.showTrigger(player: id, result: result) }
scene.onFrame = { [weak host] in host?.logPhaseChanges() }

// The room's half of the feedback. The phone kicks in your hand; this is what everyone
// watching hears. Both render the same cues, so there is one place that decides meaning.
// A Mac that will not give us an output device is silent and otherwise unaffected.
let audio = GameAudio(muted: options.mute)
if audio == nil { Log.warn("running without sound") }
host.onCue = { [weak audio] cue in audio?.play(cue) }
scene.onToggleMute = { [weak audio] in
    guard let audio else { return nil }
    audio.isMuted.toggle()
    return audio.isMuted
}

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

// Everyone scans the same code off the television, so it must survive being used. Each
// player is still approved individually and the code still expires.
let pairing = PairingService(trustStore: TrustStore(secrets: deviceSecrets),
                             approver: ConsoleApprover(autoApprove: options.autoApprove),
                             consumeOnSuccess: false)

let serverConfig = ServerConfig(
    port: options.port,
    bindHost: options.bindHost,
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
scene.showJoinCode(url: joinURL,
                   address: "\(primaryHost):\(options.port)",
                   code: secret.displayCode)

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

// The code on screen must always be the live one. A QR that rotated out from under the
// player is indistinguishable from a broken pairing — the same trap the terminal banner hit.
var displayedCode = secret.displayCode
let codeRefresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let current = pairing.currentSecret()
    guard current.displayCode != displayedCode else { return }
    displayedCode = current.displayCode
    let url = current.pairingURL(host: primaryHost, port: options.port,
                                 fingerprint: identity.certificateFingerprint)
    scene.showJoinCode(url: url, address: "\(primaryHost):\(options.port)",
                       code: current.displayCode)
    Log.info("pairing code rotated to \(current.displayCode)")
}
RunLoop.main.add(codeRefresh, forMode: .common)

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
