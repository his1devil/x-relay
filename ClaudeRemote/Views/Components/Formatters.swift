import Foundation

enum TimeFormat {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d 'at' h:mm"
        return f
    }()

    /// "Today at 9:41" / "Jun 25 at 9:41" — the per-message stamp.
    static func messageStamp(_ date: Date?) -> String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) {
            return "Today at \(clock.string(from: date))"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday at \(clock.string(from: date))"
        }
        return dayClock.string(from: date)
    }

    /// "9:41" — bare clock used on slash-command notes.
    static func clockShort(_ date: Date?) -> String {
        guard let date else { return "" }
        return clock.string(from: date)
    }

    /// "now" / "5m" / "3h" / "2d" — the relative stamp in the sessions list.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
