import Foundation

/// AI 会话的使用统计 (来自 transcript 解析)
public struct UsageStats: Hashable, Codable {
    /// 输入 token 数
    public var inputTokens: Int?

    /// 输出 token 数
    public var outputTokens: Int?

    /// Cache 创建 token 数
    public var cacheCreateTokens: Int?

    /// Cache 读取 token 数
    public var cacheReadTokens: Int?

    /// 预估费用 (USD)
    public var estimatedCost: Double?

    /// 使用的模型名称
    public var model: String?

    /// 对话轮数
    public var turns: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreateTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        estimatedCost: Double? = nil,
        model: String? = nil,
        turns: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCost = estimatedCost
        self.model = model
        self.turns = turns
    }

    /// 总 token 数
    public var totalTokens: Int? {
        guard let input = inputTokens, let output = outputTokens else { return nil }
        return input + output
    }
}
