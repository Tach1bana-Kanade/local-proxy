import XCTest
@testable import ProxyAppsCore

final class WebsiteProxyTests: XCTestCase {
    func testNormalizerExtractsURLHost() throws {
        XCTAssertEqual(try WebsiteNormalizer.normalize(" https://GitHub.com/openai/codex?tab=readme "), "github.com")
    }

    func testNormalizerLowercasesAndRemovesTrailingDot() throws {
        XCTAssertEqual(try WebsiteNormalizer.normalize("WWW.GitHub.COM."), "www.github.com")
    }

    func testNormalizerRejectsUnsafeAndLocalInputs() {
        let inputs = ["ftp://example.com", "https://u:p@example.com", "https://example.com:8080", "example.com/path", "*.example.com", ".example.com", "localhost", "host.local", "x.localhost", "router.home.arpa", "127.1", "0177.0.0.1", "127.0.0.1", "1.1.1.1", "bad_domain.com", "例子.测试", "example.com\";alert(1)//"]
        for input in inputs {
            XCTAssertThrowsError(try WebsiteNormalizer.normalize(input), input)
        }
    }

    func testNormalizedDomainsCanBeDeduplicated() throws {
        let values = try ["github.com", "HTTPS://GITHUB.COM/path", "github.com."].map(WebsiteNormalizer.normalize)
        XCTAssertEqual(Set(values), ["github.com"])
    }

    func testPACMatching() {
        let rules = [ManagedWebsite(domain: "github.com")]
        XCTAssertTrue(PACGenerator.shouldProxy(host: "github.com", websites: rules))
        XCTAssertTrue(PACGenerator.shouldProxy(host: "api.github.com", websites: rules))
        XCTAssertFalse(PACGenerator.shouldProxy(host: "notgithub.com", websites: rules))
        XCTAssertFalse(PACGenerator.shouldProxy(host: "localhost", websites: rules))
        XCTAssertFalse(PACGenerator.shouldProxy(host: "127.0.0.2", websites: rules))
        XCTAssertFalse(PACGenerator.shouldProxy(host: "::1", websites: rules))
        XCTAssertFalse(PACGenerator.shouldProxy(host: "github.com", websites: [ManagedWebsite(domain: "github.com", enabled: false)]))
    }

    func testPACIsStableSafeAndHasNoDirectFallback() {
        let rules = [ManagedWebsite(domain: "b.example.com"), ManagedWebsite(domain: "a.example.com")]
        let pac = PACGenerator.generate(websites: rules)
        XCTAssertEqual(pac, PACGenerator.generate(websites: rules.reversed()))
        XCTAssertTrue(PACGenerator.shouldProxy(host: "a.example.com", websites: rules))
        XCTAssertFalse(pac.contains("PROXY 127.0.0.1:21081; DIRECT"))
        XCTAssertFalse(PACGenerator.shouldProxy(host: "unknown.test", websites: []))
        let hostile = PACGenerator.generate(websites: [.init(domain: "example.com\"; return \"PROXY evil\"")])
        XCTAssertTrue(hostile.contains("example.com\\\"; return "))
        XCTAssertEqual(hostile.components(separatedBy: "return \"PROXY 127.0.0.1:21081\"").count, 2)
    }

