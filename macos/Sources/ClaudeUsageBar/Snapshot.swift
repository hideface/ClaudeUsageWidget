import AppKit
import SwiftUI
import UsageCore

/// `ClaudeUsageBar --snapshot <폴더>`: 실제 데이터로 패널·설정·메뉴바 항목(①~④)을 PNG로 그리고 끝낸다(검증·문서용).
@MainActor
enum Snapshot {
    static func run(to dir: URL) async {
        // 사용자의 설정을 바꾸지 않도록 임시 저장소를 쓴다
        let settings = AppSettings(defaults: UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!)
        settings.showClaude = true
        settings.showCodex = true
        let store = UsageStore.live(settings: settings, offline: true)   // 실행 중인 앱과 상태 파일·API를 공유하지 않는다
        await store.refresh(force: false)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let bg = scheme == .light ? Color.white : Color(white: 0.16)
            save(PanelView(store: store).background(bg).environment(\.colorScheme, scheme), dir.appendingPathComponent("panel-\(name).png"))
            let items = VStack(alignment: .leading, spacing: 6) {
                ForEach(MenubarStyle.allCases) { style in
                    HStack(spacing: 10) {
                        Text(style.label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        HStack(spacing: 4) {
                            StatusItemController.imageView(store.display, style: style)
                            let t = StatusItemController.titleText(store.display, style: style)
                            if !t.isEmpty { Text(t).font(.system(size: 13).monospacedDigit()) }
                        }
                        .frame(height: 24)
                    }
                }
            }
            save(items.padding(10).background(bg).environment(\.colorScheme, scheme), dir.appendingPathComponent("menubar-\(name).png"))
            let seg = HStack(spacing: 12) {
                ForEach(Array(StatusItemController.segments(store, style: .donutNumbers).enumerated()), id: \.offset) { _, sg in
                    HStack(spacing: 4) {
                        sg.image
                        if !sg.text.isEmpty { Text(sg.text).font(.system(size: 13).monospacedDigit()) }
                    }
                }
            }
            .frame(height: 24)
            save(seg.padding(8).background(bg).environment(\.colorScheme, scheme), dir.appendingPathComponent("menubar-combined-\(name).png"))
            settings.compactPanel = true
            save(PanelView(store: store).background(bg).environment(\.colorScheme, scheme), dir.appendingPathComponent("panel-compact-\(name).png"))
            settings.compactPanel = false
            if scheme == .light {
                settings.showCodex = false
                save(PanelView(store: store).background(bg).environment(\.colorScheme, scheme), dir.appendingPathComponent("panel-claude-only.png"))
                settings.showCodex = true
                settings.showClaude = false
                save(PanelView(store: store).background(bg).environment(\.colorScheme, scheme), dir.appendingPathComponent("panel-codex-only.png"))
                settings.showClaude = true
            }
        }
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            saveViaWindow(SettingsView(settings: settings, onTestAlert: {}), appearance: scheme,
                          dir.appendingPathComponent("settings-\(scheme == .aqua ? "light" : "dark").png"))
        }
        print("snapshots → \(dir.path)")
    }

    /// AppKit이 그리는 컨트롤(Form 등)은 ImageRenderer로 안 그려져서, 화면 밖 창에 띄운 뒤 뜬다.
    private static func saveViaWindow(_ view: some View, appearance: NSAppearance.Name, _ url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.backgroundColor = appearance == .aqua ? .windowBackgroundColor : NSColor(white: 0.16, alpha: 1)
        w.contentView = host
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
    }

    private static func save(_ view: some View, _ url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
