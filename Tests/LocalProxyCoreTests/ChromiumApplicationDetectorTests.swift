import Foundation
import XCTest
@testable import ProxyAppsCore

final class ChromiumApplicationDetectorTests: XCTestCase {
    func testDetectsElectronFramework() throws {
        let bundleURL = try makeBundle(bundleIdentifier: "example.electron")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(ChromiumApplicationDetector.detect(bundleURL: bundleURL), .chromium)
    }

    func testDetectsKnownChromiumBundleIdentifier() throws {
        let bundleURL = try makeBundle(bundleIdentifier: "com.google.Chrome")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        XCTAssertEqual(ChromiumApplicationDetector.detect(bundleURL: bundleURL), .chromium)
    }

    func testDetectsChromiumFrameworkByName() throws {
        let bundleURL = try makeBundle(bundleIdentifier: "example.chromium")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/Frameworks/Example Chromium Framework.framework"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(ChromiumApplicationDetector.detect(bundleURL: bundleURL), .chromium)
    }

    func testDetectsCrashpadHandlerInsideFramework() throws {
        let bundleURL = try makeBundle(bundleIdentifier: "example.crashpad")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let handlerURL = bundleURL.appendingPathComponent(
            "Contents/Frameworks/Example.framework/Helpers/chrome_crashpad_handler"
        )
        try FileManager.default.createDirectory(
            at: handlerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: handlerURL.path, contents: Data()))

        XCTAssertEqual(ChromiumApplicationDetector.detect(bundleURL: bundleURL), .chromium)
    }

    func testValidNonChromiumBundleIsNotDetected() throws {
        let bundleURL = try makeBundle(bundleIdentifier: "com.apple.Safari")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        XCTAssertEqual(ChromiumApplicationDetector.detect(bundleURL: bundleURL), .notChromium)
    }

    func testMissingBundleIsReportedAsUnreadable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("不存在-\(UUID().uuidString).app")
        guard case .unreadable = ChromiumApplicationDetector.detect(bundleURL: url) else {
            return XCTFail("缺失的应用包应返回 unreadable")
        }
    }

    func testProxyLaunchArgumentsAreAddedOnlyForProxiedChromiumApps() {
        let expected = ["--proxy-server=http://127.0.0.1:21081"]
        XCTAssertEqual(ProxyLaunchArguments.arguments(usingProxy: true, isChromium: true), expected)
        XCTAssertTrue(ProxyLaunchArguments.arguments(usingProxy: true, isChromium: false).isEmpty)
        XCTAssertTrue(ProxyLaunchArguments.arguments(usingProxy: false, isChromium: true).isEmpty)
    }

    func testProxyLaunchArgumentsUseEnvironmentHTTPProxy() {
        let arguments = ProxyLaunchArguments.arguments(
            usingProxy: true,
            isChromium: true,
            environment: ["HTTP_PROXY": "http://127.0.0.1:3210"]
        )
        XCTAssertEqual(arguments, ["--proxy-server=http://127.0.0.1:3210"])
    }

    private func makeBundle(bundleIdentifier: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromiumDetector-\(UUID().uuidString).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}
