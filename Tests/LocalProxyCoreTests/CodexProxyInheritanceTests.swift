import Foundation
import XCTest
@testable import ProxyAppsCore

final class CodexProxyInheritanceTests: XCTestCase {
    private let chrome = ManagedApplication(displayName: "Chrome", bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", executableName: "Google Chrome")
    private let other = ManagedApplication(displayName: "Other", bundleIdentifier: "example.other", bundlePath: "/Applications/Other.app", executableName: "Other")

    func testChromePACProxiesItsBackendWithoutAddingFixedBrowserArguments() {
        XCTAssertEqual(CodexProxyInheritance.launchEnvironment(usingProxy: false, pacURL: "http://localhost/proxy.pac", application: chrome), ProxyEnvironment.values)
        XCTAssertNil(CodexProxyInheritance.launchEnvironment(usingProxy: false, pacURL: "http://localhost/proxy.pac", application: other))
        XCTAssertNil(CodexProxyInheritance.launchEnvironment(usingProxy: false, pacURL: nil, application: chrome))
        XCTAssertEqual(CodexProxyInheritance.launchEnvironment(usingProxy: true, pacURL: nil, application: other), ProxyEnvironment.values)
        XCTAssertEqual(ProxyLaunchArguments.websiteRules(pacURL: "http://localhost/proxy.pac"), ["--proxy-pac-url=http://localhost/proxy.pac"])
    }

    func testMigratesQuickcatOverridesAndPreservesOtherServersAndSettings() throws {
        let unrelated = "[mcp_servers.other.env]\nHTTP_PROXY = \"http://example.com:80\"\nTOKEN = \"unchanged\"\n"
        let source = "model = \"sample\"\n[mcp_servers.node_repl]\ncommand = \"/tool\"\n[mcp_servers.node_repl.env]\nNODE_REPL_NODE_PATH = \"/node\"\n" + ProxyEnvironment.values.sorted { $0.key < $1.key }.map { "\($0.key) = \"\($0.value)\"\n" }.joined() + unrelated
        let result = try CodexProxyInheritance.updating(source)
        XCTAssertTrue(result.hasPrefix("model = \"sample\"\n"))
        XCTAssertTrue(result.contains("command = \"/tool\"\n"))
        XCTAssertTrue(result.contains("NODE_REPL_NODE_PATH = \"/node\"\n"))
        XCTAssertTrue(result.hasSuffix(unrelated))
        XCTAssertFalse(result.contains("HTTP_PROXY = \"http://127.0.0.1:21081\""))
        for key in CodexProxyInheritance.variableNames { XCTAssertTrue(result.contains("\"\(key)\"")) }
        XCTAssertEqual(try CodexProxyInheritance.updating(result), result)
    }

    func testKeepsAdditionalInheritedVariablesCommentsAndExplicitOverrides() throws {
        let source = "[mcp_servers.node_repl]\nenv_vars = ['CUSTOM', \"HTTP_PROXY\", ] # keep\n[mcp_servers.node_repl.env]\nHTTP_PROXY = \"http://custom:8080\"\n"
        let result = try CodexProxyInheritance.updating(source)
        XCTAssertTrue(result.contains("'CUSTOM', \"HTTP_PROXY\", ] # keep"))
        XCTAssertTrue(result.contains("HTTP_PROXY = \"http://custom:8080\""))
        XCTAssertEqual(try CodexProxyInheritance.updating(result), result)
    }

    func testDoesNotCreateAnIncompleteServer() throws {
        let source = "[mcp_servers.other]\ncommand = \"/other\"\n"
        XCTAssertEqual(try CodexProxyInheritance.updating(source), source)
    }

    func testUnsupportedConfigurationIsNotPartiallyWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.toml")
        for source in ["[mcp_servers.node_repl]\nenv_vars = [\n\"CUSTOM\"\n]\n", "[mcp_servers.node_repl]\nenv_vars = [123]\n", "[mcp_servers.node_repl]\nenv_vars = []\nenv_vars = []\n"] {
            try Data(source.utf8).write(to: url)
            XCTAssertThrowsError(try CodexProxyInheritance.prepare(configURL: url))
            XCTAssertEqual(try String(contentsOf: url), source)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["config.toml"])
    }

    func testFileUpdateBacksUpOriginalAndIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.toml")
        let source = "[mcp_servers.node_repl]\ncommand = \"/tool\"\n"
        try Data(source.utf8).write(to: url)
        XCTAssertTrue(try CodexProxyInheritance.prepare(configURL: url))
        XCTAssertFalse(try CodexProxyInheritance.prepare(configURL: url))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("config-before-proxyapps-") })
        XCTAssertEqual(try String(contentsOf: backup), source)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
