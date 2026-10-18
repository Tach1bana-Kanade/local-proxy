import Foundation

/// Uses the desktop app's runtime-path override instead of editing its generated MCP table.
public enum CodexProxyToolLauncher {
    public static let overrideKey = "CODEX_NODE_REPL_PATH"

    public static func isRequired(for application: ManagedApplication, usingProxy: Bool) -> Bool {
        usingProxy && application.bundleIdentifier == "com.openai.codex"
    }

    public static func script(executableURL: URL) -> String {
        let exports = ProxyEnvironment.values.sorted { $0.key < $1.key }
            .map { "    export \($0.key)=\(quote($0.value))" }.joined(separator: "\n")
        return """
        #!/bin/sh
        set -eu
        # Proxy Apps: reapply only Quickcat proxy variables filtered by the MCP launcher.
        # The config is shared with Chrome. Respect the parent backend's launch mode.
        # Parent environment is checked locally; its contents are never printed or logged.
        if /bin/ps eww -p "$PPID" -o command= | /usr/bin/grep -Eq '(^|[[:space:]])(HTTP_PROXY|http_proxy)=http://127[.]0[.]0[.]1:21081([[:space:]]|$)'; then
        \(exports)
        fi
        exec \(quote(executableURL.path)) "$@"

        """
    }

    public static func prepare(executableURL: URL, directory: URL) throws -> URL {
        let fm = FileManager.default
        guard executableURL.isFileURL, fm.isExecutableFile(atPath: executableURL.path) else {
            throw RoutingError.invalid("找不到 Codex 浏览器控制程序：\(executableURL.path)")
        }
        let data = Data(script(executableURL: executableURL).utf8)
        let name = "node-repl-quickcat-" + PACGenerator.revision(String(decoding: data, as: UTF8.self)) + ".sh"
        let url = directory.appendingPathComponent(name)
        if (try? Data(contentsOf: url)) != data { try PrivateFile.write(data, to: url) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
