import Foundation

/// 使用统计 - 用于追踪 token 使用量和成本
/// 移植自 csm 的 UsageStats 数据类
public struct UsageStats: Codable, Hashable {
    public var turns: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreateTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var model: String = ""

    public init(
        turns: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreateTokens: Int = 0,
        cacheReadTokens: Int = 0,
        model: String = ""
    ) {
        self.turns = turns
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.cacheReadTokens = cacheReadTokens
        self.model = model
    }

    /// 总 token 数
    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// 预估成本 (USD)
    /// 基于 Claude Opus 4 定价:
    /// - Input: $15/M tokens
    /// - Output: $75/M tokens
    /// - Cache Create: $18.75/M tokens
    /// - Cache Read: $1.50/M tokens
    public var costUSD: Double {
        Double(inputTokens) * 15.0 / 1_000_000
        + Double(outputTokens) * 75.0 / 1_000_000
        + Double(cacheCreateTokens) * 18.75 / 1_000_000
        + Double(cacheReadTokens) * 1.5 / 1_000_000
    }

    /// 格式化成本字符串
    public var formattedCost: String {
        if costUSD < 0.01 {
            return String(format: "$%.4f", costUSD)
        } else if costUSD < 1 {
            return String(format: "$%.3f", costUSD)
        } else {
            return String(format: "$%.2f", costUSD)
        }
    }

    /// 格式化 token 数量
    public var formattedTokens: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        } else {
            return "\(totalTokens)"
        }
    }

    /// 格式化输入/输出 token
    public var formattedInOut: String {
        "\(formatTokenCount(inputTokens))/\(formatTokenCount(outputTokens))"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    /// 合并两个使用统计
    public static func + (lhs: UsageStats, rhs: UsageStats) -> UsageStats {
        UsageStats(
            turns: lhs.turns + rhs.turns,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreateTokens: lhs.cacheCreateTokens + rhs.cacheCreateTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            model: rhs.model.isEmpty ? lhs.model : rhs.model
        )
    }
}