import Foundation

/// Codex CLI가 세션 로그(`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)의 `token_count` 이벤트에 남기는 한도 기록 하나.
public struct CodexLimit: Sendable, Equatable, Codable {
    public struct Window: Sendable, Equatable, Codable {
        public var minutes: Int
        public var percent: Double
        public var resetsAt: Date?
    }

    public var id: String            // limit_id: "codex", "codex_bengalfox" …
    public var name: String?         // limit_name: "GPT-5.3-Codex-Spark" …
    public var plan: String?
    public var windows: [Window]
    public var observedAt: Date
    public var credits: CodexCredits? = nil
}

public struct CodexCredits: Sendable, Equatable, Codable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?
}

public struct CodexSnapshot: Sendable, Equatable {
    public var limits: [CodexLimit] = []
    public init(limits: [CodexLimit] = []) { self.limits = limits }
    public var observedAt: Date? { limits.map(\.observedAt).max() }

    /// 여러 출처(파일 꼬리, 오늘 로그 전체, 저장해 둔 값)를 한도별 최신 기록으로 합친다.
    /// `horizon`보다 오래된 건 버리되, `keep`에 있는 한도(기본 Codex 한도)는 오래 안 써도 남긴다
    /// (리셋이 지났으면 0% "리셋됨"으로 보인다).
    public static func merged(_ sources: [[CodexLimit]], horizon: Date, keep: Set<String> = []) -> CodexSnapshot {
        var latest: [String: CodexLimit] = [:]
        for l in sources.joined() where l.observedAt >= horizon || keep.contains(l.id) {
            if let cur = latest[l.id], cur.observedAt >= l.observedAt { continue }
            latest[l.id] = l
        }
        return CodexSnapshot(limits: latest.values.sorted { a, b in
            a.id == "codex" ? true : b.id == "codex" ? false : a.id < b.id
        })
    }
}

/// 최근 세션 파일의 끝부분만 읽어 한도별 마지막 기록을 모은다. 세션 로그는 수 GB가 될 수 있어 전체를 훑지 않는다.
/// 꼬리에 없는 한도(같은 세션에서 앞서 쓴 모델 등)는 오늘 로그 전체를 읽는 `CodexTokenScanner`와
/// 저장해 둔 값으로 보완한다(`UsageEngine`에서 `CodexSnapshot.merged`).
/// - 최근 `lookbackDays`일 날짜 폴더만 보고, 그중 `freshDays`일 안에 수정된 파일만 읽는다
/// - 파일 수정 시각이 그대로면 다시 읽지 않는다
public final class CodexLogReader {
    public let root: URL
    private let calendar: Calendar
    private let lookbackDays: Int
    private let freshDays: Double
    private var cache: [String: (mtime: Date, limits: [String: CodexLimit])] = [:]
    private static let marker = Data(#""rate_limits""#.utf8)
    private static let tailSizes = [256 << 10, 4 << 20]

    public init(root: URL, calendar: Calendar = .current, lookbackDays: Int = 30, freshDays: Double = 8) {
        self.root = root
        self.calendar = calendar
        self.lookbackDays = lookbackDays
        self.freshDays = freshDays
    }

    public func read(now: Date) -> CodexSnapshot {
        let fm = FileManager.default
        let horizon = now.addingTimeInterval(-freshDays * 86400)
        var seen = Set<String>()
        var latest: [String: CodexLimit] = [:]

        for offset in 0...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.path + String(format: "/%04d/%02d/%02d", c.year!, c.month!, c.day!)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name            // 파일이 수천 개라 URL 대신 문자열 경로
                guard let mtime = Self.modificationDate(path), mtime >= horizon else { continue }
                seen.insert(path)
                let limits: [String: CodexLimit]
                if let hit = cache[path], hit.mtime == mtime {
                    limits = hit.limits
                } else {
                    limits = Self.lastLimits(in: URL(fileURLWithPath: path))
                    cache[path] = (mtime, limits)
                }
                for (id, l) in limits where l.observedAt >= horizon {
                    if let cur = latest[id], cur.observedAt >= l.observedAt { continue }
                    latest[id] = l
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return CodexSnapshot(limits: latest.values.sorted { a, b in
            a.id == "codex" ? true : b.id == "codex" ? false : a.id < b.id
        })
    }

    /// `attributesOfItem`은 확장 속성까지 읽어 느리다. 10초마다 수백 개를 보므로 stat만 쓴다.
    static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// 파일 끝에서부터 읽어 한도별 마지막 기록을 찾는다. 없으면 더 크게 읽는다.
    static func lastLimits(in url: URL) -> [String: CodexLimit] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return [:] }
        for tail in tailSizes {
            let start = size > UInt64(tail) ? size - UInt64(tail) : 0
            guard (try? fh.seek(toOffset: start)) != nil, let data = try? fh.readToEnd() else { return [:] }
            var out: [String: CodexLimit] = [:]
            autoreleasepool {
                for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
                    if let l = parse(Data(line)) { out[l.id] = l }   // 뒤에 나온 줄이 최신
                }
            }
            if !out.isEmpty || start == 0 { return out }
        }
        return [:]
    }

    static func parse(_ line: Data) -> CodexLimit? {
        guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return parse(json: j)
    }

    /// 이미 디코딩한 token_count 줄에서 한도 기록을 꺼낸다(오늘 토큰 스캐너와 같이 쓴다).
    static func parse(json j: [String: Any]) -> CodexLimit? {
        guard let p = j["payload"] as? [String: Any], p["type"] as? String == "token_count",
              let rl = p["rate_limits"] as? [String: Any],
              let id = rl["limit_id"] as? String,
              let ts = ISODate.parse(j["timestamp"] as? String) else { return nil }
        let windows = ["primary", "secondary"].compactMap { k -> CodexLimit.Window? in
            guard let w = rl[k] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let mins = (w["window_minutes"] as? NSNumber)?.intValue else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexLimit.Window(minutes: mins, percent: pct, resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }   // 창 정보가 없는 기록(premium 등)은 건너뛴다
        var credits: CodexCredits?
        if let c = rl["credits"] as? [String: Any] {
            credits = CodexCredits(hasCredits: c["has_credits"] as? Bool ?? false, unlimited: c["unlimited"] as? Bool ?? false,
                                   balance: (c["balance"] as? String) ?? (c["balance"] as? NSNumber)?.stringValue)
        }
        return CodexLimit(id: id, name: rl["limit_name"] as? String, plan: rl["plan_type"] as? String,
                          windows: windows, observedAt: ts, credits: credits)
    }
}

