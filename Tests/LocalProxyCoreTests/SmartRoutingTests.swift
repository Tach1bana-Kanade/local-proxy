import XCTest
import JavaScriptCore
@testable import ProxyAppsCore

final class SmartRoutingTests: XCTestCase {
    func testMatcherAndPACAgreeForModesPrecedenceAndLocalLiterals() throws {
        let manual: [ManagedWebsite] = [.init(domain: "example.com", action: .direct), .init(domain: "api.example.com", action: .proxy), .init(domain: "api.example.com", match: .exact, action: .direct), .init(domain: "direct.test", action: .proxy), .init(domain: "disabled.test", enabled: false)]
        let automatic: [DomainRule] = [.init(domain: "example.com", action: .proxy), .init(domain: "deep.example.com", action: .proxy), .init(domain: "direct.test", action: .direct), .init(domain: "disabled.test", action: .proxy), .init(domain: "test", action: .proxy)]
        let matcher = DomainRuleMatcher(manual: manual, automatic: automatic)
        XCTAssertEqual(matcher.decision(host: "deep.example.com", mode: .smart).action, .direct)
        XCTAssertEqual(matcher.decision(host: "a.api.example.com", mode: .smart).action, .proxy)
        XCTAssertEqual(matcher.decision(host: "api.example.com", mode: .smart).action, .direct)
        XCTAssertEqual(matcher.decision(host: "direct.test", mode: .smart).source, "手动规则")
        XCTAssertEqual(matcher.decision(host: "disabled.test", mode: .smart).source, "规则库")
        XCTAssertEqual(matcher.decision(host: "notexample.com", mode: .smart).action, .direct)
        let hosts = ["example.com", "api.example.com", "a.api.example.com", "deep.example.com", "notexample.com", "direct.test", "disabled.test", "unknown.net", "foo", "localhost", "x.localhost", "home.arpa", "router.home.arpa", "x.local", "x.lan", "127.99.1.2", "10.1.2.3", "172.16.1.2", "192.168.1.1", "169.254.1.2", "100.64.1.1", "8.8.8.8", "[::1]", "::", "::100", "::ffff:192.168.1.1", "::ffff:8.8.8.8", "0:0:0:0:0:ffff:7f00:1", "fe80::ab", "febf::1", "fc00::1", "fdff::1", "ff02::1", "2001:4860:4860::8888", "EXAMPLE.COM."]
        for mode in [RoutingMode.off, .manual, .smart] {
            let js = JSContext()!
            let pac = PACGenerator.generate(mode: mode, manual: manual, automatic: automatic)
            js.evaluateScript(pac)
            XCTAssertNil(js.exception)
            for host in hosts {
                let result = js.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["https://\(host)/", host])!.toString()!
                XCTAssertEqual(result, matcher.decision(host: host, mode: mode).action == .proxy ? "PROXY 127.0.0.1:21081" : "DIRECT", "\(mode) \(host)")
            }
            XCTAssertFalse(pac.contains("; DIRECT"))
            XCTAssertFalse(pac.contains("dnsResolve")); XCTAssertFalse(pac.contains("isInNet"))
        }
    }
    func testParserFormatsConflictsAndLimits() throws {
        let parsed = try RuleSetParser.parse(direct: Data("# comment\nexample.com\nfull:api.example.com\nregexp:.*\nexample.com\n".utf8), proxy: Data("domain:example.com\nfull:proxy.test\nkeyword:abc\nunknown:whatever\n".utf8))
        XCTAssertEqual(parsed.conflicts, 1); XCTAssertEqual(parsed.unsupported, 3); XCTAssertEqual(parsed.duplicates, 1)
        XCTAssertEqual(parsed.rules.first { $0.domain == "example.com" }?.action, .direct)
        XCTAssertEqual(parsed.rules.first { $0.domain == "proxy.test" }?.match, .exact)
        for text in ["", "bad domain.com", "full:", "a..b", "https://example.com", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try RuleSetParser.parse(direct: Data(text.utf8), proxy: Data("valid.test".utf8)), text)
        }
        XCTAssertThrowsError(try RuleSetParser.parse(direct: Data(repeating: 65, count: RuleSetParser.maxBytes + 1), proxy: Data("valid.test".utf8)))
        XCTAssertThrowsError(try RuleSetParser.parse(direct: Data(String(repeating: "a.test\n", count: 500_000).utf8), proxy: Data("b.test".utf8)))
    }
    func testBundledSnapshotAndCorruptCacheFallback() throws {
        let dir = directory(), store = RuleSetStore(directory: dir)
        let (cache, warning) = try store.load()
        XCTAssertNil(warning); XCTAssertGreaterThan(try cache.current.parse().rules.count, 100_000)
        XCTAssertEqual(try cache.current.parse().unsupported, 159)
        let matcher = DomainRuleMatcher(manual: [], automatic: try cache.current.parse().rules)
        XCTAssertEqual(matcher.decision(host: "google.com", mode: .smart).action, .proxy)
        XCTAssertEqual(matcher.decision(host: "baidu.com", mode: .smart).action, .direct)
        try PrivateFile.write(Data("broken".utf8), to: dir.appendingPathComponent("rule-cache.json"))
        XCTAssertNotNil(try store.load().1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("rule-cache.json")), "broken")
        try store.save(cache)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("rule-cache-corrupt-") })
        XCTAssertEqual(try store.load().0.current.version, cache.current.version)
    }
    func testMigrationKeepsIdentityAndDisabledAndCorruptionIsNotOverwritten() throws {
        let dir = directory(), store = RoutingConfigurationStore(directory: dir), id = UUID()
        let legacy = "[{\"id\":\"\(id)\",\"domain\":\"www.example.com\",\"enabled\":false}]"
        try PrivateFile.write(Data(legacy.utf8), to: dir.appendingPathComponent("websites.json"))
        let config = try store.load()
        XCTAssertEqual(config.preferredMode, .manual); XCTAssertTrue(config.needsConfirmation)
        let rule = try XCTUnwrap(config.manualRules.first)
        XCTAssertEqual(rule.id, id); XCTAssertEqual(rule.domain, "www.example.com"); XCTAssertFalse(rule.enabled)
        XCTAssertEqual(rule.action, .proxy); XCTAssertEqual(rule.match, .suffix); XCTAssertEqual(rule.source, .migration)
        XCTAssertEqual(try store.load(), config)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("websites.json")), legacy)
        let url = dir.appendingPathComponent("routing.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try PrivateFile.write(Data("broken".utf8), to: url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try String(contentsOf: url), "broken")
        var confirmed = config; confirmed.confirmation = RoutingConfiguration.consentVersion
        XCTAssertFalse(confirmed.needsConfirmation)
    }
    func testScheduleWithFakeClock() {
        let now = Date(timeIntervalSince1970: 100)
        var schedule = UpdateSchedule(lastSuccess: now, now: now)
        XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(86399), automatic: true))
        XCTAssertTrue(schedule.isDue(at: now.addingTimeInterval(86400), automatic: true))
        for delay in [900.0, 3600, 21600, 21600] { schedule.failed(at: now); XCTAssertEqual(schedule.nextCheck, now.addingTimeInterval(delay)) }
        schedule.succeeded(at: now); XCTAssertEqual(schedule.failures, 0)
        XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(90000), automatic: false))
    }
    func testHundredThousandRulesPerformanceAndJSExecution() {
        let rules = (0..<100_000).map { DomainRule(domain: "d\($0).example.net", action: $0 % 2 == 0 ? .proxy : .direct) }
        let start = Date(), matcher = DomainRuleMatcher(manual: [], automatic: rules)
        let pac = PACGenerator.generate(mode: .smart, manual: [], automatic: rules)
        let compile = Date().timeIntervalSince(start)
        let matchStart = Date()
        for i in 0..<10_000 { XCTAssertEqual(matcher.decision(host: "x.d\(i).example.net", mode: .smart).action, i % 2 == 0 ? .proxy : .direct) }
        let elapsed = Date().timeIntervalSince(matchStart)
        let js = JSContext()!; js.evaluateScript(pac); XCTAssertNil(js.exception)
        let jsStart = Date()
        js.evaluateScript("for(var i=0;i<10000;i++) { var r=FindProxyForURL('', 'x.d'+i+'.example.net'); if(r!==(i%2===0?'PROXY 127.0.0.1:21081':'DIRECT')) throw Error('mismatch'); }")
        XCTAssertNil(js.exception)
        print("BENCH rules=100000 compile=\(compile)s bytes=\(pac.utf8.count) swift10000=\(elapsed)s js10000=\(Date().timeIntervalSince(jsStart))s")
    }
    func testRevisionJournalPreservesOriginalAndBothURLsAndConflict() throws {
        let original = NetworkServicePACState(serviceName: "Wi-Fi", enabled: false, url: "http://original/pac")
        let client = RevisionFake(states: [original]), transaction = PACTransaction(client: client)
        let snapshot = try transaction.apply(serviceNames: ["Wi-Fi"], managedPACURL: "http://127.0.0.1/proxy.pac?v=a")
        var saved: NetworkServiceProxySnapshot?
        let next = try transaction.revise(snapshot, newURL: "http://127.0.0.1/proxy.pac?v=b") { saved = $0 }
        XCTAssertEqual(next.services, [original]); XCTAssertEqual(saved, next)
        XCTAssertEqual(next.ownedPACURLs?.count, 2)
        // Crash during revision: either recorded URL is still owned.
        client.states["Wi-Fi"]?.url = snapshot.managedPACURL
        try transaction.restore(next); XCTAssertEqual(client.states["Wi-Fi"], original)
        client.states["Wi-Fi"] = .init(serviceName: "Wi-Fi", enabled: true, url: "http://127.0.0.1/foreign.pac")
        XCTAssertThrowsError(try transaction.restore(next))
        XCTAssertThrowsError(try transaction.revise(next, newURL: "c") { _ in XCTFail("must preflight before journal") })
    }
    func testRevisionPartialFailureRollsBackAndFailedRollbackKeepsJournal() throws {
        let originals = [NetworkServicePACState(serviceName: "a", enabled: false, url: nil), .init(serviceName: "b", enabled: true, url: "original")]
        let fake = RevisionFake(states: originals), tx = PACTransaction(client: fake)
        let first = try tx.apply(serviceNames: ["a", "b"], managedPACURL: "old")
        fake.failURL = "new"; fake.failService = "b"
        var journal = first
        XCTAssertThrowsError(try tx.revise(first, newURL: "new") { journal = $0 })
        XCTAssertEqual(journal, first); XCTAssertTrue(fake.states.values.allSatisfy { $0.url == "old" })
        fake.failRollback = true
        XCTAssertThrowsError(try tx.revise(first, newURL: "new") { journal = $0 })
        XCTAssertEqual(journal.services, originals); XCTAssertEqual(journal.managedPACURL, "new")
    }
    func testLaunchArgumentsDoNotMixModes() {
        XCTAssertEqual(ProxyLaunchArguments.arguments(usingProxy: false, isChromium: true), [])
        XCTAssertEqual(ProxyLaunchArguments.websiteRules(pacURL: "http://127.0.0.1/proxy.pac?v=a"), ["--proxy-pac-url=http://127.0.0.1/proxy.pac?v=a"])
        XCTAssertTrue(ProxyLaunchArguments.arguments(usingProxy: true, isChromium: true).first!.hasPrefix("--proxy-server="))
    }
    func testPackedAutomaticPreservesAlternatingSuffixAndExactExceptions() throws {
        let rules: [DomainRule] = [
            .init(domain: "test", action: .proxy),
            .init(domain: "a.test", action: .direct),
            .init(domain: "b.a.test", action: .proxy),
            .init(domain: "b.a.test", match: .exact, action: .direct),
            .init(domain: "c.b.a.test", action: .direct),
            .init(domain: "same.test", action: .proxy),
            .init(domain: "exact.test", match: .exact, action: .direct),
            .init(domain: "only.example", match: .exact, action: .proxy)
        ]
        let pac = try PACValidation.compile(mode: .smart, manual: [], automatic: rules)
        XCTAssertEqual(pac, try PACValidation.compile(mode: .smart, manual: [], automatic: rules.reversed()))
        let js = JSContext()!; js.evaluateScript(pac)
        let matcher = DomainRuleMatcher(manual: [], automatic: rules)
        for domain in rules.map(\.domain) + ["unknown.example", "nottest", "other.test"] {
            for host in [domain, "child." + domain, "deep.child." + domain] {
                let actual = js.objectForKeyedSubscript("FindProxyForURL")!.call(withArguments: ["", host])!.toString()
                XCTAssertEqual(actual, matcher.decision(host: host, mode: .smart).action == .proxy ? "PROXY 127.0.0.1:21081" : "DIRECT", host)
            }
        }
    }
    func testPACValidationRejectsOversizeAndBrokenScripts() throws {
        XCTAssertThrowsError(try PACValidation.validate(String(repeating: " ", count: PACValidation.maximumBytes + 1)))
        XCTAssertThrowsError(try PACValidation.validate("function FindProxyForURL( {"))
        XCTAssertThrowsError(try PACValidation.validate("var unrelated = 1;"))
        try PACValidation.validate(PACGenerator.generate(mode: .manual, manual: []))
    }
    func testFullBundledPACEquivalenceAndExportFixtures() throws {
        let snapshot = try RuleSetStore(directory: directory()).bundled()
        let rules = try snapshot.parse().rules
        let start = Date()
        let pac = try PACValidation.compile(mode: .smart, manual: [], automatic: rules)
        XCTAssertLessThan(pac.utf8.count, PACValidation.maximumBytes)
        let matcher = DomainRuleMatcher(manual: [], automatic: rules), js = JSContext()!
        js.evaluateScript(pac)
        var fixtures: [[String]] = []
        for rule in rules {
            for host in [rule.domain, "child." + rule.domain] {
                fixtures.append([host, matcher.decision(host: host, mode: .smart).action == .proxy ? "PROXY 127.0.0.1:21081" : "DIRECT"])
            }
        }
        let data = try JSONEncoder().encode(fixtures)
        js.evaluateScript("var checks=" + String(decoding: data, as: UTF8.self) + "; for(var i=0;i<checks.length;i++) { if(FindProxyForURL('',checks[i][0])!==checks[i][1]) throw Error('Mismatch: '+checks[i][0]); }")
        XCTAssertNil(js.exception, js.exception?.toString() ?? "")
        print("BUNDLED PAC bytes=\(pac.utf8.count) hosts=\(fixtures.count) compileAndComparison=\(Date().timeIntervalSince(start))s")
        // Optional integration fixtures contain only public bundled rules and synthetic overrides.
        if let output = ProcessInfo.processInfo.environment["PROXY_APPS_PAC_FIXTURES"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pac.write(to: directory.appendingPathComponent("smart.pac"), atomically: true, encoding: .utf8)
            let overrides: [ManagedWebsite] = [.init(domain: "google.com", action: .direct), .init(domain: "baidu.com", action: .proxy)]
            try PACValidation.compile(mode: .smart, manual: overrides, automatic: rules).write(to: directory.appendingPathComponent("override.pac"), atomically: true, encoding: .utf8)
            try PACValidation.compile(mode: .manual, manual: overrides).write(to: directory.appendingPathComponent("manual.pac"), atomically: true, encoding: .utf8)
        }
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("proxy-test-" + UUID().uuidString) }
}
private final class RevisionFake: SystemPACClient {
    var states: [String: NetworkServicePACState]
    var failURL: String?, failService: String?, failRollback = false
    init(states: [NetworkServicePACState]) { self.states = Dictionary(uniqueKeysWithValues: states.map { ($0.serviceName, $0) }) }
    func currentState(for serviceName: String) throws -> NetworkServicePACState { states[serviceName]! }
    func setState(_ state: NetworkServicePACState) throws {
        if state.serviceName == failService && state.url == failURL || failRollback && state.url == "old" { throw RoutingError.invalid("injected") }
        states[state.serviceName] = state
    }
}
