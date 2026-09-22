import Foundation
import Darwin

public struct DomainRule: Codable, Equatable, Sendable {
    public let domain: String
    public let match: RuleMatch
    public let action: RuleAction
    public init(domain: String, match: RuleMatch = .suffix, action: RuleAction) {
        self.domain = domain; self.match = match; self.action = action
    }
    public var key: String { (match == .exact ? "e:" : "s:") + domain }
}
public struct RoutingDecision: Equatable, Sendable {
    public let action: RuleAction
    public let source: String
    public let rule: DomainRule?
    public var reason: String { rule.map { "\(source)：\($0.domain)（\($0.match == .exact ? "仅此域名" : "包含子域名")）" } ?? source }
}
public struct DomainRuleMatcher: Sendable {
    public let manual: [String: RuleAction]
    public let automatic: [String: RuleAction]
    public init(manual: [ManagedWebsite], automatic: [DomainRule] = []) {
        self.manual = Self.index(manual.filter(\.enabled).map { DomainRule(domain: $0.domain, match: $0.match, action: $0.action) })
        self.automatic = Self.index(automatic)
    }
    public static func index(_ rules: [DomainRule]) -> [String: RuleAction] {
        var result: [String: RuleAction] = [:]
        for rule in rules { if result[rule.key] != .direct { result[rule.key] = rule.action } }
        return result
    }
    public func decision(host: String, mode: RoutingMode) -> RoutingDecision {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if LocalTarget.isProtected(host) { return .init(action: .direct, source: "本地目标保护", rule: nil) }
        if mode == .off { return .init(action: .direct, source: "分流关闭", rule: nil) }
        if let rule = Self.lookup(host, in: manual) { return .init(action: rule.action, source: "手动规则", rule: rule) }
        if mode == .smart, let rule = Self.lookup(host, in: automatic) { return .init(action: rule.action, source: "规则库", rule: rule) }
        return .init(action: .direct, source: "未知，默认直连", rule: nil)
    }
    private static func lookup(_ host: String, in index: [String: RuleAction]) -> DomainRule? {
        if let action = index["e:" + host] { return .init(domain: host, match: .exact, action: action) }
        var name = host
        while true {
            if let action = index["s:" + name] { return .init(domain: name, action: action) }
            guard let dot = name.firstIndex(of: ".") else { return nil }
            name = String(name[name.index(after: dot)...])
        }
    }
}
public enum LocalTarget {
    public static func isProtected(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if !h.contains(".") && !h.contains(":") || h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".localhost") || h == "home.arpa" || h.hasSuffix(".home.arpa") { return true }
        var v4 = in_addr(); var v6 = in6_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr), a = n >> 24, b = (n >> 16) & 255
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127) || a >= 224
        }
        if inet_pton(AF_INET6, h, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
                return isProtected(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
            return bytes.prefix(12).allSatisfy({ $0 == 0 }) || bytes[0] & 254 == 252 || (bytes[0] == 254 && bytes[1] & 192 == 128) || bytes[0] == 255
        }
        return false
    }
    public static func isProbeReserved(_ ip: String) -> Bool {
        if isProtected(ip) { return true }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if inet_pton(AF_INET, ip, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr), a = n >> 24, b = (n >> 16) & 255, c = (n >> 8) & 255
            return (a == 192 && b == 0 && (c == 0 || c == 2)) || (a == 192 && b == 88 && c == 99) ||
                (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113)
        }
        if inet_pton(AF_INET6, ip, &ipv6) == 1 {
            let b = withUnsafeBytes(of: &ipv6) { Array($0) }
            if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 255 && b[11] == 255 {
                return isProbeReserved(b.suffix(4).map(String.init).joined(separator: "."))
            }
            // Only global unicast, excluding protocol assignments, 6to4 and documentation ranges.
            return b[0] & 224 != 32 || (b[0] == 32 && b[1] == 1 && b[2] < 2) ||
                (b[0] == 32 && b[1] == 1 && b[2] == 13 && b[3] == 184) ||
                (b[0] == 32 && b[1] == 2) || (b[0] == 63 && b[1] == 255 && b[2] & 240 == 0)
        }
        return true // A resolver adapter must return numeric addresses, never another hostname.
    }
}
