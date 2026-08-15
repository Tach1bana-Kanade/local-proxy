import XCTest
@testable import ProxyAppsCore

final class ProxyAppsModelsTests: XCTestCase {
    func testProxyEnvironmentContainsUppercaseAndLowercaseVariables() {
        let environment = ProxyEnvironment.values
        XCTAssertEqual(environment.count, 8)
        XCTAssertEqual(environment["HTTP_PROXY"], "http://127.0.0.1:21081")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://127.0.0.1:21081")
        XCTAssertEqual(environment["ALL_PROXY"], "socks5h://127.0.0.1:21080")
        XCTAssertEqual(environment["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(environment["http_proxy"], environment["HTTP_PROXY"])
        XCTAssertEqual(environment["https_proxy"], environment["HTTPS_PROXY"])
        XCTAssertEqual(environment["all_proxy"], environment["ALL_PROXY"])
        XCTAssertEqual(environment["no_proxy"], environment["NO_PROXY"])
    }

    func testSystemProxyParserRecognizesSupportedProxyTypes() {
        XCTAssertTrue(DiagnosticParser.systemProxyEnabled(in: "HTTPEnable : 1\nHTTPSEnable : 0"))
        XCTAssertTrue(DiagnosticParser.systemProxyEnabled(in: "SOCKSEnable : 1"))
        XCTAssertFalse(DiagnosticParser.systemProxyEnabled(in: "HTTPEnable : 0\nHTTPSEnable : 0\nSOCKSEnable : 0"))
    }

    func testLsofMachineOutputParserFindsQuickcatConnections() {
        let output = """
        p123
        cCodex Helper
        f18
        n127.0.0.1:50123->127.0.0.1:21081
        p456
        cQuickcat
        f10
        n127.0.0.1:21080
        """
        let connections = DiagnosticParser.proxyConnections(in: output)
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections[0].pid, 123)
        XCTAssertEqual(connections[0].processName, "Codex Helper")
        XCTAssertEqual(connections[1].endpoint, "127.0.0.1:21080")
    }

    func testManagedApplicationJSONRoundTripPreservesPathsWithSpecialCharacters() throws {
        let application = ManagedApplication(
            displayName: "My App",
            bundleIdentifier: "example.my-app",
            bundlePath: "/Applications/My App's 测试.app",
            executableName: "My App"
        )
        let data = try JSONEncoder().encode(application)
        XCTAssertEqual(try JSONDecoder().decode(ManagedApplication.self, from: data), application)
    }
}
