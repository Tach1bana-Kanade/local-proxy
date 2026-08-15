import AppKit
import Foundation
import LocalProxyCore
import UniformTypeIdentifiers

@MainActor
final class ProxyController: ObservableObject {
    @Published var configuration: LocalProxyConfiguration
    @Published var quickcatAvailable = false
    @Published var systemProxyEnabled = true
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var statusMessage = "正在检查运行环境…"
    @Published var showingError = false
    @Published var errorMessage = ""

    private let manager: ProxyManager

    var canStart: Bool {
        quickcatAvailable && !systemProxyEnabled && manager.mihomoExecutablePath != nil
    }

    var upstreamEndpointDescription: String {
        let host = configuration.upstream.host.contains(":")
            ? "[\(configuration.upstream.host)]"
            : configuration.upstream.host
        return "\(host):\(configuration.upstream.socksPort)"
    }

    init() {
        let manager = ProxyManager()
        self.manager = manager
        let loaded = manager.loadConfiguration() ?? Self.defaultConfiguration()
        var migrated = ConfigurationMigrator.addingRequiredCodexHelpers(to: loaded)
        if let currentServicePath = Self.currentCodexServicePath() {
            for index in migrated.applicationRules.indices
                where migrated.applicationRules[index].executableName == "Codex (Service)" {
                migrated.applicationRules[index].executablePath = currentServicePath
            }
        }
        self.configuration = migrated
        do {
            try manager.saveConfiguration(configuration)
        } catch {
            self.errorMessage = "无法保存初始配置：\(error.localizedDescription)"
            self.showingError = true
        }
        self.isRunning = manager.detectRunningProcess()
    }

    func refreshStatus() async {
        isBusy = true
        let result = await manager.inspectEnvironment(configuration: configuration)
        quickcatAvailable = result.quickcatAvailable
        systemProxyEnabled = result.systemProxyEnabled
        isRunning = manager.detectRunningProcess()
        if isRunning {
            statusMessage = "Mihomo 正在接管流量；命中规则走 Quickcat，其余直连。"
        } else if !quickcatAvailable {
            statusMessage = "请先连接 Quickcat，并保持本地 SOCKS5 端口可用。"
        } else if systemProxyEnabled {
            statusMessage = "Quickcat 已连接。请切换到纯代理模式并关闭系统代理。"
        } else if manager.mihomoExecutablePath == nil {
            statusMessage = "没有找到 Mihomo，请确认已安装到 /opt/homebrew/bin/mihomo。"
        } else {
            statusMessage = "环境已就绪。点击按钮后会出现 macOS 管理员授权提示。"
        }
        isBusy = false
    }

