import Foundation

public enum Format {
    /// 리셋까지 남은 시간: "4일 3시간" / "2시간 14분" / "38분" / "곧"
    public static func left(until date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "곧" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d >= 1 { return "\(d)일 \(h)시간" }
        if h >= 1 { return "\(h)시간 \(m)분" }
        return "\(max(1, m))분"
    }

    /// 리셋 시각: "9/30 (화) 04:00"
    public static func resetAt(_ date: Date?, short: Bool = false) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = short ? "M/d HH:mm" : "M/d (E) HH:mm"
        return f.string(from: date)
    }

    /// "3분 전" / "방금"
    public static func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }

    public static func tokens(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
        return "\(n)"
    }

    public static func money(_ v: Double?, currency: String) -> String? {
        guard let v else { return nil }
        if currency == "USD" { return String(format: "$%.2f", v) }
        return String(format: "%.2f %@", v, currency)
    }

    public static func percent(_ p: Double) -> String { "\(Int(p.rounded()))" }
}
