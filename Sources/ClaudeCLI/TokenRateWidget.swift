import Foundation
import SwiftUI
import Meee2PluginKit

/// Claude Code token 速率 widget——挂在灵动岛 expandedTop slot 上的紧凑栅格，
/// 展示 in / out 两条速率各自的 1m / 1h / 1d 窗口值。
///
/// IslandWidget 协议要求实例稳定（host 不会重新构造），因此 monitor 由 ClaudePlugin
/// 持有，widget 只是绑定它的 view。
struct TokenRateWidget: IslandWidget {
    let monitor: TokenRateMonitor

    var id: String { "com.meee2.plugin.claude.tokenRate" }
    var pluginId: String { "com.meee2.plugin.claude" }
    var placement: IslandWidgetPlacement { .expandedTop }

    @MainActor
    func makeView() -> AnyView {
        AnyView(TokenRateWidgetView(monitor: monitor))
    }
}

private struct TokenRateWidgetView: View {
    @ObservedObject var monitor: TokenRateMonitor

    private let colWidth: CGFloat = 44

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左侧：图标 + 标题
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange.opacity(0.85))
                Text("Claude\ntok/s")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .lineSpacing(1)
            }

            Spacer(minLength: 4)

            // 右侧：3 列 × 3 行小栅格（header + in + out）
            VStack(alignment: .trailing, spacing: 2) {
                // 时间标签行
                HStack(spacing: 0) {
                    rowLabel("")
                    columnHeader("1m")
                    columnHeader("1h")
                    columnHeader("1d")
                }
                .padding(.bottom, 1)

                // in 行
                HStack(spacing: 0) {
                    rowLabel("in")
                    valueCell(monitor.rateMinIn)
                    valueCell(monitor.rateHourIn)
                    valueCell(monitor.rateDayIn)
                }

                // out 行
                HStack(spacing: 0) {
                    rowLabel("out")
                    valueCell(monitor.rateMinOut)
                    valueCell(monitor.rateHourOut)
                    valueCell(monitor.rateDayOut)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
        .padding(.horizontal, 8)
        .help("Total this session — in: \(monitor.totalIn.formatted())  out: \(monitor.totalOut.formatted())")
    }

    @ViewBuilder
    private func columnHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.4))
            .frame(width: colWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func rowLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.5))
            .frame(width: 28, alignment: .trailing)
            .padding(.trailing, 4)
    }

    @ViewBuilder
    private func valueCell(_ v: Double) -> some View {
        Text(formatRate(v))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.9))
            .frame(width: colWidth, alignment: .trailing)
    }

    /// 默认用 k 做单位，到 1M 才切到 M。小于 1k 也用 k（小数），统一可读。
    private func formatRate(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v <= 0 { return "0" }
        let k = v / 1000
        if k >= 10 { return String(format: "%.1fk", k) }   // 10k - 999.9k
        return String(format: "%.2fk", k)                   // 0.01k - 9.99k
    }
}
