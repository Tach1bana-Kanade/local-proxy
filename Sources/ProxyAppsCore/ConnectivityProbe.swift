import Foundation
import Darwin

public enum ProbeOutcome: Equatable, Sendable {
    case response(Int)
    case connectionFailure(String)
    case uncertain(String)
    case skipped(String)
    public var text: String {
        switch self {
        case .response(let code): return "HTTPS \(code)" + ((300..<400).contains(code) ? "，目标发生跳转；未跟随" : "，仅验证原主机响应")
        case .connectionFailure(let s), .uncertain(let s), .skipped(let s): return s
        }
    }
    var normal: Bool { if case .response(let c) = self { return (200..<300).contains(c) }; return false }
}
public struct ProbeResult: Equatable, Sendable {
    public let domain: String
    public let direct: ProbeOutcome
    public let proxy: ProbeOutcome
    public var suggestion: String {
        if direct.normal { return "建议直连；单次速度差不会修改规则" }
        if case .connectionFailure = direct, proxy.normal { return "建议代理：直连重复连接失败，代理获得正常 HTTPS 响应" }
        return "暂无法判断；跳转、证书、限流或访问限制不能证明网站可正常使用"
    }
}
public protocol ProbeNetworking: Sendable {
    func resolve(_ domain: String, deadline: Date) async throws -> [String]
    func head(_ domain: String, channel: NetworkChannel, address: String?, deadline: Date) async throws -> ProbeOutcome
}
public struct CurlProbeNetworking: ProbeNetworking {
    public init() {}
    public func resolve(_ domain: String, deadline: Date) async throws -> [String] {
        let result = try await BoundedCommand().run(executable: "/usr/bin/dscacheutil", arguments: ["-q", "host", "-a", "name", domain], timeout: min(2, deadline.timeIntervalSinceNow), limit: 65536)
        guard result.status == 0, let text = String(data: result.data, encoding: .utf8) else { throw RoutingError.invalid("DNS 查询失败") }
        let addresses = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("ip_address:") || line.hasPrefix("ipv6_address:") else { return nil }
            let ip = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            var v4 = in_addr(), v6 = in6_addr()
            return inet_pton(AF_INET, ip, &v4) == 1 || inet_pton(AF_INET6, ip, &v6) == 1 ? ip : nil
        }
        guard !addresses.isEmpty else { throw RoutingError.invalid("DNS 没有返回可用地址") }
        return addresses
    }
    public func head(_ domain: String, channel: NetworkChannel, address: String?, deadline: Date) async throws -> ProbeOutcome {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CancellationError() }
        var args = CurlTransport.arguments(channel: channel) + ["--head", "--max-time", String(min(3, remaining)), "--connect-timeout", String(min(3, remaining)), "--output", "/dev/null", "--write-out", "%{http_code}", "https://\(domain)/"]
        if let address {
            // Pin the validated address while retaining hostname SNI and normal certificate checks.
            args += ["--resolve", "\(domain):443:\(address.contains(":") ? "[\(address)]" : address)"]
        }
        let result = try await BoundedCommand().run(executable: "/usr/bin/curl", arguments: args, timeout: remaining, limit: 16384)
        if result.status == 0, let text = String(data: result.data, encoding: .utf8), let code = Int(text), code > 0 { return .response(code) }
        if [5, 6, 7, 28, 52, 55, 56].contains(result.status) { return .connectionFailure("连接阶段失败（curl \(result.status)）") }
        return .uncertain("TLS 或协议错误（curl \(result.status)），无法判断")
    }
}
public actor ConnectivityProbe {
    private let network: ProbeNetworking
    private let budget: TimeInterval
    private let now: @Sendable () -> Date
    private var generation = 0
    private var cache: [String: (Date, ProbeResult)] = [:]
    private var flightIDs: [String: UUID] = [:]
    private var inFlight: [String: Task<ProbeResult, Never>] = [:]
    public init(network: ProbeNetworking = CurlProbeNetworking(), now: @escaping @Sendable () -> Date = { Date() }, budget: TimeInterval = 8) { self.network = network; self.now = now; self.budget = budget }
    public func invalidate() { generation += 1; cache.removeAll(); for task in inFlight.values { task.cancel() }; inFlight.removeAll(); flightIDs.removeAll() }
    public func cancel() { for task in inFlight.values { task.cancel() }; inFlight.removeAll(); flightIDs.removeAll() }
    public func check(domain: String, skipDirect: Bool, proxyAvailable: Bool) async -> ProbeResult {
        cache = cache.filter { now().timeIntervalSince($0.value.0) < 600 }
        let key = "\(generation):\(domain):\(skipDirect):\(proxyAvailable)"
        if let (date, result) = cache[key], now().timeIntervalSince(date) < 600 { return result }
        if let existing = inFlight[key], !existing.isCancelled { return await existing.value }
        let flightID = UUID()
        let network = self.network, deadline = now().addingTimeInterval(budget), initialGeneration = generation
        let task = Task<ProbeResult, Never> {
            @Sendable func channel(_ channel: NetworkChannel) async -> ProbeOutcome {
                if channel == .direct && skipDirect { return .skipped("按现有代理规则跳过直连测试") }
                if channel == .proxy && !proxyAvailable { return .skipped("Quickcat 代理入口不可用") }
                do {
                    guard (try? WebsiteNormalizer.normalize(domain)) == domain, !LocalTarget.isProtected(domain) else { return .skipped("本地或保留目标不探测") }
                    var address: String?
                    if channel == .direct {
                        let addresses = try await network.resolve(domain, deadline: deadline)
                        guard !addresses.isEmpty, !addresses.contains(where: LocalTarget.isProbeReserved) else { return .skipped("DNS 返回本地或保留地址，拒绝直连探测") }
                        address = addresses.first
                    }
                    var outcome: ProbeOutcome = .uncertain("未检测")
                    for _ in 0..<2 {
                        try Task.checkCancellation()
                        outcome = try await network.head(domain, channel: channel, address: address, deadline: deadline)
                        if case .connectionFailure = outcome { continue }; return outcome
                    }
                    return outcome
                } catch is CancellationError { return .uncertain("检测已取消或超出 8 秒预算") }
                catch { return .uncertain("DNS/探测失败：\(error.localizedDescription)") }
            }
            async let direct = channel(.direct)
            async let proxy = channel(.proxy)
            return await ProbeResult(domain: domain, direct: direct, proxy: proxy)
        }
        inFlight[key] = task; flightIDs[key] = flightID
        let nanoseconds = UInt64(max(0.001, budget) * 1_000_000_000)
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: nanoseconds); task.cancel() } catch {}
        }
        defer { watchdog.cancel() }
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if flightIDs[key] == flightID { inFlight[key] = nil; flightIDs[key] = nil }
        if initialGeneration == generation && !task.isCancelled { cache[key] = (now(), result) }
        return result
    }
}
