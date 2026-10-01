import Foundation

public struct CodexTokenTally: Sendable, Equatable {
    /// 입력(캐시 읽기 포함)
    public var input: Int64 = 0
    public var cachedInput: Int64 = 0
    public var output: Int64 = 0
    public var total: Int64 = 0
    public var sessions = 0

    public init() {}
}

/// 오늘 Codex 토큰. 세션마다 `total_token_usage`(누적치)를 쓰므로 중복 이벤트에 영향받지 않는다.
/// 세션별 오늘 사용량 = 오늘 마지막 누적치 − 오늘 0시 이전 마지막 누적치(없으면 0).
/// - 처음에는 오늘 수정된 파일을 끝까지 읽고, 이후에는 새로 붙은 줄만 읽는다
/// - 폴더 탐색은 60초에 한 번, 자정이 지나면 처음부터
public final class CodexTokenScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var baseline: Usage?
        var latestToday: Usage?
    }

    struct Usage: Equatable {
        var input: Int64, cached: Int64, output: Int64, total: Int64
        static func - (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input - b.input, cached: a.cached - b.cached, output: a.output - b.output, total: a.total - b.total)
        }
    }

    public let root: URL
    private let calendar: Calendar
    private var day: Date?
    private var files: [String: FileState] = [:]
    private var candidates: [String] = []
    private var enumeratedAt = Date.distantPast
    /// 오늘 로그에서 본 한도별 마지막 기록(파일 꼬리만 읽는 CodexLogReader가 놓치는 한도를 보완).
    public private(set) var limits: [String: CodexLimit] = [:]
    /// 직전 scan에서 읽은 바이트 수(큰 첫 스캔 뒤 메모리 반환 판단용).
    public private(set) var lastBytesRead: UInt64 = 0
    private static let marker = Data(#""token_count""#.utf8)
    private static let chunk = 4 << 20

    public init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    public func scan(now: Date) -> CodexTokenTally {
        let start = calendar.startOfDay(for: now)
        lastBytesRead = 0
        if day != start {
            day = start
            files = [:]
            limits = [:]
            enumeratedAt = .distantPast
        }
        if now.timeIntervalSince(enumeratedAt) >= 60 || now < enumeratedAt {
            enumeratedAt = now
            candidates = todayFiles(start: start, now: now)
        }
        for path in candidates {
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            let size = UInt64(st.st_size)
            var f = files[path] ?? FileState()
            if size < f.offset { f = FileState() }
            if size == f.offset { files[path] = f; continue }
            let before = f.offset
            read(path, into: &f, start: start)
            lastBytesRead += f.offset - before
            files[path] = f
        }

        var t = CodexTokenTally()
        for f in files.values {
            guard let latest = f.latestToday else { continue }
            let d = latest - (f.baseline ?? Usage(input: 0, cached: 0, output: 0, total: 0))
            t.input += d.input
            t.cachedInput += d.cached
            t.output += d.output
            t.total += d.total
            t.sessions += 1
        }
        return t
    }

    /// 오늘 수정된 세션 파일. 세션은 시작한 날짜 폴더에 있으므로 최근 30일 폴더를 본다.
    private func todayFiles(start: Date, now: Date) -> [String] {
        var out: [String] = []
        for offset in 0...30 {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            let dir = root.path + String(format: "/%04d/%02d/%02d", c.year!, c.month!, c.day!)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                if let m = CodexLogReader.modificationDate(path), m >= start { out.append(path) }
            }
        }
        return out
    }

    private func read(_ path: String, into f: inout FileState, start: Date) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: f.offset) } catch { return }
        var carry = Data()
        var done = false
        while !done {
            // 읽은 조각이 반복문 끝까지 남지 않도록 조각마다 풀을 비운다(첫 스캔은 수백 MB)
            autoreleasepool {
                guard let data = try? fh.read(upToCount: Self.chunk), !data.isEmpty else { done = true; return }
                carry.append(data)
                guard let lastNL = carry.lastIndex(of: 0x0A) else { return }
                let complete = carry[carry.startIndex...lastNL]
                for line in complete.split(separator: 0x0A) where line.range(of: Self.marker) != nil {
                    guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if let (ts, u) = Self.usage(json: j) {
                        if ts < start { f.baseline = u } else { f.latestToday = u }
                    }
                    if let l = CodexLogReader.parse(json: j), (limits[l.id]?.observedAt ?? .distantPast) <= l.observedAt {
                        limits[l.id] = l
                    }
                }
                f.offset += UInt64(complete.count)
                carry = Data(carry[carry.index(after: lastNL)...])
            }
        }
    }

    static func usage(json j: [String: Any]) -> (Date, Usage)? {
        guard let p = j["payload"] as? [String: Any], p["type"] as? String == "token_count",
              let info = p["info"] as? [String: Any],
              let tot = info["total_token_usage"] as? [String: Any],
              let ts = ISODate.parse(j["timestamp"] as? String) else { return nil }
        func n(_ k: String) -> Int64 { (tot[k] as? NSNumber)?.int64Value ?? 0 }
        return (ts, Usage(input: n("input_tokens"), cached: n("cached_input_tokens"), output: n("output_tokens"), total: n("total_tokens")))
    }
}
