import Foundation
import CryptoKit

enum PlannerArtifactPayloadType: String, Codable, Equatable, CaseIterable {
    case text
    case html
    case kanban
    case integration
    case json
    case file
}

enum PlannerArtifactStorage {
    static let inlinePayloadLimitBytes = 64 * 1024
    private static let scheme = "meee2-artifact://"

    static func normalizePayload(
        _ payload: BoardJSONValue?,
        canvasId: String,
        artifactId: String,
        workspacePath: String?
    ) throws -> BoardJSONValue? {
        guard let payload else { return nil }
        guard var object = payload.objectValue else {
            try enforceInlineLimit(payload, type: nil)
            return payload
        }

        if let file = object["file"]?.objectValue,
           let rawPath = file["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            let cwd = file["cwd"]?.stringValue
            let mimeType = file["mimeType"]?.stringValue
                ?? file["mime_type"]?.stringValue
                ?? inferMimeType(path: rawPath)
            let preferredName = file["name"]?.stringValue
            let imported = try importFile(
                rawPath,
                canvasId: canvasId,
                artifactId: artifactId,
                cwd: cwd,
                workspacePath: workspacePath,
                preferredName: preferredName
            )
            object["file"] = nil
            if object["type"] == nil {
                object["type"] = .string(payloadType(forMimeType: mimeType, filename: imported.filename).rawValue)
            }
            object["blobRef"] = .string(imported.blobRef)
            object["filename"] = .string(imported.filename)
            object["mimeType"] = .string(mimeType)
            object["size"] = .number(Double(imported.size))
            object["sha256"] = .string(imported.sha256)
            return .object(object)
        }

        try enforceInlineLimit(.object(object), type: object["type"]?.stringValue)
        return .object(object)
    }

    static func content(for artifact: PlannerArtifact) throws -> PlannerArtifactContent {
        let payload = artifact.payload
        let object = payload?.objectValue
        let type = object?["type"]?.stringValue
            ?? defaultPayloadType(for: artifact).rawValue
        let mimeType = object?["mimeType"]?.stringValue ?? mimeType(forPayloadType: type)
        let size = object?["size"]?.intValue
        let sha256 = object?["sha256"]?.stringValue
        let filename = object?["filename"]?.stringValue

        if let blobRef = object?["blobRef"]?.stringValue {
            let url = try fileURL(forBlobRef: blobRef)
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
            return PlannerArtifactContent(
                artifactId: artifact.id,
                type: type,
                mimeType: mimeType,
                filename: filename ?? url.lastPathComponent,
                size: size ?? data.count,
                sha256: sha256,
                blobRef: blobRef,
                content: text,
                payload: nil
            )
        }

        return PlannerArtifactContent(
            artifactId: artifact.id,
            type: type,
            mimeType: mimeType,
            filename: filename,
            size: size,
            sha256: sha256,
            blobRef: nil,
            content: inlineContent(from: payload, type: type),
            payload: payload
        )
    }

    private static func enforceInlineLimit(_ payload: BoardJSONValue, type: String?) throws {
        if type == PlannerArtifactPayloadType.kanban.rawValue { return }
        let encoder = JSONEncoder()
        let bytes = (try? encoder.encode(payload).count) ?? inlinePayloadLimitBytes + 1
        if bytes > inlinePayloadLimitBytes {
            throw PlannerCoreError.invalidNodeOutput(
                "Artifact payload is \(bytes) bytes; payloads over \(inlinePayloadLimitBytes) bytes must be submitted as payload.file.path."
            )
        }
    }

