import Foundation

/// 한도 종류. 색 규칙(5시간 코랄 / 주간 보라 / 모델별 청록 / Codex 파랑)이 이 값을 따른다.
public enum LimitKind: Sendable, Equatable, Codable {
    case session
    case weekly
    case model(String)
    /// Codex 한도 창. 값은 "limit_id:창 길이(분)".
    case codex(String)
}

public struct LimitRow: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var kind: LimitKind
    public var name: String
    public var percent: Double
    public var resetsAt: Date?
    public var isActive: Bool
    public var severity: String?
    /// 리셋 시각이 추정값(5시간 창을 데스크톱 기록으로 추정). 옵셔널이라 예전 state.json도 읽힌다.
    public var resetEstimated: Bool? = nil
    /// 사용률이 추정값(리셋 시각이 지나 0%로 본 경우. 그 사이 다른 곳에서 썼다면 실제와 다를 수 있음).
    public var percentInferred: Bool? = nil

    public init(kind: LimitKind, name: String, percent: Double, resetsAt: Date?, isActive: Bool, severity: String? = nil) {
        switch kind {
        case .session: id = "session"
        case .weekly: id = "weekly"
        case .model(let m): id = "model:\(m)"
        case .codex(let c): id = "codex:\(c)"
        }
        self.kind = kind
        self.name = name
        self.percent = min(max(percent, 0), 100)
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.severity = severity
    }
}

/// 추가 사용 크레딧. 금액은 이미 주 단위(달러)로 환산된 값.
public struct Credit: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var used: Double?
    public var limit: Double?
    public var currency: String
    public var percent: Double?
}

/// API 한 번 성공했을 때의 스냅샷.
public struct UsageSnapshot: Sendable, Equatable, Codable {
    public var fiveHour: LimitRow?
    public var weekly: LimitRow?
    public var models: [LimitRow]
    public var credit: Credit?
    public var fetchedAt: Date

    public var rows: [LimitRow] { [fiveHour, weekly].compactMap { $0 } + models }
}

public struct TokenTally: Sendable, Equatable, Codable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var cacheRead: Int64 = 0
    public var messages: Int = 0

    public init() {}
    public var total: Int64 { input + output + cacheWrite + cacheRead }
}

public enum FetchStatus: Sendable, Equatable, Codable {
    case idle
    case ok
    case rateLimited(until: Date)
    case tokenExpired
    case noCredential
    case auth
    case error(String)
    /// 구독 로그인 없이 API 키만 쓰는 경우. 5시간·주간 한도가 없다.
    case apiKeyOnly
}
