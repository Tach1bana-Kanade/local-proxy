import Foundation
import Darwin

public enum RoutingMode: String, Codable, Sendable { case off, manual, smart }
public enum RuleAction: String, Codable, Sendable { case direct, proxy }
public enum RuleMatch: String, Codable, Sendable { case exact, suffix }
public enum RuleSource: String, Codable, Sendable { case user, diagnosis, migration }
public struct RoutingConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var preferredMode: RoutingMode = .off
    public var confirmation: String?
    public var automaticUpdates = true
    public var lastSuccessfulCheck: Date?
    public var manualRules: [ManagedWebsite] = []
    public static let consentVersion = "loyalsoldier-v1-smart-unknown-direct"
    public init() {}
    public var needsConfirmation: Bool { confirmation != Self.consentVersion }
    public func validated() throws -> Self {
        guard schemaVersion == 1 else { throw RoutingError.invalid("配置版本不支持") }
        var keys = Set<String>()
        var ids = Set<UUID>()
        for rule in manualRules {
            guard try WebsiteNormalizer.normalize(rule.domain) == rule.domain,
                  keys.insert(rule.domain + ":" + rule.match.rawValue).inserted,
                  ids.insert(rule.id).inserted else { throw RoutingError.invalid("重复或无效手动规则") }
        }
        return self
    }
}
public enum RoutingError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
public struct RoutingConfigurationStore {
    public let directory: URL
    private let writer: (Data, URL) throws -> Void
    public init(directory: URL, writer: @escaping (Data, URL) throws -> Void = { try PrivateFile.write($0, to: $1) }) { self.directory = directory; self.writer = writer }
    public func load() throws -> RoutingConfiguration {
        let url = directory.appendingPathComponent("routing.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(RoutingConfiguration.self, from: Data(contentsOf: url)).validated()
        }
        var config = RoutingConfiguration()
        let legacy = directory.appendingPathComponent("websites.json")
        if FileManager.default.fileExists(atPath: legacy.path) {
            config.manualRules = try JSONDecoder().decode([ManagedWebsite].self, from: Data(contentsOf: legacy))
            config.preferredMode = .manual
        }
        try save(config)
        return config
    }
    public func save(_ configuration: RoutingConfiguration) throws {
        try writer(try JSONEncoder().encode(configuration.validated()), directory.appendingPathComponent("routing.json"))
    }
}
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(.EIO) }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        } catch { close(fd); throw error }
        close(fd)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}
