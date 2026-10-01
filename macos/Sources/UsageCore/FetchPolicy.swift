import Foundation

/// API 호출 시점 결정. 원본 위젯의 규칙을 따른다.
/// - 주기는 최소 120초
/// - 429: 5 → 10 → 20 → 30분(최대). Retry-After가 더 길면 그 값
/// - 429 대기 중에는 수동 갱신도 무시, 그 밖에도 수동 갱신은 2분에 한 번까지만(API를 2분보다 자주 부르지 않는다)
/// - 앱을 다시 켜도 대기 상태를 이어받도록 Codable로 저장한다
public struct FetchPolicy: Sendable, Equatable, Codable {
    public static let minInterval: TimeInterval = 120
    public static let forceThrottle: TimeInterval = 120
    public static let firstBackoff: TimeInterval = 300
    public static let maxBackoff: TimeInterval = 1800
    /// 토큰 없음·만료일 때 다시 확인하는 간격. CLI가 토큰을 갱신하면 곧 따라잡는다.
    public static let credentialRecheck: TimeInterval = 60

    public var nextAPI: Date = .distantPast
    public var backoff: TimeInterval = 0
    public var lastForce: Date = .distantPast
    public var rateLimited = false

    public init() {}

    public static func clamp(_ interval: TimeInterval) -> TimeInterval { max(minInterval, interval) }

    public func shouldCall(now: Date, force: Bool) -> Bool {
        if force {
            if rateLimited && now < nextAPI { return false }
            return now >= lastForce.addingTimeInterval(Self.forceThrottle)
        }
        return now >= nextAPI
    }

    /// shouldCall이 참일 때 호출 직전에 부른다.
    public mutating func willCall(now: Date, force: Bool, interval: TimeInterval) {
        if force { lastForce = now }
        nextAPI = now.addingTimeInterval(Self.clamp(interval))
    }

    public mutating func succeeded(now: Date, interval: TimeInterval) {
        backoff = 0
        rateLimited = false
        nextAPI = now.addingTimeInterval(Self.clamp(interval))
    }

    public mutating func hitRateLimit(now: Date, retryAfter: TimeInterval?) {
        backoff = backoff <= 0 ? Self.firstBackoff : min(Self.maxBackoff, backoff * 2)
        rateLimited = true
        nextAPI = now.addingTimeInterval(max(backoff, retryAfter ?? 0))
    }

    public mutating func failed(now: Date, interval: TimeInterval) {
        rateLimited = false
        nextAPI = now.addingTimeInterval(max(60, Self.clamp(interval)))
    }

    public mutating func credentialUnavailable(now: Date) {
        rateLimited = false
        nextAPI = now.addingTimeInterval(Self.credentialRecheck)
    }
}
