import AppKit
import ProxyAppsCore
import SwiftUI
import UniformTypeIdentifiers

enum WebsitePACStatus: Equatable {
    case disabled
    case enabled
    case failed(String)
    case needsRestore
}

@MainActor
final class ProxyAppsController: ObservableObject {
    @Published var applications: [ManagedApplication]
    @Published var websites: [ManagedWebsite]
    @Published var websitePACStatus: WebsitePACStatus = .disabled
    @Published var quickcat = QuickcatStatus(socksAvailable: false, httpAvailable: false)
    @Published var systemProxyEnabled = false
    @Published var connections: [ProxyPortConnection] = []
    @Published var isBusy = false
    @Published var hasRunDiagnostics = false
    @Published var showingError = false
    @Published var errorMessage = ""

    private let manager: ProxyAppsManager
    private let systemPACManager: SystemPACManager
    private let pacContentStore = PACContentStore()
    private lazy var pacServer = PACServer { [pacContentStore] in pacContentStore.content() }
    private var pacSettings: PACSettings

    init(
        manager: ProxyAppsManager = ProxyAppsManager(),
        systemPACManager: SystemPACManager = SystemPACManager()
    ) {
        self.manager = manager
        self.systemPACManager = systemPACManager
        applications = manager.loadApplications()
        websites = manager.loadWebsites()
        pacSettings = manager.loadPACSettings()
        pacContentStore.update(websites)
        if manager.loadRestoreSnapshot() != nil || pacSettings.enabled {
            websitePACStatus = .needsRestore
        }
    }

    var statusText: String {
        if quickcat.isAvailable { return "Quickcat 代理可用" }
        return "Quickcat 代理不可用"
    }

    var statusDetail: String {
        if quickcat.isAvailable {
            return "SOCKS5 21080 与 HTTP 21081 均可连接"
        }
        return "请启动 Quickcat、连接节点，并保持系统代理和 TUN 关闭"
    }

    var unlistedConnections: [ProxyPortConnection] {
        let listedNames = Set(applications.map { $0.executableName.lowercased() })
        return connections.filter {
            $0.processName.caseInsensitiveCompare("Quickcat") != .orderedSame
                && !listedNames.contains($0.processName.lowercased())
        }
    }

    var enabledWebsiteCount: Int { websites.filter(\.enabled).count }

    var websitePACStatusText: String {
        switch websitePACStatus {
        case .disabled: return "未启用"
        case .enabled: return "已启用"
        case .failed: return "应用失败"
        case .needsRestore: return "需要恢复"
        }
    }

    var isWebsiteProxyEnabled: Bool { websitePACStatus == .enabled }

