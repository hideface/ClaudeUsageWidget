import SwiftUI
import UsageCore

/// 패널. 켜진 서비스마다 섹션 하나(Claude 위, Codex 아래, 사이에 패널 양끝까지 닿는 띠).
/// 섹션 = 머리줄 + 한도(기본: 큰 도넛 + 작은 도넛 / 작게: 한도별 가로 막대) + 크레딧·오늘 토큰 + 상태 줄.
/// 도넛·막대를 누르면 남은 시간 ↔ 리셋 시각이 바뀐다.
struct PanelView: View {
    let store: UsageStore
    var onOpenSettings: () -> Void = {}
    var onOpenData: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
        .frame(width: 280)
    }

    private var settings: AppSettings { store.settings }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let claude = settings.showClaude ? claudeSection(now: now) : nil
        let codex = settings.showCodex ? codexSection(now: now) : nil
        VStack(spacing: 0) {
            if let claude {
                section(claude, primary: true, controls: true, now: now)
            }
            if let codex {
                if claude != nil { sectionBreak }
                section(codex, primary: claude == nil, controls: claude == nil, now: now)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    /// 섹션 사이 경계: 섹션 안의 가는 구분선과 구별되도록 패널 양끝까지 닿는 옅은 띠.
    private var sectionBreak: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 6)
            .padding(.horizontal, -16).padding(.top, 12).padding(.bottom, 14)
    }

    // MARK: - 섹션 모델

    struct Section {
        var title: String
        var plan: String?
        var dot: Color?
        var rows: [LimitRow]
        var active: LimitRow?
        var stale: (LimitRow) -> Bool
        var stats: [(label: String, value: Text, help: String?)]
        /// 섹션 끝 상태 줄(문구, 경고색 여부)
        var note: (String, Bool)? = nil
        /// 한도가 없을 때 도넛 대신 보여 줄 문구(API 키 사용, 최근 기록 없음). nil이면 빈 도넛.
        var emptyText: String? = nil
    }

    private func claudeSection(now: Date) -> Section {
        let d = store.display
        let apiKey = d.status == .apiKeyOnly && d.rows.isEmpty
        let tokens: (label: String, value: Text, help: String?) = ("오늘 토큰", Text(Format.tokens(store.tokens.total)), claudeTokenHelp)
        return Section(title: "Claude", plan: apiKey ? "API 키" : d.plan, dot: Palette.statusDot(d.status), rows: d.rows,
                       active: d.active, stale: { d.isStale($0) },
                       stats: apiKey ? [tokens] : [("크레딧", credit(d.credit), nil), tokens],
                       note: claudeNote(d, now: now),
                       emptyText: apiKey ? "API 키로 쓰는 중이라 5시간·주간 한도가 없어요" : nil)
    }

    /// 자동 갱신을 켜 둔 경우 토큰 만료 안내를 그 상태에 맞게 바꾼다.
    private func claudeNote(_ d: DisplayState, now: Date) -> (String, Bool) {
        guard settings.autoRefreshClaudeToken, d.status == .tokenExpired else { return FooterText.make(d, now: now) }
        if let last = store.lastRefresh, last.result != .refreshed {
            return ("자동 갱신 실패 · \(RefreshText.reason(last.result))", true)
        }
        return ("CLI 토큰 만료 · 자동 갱신 중…", false)
    }

    private func codexSection(now: Date) -> Section? {
        guard settings.showCodex else { return nil }
        var stats: [(label: String, value: Text, help: String?)] = []
        if let cr = store.codex?.credits {
            stats.append(("크레딧", Text(cr.unlimited ? "무제한" : cr.balance ?? "-"), nil))
        }
        if let t = store.codexTokens {
            stats.append(("오늘 토큰", Text(Format.tokens(t.total)),
                          "입력 \(Format.tokens(t.input)) (캐시 \(Format.tokens(t.cachedInput))) · 출력 \(Format.tokens(t.output)) · 세션 \(t.sessions)개"))
        }
        guard let c = store.codex else {
            // 한도 기록이 없어도 섹션은 보인다: API 키 사용자, 또는 아직 Codex를 안 쓴 경우
            return Section(title: "Codex", plan: store.codexAPIKey ? "API 키" : nil, dot: nil, rows: [], active: nil,
                           stale: { _ in false }, stats: stats,
                           emptyText: store.codexAPIKey ? "API 키로 쓰는 중이라 구독 한도가 없어요" : "아직 Codex 한도 기록이 없어요")
        }
        let ago = Format.ago(c.asOf, now: now)
        return Section(title: "Codex", plan: c.plan, dot: nil, rows: c.rows, active: c.active,
                       stale: { _ in c.isStale }, stats: stats,
                       note: c.isStale ? ("\(ago) 값 · Codex를 쓰면 갱신돼요", true) : ("\(ago) 사용", false))
    }

    // MARK: - 섹션 그리기

    @ViewBuilder
    private func section(_ s: Section, primary: Bool, controls: Bool, now: Date) -> some View {
        VStack(spacing: 0) {
            header(s, controls: controls)
            if s.rows.isEmpty, let empty = s.emptyText {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, primary ? 20 : 10)
            } else if settings.compactPanel {
                VStack(spacing: 10) { ForEach(s.rows) { bar($0, stale: s.stale($0), now: now) } }
                    .padding(.top, 12).padding(.bottom, 12)
            } else {
                if primary { hero(s, now: now).padding(.top, 16).padding(.bottom, 14) }
                else { sideHero(s, now: now).padding(.top, 12).padding(.bottom, 4) }
                let others = s.rows.filter { $0.id != s.active?.id }
                if !others.isEmpty {
                    Divider()
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              spacing: 12) {
                        ForEach(others) { small($0, stale: s.stale($0), now: now) }
                    }
                    .padding(.vertical, 12)
                }
            }
            // 두 번째 섹션(기본 모드)은 통계를 도넛 오른쪽에 붙였으므로 따로 줄을 두지 않는다
            if !s.stats.isEmpty && (primary || settings.compactPanel || s.rows.isEmpty) {
                Divider()
                HStack(alignment: .top) {
                    ForEach(Array(s.stats.enumerated()), id: \.offset) { _, st in
                        stat(st.label, st.value).help(st.help ?? "")
                    }
                }
                .padding(.top, 12)
            }
            if let (text, warn) = s.note {
                footerLine(text, warn: warn).frame(maxWidth: .infinity).padding(.top, 12)
            }
        }
    }

    private func header(_ s: Section, controls: Bool) -> some View {
        HStack(spacing: 6) {
            Text(s.title).font(.system(size: 14, weight: .medium))
            if let plan = s.plan { Text(plan).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            if let dot = s.dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if controls {
                Button { Task { await store.refresh(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: store.isRefreshing)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("지금 갱신")
                .padding(.leading, 4)
                Menu {
                    Button("지금 갱신") { Task { await store.refresh(force: true) } }
                    Button("설정…", action: onOpenSettings)
                    Button("데이터 폴더 열기", action: onOpenData)
                    Divider()
                    Button("종료", action: onQuit)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 추정 표시: 5시간 창을 기록으로 추정했으면 "약", 리셋이 지나 0%로 본 값이면 "리셋됨(추정)".
    private func resetText(_ r: LimitRow, now: Date) -> String {
        if r.percentInferred == true { return "리셋됨(추정)" }
        let approx = r.resetEstimated == true ? "약 " : ""
        if settings.showAbsoluteReset, let at = Format.resetAt(r.resetsAt) { return "\(approx)\(at) 리셋" }
        if let left = Format.left(until: r.resetsAt, now: now) { return left == "곧" ? "곧 리셋" : "\(approx)\(left) 후 리셋" }
        return r.kind.isCodex ? "리셋됨" : "리셋 시각 모름"
    }

    private func shortReset(_ r: LimitRow, now: Date) -> String {
        if r.percentInferred == true { return "리셋됨(추정)" }
        let approx = r.resetEstimated == true ? "약 " : ""
        if settings.showAbsoluteReset, let at = Format.resetAt(r.resetsAt, short: true) { return approx + at }
        return Format.left(until: r.resetsAt, now: now).map { approx + $0 } ?? "-"
    }

    private func toggleReset() { settings.showAbsoluteReset.toggle() }

    @ViewBuilder
    private func hero(_ s: Section, now: Date) -> some View {
        if let a = s.active {
            VStack(spacing: 10) {
                ZStack {
                    Donut(percent: a.percent, color: Palette.color(for: a, stale: s.stale(a)), lineWidth: 13)
                    VStack(spacing: 2) {
                        Text("\(Format.percent(a.percent))%").font(.system(size: 30, weight: .medium)).monospacedDigit()
                        Text(a.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                }
                .frame(width: 132, height: 132)
                Text(resetText(a, now: now)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle()).onTapGesture(perform: toggleReset)
        } else {
            VStack(spacing: 10) {
                Donut(percent: 0, color: Palette.stale, lineWidth: 13).frame(width: 132, height: 132)
                Text("아직 데이터가 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// 두 번째 섹션용: 도넛과 그 아래 이름·리셋, 오른쪽에 통계(오늘 토큰 등).
    @ViewBuilder
    private func sideHero(_ s: Section, now: Date) -> some View {
        if let a = s.active {
            // 도넛 칸을 섹션 폭의 절반으로 두어, 오른쪽 통계가 위 섹션의 두 번째 칸(오늘 토큰)과 같은 줄에 선다
            HStack(alignment: .center, spacing: 0) {
                VStack(spacing: 6) {
                    ZStack {
                        Donut(percent: a.percent, color: Palette.color(for: a, stale: s.stale(a)), lineWidth: 8)
                        Text("\(Format.percent(a.percent))%").font(.system(size: 18, weight: .medium)).monospacedDigit()
                    }
                    .frame(width: 76, height: 76)
                    VStack(spacing: 1) {
                        Text(a.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Text(resetText(a, now: now)).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle()).onTapGesture(perform: toggleReset)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(s.stats.enumerated()), id: \.offset) { _, st in
                        stat(st.label, st.value).help(st.help ?? "")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func small(_ r: LimitRow, stale: Bool, now: Date) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Donut(percent: r.percent, color: Palette.color(for: r, stale: stale), lineWidth: 5)
                Text(Format.percent(r.percent)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.system(size: 12)).lineLimit(1)
                Text(shortReset(r, now: now)).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .contentShape(Rectangle()).onTapGesture(perform: toggleReset)
    }

    /// 작게 모드: 이름 … 남은 시간 %  + 가로 막대
    private func bar(_ r: LimitRow, stale: Bool, now: Date) -> some View {
        let color = Palette.color(for: r, stale: stale)
        return VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(shortReset(r, now: now)).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                Text("\(Format.percent(r.percent))%").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.16))
                    Capsule().fill(color).frame(width: max(5, g.size.width * r.percent / 100))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.6), value: r.percent)
        }
        .contentShape(Rectangle()).onTapGesture(perform: toggleReset)
    }

    private func stat(_ label: String, _ value: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            value.font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func credit(_ c: Credit?) -> Text {
        guard let c, c.enabled, let used = Format.money(c.used, currency: c.currency) else { return Text("사용 안 함") }
        if let limit = Format.money(c.limit, currency: c.currency) {
            return Text(used) + Text(" / \(limit)").font(.system(size: 11, weight: .regular)).foregroundColor(.secondary)
        }
        return Text(used)
    }

    private var claudeTokenHelp: String {
        let t = store.tokens
        return "입력 \(Format.tokens(t.input)) · 출력 \(Format.tokens(t.output)) · 캐시 쓰기 \(Format.tokens(t.cacheWrite)) · 캐시 읽기 \(Format.tokens(t.cacheRead)) · 메시지 \(t.messages)건"
    }

    // MARK: - 상태 줄

    private func footerLine(_ text: String, warn: Bool) -> some View {
        Text(text)
            .font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(warn ? AnyShapeStyle(Palette.warn) : AnyShapeStyle(.tertiary))
            .multilineTextAlignment(.center)
    }
}

extension LimitKind {
    var isCodex: Bool { if case .codex = self { true } else { false } }
}

enum FooterText {
    /// (문구, 경고색 여부)
    static func make(_ d: DisplayState, now: Date) -> (String, Bool) {
        let ago = d.asOf.map { Format.ago($0, now: now) }
        let stale = !d.staleRowIDs.isEmpty && d.staleRowIDs.count == d.rows.count
        switch d.status {
        case .rateLimited(let until):
            let wait = Format.left(until: until, now: now) ?? "잠시"
            return ("호출 제한 · \(wait) 뒤 재시도" + (ago.map { " · \($0) 값" } ?? ""), true)
        case .error(let m):
            return ("조회 실패(\(m))" + (ago.map { " · \($0) 값" } ?? ""), true)
        case .auth:
            return ("인증 실패 · 터미널에서 claude 다시 로그인", true)
        case .apiKeyOnly where d.rows.isEmpty:
            return ("API 키 사용 중 · 오늘 토큰만 집계해요", false)
        case .noCredential where d.source != .desktopHistory:
            return ("Claude Code CLI 로그인이 필요해요", true)
        case .tokenExpired where d.source != .desktopHistory:
            return ("CLI 토큰 만료 · 터미널에서 claude를 실행하면 갱신돼요", true)
        default:
            break
        }
        if d.source == .desktopHistory {
            let base = "데스크톱 앱 기록 · \(ago ?? "-")"
            return (stale ? base + " 값" : base, stale)
        }
        if let ago { return (stale ? "\(ago) 값" : "\(ago) 갱신", stale) }
        return ("불러오는 중…", false)
    }
}

enum RefreshText {
    static func reason(_ r: RefreshResult) -> String {
        switch r {
        case .refreshed: "성공"
        case .cliNotFound: "claude CLI를 찾지 못했어요"
        case .failed(let m): "CLI 실행 실패(\(m)) · 터미널에서 claude 로그인 확인"
        }
    }

    static func describe(_ a: RefreshAttempt) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return "\(f.string(from: a.at)) \(reason(a.result))"
    }
}
