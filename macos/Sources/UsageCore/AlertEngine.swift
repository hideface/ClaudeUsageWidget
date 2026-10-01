import Foundation

public struct AlertSettings: Sendable, Equatable, Codable {
    public var enabled = true
    public var warnPct: Double = 85
    public var dangerPct: Double = 95
    public var pace = true
    public var credit = true

    public init() {}
}

public struct AlertEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case warn, danger, full, pace, credit }
    public var kind: Kind
    public var title: String
    public var body: String

    public init(kind: Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }

    public var isDanger: Bool { kind == .danger || kind == .full || kind == .credit }
}

/// 원본 위젯의 알림 규칙.
/// - 기준치: 경고(85%) / 위험(95%) / 100% 도달. 리셋 주기마다 단계별 1회(높은 단계가 나가면 낮은 단계도 끝난 것으로 기록)
/// - 속도 예측: 최근 10~90분 기울기로 60분 안에, 그리고 리셋보다 먼저 100%에 닿을 것 같으면 주기당 1회
/// - 크레딧: 사용액이 늘면 알림(30분에 최대 1회). 줄면(월 초기화) 기준값만 갱신
public struct AlertState: Sendable, Equatable, Codable {
    struct Point: Sendable, Equatable, Codable { var t: Date; var p: Double }

    var notified: [String] = []
    var history: [String: [Point]] = [:]
    /// 리셋 시각을 모를 때(데스크톱 기록) 주기를 구분하는 번호. 사용률이 크게 떨어지면 올린다.
    var cycles: [String: Int] = [:]
    /// 한도별로 이번 주기의 리셋 시각. Codex 로그의 resets_at은 이벤트마다 ±1초씩 흔들려서,
    /// 5분 안의 차이는 같은 주기로 본다. (옵셔널이라 예전 alerts.json도 그대로 읽힌다)
    var resetAnchors: [String: Date]? = nil
    static let resetTolerance: TimeInterval = 300
    var creditSeen: Double?
    var lastCreditNote: Date = .distantPast

    public init() {}

    public mutating func evaluate(_ d: DisplayState, now: Date, settings s: AlertSettings) -> [AlertEvent] {
        var out: [AlertEvent] = []
        let sampleTime = d.asOf ?? now

        for row in d.rows where !d.isStale(row) {
            let p = row.percent
            var h = history[row.id] ?? []
            if let last = h.last, last.p > p + 5 {           // 리셋됨
                h.removeAll()
                cycles[row.id, default: 0] += 1
            }
            if h.last?.t != sampleTime { h.append(Point(t: sampleTime, p: p)) }
            h.removeAll { sampleTime.timeIntervalSince($0.t) > 5400 }
            history[row.id] = h

            let cycle = cycleKey(row)
            let key = "\(row.id)|\(cycle)"
            let left = Format.left(until: row.resetsAt, now: now).map { "\($0) 후 리셋" } ?? "리셋 시각 모름"
            let pct = Format.percent(p)

            if p >= 100, mark(key, "full", also: ["alert", "warn"]) {
                let extra = d.credit?.enabled == true ? " 지금부터는 추가 크레딧(유료)으로 넘어갈 수 있어요." : ""
                out.append(AlertEvent(kind: .full, title: "\(row.name) 한도 도달", body: "\(left).\(extra)"))
            } else if p >= s.dangerPct, p < 100, mark(key, "alert", also: ["warn"]) {
                out.append(AlertEvent(kind: .danger, title: "\(row.name) 한도 \(pct)%", body: "곧 한도에 걸려요 · \(left)"))
            } else if p >= s.warnPct, p < s.dangerPct, mark(key, "warn") {
                out.append(AlertEvent(kind: .warn, title: "\(row.name) 한도 \(pct)%", body: left))
            }

            if s.pace, p >= 50, p < s.dangerPct, let first = h.first, h.count >= 2 {
                let dt = sampleTime.timeIntervalSince(first.t)
                if dt >= 600, p > first.p {
                    let eta = (100 - p) / ((p - first.p) / dt)
                    let toReset = row.resetsAt.map { $0.timeIntervalSince(now) } ?? .infinity
                    if eta < 3600, eta < toReset, mark(key, "pace") {
                        let m = max(1, Int((eta / 60).rounded()))
                        out.append(AlertEvent(kind: .pace, title: "이 속도면 약 \(m)분 뒤 \(row.name) 한도",
                                              body: "지금 \(pct)% · \(left)"))
                    }
                }
            }
        }

        if let c = d.credit, c.enabled, let used = c.used, d.source == .api {
            if let seen = creditSeen, used > seen + 0.004 {
                if s.credit, now.timeIntervalSince(lastCreditNote) >= 1800 {
                    lastCreditNote = now
                    let total = Format.money(used, currency: c.currency) ?? ""
                    let delta = Format.money(used - seen, currency: c.currency) ?? ""
                    out.append(AlertEvent(kind: .credit, title: "추가 크레딧 사용 중",
                                          body: "이번 달 \(total) (+\(delta)). 한도를 넘긴 사용분은 유료예요."))
                    creditSeen = used
                }
            } else if creditSeen == nil || used < creditSeen! {
                creditSeen = used
            }
        }
        return s.enabled ? out : []
    }

    /// 리셋 시각을 알면 그 시각(흔들림은 흡수), 모르면 사용률 급락으로 센 주기 번호.
    private mutating func cycleKey(_ row: LimitRow) -> String {
        guard let reset = row.resetsAt else { return "c\(cycles[row.id, default: 0])" }
        var anchors = resetAnchors ?? [:]
        if let a = anchors[row.id], abs(a.timeIntervalSince(reset)) <= Self.resetTolerance {
            return "\(Int(a.timeIntervalSince1970))"
        }
        anchors[row.id] = reset
        resetAnchors = anchors
        return "\(Int(reset.timeIntervalSince1970))"
    }

    /// 처음이면 기록하고 true.
    private mutating func mark(_ key: String, _ level: String, also: [String] = []) -> Bool {
        let k = "\(key)|\(level)"
        guard !notified.contains(k) else { return false }
        notified.append(k)
        notified += also.map { "\(key)|\($0)" }
        if notified.count > 120 { notified.removeFirst(notified.count - 120) }
        return true
    }
}
