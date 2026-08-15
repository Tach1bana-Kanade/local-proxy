import Foundation
import LocalProxyCore
import Security
import Darwin

struct EnvironmentStatus {
    let quickcatAvailable: Bool
    let systemProxyEnabled: Bool
}

final class ProxyManager {
    private let fileManager = FileManager.default
    private let appSupportDirectory: URL
    private let rulesURL: URL
    private let generatedConfigURL: URL
    private let validationDirectory: URL
    private let privilegedRuntimeDirectory: URL
    private let logURL: URL
    private let launchdSourcePlistURL: URL
    private let pidDefaultsKey = "LocalProxy.MihomoPID"
    private let launchdLabel = "local.localproxy.mihomo"
    private let launchdInstalledPlistPath = "/Library/LaunchDaemons/local.localproxy.mihomo.plist"

    private(set) lazy var mihomoExecutablePath: String? = {
        let configured = loadConfiguration()?.mihomoExecutablePath
        let candidates = [configured, "/opt/homebrew/bin/mihomo", "/usr/local/bin/mihomo"].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }()

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalProxy", isDirectory: true)
        appSupportDirectory = base
        rulesURL = base.appendingPathComponent("rules.json")
        generatedConfigURL = base.appendingPathComponent("mihomo.yaml")
        validationDirectory = base.appendingPathComponent("validation", isDirectory: true)
        privilegedRuntimeDirectory = base.appendingPathComponent("runtime", isDirectory: true)
        logURL = base.appendingPathComponent("mihomo.log")
        launchdSourcePlistURL = base.appendingPathComponent("local.localproxy.mihomo.plist")
        try? createDirectories()
    }

    func loadConfiguration() -> LocalProxyConfiguration? {
        guard let data = try? Data(contentsOf: rulesURL) else { return nil }
        return try? JSONDecoder().decode(LocalProxyConfiguration.self, from: data)
    }

    func saveConfiguration(_ configuration: LocalProxyConfiguration) throws {
        try createDirectories()
        try RuleNormalizer.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: rulesURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesURL.path)
    }

    func inspectEnvironment(configuration: LocalProxyConfiguration) async -> EnvironmentStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let available = PortProbe().canConnect(
                    host: configuration.upstream.host,
                    port: configuration.upstream.socksPort,
                    timeout: 1
                )
                let proxyOutput = (try? Self.runProcess("/usr/sbin/scutil", arguments: ["--proxy"]).output) ?? ""
                let enabled = proxyOutput.contains("HTTPEnable : 1")
                    || proxyOutput.contains("HTTPSEnable : 1")
                    || proxyOutput.contains("SOCKSEnable : 1")
                continuation.resume(returning: EnvironmentStatus(
                    quickcatAvailable: available,
                    systemProxyEnabled: enabled
                ))
            }
        }
    }

    func start(configuration: LocalProxyConfiguration) async throws {
        guard !detectRunningProcess() else { return }
        guard let executable = mihomoExecutablePath else { throw ManagerError.mihomoNotFound }
        try createDirectories()

        var runtimeConfiguration = configuration
        runtimeConfiguration.tunEnabled = true
        runtimeConfiguration.diagnosticMixedPort = nil
        runtimeConfiguration.mihomoExecutablePath = executable
        let secret = try secureRandomHex(byteCount: 32)
        let yaml = try MihomoConfigGenerator().generate(from: runtimeConfiguration, apiSecret: secret)
        try Data(yaml.utf8).write(to: generatedConfigURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: generatedConfigURL.path)
        if !fileManager.fileExists(atPath: logURL.path) {
            guard fileManager.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ManagerError.logCreationFailed
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        let validation = try Self.runProcess(executable, arguments: [
            "-t", "-d", validationDirectory.path, "-f", generatedConfigURL.path,
        ])
        guard validation.status == 0 else { throw ManagerError.configurationInvalid(validation.output) }

        try writeLaunchDaemonPlist(executable: executable)

        let serviceTarget = "system/\(launchdLabel)"
        let removeStale = "/bin/launchctl bootout \(shellQuote(serviceTarget)) >/dev/null 2>&1 || true"
        let install = [
            "/usr/bin/install", "-o", "root", "-g", "wheel", "-m", "0644",
            shellQuote(launchdSourcePlistURL.path), shellQuote(launchdInstalledPlistPath),
        ].joined(separator: " ")
        let bootstrap = "/bin/launchctl bootstrap system \(shellQuote(launchdInstalledPlistPath))"
        let printPID = "/bin/launchctl kickstart -p \(shellQuote(serviceTarget))"
        let command = "\(removeStale); \(install) && \(bootstrap) && \(printPID)"

        do {
            let pidOutput = try await runAppleScript(command: command)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int32(pidOutput), pid > 1 else {
                throw ManagerError.invalidPID(pidOutput)
            }

            try await Task.sleep(nanoseconds: 900_000_000)
            guard let runningPID = launchdPID(), isProcessAlive(runningPID),
                  processCommand(pid: runningPID)?.contains(executable) == true else {
                throw ManagerError.startFailed(readLogTail())
            }
            UserDefaults.standard.set(Int(runningPID), forKey: pidDefaultsKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: pidDefaultsKey)
            if hasManagedInstallation() {
                do {
                    try await cleanupLaunchDaemon()
                } catch let cleanupError {
                    throw ManagerError.startCleanupFailed(
                        original: error.localizedDescription,
                        cleanup: cleanupError.localizedDescription
                    )
                }
            }
            throw error
        }
    }

    func stop() async throws {
        try await cleanupLaunchDaemon()
        guard !launchdServiceLoaded(),
              !fileManager.fileExists(atPath: launchdInstalledPlistPath) else {
            throw ManagerError.stopFailed
        }
        UserDefaults.standard.removeObject(forKey: pidDefaultsKey)
    }

    func detectRunningProcess() -> Bool {
        if let pid = launchdPID(), isProcessAlive(pid),
           let command = processCommand(pid: pid),
           command.contains("mihomo"), command.contains(generatedConfigURL.path) {
            UserDefaults.standard.set(Int(pid), forKey: pidDefaultsKey)
            return true
        }
        // A loaded KeepAlive service may briefly have no PID while launchd throttles a restart.
        if launchdServiceLoaded() { return true }
        guard let pid = storedPID, isProcessAlive(pid),
              let command = processCommand(pid: pid),
              command.contains("mihomo"), command.contains(generatedConfigURL.path) else {
            return false
        }
        return true
    }

    func hasManagedInstallation() -> Bool {
        launchdServiceLoaded() || fileManager.fileExists(atPath: launchdInstalledPlistPath)
    }

    private func launchdPID() -> Int32? {
        let result = try? Self.runProcess(
            "/bin/launchctl",
            arguments: ["print", "system/\(launchdLabel)"]
        )
        guard result?.status == 0 else { return nil }
        for line in result?.output.split(separator: "\n") ?? [] {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "pid",
               let pid = Int32(parts[1].trimmingCharacters(in: .whitespaces)) {
                return pid
            }
        }
        return nil
    }

    private func launchdServiceLoaded() -> Bool {
        let result = try? Self.runProcess(
            "/bin/launchctl",
            arguments: ["print", "system/\(launchdLabel)"]
        )
        return result?.status == 0
    }

    private var storedPID: Int32? {
        let value = UserDefaults.standard.integer(forKey: pidDefaultsKey)
        return value > 1 ? Int32(value) : nil
    }

    private func createDirectories() throws {
        for directory in [appSupportDirectory, validationDirectory, privilegedRuntimeDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func writeLaunchDaemonPlist(executable: String) throws {
        let plist: [String: Any] = [
            "Label": launchdLabel,
            "ProgramArguments": [
                executable,
                "-d", privilegedRuntimeDirectory.path,
                "-f", generatedConfigURL.path,
            ],
            "WorkingDirectory": privilegedRuntimeDirectory.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 1,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchdSourcePlistURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchdSourcePlistURL.path)
    }

    private func cleanupLaunchDaemon() async throws {
        let serviceTarget = "system/\(launchdLabel)"
        let command = [
            "/bin/launchctl bootout \(shellQuote(serviceTarget)) >/dev/null 2>&1 || true",
            "/bin/rm -f \(shellQuote(launchdInstalledPlistPath))",
        ].joined(separator: "; ")
        _ = try await runAppleScript(command: command)
    }

    private func secureRandomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ManagerError.randomGenerationFailed(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func runAppleScript(command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let script = "on run argv\nreturn do shell script (item 1 of argv) with administrator privileges\nend run"
                    let result = try Self.runProcess("/usr/bin/osascript", arguments: ["-e", script, command])
                    guard result.status == 0 else { throw ManagerError.authorizationFailed(result.output) }
                    continuation.resume(returning: result.output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func processCommand(pid: Int32) -> String? {
        let result = try? Self.runProcess("/bin/ps", arguments: ["-p", String(pid), "-o", "command="])
        guard result?.status == 0 else { return nil }
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func readLogTail() -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data.suffix(16_384), encoding: .utf8) else { return "没有可用日志" }
        return text
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

private enum ManagerError: LocalizedError {
    case mihomoNotFound
    case configurationInvalid(String)
    case randomGenerationFailed(OSStatus)
    case authorizationFailed(String)
    case invalidPID(String)
    case startFailed(String)
    case startCleanupFailed(original: String, cleanup: String)
    case stopFailed
    case logCreationFailed

    var errorDescription: String? {
        switch self {
        case .mihomoNotFound: return "没有找到 Mihomo 可执行文件。"
        case .configurationInvalid(let output): return "Mihomo 配置校验失败：\n\(output)"
        case .randomGenerationFailed(let status): return "无法生成安全令牌（OSStatus \(status)）。"
        case .authorizationFailed(let output): return "管理员授权失败或已取消：\n\(output)"
        case .invalidPID(let output): return "Mihomo 启动结果无效：\(output)"
        case .startFailed(let log): return "Mihomo 未能保持运行：\n\(log)"
        case .startCleanupFailed(let original, let cleanup):
            return "Mihomo 启动失败，且自动清理 LaunchDaemon 失败：\n启动错误：\(original)\n清理错误：\(cleanup)"
        case .stopFailed: return "Mihomo 未能正常停止，请检查运行日志。"
        case .logCreationFailed: return "无法创建权限为 0600 的 Mihomo 日志文件。"
        }
    }
}
