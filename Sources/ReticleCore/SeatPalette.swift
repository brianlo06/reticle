import Foundation

/// The colour of a seat, as hue and nothing else the renderer has to guess at.
///
/// Kept out of the scene because "are four crosshairs distinguishable across a living
/// room" is a claim that can be checked, and because the answer for a fifth player used to
/// be "it reuses the first player's colour" — a limit nobody had written down anywhere it
/// could fail.
public enum SeatPalette {

    /// How many seats the palette can keep visibly apart. Beyond this the hues crowd,
    /// so the game refuses the seats rather than handing out a colour twice.
    public static let capacity = 8

    /// Hue, saturation and brightness for a seat, each 0...1.
    ///
    /// Hues are spread by the golden angle rather than divided evenly by the seat count,
    /// so a player's colour depends only on their own seat. Dividing by the count would
    /// mean the fourth player joining recoloured everybody already playing.
    public static func color(seat: Int) -> (hue: Double, saturation: Double, brightness: Double) {
        let index = max(0, seat) % capacity
        // Starting at blue, because seat zero is the most common single-player case and a
        // blue crosshair reads cleanly over the red targets.
        let hue = (0.60 + 0.618_033_988_75 * Double(index)).truncatingRemainder(dividingBy: 1)
        // Short of full saturation: a fully saturated hue on a television is a smear, and
        // the crosshair has to stay legible against a near-black arena.
        return (hue: hue, saturation: 0.72, brightness: 1.0)
    }

    /// The smallest distance around the colour wheel between any two of the first `count`
    /// seats. The scene has nothing to say about this; a test does.
    public static func minimumHueSeparation(seats count: Int) -> Double {
        guard count > 1 else { return 1 }
        let hues = (0..<min(count, capacity)).map { color(seat: $0).hue }.sorted()
        var smallest = 1.0 - (hues.last! - hues.first!)   // the gap across the wrap
        for (a, b) in zip(hues, hues.dropFirst()) { smallest = min(smallest, b - a) }
        return smallest
    }
}
