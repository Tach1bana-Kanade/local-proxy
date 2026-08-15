import Foundation

public struct ManagedWebsite: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var domain: String
    public var enabled: Bool

    public init(id: UUID = UUID(), domain: String, enabled: Bool = true) {
        self.id = id
        self.domain = domain
        self.enabled = enabled
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

    public init(managedPACURL: String, services: [NetworkServicePACState]) {
        self.managedPACURL = managedPACURL
        self.services = services
    }
}
