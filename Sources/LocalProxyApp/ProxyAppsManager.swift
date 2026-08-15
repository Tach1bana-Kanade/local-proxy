import AppKit
import Foundation
import ProxyAppsCore

struct QuickcatStatus: Equatable {
    let socksAvailable: Bool
    let httpAvailable: Bool

    var isAvailable: Bool { socksAvailable && httpAvailable }
}

struct DiagnosticReport {
    let quickcat: QuickcatStatus
    let systemProxyEnabled: Bool
    let connections: [ProxyPortConnection]
}

final class ProxyAppsManager {
    private let fileManager = FileManager.default
    private let appSupportDirectory: URL
    private let applicationsURL: URL
    private let websitesURL: URL
    private let pacSettingsURL: URL
    private let restoreStateURL: URL
    private let logURL: URL

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Proxy Apps", isDirectory: true)
        appSupportDirectory = base
        applicationsURL = base.appendingPathComponent("applications.json")
        websitesURL = base.appendingPathComponent("websites.json")
        pacSettingsURL = base.appendingPathComponent("pac-settings.json")
        restoreStateURL = base.appendingPathComponent("pac-restore-state.json")
        logURL = base.appendingPathComponent("errors.log")
    }

    func loadApplications() -> [ManagedApplication] {
        if let data = try? Data(contentsOf: applicationsURL),
           let applications = try? JSONDecoder().decode([ManagedApplication].self, from: data) {
            return applications
        }
        guard let codex = defaultCodexApplication() else { return [] }
        try? saveApplications([codex])
        return [codex]
    }

    func saveApplications(_ applications: [ManagedApplication]) throws {
        try save(applications, to: applicationsURL)
    }

    func loadWebsites() -> [ManagedWebsite] {
        load([ManagedWebsite].self, from: websitesURL) ?? []
    }

    func saveWebsites(_ websites: [ManagedWebsite]) throws {
        try save(websites, to: websitesURL)
    }

    func loadPACSettings() -> PACSettings {
        load(PACSettings.self, from: pacSettingsURL) ?? PACSettings()
    }

    func savePACSettings(_ settings: PACSettings) throws {
        try save(settings, to: pacSettingsURL)
    }

    func loadRestoreSnapshot() -> NetworkServiceProxySnapshot? {
        load(NetworkServiceProxySnapshot.self, from: restoreStateURL)
    }

    func saveRestoreSnapshot(_ snapshot: NetworkServiceProxySnapshot) throws {
        try save(snapshot, to: restoreStateURL)
    }

    func deleteRestoreSnapshot() throws {
        guard fileManager.fileExists(atPath: restoreStateURL.path) else { return }
        try fileManager.removeItem(at: restoreStateURL)
    }

    func application(from bundleURL: URL) throws -> ManagedApplication {
        guard bundleURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: bundleURL),
              let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            throw ProxyAppsError.invalidApplication
        }
        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw ProxyAppsError.invalidApplication
        }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return ManagedApplication(
            displayName: displayName,
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: bundleURL.standardizedFileURL.path,
            executableName: executableName
        )
    }

    func icon(for application: ManagedApplication) -> NSImage {
        NSWorkspace.shared.icon(forFile: application.bundlePath)
    }

    func isRunning(_ application: ManagedApplication) -> Bool {
        let expectedPath = URL(fileURLWithPath: application.bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { running in
            if let identifier = application.bundleIdentifier, running.bundleIdentifier == identifier {
                return true
            }
            return running.bundleURL?.standardizedFileURL.path == expectedPath
        }
    }

    func isChromiumApplication(_ application: ManagedApplication) -> Bool {
        let url = URL(fileURLWithPath: application.bundlePath, isDirectory: true)
        return ChromiumApplicationDetector.detect(bundleURL: url).isChromium
    }

    func launch(_ application: ManagedApplication, usingProxy: Bool) async throws {
        guard !isRunning(application) else { throw ProxyAppsError.applicationAlreadyRunning }
        let url = URL(fileURLWithPath: application.bundlePath, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { throw ProxyAppsError.applicationMissing(url.path) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if usingProxy {
            configuration.environment = ProxyEnvironment.values
            let detection = ChromiumApplicationDetector.detect(bundleURL: url)
            switch detection {
            case .chromium:
                configuration.arguments.append(contentsOf: ProxyLaunchArguments.arguments(
                    usingProxy: true,
                    isChromium: true
                ))
            case .notChromium:
                break
            case .unreadable(let detail):
                record(ChromiumDetectionError(detail: detail))
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func inspectQuickcat() async -> QuickcatStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let probe = PortProbe()
                continuation.resume(returning: QuickcatStatus(
                    socksAvailable: probe.canConnect(host: "127.0.0.1", port: 21080, timeout: 1),
                    httpAvailable: probe.canConnect(host: "127.0.0.1", port: 21081, timeout: 1)
                ))
            }
        }
    }

    func diagnose() async -> DiagnosticReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let probe = PortProbe()
                let quickcat = QuickcatStatus(
                    socksAvailable: probe.canConnect(host: "127.0.0.1", port: 21080, timeout: 1),
                    httpAvailable: probe.canConnect(host: "127.0.0.1", port: 21081, timeout: 1)
                )
                let proxyOutput = (try? Self.runProcess(
                    "/usr/sbin/scutil", arguments: ["--proxy"]
                ).output) ?? ""
                let lsofOutput = (try? Self.runProcess(
                    "/usr/sbin/lsof", arguments: ["-nP", "-iTCP:21080", "-iTCP:21081", "-Fpcn"]
                ).output) ?? ""
                continuation.resume(returning: DiagnosticReport(
                    quickcat: quickcat,
                    systemProxyEnabled: DiagnosticParser.systemProxyEnabled(in: proxyOutput),
                    connections: DiagnosticParser.proxyConnections(in: lsofOutput)
                ))
            }
        }
    }

    func record(_ error: Error) {
        do {
            try createDirectory()
            let formatter = ISO8601DateFormatter()
            let entry = "[\(formatter.string(from: Date()))] \(error.localizedDescription)\n"
            let oldData = (try? Data(contentsOf: logURL)) ?? Data()
            let retained = oldData.suffix(48 * 1024)
            var data = Data(retained)
            data.append(Data(entry.utf8))
            try data.write(to: logURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        } catch {
            // Logging must never prevent the requested launch or diagnostic operation.
        }
    }

    private func defaultCodexApplication() -> ManagedApplication? {
        let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let fallbackURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        let url = workspaceURL ?? (fileManager.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil)
        return url.flatMap { try? application(from: $0) }
    }

    private func createDirectory() throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupportDirectory.path)
    }

    private func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try createDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

