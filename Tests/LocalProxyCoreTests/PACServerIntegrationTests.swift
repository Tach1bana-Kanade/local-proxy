import XCTest
import Darwin
@testable import LocalProxyApp
@testable import ProxyAppsCore

/// Opt-in local sockets only. No networksetup, Quickcat, DNS or internet dependency.
final class PACServerIntegrationTests: XCTestCase {
    private func allowed() throws {
        guard ProcessInfo.processInfo.environment["PROXY_APPS_SOCKET_TESTS"] == "1" else {
            throw XCTSkip("Run with PROXY_APPS_SOCKET_TESTS=1 to allow loopback integration fixtures")
        }
    }
    func testImmutableHTTPRevisionsAndConcurrentDownloads() async throws {
        try allowed()
        let store = PACContentStore(), server = PACServer { store.content(revision: $0) }
        let first = store.publish(String(repeating: "a", count: 368485))
        let second = store.publish("second")
        let port = try server.start(preferredPort: 0); defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0]
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in [first, second, first, second] {
                group.addTask {
                    let (data, rawResponse) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/proxy.pac?v=\(revision)")!)
                    let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
                    XCTAssertEqual(response.statusCode, 200)
                    XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
                    XCTAssertTrue(response.value(forHTTPHeaderField: "Content-Type")?.contains("application/x-ns-proxy-autoconfig") == true)
                    XCTAssertEqual(PACGenerator.revision(String(decoding: data, as: UTF8.self)), revision)
                }
            }
            try await group.waitForAll()
        }
        for path in ["/wrong", "/proxy.pac?v=unknown"] {
            let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }
    }
    func testPortConflictFragmentedOversizeAndDisconnectedClients() throws {
        try allowed()
        let server = PACServer { _ in "fixture" }, other = PACServer { _ in "other" }
        let port = try server.start(preferredPort: 0); defer { server.stop(); other.stop() }
        XCTAssertNotEqual(try other.start(preferredPort: port), port)
        let client = try connect(port); defer { close(client) }
        try send(client, "GET /proxy.pac?v=x HTTP/1.1\r\n")
        Thread.sleep(forTimeInterval: 0.02)
        try send(client, "Host: localhost\r\n\r\n")
        let response = receive(client)
        XCTAssertTrue(response.contains("200 OK")); XCTAssertTrue(response.hasSuffix("fixture"))
        let oversized = try connect(port)
        try send(oversized, "GET /proxy.pac HTTP/1.1\r\nX-Test: " + String(repeating: "x", count: 20_000) + "\r\n\r\n")
        XCTAssertFalse(receive(oversized).contains("200 OK")); close(oversized)
        let abandoned = try connect(port); close(abandoned)
        let healthy = try connect(port); defer { close(healthy) }
        try send(healthy, "GET /proxy.pac HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertTrue(receive(healthy).hasSuffix("fixture"))
    }
    func testSlowClientDoesNotBlockOtherClientsAndTimesOut() throws {
        try allowed()
        let server = PACServer { _ in "fixture" }, port = try server.start(preferredPort: 0)
        defer { server.stop() }
        let slow = try connect(port); defer { close(slow) }
        try send(slow, "GET /proxy.pac HTTP/1.1\r\n")
        let healthy = try connect(port); defer { close(healthy) }
        try send(healthy, "GET /proxy.pac HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let start = Date()
        XCTAssertTrue(receive(healthy).hasSuffix("fixture"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(receive(slow), "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    private func connect(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }
    private func send(_ fd: Int32, _ text: String) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { throw POSIXError(.EPIPE) }
                sent += count
            }
        }
    }
    private func receive(_ fd: Int32) -> String {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
