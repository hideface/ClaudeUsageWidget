import Foundation
import Testing
@testable import UsageCore

@Suite struct AlertTests {
    let t0 = date("2026-09-29T03:00:00Z")

    func display(_ five: Double, at t: Date, reset: Date? = nil, credit: Double? = nil,
                 source: DataSource = .api) -> DisplayState {
        var d = DisplayState()
        d.rows = [LimitRow(kind: .session, name: "5시간", percent: five, resetsAt: reset ?? t0 + 3 * 3600, isActive: true)]
        d.asOf = t
        d.source = source
        if let credit { d.credit = Credit(enabled: true, used: credit, limit: 50, currency: "USD", percent: nil) }
        return d
    }

    @Test func thresholdsFireOncePerCycle() {
        var s = AlertState()
        let cfg = AlertSettings()
        #expect(s.evaluate(display(80, at: t0), now: t0, settings: cfg).isEmpty)
        #expect(s.evaluate(display(86, at: t0 + 60), now: t0 + 60, settings: cfg).map(\.kind) == [.warn])
        #expect(s.evaluate(display(88, at: t0 + 120), now: t0 + 120, settings: cfg).isEmpty)
        #expect(s.evaluate(display(96, at: t0 + 180), now: t0 + 180, settings: cfg).map(\.kind) == [.danger])
        #expect(s.evaluate(display(100, at: t0 + 240), now: t0 + 240, settings: cfg).map(\.kind) == [.full])
        #expect(s.evaluate(display(100, at: t0 + 300), now: t0 + 300, settings: cfg).isEmpty)

        // 새 주기(리셋 시각이 바뀜)면 다시 알린다
        let next = t0 + 8 * 3600
        #expect(s.evaluate(display(90, at: next, reset: next + 5 * 3600), now: next, settings: cfg).map(\.kind) == [.warn])
    }

    @Test func jumpingPastDangerSkipsWarn() {
        var s = AlertState()
        #expect(s.evaluate(display(97, at: t0), now: t0, settings: AlertSettings()).map(\.kind) == [.danger])
        #expect(s.evaluate(display(97, at: t0 + 60), now: t0 + 60, settings: AlertSettings()).isEmpty)
    }

    @Test func pacePredictsWithinAnHour() {
        var s = AlertState()
        let cfg = AlertSettings()
        _ = s.evaluate(display(50, at: t0), now: t0, settings: cfg)
        // 20분에 +20%p → 남은 30%p까지 약 30분
        let ev = s.evaluate(display(70, at: t0 + 1200), now: t0 + 1200, settings: cfg)
        #expect(ev.map(\.kind) == [.pace])
        #expect(ev.first?.title == "이 속도면 약 30분 뒤 5시간 한도")
        #expect(s.evaluate(display(75, at: t0 + 1500), now: t0 + 1500, settings: cfg).isEmpty)
    }

    @Test func paceIgnoredWhenResetComesFirst() {
        var s = AlertState()
        _ = s.evaluate(display(50, at: t0, reset: t0 + 1500), now: t0, settings: AlertSettings())
        #expect(s.evaluate(display(70, at: t0 + 1200, reset: t0 + 1500), now: t0 + 1200, settings: AlertSettings()).isEmpty)
    }

    @Test func creditIncreaseAlertsAtMostEvery30Minutes() {
        var s = AlertState()
        let cfg = AlertSettings()
        #expect(s.evaluate(display(10, at: t0, credit: 3.0), now: t0, settings: cfg).isEmpty)          // 기준값만
        let ev = s.evaluate(display(10, at: t0 + 60, credit: 3.5), now: t0 + 60, settings: cfg)
        #expect(ev.map(\.kind) == [.credit])
        #expect(ev.first?.body == "이번 달 $3.50 (+$0.50). 한도를 넘긴 사용분은 유료예요.")
        #expect(s.evaluate(display(10, at: t0 + 120, credit: 4.0), now: t0 + 120, settings: cfg).isEmpty)
        #expect(s.evaluate(display(10, at: t0 + 2000, credit: 4.5), now: t0 + 2000, settings: cfg).map(\.kind) == [.credit])
        #expect(s.evaluate(display(10, at: t0 + 4000, credit: 0.2), now: t0 + 4000, settings: cfg).isEmpty)  // 월 초기화
    }

    @Test func disabledProducesNothingButStillTracks() {
        var s = AlertState()
        var cfg = AlertSettings()
        cfg.enabled = false
        #expect(s.evaluate(display(96, at: t0), now: t0, settings: cfg).isEmpty)
        cfg.enabled = true
        #expect(s.evaluate(display(96, at: t0 + 60), now: t0 + 60, settings: cfg).isEmpty)   // 이미 지나간 단계는 다시 안 울림
    }

    @Test func unknownResetUsesDropToDetectNewCycle() {
        var s = AlertState()
        var cfg = AlertSettings()
        cfg.pace = false
        func desk(_ p: Double, _ t: Date) -> DisplayState {
            var d = display(p, at: t, source: .desktopHistory)
            d.rows[0].resetsAt = nil
            return d
        }
        #expect(s.evaluate(desk(86, t0), now: t0, settings: cfg).map(\.kind) == [.warn])
        _ = s.evaluate(desk(3, t0 + 900), now: t0 + 900, settings: cfg)
        #expect(s.evaluate(desk(87, t0 + 1800), now: t0 + 1800, settings: cfg).map(\.kind) == [.warn])
    }

    @Test func resetJitterDoesNotRefire() {
        var s = AlertState()
        let cfg = AlertSettings()
        let reset = t0 + 3 * 86400
        #expect(s.evaluate(display(86, at: t0, reset: reset), now: t0, settings: cfg).map(\.kind) == [.warn])
        #expect(s.evaluate(display(86, at: t0 + 60, reset: reset + 1), now: t0 + 60, settings: cfg).isEmpty)
        #expect(s.evaluate(display(87, at: t0 + 120, reset: reset - 1), now: t0 + 120, settings: cfg).isEmpty)
        #expect(s.evaluate(display(96, at: t0 + 180, reset: reset + 1), now: t0 + 180, settings: cfg).map(\.kind) == [.danger])
    }

    @Test func oldAlertStateStillDecodes() throws {
        let old = #"{"notified":[],"history":{},"cycles":{},"lastCreditNote":0}"#
        #expect(throws: Never.self) { try JSONDecoder().decode(AlertState.self, from: Data(old.utf8)) }
    }
}
