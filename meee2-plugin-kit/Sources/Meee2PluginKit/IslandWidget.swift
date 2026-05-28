import Foundation
import SwiftUI

/// 灵动岛上 widget 的位置。host 按 placement 决定渲染到哪一段。
/// 现在先开两个口子：`expandedTop` = 展开面板里、session 列表上方（适合速率、汇总）；
/// `expandedBottom` = 列表下方（适合 footer 状态条）。`compact` 留给未来想往刘海里塞东西
/// 的场景，host 暂时可以忽略。
public enum IslandWidgetPlacement: String, Codable, Sendable, CaseIterable {
    case compact
    case expandedTop
    case expandedBottom
}

/// 灵动岛 UI widget。Plugin 通过 `SessionPlugin.widgets` 注册一组 widget，
/// PluginManager 聚合后由 IslandView 在对应 slot 渲染。
///
/// 设计取舍：widget 只暴露 `makeView()` 返回 type-erased `AnyView`，把 host 跟 plugin
/// 的 SwiftUI 类型解耦——plugin 想用自己的 ObservableObject 做反应式数据流就在 view 内部
/// `@ObservedObject` 绑定，host 不参与。
public protocol IslandWidget {
    /// 全局唯一 id（建议 `<pluginId>.<widgetName>`），用作 ForEach 的 stable key。
    var id: String { get }

    /// 所属插件，方便后续按 plugin 启停过滤。
    var pluginId: String { get }

    /// 渲染位置。
    var placement: IslandWidgetPlacement { get }

    /// 构造 SwiftUI 视图。host 在主线程上调用。
    @MainActor func makeView() -> AnyView
}
