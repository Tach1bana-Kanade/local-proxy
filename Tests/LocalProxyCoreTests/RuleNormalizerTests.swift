import XCTest
@testable import LocalProxyCore

final class RuleNormalizerTests: XCTestCase {
    func testNormalizesURLToLowercaseHost() throws {
        XCTAssertEqual(
            try RuleNormalizer.normalize(" HTTPS://API.Example.COM/path?q=1 ", as: .exact),
            "api.example.com"
        )
    }

    func testNormalizesSingleIPToHostCIDR() throws {
        XCTAssertEqual(try RuleNormalizer.normalize("203.0.113.10", as: .ipCIDR), "203.0.113.10/32")
        XCTAssertEqual(try RuleNormalizer.normalize("2001:db8::1", as: .ipCIDR), "2001:db8::1/128")
    }

    func testNormalizesWildcardRule() throws {
        XCTAssertEqual(
            try RuleNormalizer.normalize("*.API.Example.COM.", as: .wildcard),
            "*.api.example.com"
        )
    }

    func testRejectsDangerouslyBroadCIDR() {
        XCTAssertThrowsError(try RuleNormalizer.normalize("0.0.0.0/0", as: .ipCIDR))
        XCTAssertThrowsError(try RuleNormalizer.normalize("2001:db8::/16", as: .ipCIDR))
    }

    func testRejectsIPAddressEnteredAsDomain() {
        XCTAssertThrowsError(try RuleNormalizer.normalize("127.0.0.1", as: .exact))
    }

    func testRejectsRelativeExecutablePath() {
        let configuration = LocalProxyConfiguration(applicationRules: [
            ApplicationRule(displayName: "Bad", executablePath: "bin/bad", executableName: "bad")
        ])
        XCTAssertThrowsError(try RuleNormalizer.validate(configuration))
    }
}
