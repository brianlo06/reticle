import Foundation

enum Reticle {
    static let version = "0.1.0"
    /// Compared against what the phone reports, so a stale page held in a backgrounded
    /// browser tab is detected rather than silently misbehaving — a lesson inherited from
    /// AirPoint, where exactly that cost three rounds of debugging.
    static let controllerVersion = "0.3.0"
}
