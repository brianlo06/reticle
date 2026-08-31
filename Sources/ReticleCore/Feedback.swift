import Foundation
import RemoteKit

/// Turns game events into the feedback cues the phone renders.
///
/// Pure and separate from the host so the mapping is testable: "a five-streak hit should
/// feel stronger than a first hit" is a rule, and rules belong where they can be asserted
/// rather than buried in a network callback.
///
/// The cue vocabulary is deliberately about feel rather than meaning — `success` at some
/// intensity, not `targetDestroyed`. The phone decides what a firm success feels like on
/// its hardware, and the same vocabulary works for any host built on the same server.
public enum Feedback {

    /// What a trigger pull should feel like.
    public static func cue(for result: TriggerResult) -> CuePayload? {
        switch result {
        case .shot(.hit(_, let points, let multiplier)):
            // A long streak should be felt, not read. Intensity climbs with the multiplier
            // so the phone kicks harder the better you are doing.
            let intensity = min(0.5 + Double(multiplier - 1) * 0.12, 1.0)
            let label = multiplier > 1 ? "+\(points) x\(multiplier)" : "+\(points)"
            return CuePayload(kind: .success, intensity: intensity, text: label)

        case .shot(.miss):
            return CuePayload(kind: .failure, intensity: 0.35)

        case .readied(let ready):
            return CuePayload(kind: .info, intensity: ready ? 0.6 : 0.3,
                              text: ready ? "Ready" : "Not ready")

        // A shot the game refused never happened, so it must not be felt. Buzzing here
        // would teach the player that the cooldown is a punishment rather than a rhythm.
        case .shot(.tooSoon), .shot(.noSuchPlayer), .ignored, .noSuchPlayer:
            return nil
        }
    }

    /// What a phase change should feel like. `nil` when nothing should be felt.
    public static func cue(movingTo phase: Phase, from previous: Phase?) -> CuePayload? {
        guard phase != previous else { return nil }
        switch phase {
        case .countdown:
            return CuePayload(kind: .info, intensity: 0.5, text: "Get ready")
        case .playing:
            return CuePayload(kind: .start, intensity: 0.9, text: "GO")
        case .results:
            return CuePayload(kind: .finish, intensity: 0.8, text: "Round over")
        case .lobby:
            // Returning to the lobby is not an event anyone needs to feel.
            return previous == nil ? nil : CuePayload(kind: .info, intensity: 0.3)
        }
    }

    /// One beat of the countdown, so "3, 2, 1" is felt rather than watched. The point of a
    /// phone-as-gun is that you can look at the television instead of your hands.
    public static func countdownTick(secondsLeft: Int) -> CuePayload? {
        guard (1...3).contains(secondsLeft) else { return nil }
        return CuePayload(kind: .tick, intensity: 0.45, text: "\(secondsLeft)")
    }

    /// The last seconds of a round, so time pressure is felt too.
    public static func roundEndingTick(secondsLeft: Int) -> CuePayload? {
        guard (1...3).contains(secondsLeft) else { return nil }
        return CuePayload(kind: .warning, intensity: 0.5)
    }
}
