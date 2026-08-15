import Darwin
import Foundation

public struct ManagedApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var bundleIdentifier: String?
    public var bundlePath: String
    public var executableName: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        bundlePath: String,
        executableName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executableName = executableName
    }
}

public enum ProxyEnvironment {
    public static let values: [String: String] = [
        "HTTP_PROXY": "http://127.0.0.1:21081",
        "HTTPS_PROXY": "http://127.0.0.1:21081",
        "ALL_PROXY": "socks5h://127.0.0.1:21080",
        "NO_PROXY": "localhost,127.0.0.1,::1",
        "http_proxy": "http://127.0.0.1:21081",
        "https_proxy": "http://127.0.0.1:21081",
        "all_proxy": "socks5h://127.0.0.1:21080",
        "no_proxy": "localhost,127.0.0.1,::1",
    ]
}

public struct ProxyPortConnection: Equatable, Identifiable, Sendable {
    public var id: String { "\(pid):\(endpoint)" }
    public let pid: Int32
    public let processName: String
    public let endpoint: String

    public init(pid: Int32, processName: String, endpoint: String) {
        self.pid = pid
        self.processName = processName
        self.endpoint = endpoint
    }
}

public enum DiagnosticParser {
    public static func systemProxyEnabled(in output: String) -> Bool {
        let enabledKeys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"]
        return output.split(separator: "\n").contains { line in
            let compact = line.replacingOccurrences(of: " ", with: "")
            return enabledKeys.contains { compact == "\($0):1" }
        }
    }

    public static func proxyConnections(in output: String) -> [ProxyPortConnection] {
        var pid: Int32?
        var command: String?
        var results: [ProxyPortConnection] = []

        for rawLine in output.split(separator: "\n") {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch prefix {
            case "p": pid = Int32(value); command = nil
            case "c": command = value
            case "n":
                guard let pid, let command,
                      value.contains(":21080") || value.contains(":21081") else { continue }
                results.append(ProxyPortConnection(pid: pid, processName: command, endpoint: value))
            default: continue
            }
        }

        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }
}

public struct PortProbe {
    public init() {}

    public func canConnect(host: String, port: Int, timeout: TimeInterval = 1.0) -> Bool {
        guard (1...65535).contains(port), timeout > 0 else { return false }
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: Int32(IPPROTO_TCP),
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(min(timeout, 86_400) * 1_000_000_000)
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                if flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 {
                    let status = Darwin.connect(fd, info.ai_addr, info.ai_addrlen)
                    if status == 0 { close(fd); return true }
                    if errno == EINPROGRESS {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        var pollStatus: Int32 = -1
                        repeat {
                            let now = DispatchTime.now().uptimeNanoseconds
                            guard now < deadline else { break }
                            let milliseconds = max(UInt64(1), (deadline - now) / 1_000_000)
                            pollStatus = Darwin.poll(
                                &descriptor, 1, Int32(min(UInt64(Int32.max), milliseconds))
                            )
                        } while pollStatus < 0 && errno == EINTR
                        if pollStatus > 0 {
                            var socketError: Int32 = 0
                            var length = socklen_t(MemoryLayout<Int32>.size)
                            let optionStatus = withUnsafeMutablePointer(to: &socketError) {
                                getsockopt(fd, SOL_SOCKET, SO_ERROR, $0, &length)
                            }
                            if optionStatus == 0, socketError == 0 { close(fd); return true }
                        }
                    }
                }
                close(fd)
            }
            current = info.ai_next
        }
        return false
    }
}
