import XCTest
@testable import LocalProxyCore

final class PortProbeTests: XCTestCase {
    func testRejectsInvalidPortAndNonPositiveTimeout() {
        let probe = PortProbe()
        XCTAssertFalse(probe.canConnect(host: "127.0.0.1", port: 0, timeout: 1))
        XCTAssertFalse(probe.canConnect(host: "127.0.0.1", port: 21080, timeout: 0))
    }

    func testUnreachableNumericAddressRespectsDeadline() {
        let started = Date()
        _ = PortProbe().canConnect(host: "203.0.113.1", port: 9, timeout: 0.05)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}
