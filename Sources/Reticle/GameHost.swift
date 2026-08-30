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
    var onShot: ((UUID, ShotOutcome) -> Void)?
    var onRosterChange: (() -> Void)?

    init(game: Game) {
        self.game = game
    }

    // MARK: - Capabilities

    func features(for session: RemoteSession) -> [String] {
        // No keyboard, no media, no scrolling: a gun has one button. Advertising only what
        // exists lets the controller hide the rest rather than offering dead UI.
        ["pointer", "fire", "recenter"]
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
            self.game.addPlayer(id: session.id, name: name)
            Log.info("\(name) joined — \(self.game.players.count) playing")
            self.onRosterChange?()
        }
    }

    func sessionDidEnd(_ session: RemoteSession) {
        queue.async { [weak self] in
            guard let self else { return }
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
                let outcome = self.game.fire(player: session.id, at: Date().timeIntervalSince1970)
                self.onShot?(session.id, outcome)
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
