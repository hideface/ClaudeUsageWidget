import Foundation
import Testing
@testable import UsageCore

@Suite struct CodexTests {
    let now = date("2026-09-29T03:00:00Z")   // 12:00 KST

    /// 실제 로그와 같은 모양의 token_count 줄.
    func line(_ ts: String, id: String?, name: String? = nil, plan: String = "pro",
              primary: (Double, Int, Double)? = nil, secondary: (Double, Int, Double)? = nil) -> String {
        func w(_ v: (Double, Int, Double)?) -> Any {
            guard let v else { return NSNull() }
            return ["used_percent": v.0, "window_minutes": v.1, "resets_at": v.2]
        }
        let rl: [String: Any] = ["limit_id": id as Any? ?? NSNull(), "limit_name": name as Any? ?? NSNull(),
                                 "primary": w(primary), "secondary": w(secondary), "plan_type": plan,
                                 "credits": ["has_credits": false, "unlimited": false, "balance": "0"]]
        let obj: [String: Any] = ["timestamp": ts, "type": "event_msg", "ordinal": 1,
                                  "payload": ["type": "token_count", "info": ["total_token_usage": [:]], "rate_limits": rl]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func root(_ files: [String: [String]]) throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        for (path, lines) in files {
            let url = r.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return r
    }

    var weekReset: Double { now.timeIntervalSince1970 + 3 * 86400 }

    @Test func picksLatestRecordPerLimit() throws {
        let r = try root([
            "2026/09/28/rollout-a.jsonl": [
                line("2026-09-28T10:00:00.000Z", id: "codex", primary: (40, 10080, weekReset)),
                #"{"timestamp":"2026-09-28T10:00:01.000Z","type":"response_item","payload":{"type":"message"}}"#,
            ],
            "2026/09/29/rollout-b.jsonl": [
                line("2026-09-29T02:00:00.000Z", id: "codex", primary: (44, 10080, weekReset)),
                line("2026-09-29T02:30:00.000Z", id: "codex", primary: (45, 10080, weekReset)),
                line("2026-09-29T02:31:00.000Z", id: "premium"),
                line("2026-09-29T02:32:00.000Z", id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                     primary: (12, 300, now.timeIntervalSince1970 + 3600), secondary: (30, 10080, weekReset)),
            ],
        ])
        let s = CodexLogReader(root: r, calendar: seoul).read(now: now)
        #expect(s.limits.map(\.id) == ["codex", "codex_bengalfox"])        // 창 없는 premium은 제외, codex가 먼저
        #expect(s.limits.first?.windows.first?.percent == 45)
        #expect(s.observedAt == date("2026-09-29T02:32:00.000Z"))

        let d = try #require(CodexResolver.resolve(s, now: now))
        #expect(d.rows.map(\.name) == ["주간", "GPT-5.3-Codex-Spark 5시간", "GPT-5.3-Codex-Spark 주간"])
        #expect(d.active?.percent == 45)
        #expect(d.plan == "Pro")
        #expect(d.isStale == false)
        #expect(d.rows.first?.id == "codex:codex:10080")
    }

    @Test func dropsOldLimitsAndZeroesPassedWindows() throws {
        let r = try root([
            "2026/09/10/rollout-old.jsonl": [line("2026-09-10T00:00:00.000Z", id: "codex_old", primary: (80, 10080, 0))],
            "2026/09/29/rollout-b.jsonl": [line("2026-09-29T02:00:00.000Z", id: "codex",
                                                 primary: (70, 300, now.timeIntervalSince1970 - 60),
                                                 secondary: (20, 10080, weekReset))],
        ])
        let d = try #require(CodexResolver.resolve(CodexLogReader(root: r, calendar: seoul).read(now: now), now: now))
        #expect(d.rows.map(\.name) == ["5시간", "주간"])                    // 8일 넘은 한도는 안 보임
        #expect(d.rows[0].percent == 0)                                     // 리셋 시각이 지난 창은 0%
        #expect(d.rows[0].resetsAt == nil)
    }

    @Test func staleAfterSixHours() throws {
        let r = try root(["2026/09/28/rollout.jsonl": [line("2026-09-28T18:00:00.000Z", id: "codex", primary: (45, 10080, weekReset))]])
        let d = try #require(CodexResolver.resolve(CodexLogReader(root: r, calendar: seoul).read(now: now), now: now))
        #expect(d.isStale)
    }

    @Test func noDataIsNil() throws {
        let r = try root([:])
        #expect(CodexResolver.resolve(CodexLogReader(root: r, calendar: seoul).read(now: now), now: now) == nil)
    }

    @Test func readsTailOfLargeFileAndCaches() throws {
        let filler = String(repeating: #"{"timestamp":"2026-09-29T01:00:00.000Z","type":"response_item","payload":{"type":"message","text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"#, count: 1)
        var lines = Array(repeating: filler, count: 6000)                 // 약 900KB: 처음 256KB 꼬리에는 기록 없음
        lines.insert(line("2026-09-29T00:59:00.000Z", id: "codex", primary: (33, 10080, weekReset)), at: 0)
        lines.insert(line("2026-09-29T00:59:30.000Z", id: "codex", primary: (34, 10080, weekReset)), at: 1000)
        let r = try root(["2026/09/29/rollout-big.jsonl": lines])
        let reader = CodexLogReader(root: r, calendar: seoul)
        #expect(reader.read(now: now).limits.first?.windows.first?.percent == 34)

        // 같은 파일에 새 기록이 붙으면 다시 읽는다
        let url = r.appendingPathComponent("2026/09/29/rollout-big.jsonl")
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data((line("2026-09-29T02:50:00.000Z", id: "codex", primary: (36, 10080, weekReset)) + "\n").utf8))
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(reader.read(now: now).limits.first?.windows.first?.percent == 36)
    }

    @Test func windowNames() {
        #expect(CodexResolver.windowName(300) == "5시간")
        #expect(CodexResolver.windowName(10080) == "주간")
        #expect(CodexResolver.windowName(1440) == "1일")
        #expect(CodexResolver.windowName(90) == "90분")
        #expect(CodexResolver.planLabel("prolite") == "Pro Lite")
    }
}

@Suite struct CodexTokenTests {
    let now = date("2026-09-29T03:00:00Z")   // 12:00 KST, 0시 KST = 09-28T15:00Z

    func tc(_ ts: String, total: Int64, input: Int64, cached: Int64, output: Int64) -> String {
        let usage: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "total_tokens": total]
        let obj: [String: Any] = ["timestamp": ts, "type": "event_msg",
                                  "payload": ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func write(_ root: URL, _ path: String, _ lines: [String]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func todayIsLatestMinusBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-\(UUID().uuidString)")
        // 어제 시작해 오늘까지 이어진 세션: 0시 전 누적 1000 → 오늘 누적 1600, 중복 이벤트 포함
        _ = try write(root, "2026/09/28/rollout-a.jsonl", [
            tc("2026-09-28T14:00:00.000Z", total: 1000, input: 900, cached: 500, output: 100),
            tc("2026-09-28T16:00:00.000Z", total: 1300, input: 1150, cached: 600, output: 150),
            tc("2026-09-28T16:00:01.000Z", total: 1300, input: 1150, cached: 600, output: 150),
            tc("2026-09-29T01:00:00.000Z", total: 1600, input: 1400, cached: 700, output: 200),
        ])
        // 오늘 시작한 세션
        let b = try write(root, "2026/09/29/rollout-b.jsonl", [tc("2026-09-29T02:00:00.000Z", total: 50, input: 40, cached: 0, output: 10)])

        let s = CodexTokenScanner(root: root, calendar: seoul)
        var t = s.scan(now: now)
        #expect(t.total == 600 + 50)
        #expect(t.output == 100 + 10)
        #expect(t.cachedInput == 200)
        #expect(t.sessions == 2)

        let h = try FileHandle(forWritingTo: b)
        h.seekToEndOfFile()
        h.write(Data((tc("2026-09-29T02:30:00.000Z", total: 80, input: 60, cached: 0, output: 20) + "\n").utf8))
        try h.close()
        t = s.scan(now: now)
        #expect(t.total == 600 + 80)
    }
}

@Suite struct ProviderToggleTests {
    @Test func claudeOffSkipsKeychainAndAPI() async {
        let t0 = date("2026-09-29T03:00:00Z")
        let api = StubAPI(.success(UsageSnapshot(fiveHour: nil, weekly: nil, models: [], credit: nil, fetchedAt: t0)))
        let e = UsageEngine(credentials: StubCredentials(cred: OAuthCredential(accessToken: "x", expiresAt: t0 + 3600)),
                            api: api, desktop: StubDesktop(list: []),
                            projectsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("none"),
                            stateURL: nil, calendar: seoul, clock: { t0 })
        let out = await e.tick(force: true, interval: 180, claude: false, codex: false)
        #expect(api.calls == 0)
        #expect(out.display.rows.isEmpty)
        #expect(out.codex == nil)
    }
}

@Suite struct CodexMergeTests {
    let now = date("2026-09-29T03:00:00Z")
    let helper = CodexTests()

    func engine(root: URL, stateURL: URL, api: StubAPI? = nil, allowNetwork: Bool = true) -> UsageEngine {
        UsageEngine(credentials: StubCredentials(cred: OAuthCredential(accessToken: "x", expiresAt: now + 3600)),
                    api: api ?? StubAPI(.failure(.network("off"))), desktop: StubDesktop(list: []),
                    projectsRoot: root.appendingPathComponent("none"), codexSessionsRoot: root,
                    stateURL: stateURL, calendar: seoul, allowNetwork: allowNetwork, clock: { [now] in now })
    }

    /// 같은 세션에서 앞서 쓴 모델의 한도가 파일 꼬리에 없어도 보인다(오늘 로그 전체 스캔 + 저장).
    @Test func earlierLimitInSameFileIsKeptAndPersisted() async throws {
        let week = now.timeIntervalSince1970 + 3 * 86400
        let filler = #"{"timestamp":"2026-09-29T01:00:00.000Z","type":"response_item","payload":{"type":"message","text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"#
        var lines = [helper.line("2026-09-29T00:30:00.000Z", id: "codex_bengalfox", name: "Spark", primary: (20, 10080, week))]
        lines += Array(repeating: filler, count: 3000)                     // 약 400KB: 256KB 꼬리 밖으로 밀어냄
        lines.append(helper.line("2026-09-29T02:00:00.000Z", id: "codex", primary: (45, 10080, week)))
        let root = try helper.root(["2026/09/29/rollout-a.jsonl": lines])
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString).json")

        let out = await engine(root: root, stateURL: stateURL).tick(force: false, interval: 180, claude: false, codex: true)
        #expect(out.codex?.rows.map(\.name) == ["주간", "Spark 주간"])

        // 파일이 없어진 뒤 다시 켜도 저장해 둔 한도가 남는다
        let empty = try helper.root(["2026/09/29/rollout-b.jsonl": [helper.line("2026-09-29T02:10:00.000Z", id: "codex", primary: (46, 10080, week))]])
        let again = await engine(root: empty, stateURL: stateURL).tick(force: false, interval: 180, claude: false, codex: true)
        #expect(again.codex?.rows.map(\.name) == ["주간", "Spark 주간"])
        #expect(again.codex?.rows.first?.percent == 46)
    }

    @Test func offlineEngineNeverCallsAPI() async throws {
        let api = StubAPI(.success(UsageSnapshot(fiveHour: nil, weekly: nil, models: [], credit: nil, fetchedAt: now)))
        let root = try helper.root([:])
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString).json")
        _ = await engine(root: root, stateURL: stateURL, api: api, allowNetwork: false).tick(force: true, interval: 180)
        #expect(api.calls == 0)
    }

    @Test func savesOnlyOnMeaningfulChange() {
        let w = [CodexLimit.Window(minutes: 10080, percent: 45, resetsAt: nil)]
        let a = CodexLimit(id: "codex", name: nil, plan: "pro", windows: w, observedAt: now)
        var b = a; b.observedAt = now + 60
        var c = a; c.observedAt = now + 700
        var d = a; d.windows = [CodexLimit.Window(minutes: 10080, percent: 46, resetsAt: nil)]
        #expect(!UsageEngine.worthSaving([b], over: [a]))
        #expect(UsageEngine.worthSaving([c], over: [a]))
        #expect(UsageEngine.worthSaving([d], over: [a]))
        #expect(UsageEngine.worthSaving([a], over: []))
    }
}
