import Foundation

public enum Reconnect {
    /// Exponential backoff, capped at two minutes. `jitter` in 0...1 spreads
    /// reconnects by up to 25% so accounts don't all retry in the same instant.
    public static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = min(max(attempt, 0), 7)
        let base = min(pow(2.0, Double(exponent)), 120)
        return base * (1 + 0.25 * min(max(jitter, 0), 1))
    }
}
