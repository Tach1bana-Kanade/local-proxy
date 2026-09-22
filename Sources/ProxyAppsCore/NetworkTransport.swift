import Foundation
import Darwin

public struct CommandResult: Sendable { public let status: Int32; public let data: Data }
/// Each operation owns its subprocess. Cancellation and deadline kill it and close pipes; no shell is involved.
public final class BoundedCommand: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var active: [UUID: BoundedCommand] = [:]
    public static func cancelAll() {
        registryLock.lock(); let commands = Array(active.values); registryLock.unlock()
        commands.forEach { $0.cancel() }
    }
    private let id = UUID()
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    public func run(executable: String, arguments: [String], timeout: Double, limit: Int) async throws -> CommandResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    Self.registryLock.lock(); Self.active[self.id] = self; Self.registryLock.unlock()
                    defer { Self.registryLock.lock(); Self.active[self.id] = nil; Self.registryLock.unlock() }
                    let p = Process(), output = Pipe()
                    p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
                    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
                    p.standardOutput = output; p.standardError = FileHandle.nullDevice
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    do { try p.run(); self.process = p; self.lock.unlock() }
                    catch { self.lock.unlock(); continuation.resume(throwing: error); return }
                    let timer = DispatchWorkItem { self.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
                    var data = Data(), exceeded = false
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        if data.count + chunk.count > limit { exceeded = true; self.cancel(); break }
                        data.append(chunk)
                    }
                    try? output.fileHandleForReading.close()
                    p.waitUntilExit(); timer.cancel()
                    self.lock.lock(); self.process = nil; let cancelled = self.cancelled; self.lock.unlock()
                    if exceeded { continuation.resume(throwing: RoutingError.invalid("响应超出大小上限")) }
                    else if cancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(returning: CommandResult(status: p.terminationStatus, data: data)) }
                }
            }
        }, onCancel: { self.cancel() })
    }
}
public enum NetworkChannel: String, Sendable { case direct, proxy }
public enum CurlTransport {
    public static func arguments(channel: NetworkChannel) -> [String] {
        ["--disable", "--silent", "--show-error", "--proto", "=https", "--noproxy", channel == .direct ? "*" : "", "--proxy", channel == .direct ? "" : "http://127.0.0.1:21081"]
    }
    public static func download(_ url: URL, channel: NetworkChannel, limit: Int) async throws -> Data {
        let command = BoundedCommand()
        let result = try await command.run(executable: "/usr/bin/curl", arguments: arguments(channel: channel) + ["--fail", "--max-time", "30", "--connect-timeout", "8", "--max-filesize", String(limit), url.absoluteString], timeout: 31, limit: limit)
        guard result.status == 0 else { throw RoutingError.invalid("下载失败（\(channel.rawValue)，curl \(result.status)），继续使用旧规则") }
        return result.data
    }
}
public actor RuleSetUpdater {
    public typealias Download = @Sendable (URL, NetworkChannel, Int) async throws -> Data
    private let download: Download
    private var task: Task<RuleSetSnapshot, Error>?
    public init(download: @escaping Download = { url, channel, limit in try await CurlTransport.download(url, channel: channel, limit: limit) }) { self.download = download }
    public func cancel() { task?.cancel() }
    public func update(proxyAvailable: Bool, now: Date = Date()) async throws -> RuleSetSnapshot {
        if let task { return try await task.value }
        let download = self.download
        let task = Task<RuleSetSnapshot, Error> {
            func attempt(_ channel: NetworkChannel) async throws -> RuleSetSnapshot {
                let versionData = try await download(URL(string: "https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/commits/release")!, channel, 1024 * 1024)
                struct Commit: Decodable { let sha: String }
                let version = try JSONDecoder().decode(Commit.self, from: versionData).sha
                guard version.count == 40, version.allSatisfy(\.isHexDigit) else { throw RoutingError.invalid("上游提交版本无效") }
                let base = "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/\(version)/"
                async let direct = download(URL(string: base + "direct-list.txt")!, channel, RuleSetParser.maxBytes)
                async let proxy = download(URL(string: base + "proxy-list.txt")!, channel, RuleSetParser.maxBytes)
                let snapshot = try await RuleSetSnapshot(version: version, direct: direct, proxy: proxy, now: now)
                _ = try snapshot.parse(); try Task.checkCancellation(); return snapshot
            }
            do { return try await attempt(.direct) }
            catch { try Task.checkCancellation(); guard proxyAvailable else { throw error }; return try await attempt(.proxy) }
        }
        self.task = task
        defer { self.task = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
