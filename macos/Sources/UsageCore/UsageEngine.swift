import Foundation

/// 앱을 다시 켜도 이어받는 상태.
struct PersistedState: Codable {
    var policy = FetchPolicy()
    var status: FetchStatus = .idle
    var lastAPI: UsageSnapshot?
    var plan: String?
    /// 한 번 본 Codex 한도 기록. 파일 꼬리에 없는 한도도 재시작 후 유지된다.
    var codexLimits: [CodexLimit]?
}

public struct EngineOutput: Sendable, Equatable {
    public var display: DisplayState
    public var tokens: TokenTally
    public var calledAPI: Bool
    public var codex: CodexDisplay?
    public var codexTokens: CodexTokenTally?
    /// Codex를 API 키로 쓰는 중(구독 한도 없음).
    public var codexAPIKey = false
    /// 마지막 자동 토큰 갱신 시도(시각, 결과). 설정 화면에 보여 준다.
    public var lastRefresh: RefreshAttempt?
}

public struct RefreshAttempt: Sendable, Equatable {
    public var at: Date
    public var result: RefreshResult
}

public actor UsageEngine {
    private let credentials: any CredentialProvider
    private let api: any UsageFetching
    private let desktop: any DesktopHistoryReading
    private let scanner: SessionLogScanner
    private let codexReader: CodexLogReader?
    private let codexTokenScanner: CodexTokenScanner?
    /// Codex 값은 Codex를 쓸 때만 바뀌므로 30초에 한 번만 읽는다.
    private var codexSnapshot = CodexSnapshot()
    private var codexReadAt = Date.distantPast
    /// 로그를 많이 읽은 틱(첫 스캔, 자정 직후 재스캔, Codex를 나중에 켰을 때) 뒤에는 해제된 메모리를 바로 시스템에 돌려준다.
    static let reliefThreshold: UInt64 = 32 << 20
    /// 끄면 사용량 API를 부르지 않는다(스냅샷 모드).
    private let allowNetwork: Bool
    private let refresher: (any TokenRefreshing)?
    /// 다시 시도 간격. 일시적 실패(부팅·깨어난 직후 네트워크 등)는 2분부터 두 배씩, 최대 30분.
    /// CLI를 못 찾은 경우처럼 저절로 풀리지 않는 실패는 바로 30분.
    static let refreshRetry: TimeInterval = 1800
    static let refreshFirstRetry: TimeInterval = 120
    private var lastRefresh: RefreshAttempt?
    private var refreshFailures = 0

    static func refreshWait(after result: RefreshResult?, failures: Int) -> TimeInterval {
        switch result {
        case nil, .refreshed?: return 0
        case .cliNotFound?: return refreshRetry
        case .failed?: return min(refreshRetry, refreshFirstRetry * pow(2, Double(max(0, failures - 1))))
        }
    }
    /// 데스크톱 앱 기록이 언제 쌓이는지 관찰용(새 기록이 생기면 로그).
    private var lastDesktopSample: Date?
    private let claudeAPIKeyHint: @Sendable () -> Bool
    private let codexAPIKeyHint: @Sendable () -> Bool
    private let stateURL: URL?
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var state: PersistedState

    public init(credentials: any CredentialProvider,
                api: any UsageFetching,
                desktop: any DesktopHistoryReading,
                projectsRoot: URL,
                codexSessionsRoot: URL? = nil,
                stateURL: URL?,
                calendar: Calendar = .current,
                allowNetwork: Bool = true,
                refresher: (any TokenRefreshing)? = nil,
                claudeAPIKeyHint: @escaping @Sendable () -> Bool = { false },
                codexAPIKeyHint: @escaping @Sendable () -> Bool = { false },
                clock: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.allowNetwork = allowNetwork
        self.refresher = refresher
        self.claudeAPIKeyHint = claudeAPIKeyHint
        self.codexAPIKeyHint = codexAPIKeyHint
        self.credentials = credentials
        self.api = api
        self.desktop = desktop
        self.scanner = SessionLogScanner(root: projectsRoot, calendar: calendar)
        self.codexReader = codexSessionsRoot.map { CodexLogReader(root: $0, calendar: calendar) }
        self.codexTokenScanner = codexSessionsRoot.map { CodexTokenScanner(root: $0, calendar: calendar) }
        self.stateURL = stateURL
        self.clock = clock
        self.log = log
        if let stateURL, let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = s
        } else {
            state = PersistedState()
        }
    }

    /// - claude: 끄면 키체인·API·Claude 로그를 전혀 건드리지 않는다
    /// - codex: 끄면 Codex 로그를 읽지 않는다
    /// - autoRefresh: CLI 토큰이 만료됐으면 CLI를 짧게 실행해 갱신을 시도한다(설정에서 켤 때만)
    /// - simulateExpired: 점검용. 이번 API 확인에서 토큰이 만료된 것처럼 처리한다(자동 갱신 흐름을 기다리지 않고 확인)
    public func tick(force: Bool, interval: TimeInterval, claude: Bool = true, codex: Bool = true,
                     autoRefresh: Bool = false, simulateExpired: Bool = false) async -> EngineOutput {
        let now = clock()
        var tokens = TokenTally()
        var called = false
        if claude {
            tokens = scanner.scan(now: now)
            if allowNetwork, state.policy.shouldCall(now: now, force: force) {
                state.policy.willCall(now: now, force: force, interval: interval)
                called = await callAPI(now: now, interval: interval, autoRefresh: autoRefresh, simulateExpired: simulateExpired)
                save()
            }
        }

        let later = clock()
        var display = DisplayState()
        if claude {
            let samples = desktop.samples()
            noteDesktopSample(samples)
            display = DisplayResolver.resolve(api: state.lastAPI, desktopSamples: samples, status: state.status,
                                              plan: state.plan, now: later, interval: interval)
        }
        var codexDisplay: CodexDisplay?
        var codexTokens: CodexTokenTally?
        var codexAPIKey = false
        var bytesRead = claude ? scanner.lastBytesRead : 0
        if codex, let codexReader, let codexTokenScanner {
            if force || later.timeIntervalSince(codexReadAt) >= 30 {
                codexSnapshot = codexReader.read(now: later)
                codexReadAt = later
            }
            codexTokens = codexTokenScanner.scan(now: later)
            bytesRead += codexTokenScanner.lastBytesRead
            let merged = CodexSnapshot.merged(
                [codexSnapshot.limits, Array(codexTokenScanner.limits.values), state.codexLimits ?? []],
                horizon: later.addingTimeInterval(-8 * 86400), keep: ["codex"])
            if Self.worthSaving(merged.limits, over: state.codexLimits ?? []) {
                state.codexLimits = merged.limits
                save()
            }
            codexDisplay = CodexResolver.resolve(merged, now: later)
            codexAPIKey = codexDisplay == nil && codexAPIKeyHint()
        }
        if bytesRead >= Self.reliefThreshold { malloc_zone_pressure_relief(nil, 0) }
        return EngineOutput(display: display, tokens: tokens, calledAPI: called, codex: codexDisplay,
                            codexTokens: codexTokens, codexAPIKey: codexAPIKey, lastRefresh: lastRefresh)
    }

    /// 한도 값(창·%·리셋)이 바뀌었거나 기록 시각이 10분 넘게 달라졌을 때만 저장한다(Codex 사용 중 매 틱 쓰기 방지).
    static func worthSaving(_ new: [CodexLimit], over old: [CodexLimit]) -> Bool {
        guard new.count == old.count else { return true }
        let byID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for l in new {
            guard let o = byID[l.id], o.windows == l.windows else { return true }
            if l.observedAt.timeIntervalSince(o.observedAt) > 600 { return true }
        }
        return false
    }

    /// 실제로 네트워크 호출을 했으면 true.
    /// 데스크톱 앱이 기록 파일에 새 표본을 남기면 로그에 적는다(언제 기록하는지 관찰용).
    private func noteDesktopSample(_ samples: [DesktopSample]) {
        guard let latest = samples.max(by: { $0.t < $1.t }), latest.t != lastDesktopSample else { return }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        log("[desktop] \(lastDesktopSample == nil ? "마지막 기록" : "새 기록") \(f.string(from: latest.t)) 5h=\(latest.fiveHour.map { "\(Int($0))" } ?? "-") week=\(latest.weekly.map { "\(Int($0))" } ?? "-")")
        lastDesktopSample = latest.t
    }

    private func callAPI(now: Date, interval: TimeInterval, autoRefresh: Bool, simulateExpired: Bool = false) async -> Bool {
        let loaded: OAuthCredential?
        do { loaded = try credentials.load() } catch {
            state.status = .error("credentials: \(error.localizedDescription)")
            state.policy.failed(now: now, interval: interval)
            log("[credentials] \(error.localizedDescription)")
            return false
        }
        guard var cred = loaded else {
            state.status = claudeAPIKeyHint() ? .apiKeyOnly : .noCredential
            state.policy.credentialUnavailable(now: now)
            return false
        }
        state.plan = cred.planLabel ?? state.plan
        var expired = cred.isExpired(at: now) || simulateExpired
        if simulateExpired { log("[token] simulated expiry (check mode)") }
        if expired, autoRefresh, let refresher,
           simulateExpired || now.timeIntervalSince(lastRefresh?.at ?? .distantPast)
                >= Self.refreshWait(after: lastRefresh?.result, failures: refreshFailures) {
            let result = await refresher.refresh()
            lastRefresh = RefreshAttempt(at: now, result: result)
            refreshFailures = result == .refreshed ? 0 : refreshFailures + 1
            log("[token] auto refresh via CLI: \(result)")
            if result == .refreshed, let fresh = try? credentials.load() { cred = fresh }
            expired = cred.isExpired(at: clock()) || (simulateExpired && result != .refreshed)
        }
        if expired {
            if state.status != .tokenExpired { log("[token] CLI access token expired; waiting for Claude Code to refresh it") }
            state.status = .tokenExpired
            state.policy.credentialUnavailable(now: now)
            return false
        }

        do {
            let snap = try await api.fetch(token: cred.accessToken, now: now)
            state.lastAPI = snap
            state.status = .ok
            state.policy.succeeded(now: now, interval: interval)
        } catch let e as UsageAPIError {
            switch e {
            case .rateLimited(let ra):
                state.policy.hitRateLimit(now: now, retryAfter: ra)
                state.status = .rateLimited(until: state.policy.nextAPI)
                log("[usage] 429, next try \(state.policy.nextAPI)")
            case .unauthorized(let code):
                state.status = .auth
                state.policy.failed(now: now, interval: interval)
                log("[usage] HTTP \(code)")
            case .http(let code, let body):
                state.status = .error("HTTP \(code)")
                state.policy.failed(now: now, interval: interval)
                log("[usage] HTTP \(code) \(body)")
            case .decoding(let m):
                state.status = .error("응답 형식 변경")
                state.policy.failed(now: now, interval: interval)
                log("[usage] decoding \(m)")
            case .network(let m):
                state.status = .error("네트워크")
                state.policy.failed(now: now, interval: interval)
                log("[usage] network \(m)")
            }
        } catch {
            state.status = .error(error.localizedDescription)
            state.policy.failed(now: now, interval: interval)
        }
        return true
    }

    private func save() {
        guard let stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}
