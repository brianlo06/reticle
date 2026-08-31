import Foundation
import RemoteKit
import RemoteServer
import ReticleCore

/// What the phone's events mean in a shooting gallery.
///
/// The entire network stack — TLS, pairing, framing, validation, rate limiting — comes from
/// AirPoint's `RemoteServer` and is not reimplemented here. This type is the whole
/// difference between "a remote that moves a cursor" and "a game": roughly a hundred lines,
/// because everything underneath already knew how to get a validated `pointer_move` from a
/// phone to this machine safely.
final class GameHost: RemoteSessionHandler {

    private let game: Game
    /// The game is not thread-safe and the scene reads it every frame, so every mutation is
    /// funnelled to the main queue. Sessions arrive on arbitrary queues.
    private let queue: DispatchQueue = .main

    /// Called on the main queue when a shot resolves, for sound and particles.
    var onTrigger: ((UUID, TriggerResult) -> Void)?
    var onRosterChange: (() -> Void)?

    /// Last phase announced, so the transition is logged once rather than every frame.
    private var announcedPhase: Phase?
    /// Live sessions, so cues can be sent to everyone rather than only to whoever acted.
    private var sessions: [UUID: RemoteSession] = [:]
    /// The last whole second announced during a countdown, so each beat is felt once.
    private var lastTickSecond: Int?

    init(game: Game) {
        self.game = game
    }

    private func broadcast(_ cue: CuePayload) {
        for session in sessions.values { session.send(cue: cue) }
    }

    /// One pulse per second of the countdown, and for the last seconds of a round, so the
    /// clock is felt rather than watched — the point of aiming with a phone is that you can
    /// keep your eyes on the television.
    private func emitCountdownBeats() {
        let now = Date().timeIntervalSince1970
        guard let remaining = game.remaining(at: now) else {
            lastTickSecond = nil
            return
        }
        let second = Int(ceil(remaining))
        guard second != lastTickSecond else { return }
        lastTickSecond = second

        switch game.phase {
        case .countdown:
            if let cue = Feedback.countdownTick(secondsLeft: second) { broadcast(cue) }
        case .playing:
            if let cue = Feedback.roundEndingTick(secondsLeft: second) { broadcast(cue) }
        case .lobby, .results:
            break
        }
    }

    /// Narrates the match to the terminal.
    ///
    /// Called from the scene each frame. Without this the log showed a healthy stream of
    /// pointer telemetry and said nothing about whether a round ever started or anybody
    /// scored — which made "it worked" impossible to verify from the outside.
    func logPhaseChanges() {
        emitCountdownBeats()

        let phase = game.phase
        guard phase != announcedPhase else { return }
        let previous = announcedPhase
        announcedPhase = phase

        // Everyone feels a phase change, whoever triggered it.
        if let cue = Feedback.cue(movingTo: phase, from: previous) { broadcast(cue) }

        switch phase {
        case .lobby:
            let waiting = game.players.values.filter { !$0.isReady }.count
            Log.info(game.players.isEmpty
                     ? "lobby — waiting for players to join"
                     : "lobby — waiting for \(waiting) of \(game.players.count) to ready up")
        case .countdown:
            Log.info("all ready — starting in \(Int(game.settings.countdownDuration))s")
        case .playing:
            Log.info("round started (\(Int(game.settings.roundDuration))s, \(game.players.count) playing)")
        case .results:
            for (index, player) in game.lastResults.enumerated() {
                Log.info(String(format: "  %d. %@  %d points, %.0f%% of %d shots, best streak %d",
                                index + 1, player.name, player.score,
                                player.accuracy * 100, player.shots, player.bestStreak))
            }
            if game.lastResults.isEmpty { Log.info("round over — nobody fired") }
        }
    }

    // MARK: - Capabilities

    func features(for session: RemoteSession) -> [String] {
        // No keyboard, no media, no scrolling: a gun has one button. Advertising only what
        // exists lets the controller hide the rest rather than offering dead UI.
        ["pointer", "fire", "recenter", "ready"]
    }

    func displays(for session: RemoteSession) -> [DisplayInfo] {
        let arena = queue.sync { game.arena }
        return [DisplayInfo(id: 1, w: Int(arena.width), h: Int(arena.height), scale: 1, main: true)]
    }

    func isReady(for session: RemoteSession) -> Bool {
        // Always. Unlike the cursor remote, this needs no OS permission at all — the game
        // draws its own reticle instead of moving the system pointer, so there is nothing
        // to be denied.
        true
    }

    func permissions(for session: RemoteSession) -> [String: Bool] {
        ["ready": true]
    }

    // MARK: - Lifecycle

    func sessionDidBegin(_ session: RemoteSession) {
        let name = session.deviceName ?? "Player"
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions[session.id] = session
            self.game.addPlayer(id: session.id, name: name)
            Log.info("\(name) joined — \(self.game.players.count) playing")
            self.onRosterChange?()
        }
    }

    func sessionDidEnd(_ session: RemoteSession) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions.removeValue(forKey: session.id)
            self.game.removePlayer(id: session.id)
            Log.info("\(session.deviceName ?? "a player") left — \(self.game.players.count) playing")
            self.onRosterChange?()
        }
    }

    // MARK: - Events

    func handle(_ event: ClientEvent, from session: RemoteSession) {
        switch event {
        case .pointerMove(let move):
            queue.async { [weak self] in
                self?.game.aim(player: session.id, dx: move.dx, dy: move.dy)
            }

        // A tap is a trigger pull. Reusing `left_click` rather than inventing a `fire` event
        // means the stock AirPoint controller can play the game unmodified, which is a
        // useful property for a project whose point is reuse.
        case .leftClick:
            queue.async { [weak self] in
                guard let self else { return }
                // The trigger means "shoot" mid-round and "I'm ready" in the lobby or on
                // the results screen, so a round can be started from the couch without
                // anyone touching the Mac.
                let result = self.game.pullTrigger(player: session.id,
                                                  at: Date().timeIntervalSince1970)
                if case .readied(let ready) = result {
                    Log.info("\(session.deviceName ?? "a player") is \(ready ? "ready" : "not ready")")
                }
                // Only the player who pulled the trigger feels it.
                if let cue = Feedback.cue(for: result) { session.send(cue: cue) }
                self.onTrigger?(session.id, result)
            }

        case .recenter:
            queue.async { [weak self] in self?.game.recenter(player: session.id) }

        // Everything else is a cursor-remote concern with no meaning here. Ignored rather
        // than rejected: the phone may legitimately offer buttons this host does not use.
        case .rightClick, .dragStart, .dragEnd, .scroll, .keyPress, .textInput,
             .mediaCommand, .calibration, .hello, .ping, .disconnect:
            break
        }
    }
}