    func monitorStatus() async {
        await refreshStatus()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            let stillRunning = manager.detectRunningProcess()
            if isRunning && !stillRunning && !isBusy {
                isRunning = false
                statusMessage = "Mihomo 已意外退出，局部代理不再接管网络。请恢复 Quickcat 系统代理或重新启动。"
                errorMessage = "检测到 Mihomo 意外退出。日志末尾：\n\(manager.readLogTail())"
                showingError = true
            } else {
                isRunning = stillRunning
            }
        }
    }

    func toggleProxy() async {
        guard !isBusy else { return }
        isBusy = true
        do {
            if isRunning {
                try await manager.stop()
                isRunning = false
                statusMessage = "局部代理已停止，网络已恢复为系统默认状态。"
            } else {
                let environment = await manager.inspectEnvironment(configuration: configuration)
                quickcatAvailable = environment.quickcatAvailable
                systemProxyEnabled = environment.systemProxyEnabled
                guard quickcatAvailable else { throw AppError.quickcatUnavailable }
                guard !systemProxyEnabled else { throw AppError.systemProxyStillEnabled }
                try manager.saveConfiguration(configuration)
                try await manager.start(configuration: configuration)
                isRunning = true
                statusMessage = "局部代理已开启。命中规则走 Quickcat，其余流量直连。"
            }
        } catch {
            present(error)
        }
        isBusy = false
        await refreshStatus()
    }

    func addDomainRule(_ input: String, match: DomainMatchType) {
        do {
            let normalized = try RuleNormalizer.normalize(input, as: match)
            guard !configuration.domainRules.contains(where: {
                $0.value == normalized && $0.match == match
            }) else {
                throw AppError.duplicateRule
            }
            configuration.domainRules.append(DomainRule(value: normalized, match: match))
            try manager.saveConfiguration(configuration)
        } catch {
            present(error)
        }
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择需要使用 Quickcat 的应用"
        panel.prompt = "添加应用"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }

        do {
            guard let bundle = Bundle(url: applicationURL),
                  let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
                throw AppError.invalidApplication
            }
            let executablePath = applicationURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executableName)
                .path
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw AppError.invalidApplication
            }
            guard !configuration.applicationRules.contains(where: { $0.executablePath == executablePath }) else {
                throw AppError.duplicateRule
            }
            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? applicationURL.deletingPathExtension().lastPathComponent
            configuration.applicationRules.append(ApplicationRule(
                displayName: displayName,
                bundleIdentifier: bundle.bundleIdentifier,
                executablePath: executablePath,
                executableName: executableName
            ))
            try manager.saveConfiguration(configuration)
        } catch {
            present(error)
        }
    }

    func setApplicationRule(_ id: UUID, enabled: Bool) {
        guard let index = configuration.applicationRules.firstIndex(where: { $0.id == id }) else { return }
        configuration.applicationRules[index].enabled = enabled
        persistRules()
    }

    func setDomainRule(_ id: UUID, enabled: Bool) {
        guard let index = configuration.domainRules.firstIndex(where: { $0.id == id }) else { return }
        configuration.domainRules[index].enabled = enabled
        persistRules()
    }

    func removeApplicationRule(_ id: UUID) {
        configuration.applicationRules.removeAll { $0.id == id }
        persistRules()
    }

    func removeDomainRule(_ id: UUID) {
        configuration.domainRules.removeAll { $0.id == id }
        persistRules()
    }

    private func persistRules() {
        do { try manager.saveConfiguration(configuration) }
        catch { present(error) }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }

    private static func defaultConfiguration() -> LocalProxyConfiguration {
        let servicePath = currentCodexServicePath()
            ?? "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/Current/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)"
        return LocalProxyConfiguration(
            mihomoExecutablePath: "/opt/homebrew/bin/mihomo",
            applicationRules: [
                ApplicationRule(
                    displayName: "ChatGPT",
                    bundleIdentifier: "com.openai.chat",
                    executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                    executableName: "ChatGPT"
                ),
                ApplicationRule(
                    displayName: "Codex CLI",
                    executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                    executableName: "codex"
                ),
                ApplicationRule(
                    displayName: "Codex Service",
                    executablePath: servicePath,
                    executableName: "Codex (Service)"
                ),
                ApplicationRule(
                    displayName: "ChatGPT Helper",
                    bundleIdentifier: "com.openai.chat",
                    executablePath: "/Applications/ChatGPT.app/Contents/Resources/native/codex-macos",
                    executableName: "ChatGPTHelper"
                ),
            ]
        )
    }

    private static func currentCodexServicePath() -> String? {
        let current = URL(fileURLWithPath: "/Applications/ChatGPT.app")
            .appendingPathComponent("Contents/Frameworks/Codex Framework.framework/Versions/Current")
            .appendingPathComponent("Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)")
            .resolvingSymlinksInPath()
        return FileManager.default.isExecutableFile(atPath: current.path) ? current.path : nil
    }
}

private enum AppError: LocalizedError {
    case quickcatUnavailable
    case systemProxyStillEnabled
    case invalidApplication
    case duplicateRule

    var errorDescription: String? {
        switch self {
        case .quickcatUnavailable: return "Quickcat SOCKS5 端口不可用，请先连接 Quickcat。"
        case .systemProxyStillEnabled: return "系统代理仍然开启。请先在 Quickcat 切换到纯代理模式。"
        case .invalidApplication: return "无法读取所选应用的主可执行文件。"
        case .duplicateRule: return "这条规则已经存在。"
        }
    }
}
