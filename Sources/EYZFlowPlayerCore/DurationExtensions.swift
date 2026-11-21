import Foundation

extension Duration {
    /// Whole milliseconds, truncated toward zero (Dart's `inMilliseconds`).
    public var inMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    /// Seconds with the fraction.
    public var inSecondsDouble: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// `h:mm:ss`, as the Dart player's event log writes it.
    var clockString: String {
        let total = inMilliseconds / 1000
        let sign = total < 0 ? "-" : ""
        let value = abs(total)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let seconds = value % 60
        return "\(sign)\(hours):\(String(format: "%02d:%02d", minutes, seconds))"
    }
}
