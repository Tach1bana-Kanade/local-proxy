import Darwin
import Foundation
import ProxyAppsCore

final class PACContentStore {
    private let lock = NSLock()
    private var snapshots: [String: String] = [:]
    private var latest = ""
    @discardableResult
    func stage(_ content: String) -> String {
        let revision = PACGenerator.revision(content)
        lock.lock(); snapshots[revision] = content; lock.unlock()
        return revision
    }
    func activate(_ revision: String) {
        lock.lock(); defer { lock.unlock() }
        if snapshots[revision] != nil { latest = revision }
    }
    func publish(_ content: String) -> String {
        let revision = stage(content); activate(revision); return revision
    }
    func retain(_ revisions: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        snapshots = snapshots.filter { revisions.contains($0.key) || $0.key == latest }
    }
    var snapshotCount: Int { lock.lock(); defer { lock.unlock() }; return snapshots.count }
    func content(revision: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[revision ?? latest]
    }
}

enum PACServerError: LocalizedError {
    case socketCreation(Int32)
    case bind(Int32)
    case listen(Int32)
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .socketCreation(let code): return "无法创建 PAC 回环服务（错误 \(code)）。"
        case .bind(let code): return "无法在 127.0.0.1 启动 PAC 服务（错误 \(code)）。"
        case .listen(let code): return "PAC 服务无法监听连接（错误 \(code)）。"
        case .invalidPort: return "PAC 服务返回了无效端口。"
        }
    }
}

protocol PACServing {
    func start(preferredPort: UInt16) throws -> UInt16
    func stop()
}

final class PACServer: PACServing {
    private let queue = DispatchQueue(label: "com.proxyapps.pac-server")
    private let clients = DispatchQueue(label: "com.proxyapps.pac-clients", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1
    private let contentProvider: (String?) -> String?
    private(set) var port: UInt16?

    init(contentProvider: @escaping (String?) -> String?) {
        self.contentProvider = contentProvider
    }

    func start(preferredPort: UInt16) throws -> UInt16 {
        if let port { return port }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PACServerError.socketCreation(errno) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        do {
            try bind(descriptor: descriptor, port: preferredPort)
        } catch {
            guard preferredPort != 0 else { close(descriptor); throw error }
            do { try bind(descriptor: descriptor, port: 0) }
            catch { close(descriptor); throw error }
        }
        guard Darwin.listen(descriptor, 8) == 0 else {
            let code = errno; close(descriptor); throw PACServerError.listen(code)
        }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else { close(descriptor); throw PACServerError.invalidPort }
        let selectedPort = UInt16(bigEndian: address.sin_port)

        listenDescriptor = descriptor
        port = selectedPort
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(descriptor) }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        return selectedPort
    }

    func stop() {
        source?.cancel()
        source = nil
        listenDescriptor = -1
        port = nil
    }

    private func bind(descriptor: Int32, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { throw PACServerError.bind(errno) }
    }

    private func acceptConnections(_ listening: Int32) {
        while true {
            let client = accept(listening, nil, nil)
            guard client >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            // macOS 上 accept 返回的 socket 会继承监听 socket 的 O_NONBLOCK，
            // 必须清除，否则请求数据尚未到达时 recv 立即返回 EAGAIN。
            let flags = fcntl(client, F_GETFL)
            if flags >= 0 { _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            clients.async { [self] in handle(client); close(client); slots.signal() }
        }
    }

    private func handle(_ descriptor: Int32) {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        // 循环读取直到请求头结束（\r\n\r\n），单次 recv 可能只拿到部分请求。
        let deadline = Date().addingTimeInterval(2)
        while received.count <= 16384 && Date() < deadline {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            guard count > 0 else { break }
            received.append(contentsOf: chunk.prefix(count))
            if received.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil { break }
        }
        guard received.count <= 16384, received.range(of: Data([13, 10, 13, 10])) != nil,
              let request = String(data: received, encoding: .utf8),
              let requestLine = request.split(separator: "\n", maxSplits: 1).first else {
            return
        }
        let parts = requestLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let path = URLComponents(string: String(parts[1])), path.path == "/proxy.pac" else {
            sendResponse(descriptor, status: "404 Not Found", contentType: "text/plain", body: "Not Found")
            return
        }
        let revision = path.queryItems?.first(where: { $0.name == "v" })?.value
        guard let body = contentProvider(revision) else {
            sendResponse(descriptor, status: "404 Not Found", contentType: "text/plain", body: "Unknown revision"); return
        }
        sendResponse(
            descriptor,
            status: "200 OK",
            contentType: "application/x-ns-proxy-autoconfig; charset=utf-8",
            body: body
        )
    }

    private func sendResponse(_ descriptor: Int32, status: String, contentType: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(bodyData)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            let deadline = Date().addingTimeInterval(5)
            while sent < buffer.count && Date() < deadline {
                let result = Darwin.send(descriptor, base.advanced(by: sent), buffer.count - sent, 0)
                if result <= 0 { return }
                sent += result
            }
        }
    }
}
