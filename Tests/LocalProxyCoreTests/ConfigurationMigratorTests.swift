import XCTest
@testable import LocalProxyCore

final class ConfigurationMigratorTests: XCTestCase {
    func testAddsChatGPTHelperWhenCodexRuleExists() {
        let original = LocalProxyConfiguration(applicationRules: [
            ApplicationRule(
                displayName: "Codex CLI",
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                executableName: "codex"
            )
        ])
        let migrated = ConfigurationMigrator.addingRequiredCodexHelpers(to: original)
        XCTAssertEqual(migrated.applicationRules.filter { $0.executableName == "ChatGPTHelper" }.count, 1)
    }

    func testMigrationIsIdempotent() {
        let original = LocalProxyConfiguration(applicationRules: [
            ApplicationRule(
                displayName: "ChatGPT",
                executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                executableName: "ChatGPT"
            )
        ])
        let once = ConfigurationMigrator.addingRequiredCodexHelpers(to: original)
        let twice = ConfigurationMigrator.addingRequiredCodexHelpers(to: once)
        XCTAssertEqual(once, twice)
    }

    func testDoesNotAddCodexRulesForUnrelatedConfiguration() {
        let original = LocalProxyConfiguration(applicationRules: [
            ApplicationRule(
                displayName: "Example",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                executableName: "Example"
            )
        ])
        XCTAssertEqual(ConfigurationMigrator.addingRequiredCodexHelpers(to: original), original)
    }
}
