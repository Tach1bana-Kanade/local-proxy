import Foundation
import Darwin

public enum RuleValidationError: LocalizedError, Equatable {
    case emptyValue
    case invalidDomain(String)
    case invalidWildcard(String)
    case invalidIPAddress(String)
    case invalidCIDR(String)
    case dangerousCIDR(String)
    case invalidPort(Int)
    case invalidExecutablePath(String)

    public var errorDescription: String? {
        switch self {
        case .emptyValue: return "规则不能为空"
        case .invalidDomain(let value): return "无效域名：\(value)"
        case .invalidWildcard(let value): return "无效通配符域名：\(value)"
        case .invalidIPAddress(let value): return "无效 IP 地址：\(value)"
        case .invalidCIDR(let value): return "无效 CIDR：\(value)"
        case .dangerousCIDR(let value): return "CIDR 范围过宽，已拒绝：\(value)"
        case .invalidPort(let port): return "端口必须在 1...65535：\(port)"
        case .invalidExecutablePath(let path): return "应用规则必须使用绝对可执行文件路径：\(path)"
        }
    }
}

public enum RuleNormalizer {
    public static func normalize(_ rawValue: String, as type: DomainMatchType) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuleValidationError.emptyValue }

        switch type {
        case .exact, .suffix:
            let host = try normalizeHost(trimmed)
            guard !isValidIPAddress(host, ipv6: host.contains(":")), isValidDomain(host) else {
                throw RuleValidationError.invalidDomain(host)
            }
            return host
        case .wildcard:
            var wildcard = trimmed.lowercased()
            if wildcard.hasPrefix("http://") || wildcard.hasPrefix("https://") {
                throw RuleValidationError.invalidWildcard(trimmed)
            }
            while wildcard.hasSuffix(".") { wildcard.removeLast() }
            guard wildcard.contains("*"),
                  wildcard.unicodeScalars.allSatisfy({ scalar in
                      CharacterSet.alphanumerics.contains(scalar) || ".-*?".unicodeScalars.contains(scalar)
                  }),
                  !wildcard.contains("..") else {
                throw RuleValidationError.invalidWildcard(trimmed)
            }
            return wildcard
        case .ipCIDR:
            return try normalizeIPOrCIDR(trimmed)
        }
    }

    public static func validate(_ configuration: LocalProxyConfiguration) throws {
        guard (1...65535).contains(configuration.upstream.socksPort) else {
            throw RuleValidationError.invalidPort(configuration.upstream.socksPort)
        }
        guard (1...65535).contains(configuration.upstream.httpPort) else {
            throw RuleValidationError.invalidPort(configuration.upstream.httpPort)
        }
        if let port = configuration.diagnosticMixedPort, !(1...65535).contains(port) {
            throw RuleValidationError.invalidPort(port)
        }
        for rule in configuration.domainRules where rule.enabled {
            _ = try normalize(rule.value, as: rule.match)
        }
        for rule in configuration.applicationRules where rule.enabled {
            guard rule.executablePath.hasPrefix("/"),
                  !rule.executablePath.contains(","),
                  !rule.executablePath.contains("\n"),
                  !rule.executablePath.contains("\r"),
                  !rule.executableName.isEmpty,
                  !rule.executableName.contains(","),
                  !rule.executableName.contains("\n"),
                  !rule.executableName.contains("\r") else {
                throw RuleValidationError.invalidExecutablePath(rule.executablePath)
            }
        }
    }

    private static func normalizeHost(_ input: String) throws -> String {
        var candidate = input
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let components = URLComponents(string: candidate),
              let host = components.host, !host.isEmpty else {
            throw RuleValidationError.invalidDomain(input)
        }
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }

    private static func isValidDomain(_ host: String) -> Bool {
        guard host.count <= 253, host.contains("."), !host.contains("..") else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
        }
    }

    private static func normalizeIPOrCIDR(_ input: String) throws -> String {
        let pieces = input.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { throw RuleValidationError.invalidCIDR(input) }
        let address = String(pieces[0])
        let isIPv6 = address.contains(":")
        guard isValidIPAddress(address, ipv6: isIPv6) else {
            throw RuleValidationError.invalidIPAddress(address)
        }
        guard pieces.count == 2 else { return address + (isIPv6 ? "/128" : "/32") }
        guard let prefix = Int(pieces[1]),
              (isIPv6 ? 0...128 : 0...32).contains(prefix) else {
            throw RuleValidationError.invalidCIDR(input)
        }
        let minimumPrefix = isIPv6 ? 32 : 8
        guard prefix >= minimumPrefix else { throw RuleValidationError.dangerousCIDR(input) }
        return "\(address)/\(prefix)"
    }

    private static func isValidIPAddress(_ value: String, ipv6: Bool) -> Bool {
        var storage = in6_addr()
        return value.withCString { pointer in
            inet_pton(ipv6 ? AF_INET6 : AF_INET, pointer, &storage) == 1
        }
    }
}
