import Foundation
import Swifter
import Meee2PluginKit

/// AttachmentsAPI —— 处理 `POST /api/sessions/:id/attachments`
///
/// 前端把粘贴/拖入的图片 base64 编码后作为 JSON body POST 上来，这里落盘到
/// `~/.meee2/attachments/<realSessionId>/<timestamp>-<short>.<ext>`，把绝对路径回给前端。
/// 前端下一步把 `@<path>` 拼在 `content` 前面走 inject 通道；Claude CLI 原生
/// 支持 `@/abs/path` 语法，会把该文件当作下一轮 user message 的附件读取。
///
/// 为什么是 base64 JSON 不是 multipart/form-data：Swifter 的 multipart 解析没
/// 暴露稳定 API，手撸边界解析又啰嗦且易错；图片 paste 一般 < 几 MB（10 MB 上限），
/// base64 的 33% 膨胀可以接受，JSON body 走 `Data(req.body)` 直接能拿。
enum AttachmentsAPI {
    /// 10 MB 上限（base64 解码后的原始字节数）
    static let maxBytes = 10 * 1024 * 1024

    /// POST /api/sessions/:id/attachments
    /// Body: `{"filename": "paste.png", "contentType": "image/png", "dataBase64": "..."}`
    /// 响应: 201 `{"path": "/abs/saved/path", "filename": "paste.png"}`
    static func upload(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return BoardAPI.errorResponse("bad_request", "missing session id", status: 400)
        }

        // short-id 匹配（和 injectToSession 同逻辑）
        let sessions = PluginManager.shared.sessions
        let match = sessions.first(where: { $0.id == sid })
            ?? sessions.first(where: { $0.id.hasPrefix(sid) })
        guard let session = match else {
            return BoardAPI.errorResponse("not_found", "session not found: \(sid)", status: 404)
        }

        // 和 inject 一样还原真实 sessionId（去掉 pluginId 前缀）
        let realSessionId = session.id.hasPrefix("\(session.pluginId)-")
            ? String(session.id.dropFirst("\(session.pluginId)-".count))
            : session.id

        guard let json = BoardAPI.parseJSONBody(req) else {
            return BoardAPI.errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }

        guard let filenameRaw = json["filename"] as? String, !filenameRaw.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing 'filename'", status: 400)
        }
        guard let contentType = json["contentType"] as? String, !contentType.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing 'contentType'", status: 400)
        }
        guard let dataBase64 = json["dataBase64"] as? String, !dataBase64.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing 'dataBase64'", status: 400)
        }

        // 只收图片
        guard contentType.lowercased().hasPrefix("image/") else {
            return BoardAPI.errorResponse(
                "unsupported_type",
                "only image/* content types are accepted (got: \(contentType))",
                status: 400
            )
        }

        // base64 -> Data；粗略提前挡一下明显过大的 base64 字符串（base64 字节数 ~ raw * 4/3）
        if dataBase64.count > maxBytes * 2 {
            return BoardAPI.errorResponse(
                "too_large",
                "attachment exceeds \(maxBytes) bytes",
                status: 413
            )
        }
        guard let rawData = Data(base64Encoded: dataBase64, options: .ignoreUnknownCharacters) else {
            return BoardAPI.errorResponse("bad_request", "'dataBase64' is not valid base64", status: 400)
        }
        if rawData.count > maxBytes {
            return BoardAPI.errorResponse(
                "too_large",
                "attachment exceeds \(maxBytes) bytes (got \(rawData.count))",
                status: 413
            )
        }

        // 扩展名：按 contentType 决定（jpeg/jpg 规整为 jpg；未知的挡掉）
        let ext = extensionFor(contentType: contentType)
        guard let fileExt = ext else {
            return BoardAPI.errorResponse(
                "unsupported_type",
                "unsupported image content type: \(contentType)",
                status: 400
            )
        }

        // 保存目录：~/.meee2/attachments/<sid>/
        let baseDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".meee2/attachments/\(realSessionId)")
        do {
            try FileManager.default.createDirectory(
                atPath: baseDir,
                withIntermediateDirectories: true
            )
        } catch {
            MError("[AttachmentsAPI] mkdir failed: \(baseDir) err=\(error)")
            return BoardAPI.errorResponse(
                "mkdir_failed",
                "failed to create attachments dir: \(error.localizedDescription)",
                status: 500
            )
        }

        // 文件名：<timestamp>-<short>.<ext>；<short> = 6 位随机 hex
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let short = randomShortHex(length: 6)
        let fileName = "\(ts)-\(short).\(fileExt)"
        let fullPath = (baseDir as NSString).appendingPathComponent(fileName)

        do {
            try rawData.write(to: URL(fileURLWithPath: fullPath), options: .atomic)
        } catch {
            MError("[AttachmentsAPI] write failed: \(fullPath) err=\(error)")
            return BoardAPI.errorResponse(
                "write_failed",
                "failed to write attachment: \(error.localizedDescription)",
                status: 500
            )
        }

        MInfo("[AttachmentsAPI] saved \(rawData.count)B sid=\(realSessionId.prefix(8)) path=\(fullPath)")

        return BoardAPI.jsonResponse(
            AttachmentResponseDTO(path: fullPath, filename: filenameRaw),
            status: 201,
            reason: "Created"
        )
    }

    // MARK: - Helpers

    private static func extensionFor(contentType: String) -> String? {
        let lower = contentType.lowercased()
        // 容忍诸如 "image/png; charset=binary" 的 parameter 尾巴
        let main = lower.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? lower
        switch main {
        case "image/png":           return "png"
        case "image/jpeg", "image/jpg": return "jpeg"
        case "image/gif":           return "gif"
        case "image/webp":          return "webp"
        default:                    return nil
        }
    }

    private static func randomShortHex(length: Int) -> String {
        let chars = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
    }
}

/// 附件上传成功响应
struct AttachmentResponseDTO: Encodable {
    let path: String
    let filename: String
}