    private static func importFile(
        _ rawPath: String,
        canvasId: String,
        artifactId: String,
        cwd: String?,
        workspacePath: String?,
        preferredName: String?
    ) throws -> (blobRef: String, filename: String, size: Int, sha256: String) {
        let source = try resolveSourceFile(rawPath, cwd: cwd, workspacePath: workspacePath)
        let filename = sanitizedFilename(preferredName) ?? sanitizedFilename(source.lastPathComponent) ?? "artifact"
        let directory = artifactDirectory(canvasId: canvasId, artifactId: artifactId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        let data = try Data(contentsOf: destination)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (
            blobRef: "\(scheme)\(canvasId)/\(artifactId)/\(filename)",
            filename: filename,
            size: data.count,
            sha256: digest
        )
    }

    private static func resolveSourceFile(
        _ rawPath: String,
        cwd: String?,
        workspacePath: String?
    ) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let base = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: base ?? FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PlannerCoreError.invalidNodeOutput("Artifact file does not exist: \(rawPath)")
        }
        let allowedRoots = [cwd, workspacePath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() }
        guard !allowedRoots.isEmpty else {
            throw PlannerCoreError.invalidNodeOutput("Artifact file submissions require a canvas workspace or payload.file.cwd.")
        }
        guard allowedRoots.contains(where: { isPath(resolved.path, inside: $0.path) }) else {
            throw PlannerCoreError.invalidNodeOutput("Artifact file must be inside the session cwd or canvas workspace.")
        }
        return resolved
    }

    private static func fileURL(forBlobRef blobRef: String) throws -> URL {
        guard blobRef.hasPrefix(scheme) else {
            throw PlannerCoreError.invalidNodeOutput("Unsupported artifact blobRef.")
        }
        let rest = String(blobRef.dropFirst(scheme.count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else {
            throw PlannerCoreError.invalidNodeOutput("Malformed artifact blobRef.")
        }
        let canvasId = parts[0]
        let artifactId = parts[1]
        let filename = parts.dropFirst(2).joined(separator: "-")
        return artifactDirectory(canvasId: canvasId, artifactId: artifactId).appendingPathComponent(filename)
    }

    private static func artifactDirectory(canvasId: String, artifactId: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(safePathComponent(canvasId), isDirectory: true)
            .appendingPathComponent(safePathComponent(artifactId), isDirectory: true)
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(normalizedRoot)
    }

    private static func sanitizedFilename(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let mapped = raw.map { char in
            char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" ? char : "-"
        }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_/ "))
        return value.isEmpty ? nil : value
    }

    private static func safePathComponent(_ raw: String) -> String {
        let mapped = raw.map { char in char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" ? char : "-" }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_/ "))
        return value.isEmpty ? "item" : value
    }

    private static func inferMimeType(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private static func payloadType(forMimeType mimeType: String, filename: String) -> PlannerArtifactPayloadType {
        if mimeType.contains("html") { return .html }
        if mimeType.contains("json") { return .json }
        if mimeType.hasPrefix("text/") || filename.lowercased().hasSuffix(".md") { return .text }
        return .file
    }

    private static func defaultPayloadType(for artifact: PlannerArtifact) -> PlannerArtifactPayloadType {
        if artifact.kind == .kanban { return .kanban }
        let ref = artifact.reference.lowercased()
        if ref.contains("://") || ref.hasPrefix("github:") || ref.hasPrefix("lark") { return .integration }
        return .text
    }

    private static func mimeType(forPayloadType type: String) -> String {
        switch type {
        case PlannerArtifactPayloadType.html.rawValue: return "text/html"
        case PlannerArtifactPayloadType.json.rawValue, PlannerArtifactPayloadType.kanban.rawValue: return "application/json"
        case PlannerArtifactPayloadType.text.rawValue: return "text/plain"
        default: return "application/octet-stream"
        }
    }

    private static func inlineContent(from payload: BoardJSONValue?, type: String) -> String? {
        guard let object = payload?.objectValue else {
            if case .string(let text)? = payload { return text }
            return nil
        }
        if type == PlannerArtifactPayloadType.html.rawValue {
            return object["html"]?.stringValue
        }
        if type == PlannerArtifactPayloadType.text.rawValue {
            return object["text"]?.stringValue
        }
        if type == PlannerArtifactPayloadType.json.rawValue {
            return object["json"]?.stringValue
        }
        return nil
    }
}

struct PlannerArtifactContent: Encodable {
    var artifactId: String
    var type: String
    var mimeType: String
    var filename: String?
    var size: Int?
    var sha256: String?
    var blobRef: String?
    var content: String?
    var payload: BoardJSONValue?
}

extension BoardJSONValue {
    var objectValue: [String: BoardJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
