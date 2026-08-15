import Foundation

public enum ConfigurationMigrator {
    /// Adds networking helpers required by the bundled Codex desktop runtime.
    /// The migration only runs when an existing ChatGPT/Codex rule is present,
    /// so users who intentionally removed the app are not opted back in.
    public static func addingRequiredCodexHelpers(
        to configuration: LocalProxyConfiguration
    ) -> LocalProxyConfiguration {
        var migrated = configuration
        let codexNames: Set<String> = ["ChatGPT", "codex", "Codex (Service)"]
        let hasCodexRule = migrated.applicationRules.contains {
            codexNames.contains($0.executableName)
        }
        guard hasCodexRule,
              !migrated.applicationRules.contains(where: { $0.executableName == "ChatGPTHelper" }) else {
            return migrated
        }

        migrated.applicationRules.append(ApplicationRule(
            displayName: "ChatGPT Helper",
            bundleIdentifier: "com.openai.chat",
            executablePath: "/Applications/ChatGPT.app/Contents/Resources/native/codex-macos",
            executableName: "ChatGPTHelper",
            action: .proxy
        ))
        return migrated
    }
}
