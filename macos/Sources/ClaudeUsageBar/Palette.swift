import SwiftUI
import UsageCore

/// 색은 그래프(도넛)에만 쓴다(01-analysis-and-plan.md 3.4).
enum Palette {
    static let session = Color(hex: 0xD85A30)   // 5시간 · 코랄
    static let weekly = Color(hex: 0x7F77DD)    // 주간 · 보라
    static let model = Color(hex: 0x1D9E75)     // 모델별 주간 · 청록
    static let codex = Color(hex: 0x378ADD)     // Codex 전체 · 파랑
    static let warn = Color(hex: 0xBA7517)      // 70% 이상
    static let danger = Color(hex: 0xE24B4A)    // 90% 이상
    static let stale = Color(hex: 0x888780)     // 최신 값이 아님
    static let ok = Color(hex: 0x639922)

    static func color(for row: LimitRow, stale: Bool) -> Color {
        if stale { return Self.stale }
        if row.percent >= 90 { return danger }
        if row.percent >= 70 { return warn }
        switch row.kind {
        case .session: return session
        case .weekly: return weekly
        case .model: return model
        case .codex: return codex
        }
    }

    static func statusDot(_ s: FetchStatus) -> Color {
        switch s {
        case .ok: ok
        case .idle, .tokenExpired, .apiKeyOnly: Color.secondary.opacity(0.5)
        case .rateLimited, .error: warn
        case .auth, .noCredential: danger
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct Donut: View {
    var percent: Double
    var color: Color
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, percent / 100))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.6), value: percent)
    }
}
