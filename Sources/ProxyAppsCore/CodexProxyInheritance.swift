import Foundation

/// Codex filters MCP environments; explicitly allow the launcher's proxy variables.
/// This edits only the built-in node_repl server, preserving other servers/settings.
public enum CodexProxyInheritance {
    public static let variableNames = ProxyEnvironment.values.keys.sorted()

    public static func applies(to application: ManagedApplication) -> Bool {
        application.bundleIdentifier == "com.openai.codex"
            || application.bundleIdentifier == "com.google.Chrome"
    }

    public static func launchEnvironment(usingProxy: Bool, pacURL: String?, application: ManagedApplication) -> [String: String]? {
        if usingProxy || (pacURL != nil && application.bundleIdentifier == "com.google.Chrome") {
            return ProxyEnvironment.values
        }
        return nil
    }

    public static func updating(_ text: String) throws -> String {
        // Avoid interpreting section-like lines embedded in TOML multiline strings.
        guard !text.contains("\"\"\""), !text.contains("'''"), !text.contains("\r") else {
            throw RoutingError.invalid("Codex 配置使用了暂不支持的格式，未修改配置。")
        }
        var lines = text.components(separatedBy: "\n")
        func section(_ line: String) -> String? {
            let value = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("[") && value.hasSuffix("]") ? value : nil
        }
        let header = "[mcp_servers.node_repl]"
        let headers = lines.indices.filter { section(lines[$0]) == header }
        guard headers.count <= 1 else { throw RoutingError.invalid("Codex node_repl 配置重复，未修改配置。") }
        // The desktop app creates its built-in server configuration at first use.
        guard let start = headers.first else { return text }
        let end = lines.indices.first { $0 > start && section(lines[$0]) != nil } ?? lines.count
        let assignments = ((start + 1)..<end).filter {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("env_vars")
                && !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        guard assignments.count <= 1 else { throw RoutingError.invalid("Codex env_vars 配置重复，未修改配置。") }
        if let index = assignments.first {
            let expression = try NSRegularExpression(pattern: #"^\s*env_vars\s*=\s*\[(.*)\]\s*(?:#.*)?$"#)
            let line = lines[index] as NSString
            guard let match = expression.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) else {
                throw RoutingError.invalid("Codex env_vars 需要单行字符串数组，未修改配置。")
            }
            let content = line.substring(with: match.range(at: 1))
            let tokens = content.split(separator: ",", omittingEmptySubsequences: false)
            var existing = Set<String>()
            for (offset, token) in tokens.enumerated() {
                let value = token.trimmingCharacters(in: .whitespaces)
                if value.isEmpty && offset == tokens.count - 1 { continue }
                guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else {
                    throw RoutingError.invalid("Codex env_vars 包含不支持的值，未修改配置。")
                }
                let name = String(value.dropFirst().dropLast())
                guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                    throw RoutingError.invalid("Codex env_vars 包含不支持的变量名，未修改配置。")
                }
                existing.insert(name)
            }
            let missing = variableNames.filter { !existing.contains($0) }
            if !missing.isEmpty {
                let additions = missing.map { "\"\($0)\"" }.joined(separator: ", ")
                let prefix = content.trimmingCharacters(in: .whitespaces).isEmpty ? additions : additions + ", " + content
                lines[index] = line.replacingCharacters(in: match.range(at: 1), with: prefix)
            }
        } else {
            lines.insert("env_vars = [" + variableNames.map { "\"\($0)\"" }.joined(separator: ", ") + "]", at: start + 1)
        }
        // Migrate only the exact Quickcat values installed by the earlier repair.
        // Other explicit user overrides continue to take precedence over inheritance.
        var currentSection: String?
        lines = lines.filter { line in
            if let value = section(line) { currentSection = value }
            guard currentSection == "[mcp_servers.node_repl.env]" else { return true }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !ProxyEnvironment.values.contains { key, value in
                trimmed == "\(key) = \"\(value)\""
            }
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public static func prepare(configURL: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else { return false }
        let original = try Data(contentsOf: configURL)
        guard let source = String(data: original, encoding: .utf8) else { throw RoutingError.invalid("Codex 配置不是 UTF-8，未修改配置。") }
        let revised = Data(try updating(source).utf8)
        guard revised != original else { return false }
        let backup = configURL.deletingLastPathComponent().appendingPathComponent("config-before-proxyapps-\(UUID().uuidString).toml")
        try PrivateFile.write(original, to: backup)
        guard try Data(contentsOf: configURL) == original else { throw RoutingError.invalid("Codex 配置正在变化，请重试启动。原配置已备份。") }
        try PrivateFile.write(revised, to: configURL)
        return true
    }
}
