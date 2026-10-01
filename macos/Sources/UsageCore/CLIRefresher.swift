import Foundation

public enum RefreshResult: Sendable, Equatable {
    case refreshed
    case cliNotFound
    case failed(String)
}

public protocol TokenRefreshing: Sendable {
    func refresh() async -> RefreshResult
}

/// CLI 토큰이 만료됐을 때 Claude Code CLI를 짧게 한 번 실행해, CLI가 스스로 토큰을 갱신하게 한다(설정에서 켤 때만).
/// 앱은 토큰을 직접 갱신하거나 키체인에 쓰지 않는다. 갱신은 모델 호출이 있어야 일어나므로(`claude auth status`로는 안 됨)
/// 가장 싼 조합으로 부른다: Haiku, 짧은 시스템 프롬프트, 도구·MCP·슬래시 명령 끔, 세션 저장 안 함 → 약 500토큰.
public struct ClaudeCLIRefresher: TokenRefreshing {
    public var home: URL
    /// CLI를 실행할 고정 폴더. 혹시 CLI가 흔적을 남겨도 `~/.claude/projects`에 폴더 하나로만 모인다.
    public var workDir: URL
    public var timeout: TimeInterval = 60

    public init(home: URL, workDir: URL) {
        self.home = home
        self.workDir = workDir
    }

    static let arguments = ["-p", "OK", "--model", "haiku", "--system-prompt", "Reply with OK.",
                            "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                            "--disable-slash-commands"]

    /// 메뉴바 앱은 터미널의 PATH를 모르므로 흔한 설치 위치를 직접 찾는다.
    public static func findCLI(home: URL, fileManager fm: FileManager = .default) -> String? {
        var candidates = [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude",
                          ".volta/bin/claude"].map { home.appendingPathComponent($0).path }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvm.path) {
            candidates += versions.sorted().reversed().map { nvm.appendingPathComponent("\($0)/bin/claude").path }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public func refresh() async -> RefreshResult {
        guard let cli = Self.findCLI(home: home) else { return .cliNotFound }
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = Self.arguments
        p.currentDirectoryURL = workDir
        // 최소 환경: 다른 Claude 세션의 환경변수(CLAUDECODE 등)를 물려받지 않게 한다
        let cliDir = URL(fileURLWithPath: cli).deletingLastPathComponent().path
        p.environment = ["HOME": home.path, "USER": NSUserName(), "PATH": "\(cliDir):/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        let timeout = self.timeout
        return await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                let code = proc.terminationStatus
                cont.resume(returning: code == 0 ? .refreshed : .failed("exit \(code)"))
            }
            do { try p.run() } catch {
                p.terminationHandler = nil
                cont.resume(returning: .failed(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }   // 종료되면 terminationHandler가 결과를 돌려준다
            }
        }
    }
}
