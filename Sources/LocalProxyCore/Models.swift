import Foundation

public enum RuleAction: String, Codable, CaseIterable, Sendable {
    case proxy = "QUICKCAT"
    case direct = "DIRECT"
    case reject = "REJECT"
}

public enum DomainMatchType: String, Codable, CaseIterable, Sendable {
    case exact
    case suffix
    case wildcard
    case ipCIDR = "ip-cidr"
}

public struct DomainRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var value: String
    public var match: DomainMatchType
    public var action: RuleAction
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        value: String,
        match: DomainMatchType = .suffix,
        action: RuleAction = .proxy,
        enabled: Bool = true
    ) {
        self.id = id
        self.value = value
        self.match = match
        self.action = action
        self.enabled = enabled
    }
}

public struct ApplicationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var bundleIdentifier: String?
    public var executablePath: String
    public var executableName: String
    public var includeHelpers: Bool
    public var action: RuleAction
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        executablePath: String,
        executableName: String,
        includeHelpers: Bool = false,
        action: RuleAction = .proxy,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.executableName = executableName
        self.includeHelpers = includeHelpers
        self.action = action
        self.enabled = enabled
    }
}

public enum FailurePolicy: String, Codable, Sendable {
    case block = "block"
    case direct = "direct"
}

public struct UpstreamSettings: Codable, Equatable, Sendable {
    public var host: String
    public var socksPort: Int
    public var httpPort: Int
    public var udpEnabled: Bool

    public init(
        host: String = "127.0.0.1",
        socksPort: Int = 21080,
        httpPort: Int = 21081,
        udpEnabled: Bool = false
    ) {
        self.host = host
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.udpEnabled = udpEnabled
    }
}

public struct LocalProxyConfiguration: Codable, Equatable, Sendable {
    public var upstream: UpstreamSettings
    public var failurePolicy: FailurePolicy
    /// `nil` means enabled. Set to `false` only for an explicit non-TUN smoke test.
    public var tunEnabled: Bool?
    /// Optional loopback mixed proxy port used by phase-0 diagnostics.
    public var diagnosticMixedPort: Int?
    public var mihomoExecutablePath: String?
    public var quickcatExecutablePath: String
    public var domainRules: [DomainRule]
    public var applicationRules: [ApplicationRule]

    public init(
        upstream: UpstreamSettings = UpstreamSettings(),
        failurePolicy: FailurePolicy = .block,
        tunEnabled: Bool? = nil,
        diagnosticMixedPort: Int? = nil,
        mihomoExecutablePath: String? = nil,
        quickcatExecutablePath: String = "/Applications/Quickcat.app/Contents/MacOS/Quickcat",
        domainRules: [DomainRule] = [],
        applicationRules: [ApplicationRule] = []
    ) {
        self.upstream = upstream
        self.failurePolicy = failurePolicy
        self.tunEnabled = tunEnabled
        self.diagnosticMixedPort = diagnosticMixedPort
        self.mihomoExecutablePath = mihomoExecutablePath
        self.quickcatExecutablePath = quickcatExecutablePath
        self.domainRules = domainRules
        self.applicationRules = applicationRules
    }
}
