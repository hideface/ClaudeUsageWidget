import Foundation
import Testing
@testable import UsageCore

private func snapshot(at t: Date, five: Double = 42, fiveReset: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: LimitRow(kind: .session, name: "5시간", percent: five, resetsAt: fiveReset, isActive: true),
        weekly: LimitRow(kind: .weekly, name: "주간", percent: 18, resetsAt: t + 86400 * 3, isActive: false),
        models: [LimitRow(kind: .model("Fable"), name: "Fable 주간", percent: 61, resetsAt: t + 86400 * 3, isActive: false)],
        credit: Credit(enabled: true, used: 3.2, limit: 50, currency: "USD", percent: 6.4),
        fetchedAt: t)
}

@Suite struct DisplayResolverTests {
    let now = date("2026-09-29T03:00:00Z")

    @Test func freshAPIWins() {
        let d = DisplayResolver.resolve(api: snapshot(at: now - 60), desktop: DesktopSample(t: now, fiveHour: 99, weekly: 99),
                                        status: .ok, plan: nil, now: now, interval: 180)
        #expect(d.source == .api)
        #expect(d.active?.percent == 42)
        #expect(d.staleRowIDs.isEmpty)
    }

    @Test func expiredTokenFallsBackToDesktop() {
        let api = snapshot(at: now - 7200, fiveReset: now + 600)
        let d = DisplayResolver.resolve(api: api, desktop: DesktopSample(t: now - 300, fiveHour: 55, weekly: 20, extra: 7),
                                        status: .tokenExpired, plan: nil, now: now, interval: 180)
        #expect(d.source == .desktopHistory)
        #expect(d.fiveHour?.percent == 55)
        #expect(d.fiveHour?.resetsAt == now + 600)          // 아직 안 지난 리셋 시각은 캐시에서
        #expect(d.weekly?.percent == 20)
        #expect(d.staleRowIDs == ["model:Fable"])            // 모델별은 회색
        #expect(d.credit?.percent == 7)
        #expect(d.active?.kind == .session)
    }

    @Test func passedResetIsReestimated() {
        let api = snapshot(at: now - 7200, fiveReset: now - 60)
        let d = DisplayResolver.resolve(api: api, desktop: DesktopSample(t: now - 60, fiveHour: 3, weekly: 20),
                                        status: .tokenExpired, plan: nil, now: now, interval: 180)
        // 지난 리셋은 버리고, 데스크톱 기록으로 추정한다(기록이 하나뿐이면 그 시각을 창 시작으로)
        #expect(d.fiveHour?.resetsAt == now - 60 + 5 * 3600)
        #expect(d.fiveHour?.resetEstimated == true)
    }

    @Test func everythingOldIsStale() {
        let d = DisplayResolver.resolve(api: snapshot(at: now - 7200), desktop: DesktopSample(t: now - 7000, fiveHour: 1, weekly: 1),
                                        status: .rateLimited(until: now + 600), plan: nil, now: now, interval: 180)
        #expect(d.source == .api)
        #expect(d.staleRowIDs.count == 3)
    }

    @Test func nothingAtAll() {
        let d = DisplayResolver.resolve(api: nil, desktop: nil, status: .noCredential, plan: nil, now: now, interval: 180)
        #expect(d.source == .none)
        #expect(d.active == nil)
    }
}

@Suite struct UsageEngineTests {
    let t0 = date("2026-09-29T03:00:00Z")
    let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")

    func engine(cred: OAuthCredential?, api: StubAPI, clock: MutableClock, desktop: [DesktopSample] = [],
                stateURL: URL? = nil) -> UsageEngine {
        UsageEngine(credentials: StubCredentials(cred: cred), api: api, desktop: StubDesktop(list: desktop),
                    projectsRoot: emptyRoot, stateURL: stateURL, calendar: seoul, clock: { clock.now })
    }

    @Test func expiredTokenSkipsNetworkAndUsesDesktop() async {
        let api = StubAPI(.success(snapshot(at: t0)))
        let clock = MutableClock(t0)
        let e = engine(cred: OAuthCredential(accessToken: "x", expiresAt: t0 - 10), api: api, clock: clock,
                       desktop: [DesktopSample(t: t0 - 120, fiveHour: 7, weekly: 25)])
        let out = await e.tick(force: false, interval: 180)
        #expect(api.calls == 0)
        #expect(out.display.status == .tokenExpired)
        #expect(out.display.source == .desktopHistory)
        #expect(out.display.fiveHour?.percent == 7)

        clock.now = t0 + 30
        _ = await e.tick(force: false, interval: 180)
        #expect(api.calls == 0)                                   // 60초 안에는 다시 확인하지 않음
    }

    @Test func callsOncePerInterval() async {
        let api = StubAPI(.success(snapshot(at: t0)))
        let clock = MutableClock(t0)
        let e = engine(cred: OAuthCredential(accessToken: "x", expiresAt: t0 + 3600), api: api, clock: clock)
        let first = await e.tick(force: false, interval: 180)
        #expect(first.calledAPI && first.display.source == .api)
        clock.now = t0 + 100
        _ = await e.tick(force: false, interval: 180)
        clock.now = t0 + 180
        _ = await e.tick(force: false, interval: 180)
        #expect(api.calls == 2)
    }

    @Test func rateLimitPersistsAcrossRestart() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
        let api = StubAPI(.failure(.rateLimited(retryAfter: nil)))
        let clock = MutableClock(t0)
        let cred = OAuthCredential(accessToken: "x", expiresAt: t0 + 86400)
        let out = await engine(cred: cred, api: api, clock: clock, stateURL: url).tick(force: false, interval: 180)
        #expect(out.display.status == .rateLimited(until: t0 + 300))

        clock.now = t0 + 60
        let restarted = engine(cred: cred, api: api, clock: clock, stateURL: url)
        _ = await restarted.tick(force: true, interval: 180)
        #expect(api.calls == 1)                                   // 재시작 + 수동 갱신도 대기 중엔 호출 안 함
    }
}

@Suite struct FormatTests {
    let now = Date(timeIntervalSince1970: 0)
    @Test func left() {
        #expect(Format.left(until: now + 86400 * 4 + 3 * 3600 + 5, now: now) == "4일 3시간")
        #expect(Format.left(until: now + 2 * 3600 + 14 * 60 + 5, now: now) == "2시간 14분")
        #expect(Format.left(until: now + 30, now: now) == "1분")
        #expect(Format.left(until: now - 1, now: now) == "곧")
        #expect(Format.left(until: nil, now: now) == nil)
    }
    @Test func tokens() {
        #expect(Format.tokens(4_102_653) == "4.1M")
        #expect(Format.tokens(999) == "999")
    }
}
