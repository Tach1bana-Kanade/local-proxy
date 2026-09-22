import XCTest
@testable import LocalProxyApp
@testable import ProxyAppsCore

@MainActor
final class RoutingControllerTests: XCTestCase {
    func testFirstConsentCancelSmartWithoutManualAndRestartOff() async throws {
        let (controller, manager, system) = fixture()
        controller.parsedRules = try RuleSetParser.parse(direct: Data("direct.test".utf8), proxy: Data("proxy.test".utf8))
        controller.requestSmart(true)
        XCTAssertTrue(controller.showingConsent); XCTAssertEqual(controller.activeMode, .off)
        controller.showingConsent = false
        XCTAssertTrue(system.writes.isEmpty); XCTAssertTrue(controller.configuration.needsConfirmation)
        await controller.setMode(.smart, consent: true)
        XCTAssertEqual(controller.activeMode, .smart); XCTAssertTrue(controller.websites.isEmpty)
        XCTAssertFalse(controller.configuration.needsConfirmation); XCTAssertFalse(system.writes.isEmpty)
        XCTAssertNotNil(try manager.readRestoreSnapshot())
        await controller.setMode(.off)
        XCTAssertEqual(controller.activeMode, .off); XCTAssertEqual(system.state.url, "http://original/pac")
        let restarted = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in })
        XCTAssertEqual(restarted.activeMode, .off); XCTAssertFalse(restarted.configuration.needsConfirmation)
        await controller.shutdownForTermination(); await restarted.shutdownForTermination()
    }
    func testOffEditsAndManualZeroRulesAndUpdatePreservesOriginal() async throws {
        let (controller, manager, system) = fixture()
        let saved = await controller.saveRule("https://www.example.com/private?q=secret", action: .direct, match: .exact)
        XCTAssertTrue(saved); XCTAssertTrue(system.writes.isEmpty)
        XCTAssertEqual(controller.websites.first?.domain, "www.example.com")
        await controller.setMode(.manual)
        XCTAssertEqual(controller.activeMode, .manual)
        let first = try XCTUnwrap(manager.readRestoreSnapshot())
        _ = await controller.saveRule("proxy.test", action: .proxy, match: .suffix)
        let revised = try XCTUnwrap(manager.readRestoreSnapshot())
        XCTAssertEqual(first.services, revised.services); XCTAssertNotEqual(first.managedPACURL, revised.managedPACURL)
        await controller.shutdownForTermination()
        XCTAssertEqual(system.state.url, "http://original/pac")
        XCTAssertFalse(manager.hasRestoreSnapshot)
    }
    func testFailedEnableKeepsModeAndRulesAndExternalConflictIsNotOverwritten() async throws {
        let (controller, manager, system) = fixture()
        await controller.setMode(.manual)
        let before = controller.configuration
        system.state.url = "http://external/pac"
        let count = system.writes.count
        let success = await controller.saveRule("example.com", action: .proxy, match: .suffix)
        XCTAssertFalse(success); XCTAssertEqual(controller.configuration, before)
        XCTAssertEqual(try manager.routingStore.load(), before); XCTAssertEqual(system.writes.count, count)
        await controller.restoreOriginalNetworkSettings()
        XCTAssertEqual(controller.websitePACStatus, .needsRestore); XCTAssertEqual(system.state.url, "http://external/pac")
        await controller.shutdownForTermination()
    }
    func testUnhealthyPACAndUnavailableQuickcatDoNotApply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-controller-" + UUID().uuidString)
        let manager = ProxyAppsManager(directory: directory, quickcatInspection: { QuickcatStatus(socksAvailable: false, httpAvailable: false) }), system = FakeSystem()
        let controller = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in XCTFail() })
        await controller.setMode(.manual)
        XCTAssertEqual(controller.activeMode, .off); XCTAssertTrue(system.writes.isEmpty)
        let goodManager = ProxyAppsManager(directory: directory, quickcatInspection: { QuickcatStatus(socksAvailable: true, httpAvailable: true) })
        let unhealthy = ProxyAppsController(manager: goodManager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in throw RoutingError.invalid("health failed") })
        await unhealthy.setMode(.manual)
        XCTAssertEqual(unhealthy.activeMode, .off); XCTAssertTrue(system.writes.isEmpty)
        await controller.shutdownForTermination(); await unhealthy.shutdownForTermination()
    }
    func testCorruptConfigurationAndRestoreJournalBlockWrites() async throws {
        let (controller, manager, system) = fixture()
        await controller.shutdownForTermination()
        try PrivateFile.write(Data("broken".utf8), to: manager.routingStore.directory.appendingPathComponent("routing.json"))
        let broken = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in })
        let result = await broken.saveRule("example.com", action: .proxy, match: .suffix)
        XCTAssertFalse(result); XCTAssertTrue(system.writes.isEmpty)
        XCTAssertEqual(try String(contentsOf: manager.routingStore.directory.appendingPathComponent("routing.json")), "broken")
        await broken.shutdownForTermination()
    }
    func testConfigurationWriteFailureRollsBackMemoryDiskAndPAC() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-write-failure-" + UUID().uuidString)
        let fault = WriteFault(), system = FakeSystem()
        let manager = ProxyAppsManager(directory: dir, quickcatInspection: { QuickcatStatus(socksAvailable: true, httpAvailable: true) }, routingWriter: { data, url in
            if fault.failNext { fault.failNext = false; throw RoutingError.invalid("injected disk failure") }
            try PrivateFile.write(data, to: url)
        })
        let controller = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in })
        await controller.setMode(.manual)
        let config = controller.configuration, url = system.state.url
        fault.failNext = true
        let result = await controller.saveRule("example.com", action: .proxy, match: .suffix)
        XCTAssertFalse(result)
        XCTAssertEqual(controller.configuration, config); XCTAssertEqual(try manager.routingStore.load(), config)
        XCTAssertEqual(system.state.url, url); XCTAssertEqual(controller.websitePACStatus, .enabled)
        await controller.shutdownForTermination()
    }
    func testOffUpdatePreservesManualAndRollbackPausesAutomatic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-update-" + UUID().uuidString), system = FakeSystem()
        let manager = ProxyAppsManager(directory: dir)
        let updater = RuleSetUpdater(download: { url, _, _ in
            if url.host == "api.github.com" { return Data("{\"sha\":\"\(String(repeating: "b", count: 40))\"}".utf8) }
            return Data((url.path.hasSuffix("direct-list.txt") ? "direct.test" : "proxy.test").utf8)
        })
        let controller = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in }, updater: updater)
        controller.ruleCache = RuleSetCache(current: RuleSetSnapshot(version: String(repeating: "a", count: 40), direct: Data("old.test".utf8), proxy: Data("oldproxy.test".utf8)))
        let saved = await controller.saveRule("example.com", action: .direct, match: .exact)
        XCTAssertTrue(saved)
        let manual = controller.websites
        await controller.updateRules()
        XCTAssertEqual(controller.ruleCache?.current.version, String(repeating: "b", count: 40))
        XCTAssertEqual(controller.websites, manual); XCTAssertTrue(system.writes.isEmpty)
        await controller.rollbackRules()
        XCTAssertEqual(controller.ruleCache?.current.version, String(repeating: "a", count: 40))
        XCTAssertFalse(controller.configuration.automaticUpdates)
        XCTAssertFalse(try manager.routingStore.load().automaticUpdates)
        XCTAssertEqual(controller.websites, manual); XCTAssertTrue(system.writes.isEmpty)
        await controller.shutdownForTermination()
    }
    func testContentStoreServesImmutableRevisionsAndRejectsUnknown() {
        let store = PACContentStore(), first = store.publish("first"), second = store.publish("second")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.content(revision: first), "first")
        XCTAssertEqual(store.content(revision: second), "second")
        XCTAssertEqual(store.content(revision: nil), "second")
        XCTAssertNil(store.content(revision: "unknown"))
    }
    func testFailedQuitPreservesPACServiceAndCanRetryAfterConflictResolved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-quit-" + UUID().uuidString)
        let manager = ProxyAppsManager(directory: directory, quickcatInspection: { QuickcatStatus(socksAvailable: true, httpAvailable: true) })
        let system = FakeSystem(), server = FakeServer()
        let controller = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: server, pacValidation: { _ in })
        await controller.setMode(.manual)
        let owned = system.state.url
        system.state.url = "http://external/pac"
        let stops = server.stops
        let failed = await controller.shutdownForTermination()
        XCTAssertFalse(failed); XCTAssertFalse(controller.preparingToQuit)
        XCTAssertEqual(server.stops, stops); XCTAssertTrue(manager.hasRestoreSnapshot)
        XCTAssertEqual(system.state.url, "http://external/pac")
        system.state.url = owned
        let succeeded = await controller.shutdownForTermination()
        XCTAssertTrue(succeeded); XCTAssertGreaterThan(server.stops, stops)
        XCTAssertFalse(manager.hasRestoreSnapshot); XCTAssertEqual(system.state.url, "http://original/pac")
    }
    func testQuitDuringPACHealthCheckWaitsForTransactionThenRestores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-quit-race-" + UUID().uuidString)
        let manager = ProxyAppsManager(directory: directory, quickcatInspection: { QuickcatStatus(socksAvailable: true, httpAvailable: true) })
        let system = FakeSystem(), gate = HealthGate()
        let controller = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in
            gate.entered = true
            while !gate.release { try await Task.sleep(nanoseconds: 5_000_000) }
        })
        let enabling = Task { await controller.setMode(.manual) }
        while !gate.entered { try await Task.sleep(nanoseconds: 5_000_000) }
        let quitting = Task { await controller.shutdownForTermination() }
        while !controller.preparingToQuit { try await Task.sleep(nanoseconds: 5_000_000) }
        gate.release = true
        await enabling.value
        let quit = await quitting.value
        XCTAssertTrue(quit); XCTAssertFalse(manager.hasRestoreSnapshot)
        XCTAssertEqual(system.state.url, "http://original/pac"); XCTAssertFalse(system.state.enabled)
    }
    func testStagingDoesNotReplaceLatestAndUnusedSnapshotsArePruned() {
        let store = PACContentStore(), first = store.publish("first")
        let candidate = store.stage("candidate")
        XCTAssertEqual(store.content(revision: nil), "first")
        store.retain([first]); XCTAssertNil(store.content(revision: candidate))
        let pinned = store.publish("pinned")
        for index in 0..<100 { _ = store.publish("version-\(index)"); store.retain([pinned]) }
        XCTAssertEqual(store.snapshotCount, 2)
        XCTAssertEqual(store.content(revision: pinned), "pinned")
        XCTAssertEqual(store.content(revision: nil), "version-99")
        store.retain([]); XCTAssertEqual(store.snapshotCount, 1)
    }
    func testOversizedOffUpdatePreservesLastWorkingCacheAndConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-size-update-" + UUID().uuidString)
        let manager = ProxyAppsManager(directory: directory), system = FakeSystem()
        let previous = RuleSetCache(current: RuleSetSnapshot(version: String(repeating: "a", count: 40), direct: Data("direct.test".utf8), proxy: Data("proxy.test".utf8)))
        try manager.ruleSetStore.save(previous)
        let large = Data((0..<25_000).map { String(RuleSetSnapshot.hash(Data(String($0).utf8)).prefix(60)) + ".test" }.joined(separator: "\n").utf8)
        let updater = RuleSetUpdater(download: { url, _, _ in
            if url.host == "api.github.com" { return Data("{\"sha\":\"\(String(repeating: "b", count: 40))\"}".utf8) }
            return url.path.hasSuffix("direct-list.txt") ? Data("direct.test".utf8) : large
        })
        let controller = ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in }, updater: updater)
        controller.ruleCache = previous
        let original = controller.configuration
        await controller.updateRules()
        XCTAssertEqual(controller.configuration, original)
        XCTAssertEqual(controller.ruleCache?.current, previous.current)
        XCTAssertEqual(try manager.ruleSetStore.load().0.current, previous.current)
        XCTAssertTrue(controller.ruleError?.contains("1 MiB") == true)
        XCTAssertTrue(system.writes.isEmpty)
        await controller.shutdownForTermination()
    }
    private func fixture() -> (ProxyAppsController, ProxyAppsManager, FakeSystem) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-controller-" + UUID().uuidString)
        let manager = ProxyAppsManager(directory: dir, quickcatInspection: { QuickcatStatus(socksAvailable: true, httpAvailable: true) }), system = FakeSystem()
        return (ProxyAppsController(manager: manager, systemPACManager: system.manager, pacServer: FakeServer(), pacValidation: { _ in }), manager, system)
    }
}
private final class FakeServer: PACServing {
    func start(preferredPort: UInt16) throws -> UInt16 { 21881 }
    var stops = 0
    func stop() { stops += 1 }
}
private final class FakeSystem {
    var state = NetworkServicePACState(serviceName: "Wi-Fi", enabled: false, url: "http://original/pac")
    var writes: [[String]] = []
    lazy var manager = SystemPACManager { [self] args in
        switch args[0] {
        case "-listnetworkserviceorder": return (0, "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)")
        case "-getautoproxyurl": return (0, "URL: \(state.url ?? "")\nEnabled: \(state.enabled ? "Yes" : "No")")
        case "-setautoproxyurl": writes.append(args); state.url = args[2]; return (0, "")
        case "-setautoproxystate": writes.append(args); state.enabled = args[2] == "on"; return (0, "")
        default: throw RoutingError.invalid("unexpected command")
        }
    }
}

private final class WriteFault { var failNext = false }

@MainActor private final class HealthGate { var entered = false; var release = false }
