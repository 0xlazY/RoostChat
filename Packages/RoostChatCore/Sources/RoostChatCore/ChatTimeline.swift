import Foundation

/// When a conversation shows a centered date and time between messages.
public enum ChatTimeline {
    public static let headerGap: TimeInterval = 15 * 60

    /// True for the first message, after a long pause, or on a new calendar day.
    public static func needsHeader(previous: Date?, current: Date, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return current.timeIntervalSince(previous) >= headerGap || !calendar.isDate(previous, inSameDayAs: current)
    }
}