/// 패널·메뉴바에 그릴 Codex 상태.
public struct CodexDisplay: Sendable, Equatable {
    public var rows: [LimitRow]
    public var plan: String?
    public var asOf: Date
    /// Codex를 한동안 안 써서 값이 멈춰 있음(회색으로 그린다).
    public var isStale: Bool
    /// 추가 크레딧이 있을 때만(`has_credits`).
    public var credits: CodexCredits? = nil

    public var active: LimitRow? { rows.max { $0.percent < $1.percent } }
    public var others: [LimitRow] { rows.filter { $0.id != active?.id } }
}

public enum CodexResolver {
    /// 마지막 기록이 이보다 오래되면 회색. 다른 기기에서 쓴 사용량은 이 맥의 로그에 없다.
    public static let staleAfter: TimeInterval = 6 * 3600

    public static func resolve(_ s: CodexSnapshot, now: Date) -> CodexDisplay? {
        guard let asOf = s.observedAt else { return nil }
        var rows: [LimitRow] = []
        for l in s.limits {
            let prefix = l.id == "codex" ? "" : (l.name ?? l.id.replacingOccurrences(of: "codex_", with: "")) + " "
            for w in l.windows.sorted(by: { $0.minutes < $1.minutes }) {
                let passed = w.resetsAt.map { $0 <= now } ?? false
                var row = LimitRow(kind: .codex("\(l.id):\(w.minutes)"), name: prefix + windowName(w.minutes),
                                   percent: passed ? 0 : w.percent, resetsAt: passed ? nil : w.resetsAt, isActive: false)
                if passed { row.percentInferred = true }   // 리셋이 지났으니 0%로 본다(다른 기기 사용분은 모름)
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { return nil }
        let main = s.limits.first { $0.id == "codex" } ?? s.limits.first
        return CodexDisplay(rows: rows, plan: main?.plan.map(planLabel), asOf: asOf,
                            isStale: now.timeIntervalSince(asOf) > staleAfter,
                            credits: main?.credits.flatMap { $0.hasCredits || $0.unlimited ? $0 : nil })
    }

    static func windowName(_ minutes: Int) -> String {
        switch minutes {
        case 300: "5시간"
        case 10080: "주간"
        case let m where m % 1440 == 0: "\(m / 1440)일"
        case let m where m % 60 == 0: "\(m / 60)시간"
        case let m: "\(m)분"
        }
    }

    static func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": "Pro Lite"
        default: raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}
