import Foundation

/// CardTemplateStore —— 用户自定义卡片模板的磁盘存储
///
/// 布局：`~/.meee2/card-templates/<id>.tsx`
///
/// 约束：
/// - ID 正则：`^[a-z0-9][a-z0-9-]{0,63}$`
/// - 单个模板最大 64 KB
/// - 约定：`default-<pluginSuffix>.tsx` 为某 plugin 的默认模板
///
/// 所有公开方法线程安全（通过串行队列互斥）。保存 / 删除成功后发布
/// `SessionEvent.cardTemplateChanged(id:)` 到 `SessionEventBus`，供 BoardServer
/// 触发 WS broadcast。
public final class CardTemplateStore {
    public static let shared = CardTemplateStore()

    /// 单条模板 DTO（对外 JSON 响应使用）
    public struct Entry: Encodable {
        public let id: String
        public let source: String
        public let updatedAt: Date
        public let sizeBytes: Int
    }

    /// 最大源文件字节数（64 KB）
    public static let maxSourceBytes: Int = 64 * 1024

    /// ID 合法性校验正则：首字符必须 [a-z0-9]，长度 1..64
    private static let idPattern = "^[a-z0-9][a-z0-9-]{0,63}$"

    private let fileManager = FileManager.default
    private let dir: URL
    private let queue = DispatchQueue(label: "com.meee2.CardTemplateStore", qos: .utility)

    private init() {
        let home = NSHomeDirectory()
        self.dir = URL(fileURLWithPath: home)
            .appendingPathComponent(".meee2")
            .appendingPathComponent("card-templates")
        // 创建目录（若不存在）
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            MWarn("[CardTemplateStore] failed to create dir \(dir.path): \(error)")
        }
    }

    // MARK: - Public API

    /// 列出全部模板，按 updatedAt 降序（newest-first）
    public func list() -> [Entry] {
        queue.sync {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            var entries: [Entry] = []
            for url in files where url.pathExtension == "tsx" {
                let id = url.deletingPathExtension().lastPathComponent
                guard Self.isValidId(id) else { continue }
                guard let entry = loadEntryLocked(id: id, url: url) else { continue }
                entries.append(entry)
            }
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// 按 id 读取模板
    public func get(_ id: String) -> Entry? {
        queue.sync {
            guard Self.isValidId(id) else { return nil }
            let url = fileURL(for: id)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return loadEntryLocked(id: id, url: url)
        }
    }

    /// 保存（创建或覆盖）模板；成功后发布 `.cardTemplateChanged(id:)`
    @discardableResult
    public func save(_ id: String, source: String) throws -> Entry {
        guard Self.isValidId(id) else { throw CardTemplateError.invalidId(id) }
        let data = Data(source.utf8)
        if data.count > Self.maxSourceBytes {
            throw CardTemplateError.tooLarge
        }

        let entry: Entry = try queue.sync {
            // 目录可能在 init 之后被删除；保险起见再确保一次
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

            let target = fileURL(for: id)
            // 原子写入：写入 .tmp.<pid> 再 rename
            let pid = ProcessInfo.processInfo.processIdentifier
            let tmp = target.appendingPathExtension("tmp.\(pid)")

            // 清理可能残留的 tmp
            try? fileManager.removeItem(at: tmp)
            try data.write(to: tmp, options: [.atomic])

            // rename 覆盖；FileManager.moveItem 在目标存在时会抛错，所以先删目标
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: tmp, to: target)

            guard let saved = loadEntryLocked(id: id, url: target) else {
                // 兜底：文件写入成功但无法读取属性；用当前时间重建
                return Entry(
                    id: id,
                    source: source,
                    updatedAt: Date(),
                    sizeBytes: data.count
                )
            }
            return saved
        }

        SessionEventBus.shared.publish(.cardTemplateChanged(id: id))
        MInfo("[CardTemplateStore] saved template id=\(id) size=\(entry.sizeBytes)B")
        return entry
    }

    /// 删除模板；成功后发布 `.cardTemplateChanged(id:)`
    public func delete(_ id: String) throws {
        guard Self.isValidId(id) else { throw CardTemplateError.invalidId(id) }

        try queue.sync {
            let target = fileURL(for: id)
            guard fileManager.fileExists(atPath: target.path) else {
                throw CardTemplateError.notFound(id)
            }
            try fileManager.removeItem(at: target)
        }

        SessionEventBus.shared.publish(.cardTemplateChanged(id: id))
        MInfo("[CardTemplateStore] deleted template id=\(id)")
    }

    // MARK: - 内部

    /// 校验 ID 是否合法
    static func isValidId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.range(of: idPattern, options: .regularExpression) != nil
    }

    private func fileURL(for id: String) -> URL {
        dir.appendingPathComponent("\(id).tsx")
    }

    /// 读取文件内容 + 元数据为 Entry；出错时返回 nil。必须在 queue 内调用。
    private func loadEntryLocked(id: String, url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let source = String(data: data, encoding: .utf8) ?? ""
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let updatedAt = (attrs?[.modificationDate] as? Date) ?? Date()
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? data.count
        return Entry(id: id, source: source, updatedAt: updatedAt, sizeBytes: size)
    }
}

/// CardTemplateStore 抛出的错误
public enum CardTemplateError: Error, Equatable {
    /// ID 不合法（不符合 `[a-z0-9][a-z0-9-]{0,63}` 或长度超限）
    case invalidId(String)
    /// 对应 id 的模板不存在
    case notFound(String)
    /// 源文件超过 64 KB
    case tooLarge
}
