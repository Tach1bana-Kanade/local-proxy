import Foundation
import CryptoKit

public struct RuleSetSnapshot: Codable, Equatable, Sendable {
    public var version: String
    public var downloadedAt: Date
    public var directText: Data
    public var proxyText: Data
    public var directSHA256: String
    public var proxySHA256: String
    public var source = "Loyalsoldier/v2ray-rules-dat"
    public init(version: String, direct: Data, proxy: Data, now: Date = Date()) {
        self.version = version; downloadedAt = now; directText = direct; proxyText = proxy
        directSHA256 = Self.hash(direct); proxySHA256 = Self.hash(proxy)
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func parse() throws -> ParsedRuleSet {
        guard source == "Loyalsoldier/v2ray-rules-dat", version.count == 40, version.allSatisfy(\.isHexDigit),
              directSHA256 == Self.hash(directText), proxySHA256 == Self.hash(proxyText) else {
            throw RoutingError.invalid("规则版本或 SHA-256 校验失败")
        }
        return try RuleSetParser.parse(direct: directText, proxy: proxyText)
    }
}
public struct ParsedRuleSet: Sendable {
    public let rules: [DomainRule]
    public let unsupported: Int
    public let conflicts: Int
    public let duplicates: Int
    public var directCount: Int { rules.filter { $0.action == .direct }.count }
    public var proxyCount: Int { rules.count - directCount }
}
public enum RuleSetParser {
    public static let maxBytes = 20 * 1024 * 1024
    public static func parse(direct: Data, proxy: Data) throws -> ParsedRuleSet {
        var index: [String: DomainRule] = [:], unsupported = 0, duplicates = 0, total = 0
        var conflicts = Set<String>()
        for (data, action) in [(direct, RuleAction.direct), (proxy, RuleAction.proxy)] {
            guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { throw RoutingError.invalid("规则文件超限或不是 UTF-8") }
            var valid = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard raw.utf8.count <= 4096 else { throw RoutingError.invalid("规则单行超过 4096 字节") }
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                total += 1
                guard total <= 500_000 else { throw RoutingError.invalid("规则合计超过 500000 条") }
                var domain = line, match: RuleMatch = .suffix
                if let colon = line.firstIndex(of: ":") {
                    let kind = String(line[..<colon]); domain = String(line[line.index(after: colon)...])
                    guard !domain.isEmpty else { throw RoutingError.invalid("规则内容为空") }
                    switch kind {
                    case "domain": break
                    case "full": match = .exact
                    case "regexp", "keyword", "geosite", "include": unsupported += 1; continue
                    default: unsupported += 1; continue
                    }
                }
                // Upstream includes bare TLD suffix rules; manual inputs intentionally require two labels.
                domain = domain.lowercased()
                guard domain.utf8.count <= 253, !domain.hasSuffix("."), domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                    !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                }) else { throw RoutingError.invalid("规则含畸形域名") }
                valid += 1
                let rule = DomainRule(domain: domain, match: match, action: action)
                if let prior = index[rule.key] {
                    if prior.action != action { conflicts.insert(rule.key) } else { duplicates += 1 }
                    if prior.action == .direct { continue }
                }
                index[rule.key] = rule
            }
            guard valid > 0 else { throw RoutingError.invalid("直连/代理规则文件必须分别非空") }
        }
        return ParsedRuleSet(rules: index.values.sorted { $0.key < $1.key }, unsupported: unsupported, conflicts: conflicts.count, duplicates: duplicates)
    }
}
public struct RuleSetCache: Codable {
    public var current: RuleSetSnapshot
    public var previous: RuleSetSnapshot?
    public init(current: RuleSetSnapshot, previous: RuleSetSnapshot? = nil) { self.current = current; self.previous = previous }
}
public struct RuleSetStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> (RuleSetCache, String?) {
        let url = directory.appendingPathComponent("rule-cache.json")
        var warning: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let cache = try JSONDecoder().decode(RuleSetCache.self, from: Data(contentsOf: url))
                _ = try cache.current.parse()
                if let previous = cache.previous { _ = try previous.parse() }
                return (cache, nil)
            } catch { warning = "本地缓存损坏，已保留原文件并回退随包规则：\(error.localizedDescription)" }
        }
        return (RuleSetCache(current: try bundled()), warning)
    }
    public func save(_ cache: RuleSetCache) throws {
        _ = try cache.current.parse()
        if let previous = cache.previous { _ = try previous.parse() }
        let url = directory.appendingPathComponent("rule-cache.json")
        if let data = try? Data(contentsOf: url) {
            do { let old = try JSONDecoder().decode(RuleSetCache.self, from: data); _ = try old.current.parse() }
            catch { try PrivateFile.write(data, to: directory.appendingPathComponent("rule-cache-corrupt-" + UUID().uuidString + ".json")) }
        }
        try PrivateFile.write(try JSONEncoder().encode(cache), to: url)
    }
    public func bundled() throws -> RuleSetSnapshot {
        struct Manifest: Decodable { let version: String; let downloadedAt: Date; let directSHA256: String; let proxySHA256: String }
        // Explicit bundle lookup also works when the app is copied away from its SwiftPM build directory.
        let bundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "LocalProxy_ProxyAppsCore", withExtension: "bundle"), let resource = Bundle(url: url) else {
                throw RoutingError.invalid("应用规则资源包缺失，请重新构建或使用立即更新修复")
            }
            bundle = resource
        } else { bundle = Bundle.module }
        func data(_ name: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: nil) else { throw RoutingError.invalid("随包规则资源缺失") }
            return try Data(contentsOf: url)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data("manifest.json"))
        var snapshot = RuleSetSnapshot(version: manifest.version, direct: try data("direct-list.txt"), proxy: try data("proxy-list.txt"), now: manifest.downloadedAt)
        snapshot.directSHA256 = manifest.directSHA256; snapshot.proxySHA256 = manifest.proxySHA256
        _ = try snapshot.parse(); return snapshot
    }
}
public struct UpdateSchedule: Equatable, Sendable {
    public var nextCheck: Date
    public var failures = 0
    public init(lastSuccess: Date?, now: Date) { nextCheck = lastSuccess?.addingTimeInterval(86400) ?? now }
    public mutating func succeeded(at now: Date) { failures = 0; nextCheck = now.addingTimeInterval(86400) }
    public mutating func failed(at now: Date) { let delays: [Double] = [900, 3600, 21600]; nextCheck = now.addingTimeInterval(delays[min(failures, 2)]); failures += 1 }
    public func isDue(at now: Date, automatic: Bool) -> Bool { automatic && now >= nextCheck }
}
