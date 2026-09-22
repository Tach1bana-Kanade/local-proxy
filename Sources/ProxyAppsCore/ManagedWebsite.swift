import Foundation

public struct ManagedWebsite: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var domain: String
    public var enabled: Bool
    public var match: RuleMatch
    public var action: RuleAction
    public var createdAt: Date
    public var modifiedAt: Date
    public var source: RuleSource
    public var reason: String?
    public init(id: UUID = UUID(), domain: String, enabled: Bool = true, match: RuleMatch = .suffix,
                action: RuleAction = .proxy, source: RuleSource = .user, now: Date = Date(), reason: String? = nil) {
        self.id = id; self.domain = domain; self.enabled = enabled; self.match = match
        self.action = action; self.source = source; createdAt = now; modifiedAt = now; self.reason = reason
    }
    enum CodingKeys: String, CodingKey { case id, domain, enabled, match, action, createdAt, modifiedAt, source, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); domain = try c.decode(String.self, forKey: .domain)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        match = try c.decodeIfPresent(RuleMatch.self, forKey: .match) ?? .suffix
        action = try c.decodeIfPresent(RuleAction.self, forKey: .action) ?? .proxy
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        source = try c.decodeIfPresent(RuleSource.self, forKey: .source) ?? .migration
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

public struct PACSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var port: UInt16

    public init(enabled: Bool = false, port: UInt16 = 21881) {
        self.enabled = enabled
        self.port = port
    }
}

public struct NetworkServicePACState: Codable, Equatable, Sendable {
    public var serviceName: String
    public var enabled: Bool
    public var url: String?

    public init(serviceName: String, enabled: Bool, url: String?) {
        self.serviceName = serviceName
        self.enabled = enabled
        self.url = url
    }
}

public struct NetworkServiceProxySnapshot: Codable, Equatable, Sendable {
    public var managedPACURL: String
    public var services: [NetworkServicePACState]
    public var ownedPACURLs: [String]?

    public init(managedPACURL: String, services: [NetworkServicePACState]) {
        self.managedPACURL = managedPACURL
        self.services = services
    }
}
