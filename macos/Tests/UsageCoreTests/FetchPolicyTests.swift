import Foundation
import Testing
@testable import UsageCore

@Suite struct FetchPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func intervalHasFloor() {
        var p = FetchPolicy()
        #expect(p.shouldCall(now: t0, force: false))
        p.willCall(now: t0, force: false, interval: 30)
        #expect(!p.shouldCall(now: t0 + 119, force: false))
        #expect(p.shouldCall(now: t0 + 120, force: false))
    }

    @Test func rateLimitBacksOffExponentially() {
        var p = FetchPolicy()
        var waits: [TimeInterval] = []
        var now = t0
        for _ in 0..<5 {
            p.hitRateLimit(now: now, retryAfter: nil)
            waits.append(p.nextAPI.timeIntervalSince(now))
            now = p.nextAPI
        }
        #expect(waits == [300, 600, 1200, 1800, 1800])
        p.succeeded(now: now, interval: 180)
        p.hitRateLimit(now: now, retryAfter: nil)
        #expect(p.nextAPI.timeIntervalSince(now) == 300)
    }

    @Test func retryAfterWinsWhenLonger() {
        var p = FetchPolicy()
        p.hitRateLimit(now: t0, retryAfter: 900)
        #expect(p.nextAPI == t0 + 900)
    }

    @Test func forceIsBlockedDuringRateLimitAndThrottled() {
        var p = FetchPolicy()
        p.hitRateLimit(now: t0, retryAfter: nil)
        #expect(!p.shouldCall(now: t0 + 10, force: true))
        #expect(p.shouldCall(now: t0 + 300, force: true))

        var q = FetchPolicy()
        q.willCall(now: t0, force: true, interval: 180)
        #expect(!q.shouldCall(now: t0 + 119, force: true))
        #expect(q.shouldCall(now: t0 + 120, force: true))
    }

    @Test func survivesRestart() throws {
        var p = FetchPolicy()
        p.hitRateLimit(now: t0, retryAfter: nil)
        p.hitRateLimit(now: t0, retryAfter: nil)
        let back = try JSONDecoder().decode(FetchPolicy.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(!back.shouldCall(now: t0 + 100, force: true))
    }
}
