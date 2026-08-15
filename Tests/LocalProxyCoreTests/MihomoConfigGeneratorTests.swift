import XCTest
@testable import LocalProxyCore

final class MihomoConfigGeneratorTests: XCTestCase {
    func testSafetyRulesPrecedeUserRulesAndDefaultDirectIsLast() throws {
        let configuration = LocalProxyConfiguration(
            mihomoExecutablePath: "/opt/localproxy/mihomo",
            domainRules: [DomainRule(value: "example.com")],
            applicationRules: [
                ApplicationRule(
                    displayName: "Example",
                    executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                    executableName: "Example"
                )
            ]
        )
        let yaml = try MihomoConfigGenerator().generate(from: configuration, apiSecret: "test-secret")
        let loopback = try XCTUnwrap(yaml.range(of: "IP-CIDR,127.0.0.0/8,DIRECT"))
        let quickcat = try XCTUnwrap(yaml.range(of: "PROCESS-PATH,/Applications/Quickcat.app/Contents/MacOS/Quickcat,DIRECT"))
        XCTAssertTrue(yaml.contains("PROCESS-NAME,mihomo,DIRECT"))
        XCTAssertTrue(yaml.contains("PROCESS-NAME,Quickcat,DIRECT"))
        let application = try XCTUnwrap(yaml.range(of: "PROCESS-PATH,/Applications/Example.app/Contents/MacOS/Example,QUICKCAT"))
        XCTAssertTrue(yaml.contains("PROCESS-NAME,Example,QUICKCAT"))
        let domain = try XCTUnwrap(yaml.range(of: "DOMAIN-SUFFIX,example.com,QUICKCAT"))
        XCTAssertLessThan(loopback.lowerBound, quickcat.lowerBound)
        XCTAssertLessThan(quickcat.lowerBound, application.lowerBound)
        XCTAssertLessThan(application.lowerBound, domain.lowerBound)
        XCTAssertTrue(yaml.hasSuffix("  - 'MATCH,DIRECT'\n"))
        XCTAssertTrue(yaml.contains("  respect-rules: true"))
        XCTAssertTrue(yaml.contains("https://1.1.1.1/dns-query#QUICKCAT"))
    }

    func testDisabledRulesAreNotGenerated() throws {
        let configuration = LocalProxyConfiguration(domainRules: [
            DomainRule(value: "disabled.example", enabled: false)
        ])
        let yaml = try MihomoConfigGenerator().generate(from: configuration, apiSecret: "secret")
        XCTAssertFalse(yaml.contains("disabled.example"))
    }

    func testUDPDefaultsToDisabledAndBlockedInLeakProtectionMode() throws {
        let configuration = LocalProxyConfiguration(
            domainRules: [DomainRule(value: "example.com")],
            applicationRules: [ApplicationRule(
                displayName: "Example",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                executableName: "Example"
            )]
        )
        let yaml = try MihomoConfigGenerator().generate(from: configuration, apiSecret: "secret")
        XCTAssertTrue(yaml.contains("    udp: false"))
        let domainReject = try XCTUnwrap(yaml.range(of: "AND,((NETWORK,udp),(DOMAIN-SUFFIX,example.com)),REJECT"))
        let domainProxy = try XCTUnwrap(yaml.range(of: "DOMAIN-SUFFIX,example.com,QUICKCAT"))
        let processReject = try XCTUnwrap(yaml.range(of: "AND,((NETWORK,udp),(PROCESS-PATH,/Applications/Example.app/Contents/MacOS/Example)),REJECT"))
        let processProxy = try XCTUnwrap(yaml.range(of: "PROCESS-PATH,/Applications/Example.app/Contents/MacOS/Example,QUICKCAT"))
        XCTAssertLessThan(domainReject.lowerBound, domainProxy.lowerBound)
        XCTAssertLessThan(processReject.lowerBound, processProxy.lowerBound)
        XCTAssertFalse(yaml.contains("  - 'NETWORK,udp,REJECT'"))
    }

    func testDoesNotExposeUnusedExternalController() throws {
        let yaml = try MihomoConfigGenerator().generate(
            from: LocalProxyConfiguration(),
            apiSecret: "secret"
        )
        XCTAssertFalse(yaml.contains("external-controller:"))
    }

    func testDiagnosticModeDisablesTUNAndBindsMixedPortToLoopback() throws {
        let configuration = LocalProxyConfiguration(tunEnabled: false, diagnosticMixedPort: 17890)
        let yaml = try MihomoConfigGenerator().generate(from: configuration, apiSecret: "secret")
        XCTAssertTrue(yaml.contains("mixed-port: 17890"))
        XCTAssertTrue(yaml.contains("bind-address: 127.0.0.1"))
        XCTAssertTrue(yaml.contains("  enable: false"))
    }
}
