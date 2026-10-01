import Foundation

public struct OAuthCredential: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < now.addingTimeInterval(margin)
    }

    /// `team` + `default_claude_max_5x` → "Team · Max 5x"
    public var planLabel: String? {
        let sub = subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        var tier: String?
        if let t = rateLimitTier, let r = t.range(of: #"max_(\d+)x"#, options: .regularExpression) {
            tier = "Max " + t[r].dropFirst(4)
        }
        switch (sub, tier) {
        case let (s?, t?) where s == "Max": return t
        case let (s?, t?): return "\(s) · \(t)"
        case let (s?, nil): return s
        case let (nil, t?): return t
        default: return nil
        }
    }

    /// Claude Code가 키체인/파일에 쓰는 JSON(`{"claudeAiOauth": {...}}`)을 읽는다. 다른 키(mcpOAuth 등)는 무시.
    public static func parse(_ data: Data) -> OAuthCredential? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = obj["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        var exp: Date?
        if let ms = o["expiresAt"] as? Double { exp = Date(timeIntervalSince1970: ms / 1000) }
        return OAuthCredential(accessToken: token, expiresAt: exp,
                               subscriptionType: o["subscriptionType"] as? String,
                               rateLimitTier: o["rateLimitTier"] as? String)
    }
}

public protocol CredentialProvider: Sendable {
    /// 항목이 없으면 nil.
    func load() throws -> OAuthCredential?
}

/// `/usr/bin/security`로 읽는다. Claude Code가 이 CLI로 항목을 만들어서 팝업 없이 읽힌다(P0에서 확인).
public struct KeychainCLICredentialProvider: CredentialProvider {
    public var service: String

    public init(service: String = "Claude Code-credentials") { self.service = service }

    public func load() throws -> OAuthCredential? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }   // 44 = 항목 없음
        return OAuthCredential.parse(data)
    }
}

/// `CLAUDE_CONFIG_DIR/.credentials.json` (Linux·구버전 방식). 있으면 키체인보다 우선.
public struct FileCredentialProvider: CredentialProvider {
    public var url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> OAuthCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return OAuthCredential.parse(data)
    }
}

public struct ChainCredentialProvider: CredentialProvider {
    public var providers: [any CredentialProvider]

    public init(_ providers: [any CredentialProvider]) { self.providers = providers }

    public func load() throws -> OAuthCredential? {
        for p in providers { if let c = try p.load() { return c } }
        return nil
    }

    public static func standard(configDir: URL) -> ChainCredentialProvider {
        ChainCredentialProvider([
            FileCredentialProvider(url: configDir.appendingPathComponent(".credentials.json")),
            KeychainCLICredentialProvider(),
        ])
    }
}

/// 구독 로그인 없이 API 키만 쓰는지 판단한다(값은 읽지 않고 키 이름만 본다).
public enum AuthHints {
    /// Claude Code: `~/.claude.json`에 `primaryApiKey`가 있거나, 구독 계정(`oauthAccount`) 없이 승인한 API 키가 있으면 API 키 사용자.
    public static func claudeUsesAPIKey(claudeJSON: URL) -> Bool {
        guard let data = try? Data(contentsOf: claudeJSON),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if j["oauthAccount"] != nil { return false }
        if let k = j["primaryApiKey"] as? String, !k.isEmpty { return true }
        if let r = j["customApiKeyResponses"] as? [String: Any], let a = r["approved"] as? [Any], !a.isEmpty { return true }
        return false
    }

    /// Codex: `~/.codex/auth.json`의 `auth_mode`가 "apikey"면 API 키 사용자(구독은 "chatgpt").
    public static func codexUsesAPIKey(authJSON: URL) -> Bool {
        guard let data = try? Data(contentsOf: authJSON),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let mode = j["auth_mode"] as? String { return mode.lowercased() == "apikey" }
        return (j["OPENAI_API_KEY"] as? String).map { !$0.isEmpty } ?? false && j["tokens"] == nil
    }
}
