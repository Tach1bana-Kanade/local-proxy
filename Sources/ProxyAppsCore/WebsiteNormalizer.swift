import Darwin
import Foundation

public enum WebsiteNormalizationError: LocalizedError, Equatable {
    case empty
    case unsupportedScheme
    case credentialsNotAllowed
    case portNotAllowed
    case malformedURL
    case wildcardNotAllowed
    case localAddressNotAllowed
    case ipAddressNotAllowed
    case nonASCIIUnsupported
    case invalidDomain

    public var errorDescription: String? {
        switch self {
        case .empty: return "请输入域名或网址。"
        case .unsupportedScheme: return "只支持 http 或 https 网址。"
        case .credentialsNotAllowed: return "网址不能包含用户名或密码。"
        case .portNotAllowed: return "网址不能包含端口。"
        case .malformedURL: return "无法识别该网址，请输入域名或完整的 http/https 网址。"
        case .wildcardNotAllowed: return "无需输入通配符；规则会自动包含所有子域名。"
        case .localAddressNotAllowed: return "localhost、.local 和回环地址始终直连。"
        case .ipAddressNotAllowed: return "网站白名单只接受域名，不接受 IP 地址。"
        case .nonASCIIUnsupported: return "当前版本暂不支持中文或其他非 ASCII 域名，请输入 Punycode 域名。"
        case .invalidDomain: return "域名格式无效。"
        }
    }
}

public enum WebsiteNormalizer {
    public static func normalize(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebsiteNormalizationError.empty }
        guard !trimmed.contains("*") else { throw WebsiteNormalizationError.wildcardNotAllowed }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
            throw WebsiteNormalizationError.nonASCIIUnsupported
        }

        let candidate: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty else {
                if let scheme = URLComponents(string: trimmed)?.scheme,
                   !["http", "https"].contains(scheme.lowercased()) {
                    throw WebsiteNormalizationError.unsupportedScheme
                }
                throw WebsiteNormalizationError.malformedURL
            }
            guard components.user == nil, components.password == nil else {
                throw WebsiteNormalizationError.credentialsNotAllowed
            }
            guard components.port == nil else { throw WebsiteNormalizationError.portNotAllowed }
            candidate = host
        } else {
            guard !trimmed.contains(where: { "/?#@:".contains($0) }) else {
                throw WebsiteNormalizationError.malformedURL
            }
            candidate = trimmed
        }

        var domain = candidate.lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty else { throw WebsiteNormalizationError.invalidDomain }
        if domain == "localhost" || domain.hasSuffix(".local") || domain.hasSuffix(".lan") || domain.hasSuffix(".localhost") || domain == "home.arpa" || domain.hasSuffix(".home.arpa") {
            throw WebsiteNormalizationError.localAddressNotAllowed
        }
        guard !isIPAddress(domain) else {
            if domain == "127.0.0.1" || domain == "::1" { throw WebsiteNormalizationError.localAddressNotAllowed }
            throw WebsiteNormalizationError.ipAddressNotAllowed
        }
        guard domain.utf8.count <= 253 else { throw WebsiteNormalizationError.invalidDomain }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last?.allSatisfy(\.isNumber) == false, labels.allSatisfy(validLabel) else {
            throw WebsiteNormalizationError.invalidDomain
        }
        return domain
    }

    private static func validLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63,
              label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }
}
