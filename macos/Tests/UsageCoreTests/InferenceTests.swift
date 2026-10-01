import Foundation
import Testing
@testable import UsageCore

@Suite struct ResetInferenceTests {
    let now = date("2026-09-29T03:00:00Z")

    func snap(at t: Date, fiveReset: Date?, weekReset: Date?) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: LimitRow(kind: .session, name: "5시간", percent: 40, resetsAt: fiveReset, isActive: false),
            weekly: LimitRow(kind: .weekly, name: "주간", percent: 30, resetsAt: weekReset, isActive: true),
            models: [LimitRow(kind: .model("Fable"), name: "Fable 주간", percent: 20, resetsAt: weekReset, isActive: false)],
            credit: nil, fetchedAt: t)
    }

    /// CLI만 쓰는 사용자가 쉬는 동안: 지난 리셋은 0%(추정), 주간은 다음 주기로.
    @Test func staleAPIRollsOverPassedResets() {
        let weekReset = now - 3600                                   // 1시간 전에 주간 리셋이 지났음
        let d = DisplayResolver.resolve(api: snap(at: now - 86400, fiveReset: now - 7200, weekReset: weekReset),
                                        desktopSamples: [], status: .tokenExpired, plan: nil, now: now, interval: 180)
        #expect(d.fiveHour?.percent == 0)
        #expect(d.fiveHour?.resetsAt == nil)
        #expect(d.fiveHour?.percentInferred == true)
        #expect(d.weekly?.percent == 0)
        #expect(d.weekly?.resetsAt == weekReset + 7 * 86400)
        #expect(d.models.first?.percent == 0)
        #expect(d.staleRowIDs.count == 3)                             // 여전히 회색
    }

    @Test func staleAPIKeepsFutureResets() {
        let d = DisplayResolver.resolve(api: snap(at: now - 86400, fiveReset: now + 600, weekReset: now + 86400),
                                        desktopSamples: [], status: .tokenExpired, plan: nil, now: now, interval: 180)
        #expect(d.fiveHour?.percent == 40)
        #expect(d.fiveHour?.percentInferred == nil)
    }

    /// 데스크톱 기록 모드: 주간 리셋은 7일씩 넘겨 계산, 5시간 리셋은 기록으로 추정.
    @Test func desktopModeComputesWeeklyAndEstimatesFiveHour() {
        let weekReset = now - 2 * 86400
        let samples = [
            DesktopSample(t: now - 3600, fiveHour: 0, weekly: 29),
            DesktopSample(t: now - 2700, fiveHour: 0, weekly: 29),
            DesktopSample(t: now - 1800, fiveHour: 12, weekly: 30),   // 이 사이(−45분 ~ −30분)에 창 시작
            DesktopSample(t: now - 900, fiveHour: 20, weekly: 31),
        ]
        let d = DisplayResolver.resolve(api: snap(at: now - 5 * 86400, fiveReset: now - 4 * 86400, weekReset: weekReset),
                                        desktopSamples: samples, status: .tokenExpired, plan: nil, now: now, interval: 180)
        #expect(d.source == .desktopHistory)
        #expect(d.weekly?.percent == 31)
        #expect(d.weekly?.resetsAt == weekReset + 7 * 86400)
        #expect(d.fiveHour?.percent == 20)
        #expect(d.fiveHour?.resetsAt == now - 2250 + 5 * 3600)        // 시작 ≈ −37.5분
        #expect(d.fiveHour?.resetEstimated == true)
        #expect(d.models.first?.percentInferred == true)              // 모델별도 리셋이 지났으니 0%(추정)
    }

    @Test func desktopModePrefersKnownFiveHourReset() {
        let samples = [DesktopSample(t: now - 600, fiveHour: 15, weekly: 30)]
        let d = DisplayResolver.resolve(api: snap(at: now - 7200, fiveReset: now + 3600, weekReset: now + 86400),
                                        desktopSamples: samples, status: .tokenExpired, plan: nil, now: now, interval: 180)
        #expect(d.fiveHour?.resetsAt == now + 3600)
        #expect(d.fiveHour?.resetEstimated == nil)
    }

    @Test func noActiveFiveHourWindowHasNoReset() {
        let samples = [DesktopSample(t: now - 900, fiveHour: 0, weekly: 30), DesktopSample(t: now - 60, fiveHour: 0, weekly: 30)]
        #expect(DisplayResolver.estimateFiveHourReset(samples, now: now) == nil)
    }

    @Test func oldStateWithoutNewFieldsDecodes() throws {
        let json = #"{"id":"session","kind":{"session":{}},"name":"5시간","percent":10,"isActive":false}"#
        let r = try JSONDecoder().decode(LimitRow.self, from: Data(json.utf8))
        #expect(r.resetEstimated == nil)
    }
}

@Suite struct AuthHintTests {
    func write(_ json: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString).json")
        try json.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func claude() throws {
        #expect(AuthHints.claudeUsesAPIKey(claudeJSON: try write(#"{"primaryApiKey":"sk-ant-api03-x"}"#)))
        #expect(!AuthHints.claudeUsesAPIKey(claudeJSON: try write(#"{"oauthAccount":{"emailAddress":"a"},"customApiKeyResponses":{"approved":["x"]}}"#)))
        #expect(AuthHints.claudeUsesAPIKey(claudeJSON: try write(#"{"customApiKeyResponses":{"approved":["x"],"rejected":[]}}"#)))
        #expect(!AuthHints.claudeUsesAPIKey(claudeJSON: try write(#"{}"#)))
    }

    @Test func codex() throws {
        #expect(AuthHints.codexUsesAPIKey(authJSON: try write(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}"#)))
        #expect(!AuthHints.codexUsesAPIKey(authJSON: try write(#"{"auth_mode":"chatgpt","tokens":{}}"#)))
        #expect(AuthHints.codexUsesAPIKey(authJSON: try write(#"{"OPENAI_API_KEY":"sk-x"}"#)))
    }

    @Test func engineReportsAPIKeyOnly() async {
        let t0 = date("2026-09-29T03:00:00Z")
        let api = StubAPI(.failure(.network("x")))
        let e = UsageEngine(credentials: StubCredentials(cred: nil), api: api, desktop: StubDesktop(list: []),
                            projectsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("none"),
                            stateURL: nil, calendar: seoul, claudeAPIKeyHint: { true }, clock: { t0 })
        let out = await e.tick(force: false, interval: 180, codex: false)
        #expect(out.display.status == .apiKeyOnly)
        #expect(api.calls == 0)
    }
}

@Suite struct CodexKeepTests {
    let now = date("2026-09-29T03:00:00Z")

    @Test func mainLimitSurvivesBeyondEightDaysAsReset() throws {
        let w = CodexLimit.Window(minutes: 10080, percent: 60, resetsAt: now - 3 * 86400)
        let main = CodexLimit(id: "codex", name: nil, plan: "pro", windows: [w], observedAt: now - 12 * 86400)
        let spark = CodexLimit(id: "codex_bengalfox", name: "Spark", plan: "pro", windows: [w], observedAt: now - 12 * 86400)
        let s = CodexSnapshot.merged([[main, spark]], horizon: now - 8 * 86400, keep: ["codex"])
        #expect(s.limits.map(\.id) == ["codex"])
        let d = try #require(CodexResolver.resolve(s, now: now))
        #expect(d.rows.first?.percent == 0)
        #expect(d.rows.first?.percentInferred == true)
        #expect(d.isStale)
    }
}
