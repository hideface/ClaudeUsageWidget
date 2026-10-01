import Foundation
import Observation
import ServiceManagement
import UsageCore

enum MenubarStyle: Int, CaseIterable, Identifiable {
    case donut = 1          // ① 도넛만
    case donutActive = 2    // ② 도넛 + 숫자
    case threeDonuts = 3    // ③ 미니 도넛 3개
    case donutNumbers = 4   // ④ 도넛 + 숫자 3개

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .donut: "① 도넛만"
        case .donutActive: "② 도넛 + 숫자"
        case .threeDonuts: "③ 미니 도넛 3개"
        case .donutNumbers: "④ 도넛 + 숫자 3개"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var interval: TimeInterval { didSet { defaults.set(interval, forKey: "apiInterval") } }
    var menubarStyle: MenubarStyle { didSet { defaults.set(menubarStyle.rawValue, forKey: "menubarStyle") } }
    /// 표시할 서비스. 처음에는 `~/.claude`, `~/.codex/sessions`가 있는지로 정한다. 둘 다 끌 수는 없다.
    var showClaude: Bool { didSet { defaults.set(showClaude, forKey: "showClaude") } }
    var showCodex: Bool { didSet { defaults.set(showCodex, forKey: "showCodex") } }
    /// 패널을 도넛 대신 한도별 가로 막대로(원본 Windows 위젯의 '작게' 모드).
    var compactPanel: Bool { didSet { defaults.set(compactPanel, forKey: "compactPanel") } }
    /// 남은 시간 대신 리셋 시각을 보여 준다(도넛·막대 클릭으로 전환).
    var showAbsoluteReset: Bool { didSet { defaults.set(showAbsoluteReset, forKey: "showAbsoluteReset") } }
    /// CLI 토큰이 만료되면 CLI를 짧게 실행해 갱신(기본 꺼짐, 갱신마다 약 500토큰).
    var autoRefreshClaudeToken: Bool { didSet { defaults.set(autoRefreshClaudeToken, forKey: "autoRefreshClaudeToken") } }
    var alerts: AlertSettings {
        didSet { if let d = try? JSONEncoder().encode(alerts) { defaults.set(d, forKey: "alerts") } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let i = defaults.double(forKey: "apiInterval")
        interval = FetchPolicy.clamp(i > 0 ? i : 180)
        menubarStyle = MenubarStyle(rawValue: defaults.integer(forKey: "menubarStyle")) ?? .donutNumbers
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let hasClaude = FileManager.default.fileExists(atPath: env["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path)
        let hasCodex = FileManager.default.fileExists(atPath: (env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path) + "/sessions")
        let claude = defaults.object(forKey: "showClaude") as? Bool ?? (hasClaude || !hasCodex)
        let codex = defaults.object(forKey: "showCodex") as? Bool ?? hasCodex
        showClaude = claude || !codex
        showCodex = codex
        compactPanel = defaults.bool(forKey: "compactPanel")
        showAbsoluteReset = defaults.bool(forKey: "showAbsoluteReset")
        autoRefreshClaudeToken = defaults.bool(forKey: "autoRefreshClaudeToken")
        alerts = defaults.data(forKey: "alerts").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// 실패하면 이유를 돌려준다.
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            AppLog.write("[login-item] \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
