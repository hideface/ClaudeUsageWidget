import AppKit
import SwiftUI
import UsageCore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var store: UsageStore? = nil
    var onTestAlert: () -> Void
    @State private var loginOn = false
    @State private var loginError: String?

    private static let presets: [(Double, Double)] = [(80, 95), (85, 95), (90, 98)]

    var body: some View {
        Form {
            Section {
                Toggle("Claude", isOn: $settings.showClaude).disabled(settings.showClaude && !settings.showCodex)
                Toggle("Codex", isOn: $settings.showCodex).disabled(settings.showCodex && !settings.showClaude)
            } header: {
                Text("표시할 서비스")
            } footer: {
                Text("쓰지 않는 서비스는 끄세요. Claude를 끄면 키체인·사용량 API에 접근하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("CLI 토큰 자동 갱신", isOn: $settings.autoRefreshClaudeToken)
                    .disabled(!settings.showClaude)
                if let last = store?.lastRefresh {
                    LabeledContent("마지막 자동 갱신", value: RefreshText.describe(last))
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("CLI 토큰이 만료되면(약 8시간마다) 앱이 claude를 짧게 한 번 실행해 CLI가 스스로 토큰을 갱신하게 합니다. 갱신마다 약 500토큰을 씁니다. 끄면 데스크톱 앱 기록이나 마지막 값으로 보여 줍니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("일반") {
                Picker("메뉴바 표시", selection: $settings.menubarStyle) {
                    ForEach(MenubarStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("패널 크기", selection: $settings.compactPanel) {
                    Text("기본 (도넛)").tag(false)
                    Text("작게 (가로 막대)").tag(true)
                }
                Picker("Claude 한도 조회 주기", selection: $settings.interval) {
                    ForEach([120.0, 180, 300, 600], id: \.self) { Text("\(Int($0 / 60))분").tag($0) }
                }
                .disabled(!settings.showClaude)
                Toggle("로그인 시 자동 실행", isOn: Binding(get: { loginOn }, set: { on in
                    loginError = settings.setLaunchAtLogin(on)
                    loginOn = settings.launchAtLogin
                }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("알림") {
                Toggle("알림 켜기", isOn: $settings.alerts.enabled)
                Picker("기준치", selection: Binding(
                    get: { "\(Int(settings.alerts.warnPct))/\(Int(settings.alerts.dangerPct))" },
                    set: { v in
                        let p = v.split(separator: "/").compactMap { Double($0) }
                        if p.count == 2 { settings.alerts.warnPct = p[0]; settings.alerts.dangerPct = p[1] }
                    })) {
                    ForEach(Self.presets, id: \.0) { Text("경고 \(Int($0.0))% · 위험 \(Int($0.1))%").tag("\(Int($0.0))/\(Int($0.1))") }
                }
                .disabled(!settings.alerts.enabled)
                Toggle("사용 속도 예측 알림", isOn: $settings.alerts.pace).disabled(!settings.alerts.enabled)
                Toggle("추가 크레딧 사용 알림", isOn: $settings.alerts.credit).disabled(!settings.alerts.enabled)
                Button("알림 테스트", action: onTestAlert)
            }
            Section("정보") {
                LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                HStack {
                    Button("데이터 폴더 열기") { NSWorkspace.shared.open(AppLog.dataDir) }
                    Button("로그 열기") { NSWorkspace.shared.open(AppLog.url) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginOn = settings.launchAtLogin }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let store: UsageStore?
    private let onTestAlert: () -> Void

    init(settings: AppSettings, store: UsageStore? = nil, onTestAlert: @escaping () -> Void) {
        self.settings = settings
        self.store = store
        self.onTestAlert = onTestAlert
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, store: store, onTestAlert: onTestAlert))
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = "Claude Usage Bar 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
