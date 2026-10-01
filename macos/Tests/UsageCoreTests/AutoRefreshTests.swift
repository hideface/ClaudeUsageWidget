import Foundation
import Testing
@testable import UsageCore

/// 갱신기가 성공하면 키체인 값이 바뀐 것처럼 새 토큰을 돌려주는 가짜.
final class RefreshableCredentials: CredentialProvider, TokenRefreshing, @unchecked Sendable {
    var cred: OAuthCredential
    var result: RefreshResult
    let fresh: OAuthCredential
    private(set) var refreshCalls = 0

    init(expiredAt: Date, freshUntil: Date, result: RefreshResult) {
        cred = OAuthCredential(accessToken: "old", expiresAt: expiredAt)
        fresh = OAuthCredential(accessToken: "new", expiresAt: freshUntil)
        self.result = result
    }
    func load() throws -> OAuthCredential? { cred }
    func refresh() async -> RefreshResult {
        refreshCalls += 1
        if result == .refreshed { cred = fresh }
        return result
    }
}

@Suite struct AutoRefreshTests {
    let t0 = date("2026-09-30T09:00:00Z")

    func engine(_ c: RefreshableCredentials, api: StubAPI, clock: MutableClock) -> UsageEngine {
        UsageEngine(credentials: c, api: api, desktop: StubDesktop(list: []),
                    projectsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("none"),
                    stateURL: nil, calendar: seoul, refresher: c, clock: { clock.now })
    }

    @Test func refreshesThenCallsAPIInSameTick() async {
        let c = RefreshableCredentials(expiredAt: t0 - 60, freshUntil: t0 + 8 * 3600, result: .refreshed)
        let api = StubAPI(.success(UsageSnapshot(fiveHour: nil, weekly: nil, models: [], credit: nil, fetchedAt: t0)))
        let out = await engine(c, api: api, clock: MutableClock(t0)).tick(force: false, interval: 180, codex: false, autoRefresh: true)
        #expect(c.refreshCalls == 1)
        #expect(api.calls == 1)
        #expect(out.display.status == .ok)
        #expect(out.lastRefresh?.result == .refreshed)
    }

    @Test func offByDefault() async {
        let c = RefreshableCredentials(expiredAt: t0 - 60, freshUntil: t0 + 8 * 3600, result: .refreshed)
        let api = StubAPI(.failure(.network("x")))
        let out = await engine(c, api: api, clock: MutableClock(t0)).tick(force: false, interval: 180, codex: false)
        #expect(c.refreshCalls == 0)
        #expect(out.display.status == .tokenExpired)
    }

    @Test func failuresRetryAtMostEvery30Minutes() async {
        let c = RefreshableCredentials(expiredAt: t0 - 60, freshUntil: t0 + 8 * 3600, result: .cliNotFound)
        let clock = MutableClock(t0)
        let e = engine(c, api: StubAPI(.failure(.network("x"))), clock: clock)
        _ = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)
        clock.now = t0 + 120                                       // 자격 증명은 60초마다 다시 보지만
        let out = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)
        #expect(c.refreshCalls == 1)                                // 갱신 시도는 30분 동안 한 번
        #expect(out.display.status == .tokenExpired)
        #expect(out.lastRefresh?.result == .cliNotFound)
        clock.now = t0 + 1800
        _ = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)
        #expect(c.refreshCalls == 2)
    }

    /// 일시적 실패(네트워크 등)는 2분 → 4분 → 8분… 으로 빨리 다시 시도한다.
    @Test func transientFailuresBackOffFromTwoMinutes() async {
        let c = RefreshableCredentials(expiredAt: t0 - 60, freshUntil: t0 + 8 * 3600, result: .failed("exit 1"))
        let clock = MutableClock(t0)
        let e = engine(c, api: StubAPI(.failure(.network("x"))), clock: clock)
        _ = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)       // 1회 실패
        clock.now = t0 + 60
        _ = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)
        #expect(c.refreshCalls == 1)
        clock.now = t0 + 120
        _ = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)       // 2분 뒤 2회
        #expect(c.refreshCalls == 2)
        c.result = .refreshed
        clock.now = t0 + 120 + 240                                                            // 4분 뒤 3회 → 성공
        let out = await e.tick(force: false, interval: 180, codex: false, autoRefresh: true)
        #expect(c.refreshCalls == 3)
        #expect(out.lastRefresh?.result == .refreshed)
    }

    @Test func retryWaits() {
        #expect(UsageEngine.refreshWait(after: .failed("x"), failures: 1) == 120)
        #expect(UsageEngine.refreshWait(after: .failed("x"), failures: 3) == 480)
        #expect(UsageEngine.refreshWait(after: .failed("x"), failures: 10) == 1800)
        #expect(UsageEngine.refreshWait(after: .cliNotFound, failures: 1) == 1800)
    }

    @Test func validTokenNeverRefreshes() async {
        let c = RefreshableCredentials(expiredAt: t0 + 3600, freshUntil: t0 + 8 * 3600, result: .refreshed)
        let api = StubAPI(.success(UsageSnapshot(fiveHour: nil, weekly: nil, models: [], credit: nil, fetchedAt: t0)))
        _ = await engine(c, api: api, clock: MutableClock(t0)).tick(force: false, interval: 180, codex: false, autoRefresh: true)
        #expect(c.refreshCalls == 0)
    }

    /// 점검 모드: 토큰이 유효해도 한 번 만료된 것처럼 처리해 자동 갱신 흐름 전체를 돈다.
    @Test func simulatedExpiryRunsTheWholeFlow() async {
        let c = RefreshableCredentials(expiredAt: t0 + 3600, freshUntil: t0 + 8 * 3600, result: .refreshed)
        let api = StubAPI(.success(UsageSnapshot(fiveHour: nil, weekly: nil, models: [], credit: nil, fetchedAt: t0)))
        let out = await engine(c, api: api, clock: MutableClock(t0))
            .tick(force: true, interval: 180, codex: false, autoRefresh: true, simulateExpired: true)
        #expect(c.refreshCalls == 1)
        #expect(api.calls == 1)
        #expect(out.display.status == .ok)
    }

    @Test func simulatedExpiryWithAutoRefreshOffShowsExpired() async {
        let c = RefreshableCredentials(expiredAt: t0 + 3600, freshUntil: t0 + 8 * 3600, result: .refreshed)
        let api = StubAPI(.failure(.network("x")))
        let out = await engine(c, api: api, clock: MutableClock(t0))
            .tick(force: true, interval: 180, codex: false, autoRefresh: false, simulateExpired: true)
        #expect(c.refreshCalls == 0)
        #expect(api.calls == 0)
        #expect(out.display.status == .tokenExpired)
    }

    @Test func findsCLIInCommonLocations() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        #expect(ClaudeCLIRefresher.findCLI(home: home) == nil || !ClaudeCLIRefresher.findCLI(home: home)!.hasPrefix(home.path))
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        #expect(ClaudeCLIRefresher.findCLI(home: home) == cli.path)
    }

    /// 실제 Process 실행 경로: 가짜 CLI(항상 성공/실패)를 만들어 결과 코드를 확인한다.
    @Test func runsCLIAndMapsExitCode() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        let work = home.appendingPathComponent("work")
        func install(_ code: Int) throws {
            try "#!/bin/sh\nexit \(code)\n".write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        }
        try install(0)
        #expect(await ClaudeCLIRefresher(home: home, workDir: work).refresh() == .refreshed)
        try install(3)
        #expect(await ClaudeCLIRefresher(home: home, workDir: work).refresh() == .failed("exit 3"))
    }
}
