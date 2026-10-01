import AppKit
import SwiftUI
import UsageCore

/// 메뉴바 항목 하나. 켜진 서비스마다 [도넛 + 숫자] 조각을 이어 붙인다: `◔ 13 · 27 · 11  ◔ 45`
/// - Claude 조각은 설정의 형식(①~④)을 따르고, Codex 조각은 도넛 + 가장 높은 %(①·③이면 도넛만)
/// - 노치 뒤로 가려지면 한 단계 줄이고(③·④ → ②, ② → ①: 숫자 없이 도넛만), 10분마다·화면 구성이 바뀔 때 다시 넓혀 본다
/// - 도넛은 텍스트 안의 이미지 첨부로 넣어서, 글자색은 메뉴바 밝기에 맞춰 시스템이 정한다
@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let openSettings: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var compact = false
    /// 시작 직후 창이 뜨기 전에도 '안 보임' 알림이 와서, 한 번 보인 뒤부터만 판단한다.
    private var hasBeenVisible = false
    private var lastExpandTry = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    /// 마지막으로 그린 내용. 같으면 다시 그리지 않는다(10초마다 호출됨).
    private var lastSignature = ""

    init(store: UsageStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        super.init()

        let host = NSHostingController(rootView: PanelView(
            store: store,
            onOpenSettings: { [weak self] in self?.popover.performClose(nil); openSettings() },
            onOpenData: { NSWorkspace.shared.open(AppLog.dataDir) },
            onQuit: { NSApp.terminate(nil) }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .noImage
        }
        render()

        let nc = NotificationCenter.default
        if let w = item.button?.window {
            observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.occlusionChanged() }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryExpand() }
        })
    }

    var effectiveStyle: MenubarStyle {
        let s = store.settings.menubarStyle
        guard compact else { return s }
        return s.rawValue >= MenubarStyle.threeDonuts.rawValue ? .donutActive : .donut
    }

    /// 메뉴바에 보이는 값만 모은 문자열(%, 색을 정하는 상태, 형식, 서비스). 바뀌었을 때만 다시 그린다.
    private func signature(style: MenubarStyle) -> String {
        var parts = ["\(style.rawValue)", "\(store.settings.showClaude)", "\(store.settings.showCodex)",
                     "\(NSScreen.main?.backingScaleFactor ?? 2)"]
        if store.settings.showClaude {
            let d = store.display
            parts += d.rows.map { "\($0.id)=\(Format.percent($0.percent)):\(d.isStale($0))" } + ["a=\(d.active?.id ?? "")"]
        }
        if store.settings.showCodex, let c = store.codex {
            parts += c.rows.map { "\($0.id)=\(Format.percent($0.percent))" } + ["cs=\(c.isStale)"]
        }
        return parts.joined(separator: "|")
    }

    func render() {
        guard let b = item.button else { return }
        b.toolTip = tooltip()
        if compact, Date().timeIntervalSince(lastExpandTry) > 600 { tryExpand(); return }
        let style = effectiveStyle
        let sig = signature(style: style)
        guard sig != lastSignature else { return }
        lastSignature = sig
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let segs = Self.segments(store, style: style)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let out = NSMutableAttributedString()
        for (i, seg) in segs.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            if let img = Self.render(seg.image, scale: scale) {
                let a = NSTextAttachment()
                a.image = img
                a.bounds = CGRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
                out.append(NSAttributedString(attachment: a))
            }
            if !seg.text.isEmpty { out.append(NSAttributedString(string: " " + seg.text, attributes: [.font: font])) }
        }
        b.image = nil
        b.attributedTitle = out
    }

    func showPanel() {
        guard let b = item.button, !popover.isShown else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.refresh(force: false) }
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if store.settings.showClaude {
            let d = store.display
            let parts = d.rows.map { "\($0.name) \(Format.percent($0.percent))%" }
            let empty = d.status == .apiKeyOnly ? "API 키 사용 중(구독 한도 없음)" : "데이터 없음"
            lines.append("Claude  " + (parts.isEmpty ? empty : parts.joined(separator: " · "))
                         + (d.source == .desktopHistory ? " (데스크톱 앱 기록)" : ""))
        }
        if store.settings.showCodex {
            if let c = store.codex {
                lines.append("Codex  " + c.rows.map { "\($0.name) \(Format.percent($0.percent))%" }.joined(separator: " · ")
                             + (c.isStale ? " (\(Format.ago(c.asOf, now: Date())) 값)" : ""))
            } else {
                lines.append("Codex  최근 기록 없음")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 조각 (스냅샷 모드도 같은 함수를 쓴다)

    struct Segment {
        var image: AnyView
        var text: String
    }

    static func segments(_ store: UsageStore, style: MenubarStyle) -> [Segment] {
        var out: [Segment] = []
        if store.settings.showClaude {
            out.append(Segment(image: imageView(store.display, style: style), text: titleText(store.display, style: style)))
        }
        if store.settings.showCodex, let c = store.codex {
            out.append(Segment(image: AnyView(codexImageView(c)), text: codexTitle(c, style: style)))
        }
        if out.isEmpty {
            out.append(Segment(image: AnyView(Donut(percent: 0, color: Palette.stale, lineWidth: 2.6).frame(width: 15, height: 15)),
                               text: "–"))
        }
        return out
    }

    static func titleText(_ d: DisplayState, style: MenubarStyle) -> String {
        guard let a = d.active else { return style == .donut || style == .threeDonuts ? "" : "–" }
        switch style {
        case .donut, .threeDonuts: return ""
        case .donutActive: return "\(Format.percent(a.percent))%"
        case .donutNumbers:
            return [d.fiveHour?.percent, d.weekly?.percent, d.models.first?.percent]
                .compactMap { $0 }.map(Format.percent).joined(separator: " · ")
        }
    }

    static func imageView(_ d: DisplayState, style: MenubarStyle) -> AnyView {
        func color(_ r: LimitRow?) -> Color { r.map { Palette.color(for: $0, stale: d.isStale($0)) } ?? Palette.stale }
        if style == .threeDonuts {
            let rows: [LimitRow?] = [d.fiveHour, d.weekly, d.models.first]
            return AnyView(HStack(spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Donut(percent: r?.percent ?? 0, color: color(r), lineWidth: 2.4).frame(width: 13, height: 13)
                }
            })
        }
        return AnyView(Donut(percent: d.active?.percent ?? 0, color: color(d.active), lineWidth: 2.6).frame(width: 15, height: 15))
    }

    static func codexTitle(_ c: CodexDisplay, style: MenubarStyle) -> String {
        guard let a = c.active, style != .donut, style != .threeDonuts else { return "" }
        return style == .donutActive ? "\(Format.percent(a.percent))%" : Format.percent(a.percent)
    }

    static func codexImageView(_ c: CodexDisplay) -> some View {
        let a = c.active
        return Donut(percent: a?.percent ?? 0, color: a.map { Palette.color(for: $0, stale: c.isStale) } ?? Palette.stale,
                     lineWidth: 2.6).frame(width: 15, height: 15)
    }

    static func render(_ view: AnyView, scale: CGFloat) -> NSImage? {
        let r = ImageRenderer(content: view)
        r.scale = scale
        let img = r.nsImage
        img?.isTemplate = false
        return img
    }

    // MARK: - 노치 대응

    private func occlusionChanged() {
        guard let w = item.button?.window else { return }
        let visible = w.occlusionState.contains(.visible)
        if visible { hasBeenVisible = true; return }
        guard hasBeenVisible, !compact, store.settings.menubarStyle != .donut else { return }
        compact = true
        AppLog.write("[menubar] status item hidden (notch?) → compact")
        render()
    }

    private func tryExpand() {
        guard compact else { return }
        lastExpandTry = Date()
        compact = false
        render()
        // 넓힌 뒤에도 가려지면 occlusionChanged가 다시 줄인다
    }

    // MARK: - 클릭

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "지금 갱신", action: #selector(refreshNow), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "설정…", action: #selector(settingsClicked), keyEquivalent: ",").target = self
            menu.addItem(withTitle: "데이터 폴더 열기", action: #selector(openData), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    @objc private func refreshNow() { Task { await store.refresh(force: true) } }
    @objc private func settingsClicked() { openSettings() }
    @objc private func openData() { NSWorkspace.shared.open(AppLog.dataDir) }
}
