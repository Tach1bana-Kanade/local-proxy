import XCTest
@testable import ProxyAppsCore

final class NetworkRoutingTests: XCTestCase {
    func testUpdaterPinsVersionDeduplicatesAndExplicitlyFallsBack() async throws {
        let fake = DownloadFake(), updater = RuleSetUpdater(download: { url, channel, limit in try await fake.fetch(url, channel: channel, limit: limit) })
        async let a = updater.update(proxyAvailable: true)
        async let b = updater.update(proxyAvailable: true)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.version, second.version)
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0.0.path.hasSuffix("release") }.count, 2) // one failed direct + one proxy
        let raw = calls.filter { $0.0.host == "raw.githubusercontent.com" }
        XCTAssertEqual(raw.count, 2)
        XCTAssertTrue(raw.allSatisfy { $0.0.path.contains(String(repeating: "a", count: 40)) && $0.1 == .proxy })
        XCTAssertTrue(CurlTransport.arguments(channel: .direct).contains("*"))
        XCTAssertTrue(CurlTransport.arguments(channel: .proxy).contains("http://127.0.0.1:21081"))
        XCTAssertNotEqual(CurlTransport.arguments(channel: .direct), CurlTransport.arguments(channel: .proxy))
    }
    func testUpdateFailureCannotPublishHalfSnapshot() async {
        let updater = RuleSetUpdater(download: { url, _, _ in
            if url.host == "api.github.com" { return Data("{\"sha\":\"\(String(repeating: "b", count: 40))\"}".utf8) }
            if url.path.hasSuffix("direct-list.txt") { return Data("example.com".utf8) }
            throw RoutingError.invalid("half download failed")
        })
        do { _ = try await updater.update(proxyAvailable: false); XCTFail() } catch {}
    }
    func testProbePathsRetryPinningCacheAndNetworkInvalidation() async {
        let fake = ProbeFake(), clock = TestClock()
        let probe = ConnectivityProbe(network: fake, now: { clock.date })
        async let first = probe.check(domain: "example.com", skipDirect: false, proxyAvailable: true)
        async let second = probe.check(domain: "example.com", skipDirect: false, proxyAvailable: true)
        let (a,b) = await (first,second)
        XCTAssertEqual(a,b); XCTAssertTrue(a.suggestion.hasPrefix("建议代理"))
        var requests = await fake.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.filter { $0.0 == .direct }.allSatisfy { $0.1 == "93.184.216.34" })
        XCTAssertTrue(requests.filter { $0.0 == .proxy }.allSatisfy { $0.1 == nil })
        _ = await probe.check(domain: "example.com", skipDirect: false, proxyAvailable: true)
        let cachedCount = await fake.requests.count; XCTAssertEqual(cachedCount, 3)
        clock.advance(601)
        _ = await probe.check(domain: "example.com", skipDirect: false, proxyAvailable: true)
        requests = await fake.requests; XCTAssertEqual(requests.count, 6)
        await probe.invalidate()
        _ = await probe.check(domain: "example.com", skipDirect: true, proxyAvailable: true)
        requests = await fake.requests; XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests.last?.0, .proxy)
    }
    func testProbeRejectsResolvedPrivateTargetAndInputLocal() async {
        let fake = ProbeFake(addresses: ["127.0.0.1"]), probe = ConnectivityProbe(network: fake)
        let result = await probe.check(domain: "example.com", skipDirect: false, proxyAvailable: false)
        XCTAssertTrue(result.direct.text.contains("拒绝")); XCTAssertTrue(result.proxy.text.contains("不可用"))
        let requests = await fake.requests; XCTAssertTrue(requests.isEmpty)
        _ = await probe.check(domain: "localhost", skipDirect: false, proxyAvailable: true)
        let count = await fake.requests.count; XCTAssertEqual(count, 0)
    }
    func testHTTPRestrictionsTLSAndRedirectsAreUncertain() {
        for outcome in [ProbeOutcome.response(403), .response(429), .response(302), .uncertain("certificate failure")] {
            XCTAssertTrue(ProbeResult(domain: "example.com", direct: .connectionFailure("twice"), proxy: outcome).suggestion.hasPrefix("暂无法判断"))
            XCTAssertTrue(ProbeResult(domain: "example.com", direct: outcome, proxy: .response(200)).suggestion.hasPrefix("暂无法判断"))
        }
        XCTAssertTrue(ProbeResult(domain: "example.com", direct: .response(200), proxy: .response(500)).suggestion.hasPrefix("建议直连"))
    }
    func testTotalProbeBudgetCancelsBothOperations() async {
        let fake = ProbeFake(delay: 2_000_000_000), probe = ConnectivityProbe(network: fake, budget: 0.05)
        let start = Date()
        let result = await probe.check(domain: "example.com", skipDirect: false, proxyAvailable: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(result.suggestion.hasPrefix("暂无法判断"))
        XCTAssertTrue(result.direct.text.contains("取消")); XCTAssertTrue(result.proxy.text.contains("取消"))
    }
    func testActualSubprocessCancellationAndTimeout() async throws {
        // Local sleep is an inert fixture; no requests, proxy settings or external network.
        let command = BoundedCommand()
        let start = Date()
        let task = Task { try await command.run(executable: "/bin/sleep", arguments: ["30"], timeout: 8, limit: 1024) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let timeout = Date()
        do { _ = try await BoundedCommand().run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.05, limit: 1024); XCTFail() } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(timeout), 2)
    }
    func testProbeCancelledResponseIsNotCached() async throws {
        let fake = ProbeFake(delay: 1_000_000_000), probe = ConnectivityProbe(network: fake)
        let task = Task { await probe.check(domain: "example.com", skipDirect: false, proxyAvailable: true) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel(); _ = await task.value
        let count = await fake.requests.count
        _ = await probe.check(domain: "example.com", skipDirect: true, proxyAvailable: true)
        let after = await fake.requests.count
        XCTAssertGreaterThan(after, count)
    }
}
private actor DownloadFake {
    var calls: [(URL, NetworkChannel, Int)] = []
    func fetch(_ url: URL, channel: NetworkChannel, limit: Int) async throws -> Data {
        calls.append((url,channel,limit)); try await Task.sleep(nanoseconds: 10_000_000)
        if channel == .direct { throw RoutingError.invalid("offline") }
        if url.host == "api.github.com" { return Data("{\"sha\":\"\(String(repeating: "a", count: 40))\"}".utf8) }
        return Data((url.path.hasSuffix("direct-list.txt") ? "direct.test" : "proxy.test").utf8)
    }
}
private actor ProbeFake: ProbeNetworking {
    var requests: [(NetworkChannel, String?)] = []
    let addresses: [String], delay: UInt64
    init(addresses: [String] = ["93.184.216.34"], delay: UInt64 = 10_000_000) { self.addresses = addresses; self.delay = delay }
    func resolve(_ domain: String, deadline: Date) async throws -> [String] { addresses }
    func head(_ domain: String, channel: NetworkChannel, address: String?, deadline: Date) async throws -> ProbeOutcome {
        requests.append((channel,address)); try await Task.sleep(nanoseconds: delay)
        return channel == .direct ? .connectionFailure("two attempts") : .response(200)
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: Double) { lock.lock(); value.addTimeInterval(interval); lock.unlock() }
}
