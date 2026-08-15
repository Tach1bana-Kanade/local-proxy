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
        let enabledKeys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable"]
        return output.split(separator: "\n").contains { line in
            let compact = line.replacingOccurrences(of: " ", with: "")
            return enabledKeys.contains { compact == "\($0):1" }
        }
    }

    /// Parses `lsof -Fpcn` output without depending on column widths or paths.
    public static func proxyConnections(in output: String) -> [ProxyPortConnection] {
        var pid: Int32?
        var command: String?
        var results: [ProxyPortConnection] = []

        for rawLine in output.split(separator: "\n") {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch prefix {
            case "p":
                pid = Int32(value)
                command = nil
            case "c":
                command = value
            case "n":
                guard let pid, let command,
                      value.contains(":21080") || value.contains(":21081") else { continue }
                results.append(ProxyPortConnection(pid: pid, processName: command, endpoint: value))
            default:
                continue
            }
        }

        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }
}