private struct ChromiumDetectionError: LocalizedError {
    let detail: String

    var errorDescription: String? {
        "Chromium 内核识别失败，已保守地仅注入代理环境变量。\(detail)"
    }
}

enum ProxyAppsError: LocalizedError {
    case invalidApplication
    case duplicateApplication
    case duplicateWebsite
    case applicationAlreadyRunning
    case applicationMissing(String)
    case quickcatUnavailable
    case quickcatHTTPUnavailable
    case enabledWebsiteRequired
    case pacUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidApplication:
            return "无法读取所选应用，请选择一个有效的 .app。"
        case .duplicateApplication:
            return "该应用已经在列表中。"
        case .duplicateWebsite:
            return "该网站已经在列表中。"
        case .applicationAlreadyRunning:
            return "该应用已经运行。请先完全退出该应用再从本工具启动，代理参数才能生效。"
        case .applicationMissing(let path):
            return "找不到应用：\(path)"
        case .quickcatUnavailable:
            return "Quickcat 代理不可用，请启动 Quickcat、连接节点，并确认本地端口 21080 和 21081 已开启。"
        case .quickcatHTTPUnavailable:
            return "Quickcat HTTP 代理不可用，请启动 Quickcat、连接节点，并确认 127.0.0.1:21081 可连接。"
        case .enabledWebsiteRequired:
            return "网站代理至少需要一条已启用的网站规则。请先关闭网站代理总开关。"
        case .pacUnavailable:
            return "本机 PAC 文件服务未能通过读取检查，系统代理尚未修改。"
        }
    }
}
