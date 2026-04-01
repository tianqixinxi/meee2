import Foundation

/// HTTP Server 接收 Claude CLI hooks 回调
/// Claude CLI 通过配置的 hook 命令调用 bridge 脚本，
/// bridge 脚本将数据 POST 到此 server
class HookReceiver {
    // MARK: - Constants

    /// 监听端口
    static let port: UInt16 = 19527

    // MARK: - Properties

    /// 是否正在运行
    private(set) var isRunning = false

    /// 收到 hook 时的回调
    var onHookReceived: ((HookEvent) -> Void)?

    /// Socket 文件描述符
    private var socketFd: Int32 = -1

    /// 接收队列
    private let receiveQueue = DispatchQueue(label: "com.peerisland.hookreceiver", qos: .userInteractive)

    /// 是否应该停止
    private var shouldStop = false

    // MARK: - Lifecycle

    init() {}

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// 启动 HTTP Server
    func start() -> Bool {
        guard !isRunning else { return true }

        shouldStop = false

        // 创建 socket
        socketFd = socket(AF_INET, SOCK_STREAM, 0)
        if socketFd < 0 {
            print("Failed to create socket")
            return false
        }

        // 设置 socket 选项
        var on: Int32 = 1
        setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        // 绑定地址
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = HookReceiver.port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(socketFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult < 0 {
            print("Failed to bind socket to port \(HookReceiver.port)")
            close(socketFd)
            socketFd = -1
            return false
        }

        // 开始监听
        if listen(socketFd, 5) < 0 {
            print("Failed to listen on socket")
            close(socketFd)
            socketFd = -1
            return false
        }

        isRunning = true
        print("HookReceiver started on port \(HookReceiver.port)")

        // 开始接收连接
        receiveQueue.async { [weak self] in
            self?.acceptConnections()
        }

        return true
    }

    /// 停止 HTTP Server
    func stop() {
        shouldStop = true
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        isRunning = false
        print("HookReceiver stopped")
    }

    // MARK: - Private Methods

    /// 接收连接循环
    private func acceptConnections() {
        while !shouldStop && socketFd >= 0 {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(socketFd, sockPtr, &clientAddrLen)
                }
            }

            if clientFd < 0 {
                if !shouldStop {
                    print("Accept failed")
                }
                continue
            }

            // 处理客户端请求
            handleClient(clientFd)
        }
    }

    /// 处理单个客户端请求
    private func handleClient(_ clientFd: Int32) {
        // 先读取数据
        var buffer = [UInt8](repeating: 0, count: 65536)  // 64KB buffer
        var totalData = [UInt8]()

        // 循环读取直到收到完整请求
        while true {
            let bytesRead = recv(clientFd, &buffer, buffer.count, 0)
            if bytesRead <= 0 {
                break
            }
            totalData.append(contentsOf: buffer[0..<bytesRead])

            // 检查是否已收到完整的 HTTP 请求
            if let dataStr = String(bytes: totalData, encoding: .utf8) {
                // 查找 Content-Length
                if let clMatch = dataStr.range(of: "Content-Length: ", options: .caseInsensitive) {
                    let start = clMatch.upperBound
                    let end = dataStr[start...].firstIndex(of: "\r") ?? dataStr.endIndex
                    let lengthStr = String(dataStr[start..<end])
                    if let contentLength = Int(lengthStr) {
                        // 检查是否收到完整的 body
                        if let headerEnd = dataStr.range(of: "\r\n\r\n") {
                            let headerEndOffset = headerEnd.upperBound.utf16Offset(in: dataStr)
                            let bodyStartIndex = totalData.count - (dataStr.utf8.count - headerEndOffset)
                            let receivedBodyLength = totalData.count - bodyStartIndex
                            if receivedBodyLength >= contentLength {
                                break  // 收到完整请求
                            }
                        }
                    }
                } else if dataStr.contains("\r\n\r\n") {
                    // 没有 Content-Length，header 结束就是请求结束
                    break
                }
            }
        }

        let requestString = String(bytes: totalData, encoding: .utf8) ?? ""

        // 解析 HTTP 请求
        let response = processRequest(requestString)

        // 发送响应
        let responseBytes = response.utf8.map { UInt8($0) }
        send(clientFd, responseBytes, responseBytes.count, 0)

        close(clientFd)
    }

    /// 处理 HTTP 请求并返回响应
    private func processRequest(_ request: String) -> String {
        NSLog("[HookReceiver] Processing request")
        // 解析请求方法和路径
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let firstLine = lines.first else {
            NSLog("[HookReceiver] Bad request - no lines")
            return httpResponse(status: 400, body: "Bad Request")
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            NSLog("[HookReceiver] Bad request - not enough parts")
            return httpResponse(status: 400, body: "Bad Request")
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // 只处理 POST /hook
        if method == "POST" && path == "/hook" {
            // 提取 body (在空行之后)
            let separator = "\r\n\r\n"
            let body: String
            if let range = request.range(of: separator) {
                body = String(request[range.upperBound...])
            } else {
                body = ""
            }

            NSLog("[HookReceiver] Request body: \(body)")

            // 解析 hook 事件
            if let event = HookEvent.parse(from: body) {
                NSLog("[HookReceiver] Parsed event: \(event.event?.rawValue ?? "nil"), sessionId: \(event.sessionId ?? "nil"), statusDescription: \(event.statusDescription ?? "nil")")
                // 在主线程回调
                DispatchQueue.main.async {
                    self.onHookReceived?(event)
                }
                return httpResponse(status: 200, body: "OK")
            } else {
                NSLog("[HookReceiver] Failed to parse event from body")
                // 尝试从 stdin 格式解析
                // Hook 数据可能包含多个字段，提取关键信息
                let sessionId = extractField(from: body, field: "sessionId")
                let cwd = extractField(from: body, field: "cwd")

                if let sessionId = sessionId {
                    let event = HookEvent(
                        sessionId: sessionId,
                        cwd: cwd,
                        timestamp: Date(),
                        rawData: body
                    )
                    NSLog("[HookReceiver] Created fallback event with sessionId: \(sessionId)")
                    DispatchQueue.main.async {
                        self.onHookReceived?(event)
                    }
                    return httpResponse(status: 200, body: "OK")
                }

                return httpResponse(status: 400, body: "Invalid hook data")
            }
        }

        // GET /status - 返回服务器状态
        if method == "GET" && path == "/status" {
            return httpResponse(status: 200, body: "{\"running\":true}")
        }

        return httpResponse(status: 404, body: "Not Found")
    }

    /// 从 JSON 字符串中提取字段值
    private func extractField(from json: String, field: String) -> String? {
        // 简单的 JSON 字段提取
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(json.startIndex..., in: json)
        guard let match = regex.firstMatch(in: json, range: range) else { return nil }

        if let valueRange = Range(match.range(at: 1), in: json) {
            return String(json[valueRange])
        }
        return nil
    }

    /// 构建 HTTP 响应
    private func httpResponse(status: Int, body: String) -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        return "HTTP/1.1 \(status) \(statusText)\r\n" +
               "Content-Type: application/json\r\n" +
               "Content-Length: \(body.count)\r\n" +
               "Connection: close\r\n" +
               "\r\n" +
               body
    }
}

// MARK: - 单例访问

extension HookReceiver {
    /// 共享实例
    static let shared = HookReceiver()
}