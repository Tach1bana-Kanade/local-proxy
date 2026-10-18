import Foundation
import XCTest
@testable import ProxyAppsCore

final class CodexProxyToolLauncherTests: XCTestCase {
    func testOverrideIsScopedToProxiedDesktopLaunch() {
        let desktop = ManagedApplication(displayName: "ChatGPT", bundleIdentifier: "com.openai.codex", bundlePath: "/Applications/ChatGPT.app", executableName: "ChatGPT")
        let chrome = ManagedApplication(displayName: "Chrome", bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", executableName: "Google Chrome")
        XCTAssertTrue(CodexProxyToolLauncher.isRequired(for: desktop, usingProxy: true))
        XCTAssertFalse(CodexProxyToolLauncher.isRequired(for: desktop, usingProxy: false))
        XCTAssertFalse(CodexProxyToolLauncher.isRequired(for: chrome, usingProxy: true))
    }

    func testRebuiltMCPConfigurationWithEmptyEnvironmentStillUsesParentProxyMode() throws {
        let fixture = try makeFixture()
        // Reproduce desktop configuration regeneration: keep the selected command,
        // discard proxy variables from the tool environment; its backend still has them.
        let output = try runTool(fixture.launcher, parentEnvironment: ProxyEnvironment.values, arguments: ["first argument", "second"])
        let lines = output.components(separatedBy: "\n")
        for (key, value) in ProxyEnvironment.values { XCTAssertTrue(lines.contains("\(key)=\(value)"), key) }
        XCTAssertTrue(lines.contains("ARG=first argument"))
        XCTAssertTrue(lines.contains("ARG=second"))
    }

    func testOrdinaryParentDoesNotAcquireFixedProxyFromSharedConfiguration() throws {
        let fixture = try makeFixture()
        let output = try runTool(fixture.launcher, parentEnvironment: [:], arguments: [])
        let lines = output.components(separatedBy: "\n")
        for key in ProxyEnvironment.values.keys { XCTAssertTrue(lines.contains("\(key)="), key) }
    }

    func testLowercaseParentProxyAlsoRestoresToolEnvironment() throws {
        let fixture = try makeFixture()
        let output = try runTool(fixture.launcher, parentEnvironment: ["http_proxy": "http://127.0.0.1:21081"], arguments: [])
        XCTAssertTrue(output.contains("HTTPS_PROXY=http://127.0.0.1:21081\n"))
    }

    func testExecutablePathAndArgumentsCannotExecuteShellSubstitutions() throws {
        let fixture = try makeFixture()
        let marker = fixture.directory.appendingPathComponent("unexpected")
        let argument = "$(touch \(marker.path)) `touch \(marker.path)` ' ; $value"
        let output = try runTool(fixture.launcher, parentEnvironment: ProxyEnvironment.values, arguments: [argument])
        XCTAssertTrue(output.contains("ARG=\(argument)\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWrapperIsPrivateAndContentAddressed() throws {
        let fixture = try makeFixture()
        let repeatURL = try CodexProxyToolLauncher.prepare(executableURL: fixture.probe, directory: fixture.directory.appendingPathComponent("runtime"))
        XCTAssertEqual(repeatURL, fixture.launcher)
        let permissions = try FileManager.default.attributesOfItem(atPath: repeatURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repeatURL.deletingLastPathComponent().path).count, 1)
    }

    func testMissingOriginalExecutableFailsWithoutCreatingWrapper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try CodexProxyToolLauncher.prepare(executableURL: directory.appendingPathComponent("missing"), directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeFixture() throws -> (directory: URL, probe: URL, launcher: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Codex proxy \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Special characters in the executable filename must remain literal.
        let probe = directory.appendingPathComponent("probe '$dollar`tick`$(name);中文.sh")
        let script = "#!/bin/sh\n" + ProxyEnvironment.values.keys.sorted().map { "printf '%s=%s\\n' '\($0)' \"${\($0)-}\"\n" }.joined() + "for argument do printf 'ARG=%s\\n' \"$argument\"; done\n"
        try Data(script.utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        return (directory, probe, try CodexProxyToolLauncher.prepare(executableURL: probe, directory: directory.appendingPathComponent("runtime")))
    }

    private func runTool(_ launcher: URL, parentEnvironment: [String: String], arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Retain a live native parent (like the Rust Codex backend), but sanitize
        // the child exactly as an MCP spawn does. macOS ps cannot reliably read
        // a shell parent's initial environment after the shell rewrites it.
        process.arguments = ["-c", "import subprocess,sys; sys.exit(subprocess.call(sys.argv[1:], env={}))", launcher.path] + arguments
        process.environment = parentEnvironment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
}
