import Foundation

public enum DataSource: Sendable, Equatable {
    case api
    case desktopHistory
    case none
}

/// 화면에 그릴 최종 상태.
public struct DisplayState: Sendable, Equatable {
    public var rows: [LimitRow] = []
    public var credit: Credit?
    public var source: DataSource = .none
    /// 표시 중인 값의 기준 시각.
    public var asOf: Date?
    /// 값이 최신이 아닌 행(회색으로 그린다).
    public var staleRowIDs: Set<String> = []
    public var status: FetchStatus = .idle
    public var plan: String?

    public init() {}

    public var fiveHour: LimitRow? { rows.first { $0.kind == .session } }
    public var weekly: LimitRow? { rows.first { $0.kind == .weekly } }
    public var models: [LimitRow] { rows.filter { if case .model = $0.kind { true } else { false } } }

    /// 지금 걸린 한도. 서버가 표시한 게 없으면 가장 높은 것.
    public var active: LimitRow? { rows.first { $0.isActive } ?? rows.max { $0.percent < $1.percent } }
    public var others: [LimitRow] { rows.filter { $0.id != active?.id } }
    public func isStale(_ row: LimitRow) -> Bool { staleRowIDs.contains(row.id) }
}

/// API 스냅샷과 데스크톱 앱 기록 중 무엇을 보여 줄지 정한다(02-spike-result.md 5.1).
public enum DisplayResolver {
    /// 데스크톱 기록은 15분 주기라 30분 안이면 최신으로 본다.
    public static let desktopFreshness: TimeInterval = 30 * 60

    public static func apiFreshness(interval: TimeInterval) -> TimeInterval { max(FetchPolicy.clamp(interval) * 2.5, 600) }

    public static func resolve(api: UsageSnapshot?, desktop: DesktopSample?, status: FetchStatus,
                               plan: String?, now: Date, interval: TimeInterval) -> DisplayState {
        resolve(api: api, desktopSamples: desktop.map { [$0] } ?? [], status: status, plan: plan, now: now, interval: interval)
    }

    /// - desktopSamples: 데스크톱 앱 기록 전체(5시간 창 시작을 추정하는 데 쓴다)
    public static func resolve(api: UsageSnapshot?, desktopSamples: [DesktopSample], status: FetchStatus,
                               plan: String?, now: Date, interval: TimeInterval) -> DisplayState {
        var d = DisplayState()
        d.status = status
        d.plan = plan
        let samples = desktopSamples.sorted { $0.t < $1.t }
        let desktop = samples.last

        let apiFresh = api.map { now.timeIntervalSince($0.fetchedAt) <= apiFreshness(interval: interval) } ?? false
        let desktopFresh = desktop.map { now.timeIntervalSince($0.t) <= desktopFreshness } ?? false
        let desktopNewer = desktop.map { s in api.map { s.t > $0.fetchedAt } ?? true } ?? false

        if let api, apiFresh {
            d.rows = api.rows
            d.credit = api.credit
            d.source = .api
            d.asOf = api.fetchedAt
        } else if let desktop, desktopFresh, desktopNewer {
            d = merge(desktop: desktop, samples: samples, cached: api, now: now, base: d)
        } else if let api {
            // 오래된 API 값(토큰 만료 + 데스크톱 기록 없음, CLI만 쓰는 사용자가 쉬는 동안 등)
            d.rows = api.rows.map { rollOver($0, now: now) }
            d.credit = api.credit
            d.source = .api
            d.asOf = api.fetchedAt
            d.staleRowIDs = Set(api.rows.map(\.id))
        } else if let desktop {
            d = merge(desktop: desktop, samples: samples, cached: nil, now: now, base: d)
            d.staleRowIDs = Set(d.rows.map(\.id))
        }
        return d
    }

    static let week: TimeInterval = 7 * 86400
    static let fiveHours: TimeInterval = 5 * 3600

    /// 리셋 시각이 지난 한도: 사용률은 0%로 보고(추정), 주간 창은 7일씩 넘겨 다음 리셋 시각을 계산한다.
    /// 5시간 창은 다음 사용 때 새로 시작하므로 리셋 시각을 비운다.
    static func rollOver(_ row: LimitRow, now: Date) -> LimitRow {
        guard let reset = row.resetsAt, reset <= now else { return row }
        var r = row
        r.percent = 0
        r.percentInferred = true
        r.isActive = false
        r.resetsAt = row.kind == .session ? nil : nextWeekly(after: reset, now: now)
        return r
    }

    /// 주간 창은 매주 같은 시각에 리셋된다.
    static func nextWeekly(after reset: Date?, now: Date) -> Date? {
        guard var r = reset else { return nil }
        while r <= now { r = r.addingTimeInterval(week) }
        return r
    }

    /// 데스크톱 기록으로 5시간 창의 리셋 시각을 추정한다. 사용률이 0에서(또는 크게 떨어진 뒤) 처음 오른 기록을
    /// 창의 시작으로 보고 +5시간. 기록이 15분 간격이라 오차가 있으므로 추정으로 표시한다.
    static func estimateFiveHourReset(_ samples: [DesktopSample], now: Date) -> Date? {
        guard let last = samples.last, let lp = last.fiveHour, lp > 0 else { return nil }
        var i = samples.count - 1
        while i > 0 {
            guard let cur = samples[i].fiveHour, let prev = samples[i - 1].fiveHour else { break }
            if prev == 0 || prev > cur + 5 { break }       // 창이 새로 시작된 지점
            i -= 1
        }
        let first = samples[i]
        var start = first.t
        if i > 0 {
            let gap = first.t.timeIntervalSince(samples[i - 1].t)
            start = gap <= 30 * 60 ? first.t.addingTimeInterval(-gap / 2) : first.t.addingTimeInterval(-7.5 * 60)
        }
        let reset = start.addingTimeInterval(fiveHours)
        return reset > now ? reset : nil
    }

    /// 데스크톱 기록의 %에, 마지막 API 값의 리셋 시각(지났으면 주간은 다음 주기로 계산, 5시간은 기록으로 추정)과
    /// 모델별 한도(회색)를 덧붙인다.
    private static func merge(desktop s: DesktopSample, samples: [DesktopSample], cached: UsageSnapshot?,
                              now: Date, base: DisplayState) -> DisplayState {
        var d = base
        var rows: [LimitRow] = []
        if let p = s.fiveHour {
            var r = LimitRow(kind: .session, name: "5시간", percent: p, resetsAt: nil, isActive: cached?.fiveHour?.isActive ?? false)
            if let known = cached?.fiveHour?.resetsAt, known > now, p > 0 {
                r.resetsAt = known
            } else if let est = estimateFiveHourReset(samples, now: now) {
                r.resetsAt = est
                r.resetEstimated = true
            }
            rows.append(r)
        }
        if let p = s.weekly {
            rows.append(LimitRow(kind: .weekly, name: "주간", percent: p,
                                 resetsAt: nextWeekly(after: cached?.weekly?.resetsAt, now: now),
                                 isActive: cached?.weekly?.isActive ?? false))
        }
        let models = (cached?.models ?? []).map { rollOver($0, now: now) }
        rows += models
        d.rows = rows
        d.staleRowIDs = Set(models.map(\.id))
        if var c = cached?.credit {
            if let x = s.extra { c.percent = x }
            d.credit = c
        }
        d.source = .desktopHistory
        d.asOf = s.t
        return d
    }
}