    func monitorStatus() async {
        preparePendingRestoreIfNeeded()
        await refreshQuickcat()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            quickcat = await manager.inspectQuickcat()
        }
    }

    func addWebsite(_ input: String) -> Bool {
        do {
            let domain = try WebsiteNormalizer.normalize(input)
            guard !websites.contains(where: { $0.domain == domain }) else {
                throw ProxyAppsError.duplicateWebsite
            }
            websites.append(ManagedWebsite(domain: domain))
            websites.sort { $0.domain < $1.domain }
            try persistWebsites()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func setWebsiteEnabled(_ website: ManagedWebsite, enabled: Bool) {
        guard let index = websites.firstIndex(where: { $0.id == website.id }) else { return }
        if isWebsiteProxyEnabled && !enabled && enabledWebsiteCount == 1 {
            present(ProxyAppsError.enabledWebsiteRequired)
            return
        }
        let previous = websites[index].enabled
        websites[index].enabled = enabled
        do { try persistWebsites() }
        catch { websites[index].enabled = previous; present(error) }
    }

    func removeWebsite(_ website: ManagedWebsite) {
        if isWebsiteProxyEnabled && website.enabled && enabledWebsiteCount == 1 {
            present(ProxyAppsError.enabledWebsiteRequired)
            return
        }
        let previous = websites
        websites.removeAll { $0.id == website.id }
        do { try persistWebsites() }
        catch { websites = previous; pacContentStore.update(websites); present(error) }
    }

    func setWebsiteProxyEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if enabled { try await enableWebsiteProxy() }
            else { try disableWebsiteProxy() }
        } catch {
            manager.record(error)
            if manager.loadRestoreSnapshot() != nil {
                websitePACStatus = .needsRestore
            } else {
                pacServer.stop()
                pacSettings.enabled = false
                try? manager.savePACSettings(pacSettings)
                websitePACStatus = .failed(error.localizedDescription)
            }
            present(error)
        }
    }

    func restoreOriginalNetworkSettings(allowConflicts: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try disableWebsiteProxy(allowConflicts: allowConflicts)
        } catch {
            manager.record(error)
            websitePACStatus = .needsRestore
            present(error)
        }
    }

    func shutdownForTermination() {
        if manager.loadRestoreSnapshot() != nil {
            do { try disableWebsiteProxy() }
            catch { manager.record(error) }
        }
        pacServer.stop()
    }

    func refreshQuickcat() async {
        guard !isBusy else { return }
        isBusy = true
        quickcat = await manager.inspectQuickcat()
        isBusy = false
    }

    func checkConnection() async {
        guard !isBusy else { return }
        isBusy = true
        let report = await manager.diagnose()
        quickcat = report.quickcat
        systemProxyEnabled = report.systemProxyEnabled
        connections = report.connections
        hasRunDiagnostics = true
        isBusy = false
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let application = try manager.application(from: url)
            guard !applications.contains(where: {
                $0.bundlePath == application.bundlePath
                    || ($0.bundleIdentifier != nil && $0.bundleIdentifier == application.bundleIdentifier)
            }) else { throw ProxyAppsError.duplicateApplication }
            applications.append(application)
            try manager.saveApplications(applications)
        } catch {
            present(error)
        }
    }

    func remove(_ application: ManagedApplication) {
        applications.removeAll { $0.id == application.id }
        do {
            try manager.saveApplications(applications)
        } catch {
            present(error)
        }
    }

    func launch(_ application: ManagedApplication, usingProxy: Bool) async {
        guard !isBusy else { return }
        if usingProxy && !quickcat.isAvailable {
            present(ProxyAppsError.quickcatUnavailable)
            return
        }
        isBusy = true
        do {
            try await manager.launch(application, usingProxy: usingProxy)
        } catch {
            manager.record(error)
            present(error)
        }
        isBusy = false
    }

    func icon(for application: ManagedApplication) -> NSImage {
        manager.icon(for: application)
    }

    func isChromiumApplication(_ application: ManagedApplication) -> Bool {
        manager.isChromiumApplication(application)
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }

    private func persistWebsites() throws {
        try manager.saveWebsites(websites)
        pacContentStore.update(websites)
    }

    private func preparePendingRestoreIfNeeded() {
        guard let snapshot = manager.loadRestoreSnapshot() else {
            if pacSettings.enabled { websitePACStatus = .needsRestore }
            return
        }
        do {
            let decisions = try snapshot.services.map { original in
                SystemPACPlanner.restoreDecision(
                    current: try systemPACManager.currentState(for: original.serviceName),
                    original: original,
                    managedPACURL: snapshot.managedPACURL
                )
            }
            if decisions.allSatisfy({ $0 == .alreadyRestored }) {
                try manager.deleteRestoreSnapshot()
                pacSettings.enabled = false
                try manager.savePACSettings(pacSettings)
                websitePACStatus = .disabled
                return
            }
        } catch {
            manager.record(error)
        }
        websitePACStatus = .needsRestore
        let snapshotPort = URL(string: snapshot.managedPACURL)?.port.flatMap(UInt16.init) ?? pacSettings.port
        do { _ = try pacServer.start(preferredPort: snapshotPort) }
        catch { manager.record(error) }
    }

    private func enableWebsiteProxy() async throws {
        guard enabledWebsiteCount > 0 else { throw ProxyAppsError.enabledWebsiteRequired }
        quickcat = await manager.inspectQuickcat()
        guard quickcat.httpAvailable else { throw ProxyAppsError.quickcatHTTPUnavailable }

        pacContentStore.update(websites)
        let port = try pacServer.start(preferredPort: pacSettings.port)
        pacSettings.port = port
        pacSettings.enabled = false
        try manager.savePACSettings(pacSettings)
        let pacURL = "http://127.0.0.1:\(port)/proxy.pac"
        guard let url = URL(string: pacURL) else { throw ProxyAppsError.pacUnavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              String(data: data, encoding: .utf8)?.contains("FindProxyForURL") == true else {
            throw ProxyAppsError.pacUnavailable
        }

        _ = try systemPACManager.apply(pacURL: pacURL) { [manager] snapshot in
            try manager.saveRestoreSnapshot(snapshot)
        }
        pacSettings.enabled = true
        try manager.savePACSettings(pacSettings)
        websitePACStatus = .enabled
    }

    private func disableWebsiteProxy(allowConflicts: Bool = false) throws {
        if let snapshot = manager.loadRestoreSnapshot() {
            try systemPACManager.restore(snapshot, allowConflicts: allowConflicts)
            try manager.deleteRestoreSnapshot()
        }
        pacSettings.enabled = false
        try manager.savePACSettings(pacSettings)
        pacServer.stop()
        websitePACStatus = .disabled
    }
}