    func testWebsiteAndSnapshotJSONRoundTrips() throws {
        let websites = [ManagedWebsite(domain: "github.com")]
        XCTAssertEqual(try JSONDecoder().decode([ManagedWebsite].self, from: JSONEncoder().encode(websites)), websites)
        let snapshot = NetworkServiceProxySnapshot(managedPACURL: "http://127.0.0.1:21881/proxy.pac", services: [.init(serviceName: "Wi-Fi", enabled: false, url: nil)])
        XCTAssertEqual(try JSONDecoder().decode(NetworkServiceProxySnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testSystemProxyParsingAndRestorePlan() throws {
        let list = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (*) VPN
        (Hardware Port: VPN, Device: )
        (2) USB 10/100/1000 LAN
        (Hardware Port: USB LAN, Device: en5)
        """
        XCTAssertEqual(try SystemPACParser.activeServiceNames(from: list), ["Wi-Fi", "USB 10/100/1000 LAN"])
        let original = try SystemPACParser.pacState(serviceName: "Wi-Fi", from: "URL: http://old/pac\nEnabled: No")
        let current = NetworkServicePACState(serviceName: "Wi-Fi", enabled: true, url: "http://127.0.0.1:21881/proxy.pac")
        XCTAssertEqual(SystemPACPlanner.restoreDecision(current: current, original: original, managedPACURL: current.url!), .restore(original))
        let changed = NetworkServicePACState(serviceName: "Wi-Fi", enabled: true, url: "http://user/new.pac")
        XCTAssertEqual(SystemPACPlanner.restoreDecision(current: changed, original: original, managedPACURL: current.url!), .conflict(current: changed, original: original))
    }

    func testPartialApplyFailureRollsBackModifiedServices() {
        let fake = FakePACClient(states: [
            .init(serviceName: "Wi-Fi", enabled: false, url: nil),
            .init(serviceName: "Ethernet", enabled: true, url: "http://old/pac"),
        ], failingService: "Ethernet")
        XCTAssertThrowsError(try PACTransaction(client: fake).apply(
            serviceNames: ["Wi-Fi", "Ethernet"], managedPACURL: "http://127.0.0.1:21881/proxy.pac"
        ))
        XCTAssertEqual(fake.states["Wi-Fi"], .init(serviceName: "Wi-Fi", enabled: false, url: nil))
        XCTAssertEqual(fake.states["Ethernet"], .init(serviceName: "Ethernet", enabled: true, url: "http://old/pac"))
    }

    func testRestoreRefusesConflictWithoutChangingAnything() {
        let fake = FakePACClient(states: [
            .init(serviceName: "Wi-Fi", enabled: true, url: "http://other/pac")
        ])
        let snapshot = NetworkServiceProxySnapshot(
            managedPACURL: "http://127.0.0.1:21881/proxy.pac",
            services: [.init(serviceName: "Wi-Fi", enabled: false, url: nil)]
        )
        XCTAssertThrowsError(try PACTransaction(client: fake).restore(snapshot))
        XCTAssertEqual(fake.setCalls, [])
    }

    func testPartialRestoreFailureReturnsEarlierServicesToManagedPAC() {
        let managedURL = "http://127.0.0.1:21881/proxy.pac"
        let fake = FakePACClient(states: [
            .init(serviceName: "Wi-Fi", enabled: true, url: managedURL),
            .init(serviceName: "Ethernet", enabled: true, url: managedURL),
        ], failingService: "Ethernet", failWhenURL: "http://old/ethernet.pac")
        let snapshot = NetworkServiceProxySnapshot(managedPACURL: managedURL, services: [
            .init(serviceName: "Wi-Fi", enabled: false, url: nil),
            .init(serviceName: "Ethernet", enabled: true, url: "http://old/ethernet.pac"),
        ])
        XCTAssertThrowsError(try PACTransaction(client: fake).restore(snapshot))
        XCTAssertEqual(fake.states["Wi-Fi"], .init(serviceName: "Wi-Fi", enabled: true, url: managedURL))
        XCTAssertEqual(fake.states["Ethernet"], .init(serviceName: "Ethernet", enabled: true, url: managedURL))
    }
}

private final class FakePACClient: SystemPACClient {
    var states: [String: NetworkServicePACState]
    var failingService: String?
    var failWhenURL: String?
    var setCalls: [NetworkServicePACState] = []

    init(states: [NetworkServicePACState], failingService: String? = nil, failWhenURL: String? = "127.0.0.1") {
        self.states = Dictionary(uniqueKeysWithValues: states.map { ($0.serviceName, $0) })
        self.failingService = failingService
        self.failWhenURL = failWhenURL
    }

    func currentState(for serviceName: String) throws -> NetworkServicePACState {
        states[serviceName]!
    }

    func setState(_ state: NetworkServicePACState) throws {
        setCalls.append(state)
        if state.serviceName == failingService,
           failWhenURL.map({ state.url?.contains($0) == true }) == true {
            throw NSError(domain: "Fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟失败"])
        }
        states[state.serviceName] = state
    }
}
