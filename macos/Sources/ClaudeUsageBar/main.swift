import AppKit
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var status: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        let settings = AppSettings()
        let store = UsageStore.live(settings: settings)
        let notifier = self.notifier
        let settingsWindow = SettingsWindowController(settings: settings, store: store, onTestAlert: {
            Task { await notifier.post(AlertEvent(kind: .danger, title: "5시간 한도 95%",
                                                  body: "알림 테스트예요 · 실제 한도가 이 정도면 이렇게 알려 드려요.")) }
        })
        let status = StatusItemController(store: store, openSettings: { settingsWindow.show() })

        store.onChange = { [weak status] in status?.render() }
        store.onAlerts = { events in
            Task { for e in events { await notifier.post(e) } }
        }
        observeStyle(settings, status)
        notifier.setup()
        notifier.onClick = { [weak status] in status?.showPanel() }

        self.store = store
        self.status = status
        self.settingsWindow = settingsWindow
        AppLog.write("[app] started")
        if CommandLine.arguments.contains("--simulate-expired-token") {
            AppLog.write("[app] check mode: simulate expired CLI token once (auto refresh \(settings.autoRefreshClaudeToken ? "on" : "off"))")
            store.simulateExpiredOnce = true
        }
        store.start()
    }

    /// 메뉴바 형식·표시할 서비스가 바뀌면 다시 읽고 다시 그린다.
    private func observeStyle(_ settings: AppSettings, _ status: StatusItemController) {
        withObservationTracking({ _ = (settings.menubarStyle, settings.showClaude, settings.showCodex) }, onChange: { [weak self, weak status] in
            Task { @MainActor in
                guard let status else { return }
                status.render()
                await self?.store?.refresh(force: false)
                self?.observeStyle(settings, status)
            }
        })
    }
}

let args = CommandLine.arguments
// 점검용: 자동 갱신과 같은 조건으로 CLI를 한 번 실행해 결과를 출력한다(약 500토큰)
if args.contains("--test-refresh") {
    let home = FileManager.default.homeDirectoryForCurrentUser
    print("CLI:", ClaudeCLIRefresher.findCLI(home: home) ?? "찾지 못함")
    Task {
        let r = await ClaudeCLIRefresher(home: home, workDir: AppLog.dataDir.appendingPathComponent("cli-refresh")).refresh()
        print("결과:", r)
        exit(r == .refreshed ? 0 : 1)
    }
    RunLoop.main.run()
}
if let i = args.firstIndex(of: "--snapshot") {
    let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "snapshots")
    Task { @MainActor in
        await Snapshot.run(to: dir)
        exit(0)
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
