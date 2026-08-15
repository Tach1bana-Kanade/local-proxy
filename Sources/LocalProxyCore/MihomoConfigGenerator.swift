import Foundation

public struct MihomoConfigGenerator {
    public init() {}

    public func generate(from configuration: LocalProxyConfiguration, apiSecret: String) throws -> String {
        try RuleNormalizer.validate(configuration)
        guard !apiSecret.isEmpty else { throw RuleValidationError.emptyValue }

        var lines = [
            "# 由 localproxy 生成；不要在此文件保存 Quickcat 凭据。",
            "mode: rule",
            "log-level: info",
            "ipv6: true",
            "find-process-mode: strict",
            "secret: \(yamlQuote(apiSecret))",
            "allow-lan: false",
        ]
        if let mixedPort = configuration.diagnosticMixedPort {
            lines.append("mixed-port: \(mixedPort)")
            lines.append("bind-address: 127.0.0.1")
        }
        lines.append(contentsOf: [
            "tun:",
            "  enable: \((configuration.tunEnabled ?? true) ? "true" : "false")",
            "  stack: mixed",
            "  auto-route: true",
            "  auto-detect-interface: true",
            "  strict-route: true",
            "  dns-hijack:",
            "    - any:53",
            "dns:",
            "  enable: true",
            "  ipv6: true",
            "  enhanced-mode: fake-ip",
            "  fake-ip-range: 198.18.0.1/16",
            "  fake-ip-filter:",
            "    - '*.lan'",
            "    - '*.local'",
            "    - 'localhost'",
            "  respect-rules: true",
            "  default-nameserver:",
            "    - system",
            "  nameserver:",
            "    - 'https://1.1.1.1/dns-query#QUICKCAT'",
            "  direct-nameserver:",
            "    - system",
            "  proxy-server-nameserver:",
            "    - system",
            "proxies:",
            "  - name: QUICKCAT",
            "    type: socks5",
            "    server: \(yamlQuote(configuration.upstream.host))",
            "    port: \(configuration.upstream.socksPort)",
            "    udp: \(configuration.upstream.udpEnabled ? "true" : "false")",
            "rules:",
        ])

        let directSafetyRules = [
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
            "IP-CIDR6,::1/128,DIRECT,no-resolve",
            "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
            "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
            "DOMAIN,localhost,DIRECT",
            "DOMAIN-SUFFIX,local,DIRECT",
        ]
        lines.append(contentsOf: directSafetyRules.map { "  - " + yamlQuote($0) })

        if let mihomoPath = configuration.mihomoExecutablePath, !mihomoPath.isEmpty {
            lines.append("  - " + yamlQuote("PROCESS-PATH,\(mihomoPath),DIRECT"))
        }
        lines.append("  - " + yamlQuote("PROCESS-NAME,mihomo,DIRECT"))
        lines.append("  - " + yamlQuote("PROCESS-PATH,\(configuration.quickcatExecutablePath),DIRECT"))
        lines.append("  - " + yamlQuote("PROCESS-NAME,Quickcat,DIRECT"))

        let enabledApplications = configuration.applicationRules.filter(\.enabled)
        let enabledDomains = configuration.domainRules.filter(\.enabled)
        for action in [RuleAction.reject, .direct, .proxy] {
            for rule in enabledApplications where rule.action == action {
                if action == .proxy && configuration.failurePolicy == .block && !configuration.upstream.udpEnabled {
                    lines.append("  - " + yamlQuote("AND,((NETWORK,udp),(PROCESS-PATH,\(rule.executablePath))),REJECT"))
                    lines.append("  - " + yamlQuote("AND,((NETWORK,udp),(PROCESS-NAME,\(rule.executableName))),REJECT"))
                }
                lines.append("  - " + yamlQuote("PROCESS-PATH,\(rule.executablePath),\(action.rawValue)"))
                lines.append("  - " + yamlQuote("PROCESS-NAME,\(rule.executableName),\(action.rawValue)"))
            }
            for rule in enabledDomains where rule.action == action {
                let value = try RuleNormalizer.normalize(rule.value, as: rule.match)
                if action == .proxy && configuration.failurePolicy == .block && !configuration.upstream.udpEnabled {
                    lines.append("  - " + yamlQuote(udpFallbackRule(type: rule.match, value: value)))
                }
                lines.append("  - " + yamlQuote(domainRule(type: rule.match, value: value, action: action)))
            }
        }

        lines.append("  - " + yamlQuote("MATCH,DIRECT"))
        return lines.joined(separator: "\n") + "\n"
    }

    private func domainRule(type: DomainMatchType, value: String, action: RuleAction) -> String {
        switch type {
        case .exact: return "DOMAIN,\(value),\(action.rawValue)"
        case .suffix: return "DOMAIN-SUFFIX,\(value),\(action.rawValue)"
        case .wildcard: return "DOMAIN-WILDCARD,\(value),\(action.rawValue)"
        case .ipCIDR:
            let keyword = value.contains(":") ? "IP-CIDR6" : "IP-CIDR"
            return "\(keyword),\(value),\(action.rawValue),no-resolve"
        }
    }

    private func udpFallbackRule(type: DomainMatchType, value: String) -> String {
        let condition: String
        switch type {
        case .exact: condition = "DOMAIN,\(value)"
        case .suffix: condition = "DOMAIN-SUFFIX,\(value)"
        case .wildcard: condition = "DOMAIN-WILDCARD,\(value)"
        case .ipCIDR: condition = "\(value.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(value)"
        }
        return "AND,((NETWORK,udp),(\(condition))),REJECT"
    }

    private func yamlQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
