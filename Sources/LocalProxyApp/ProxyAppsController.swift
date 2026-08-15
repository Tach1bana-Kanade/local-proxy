import AppKit
import ProxyAppsCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProxyAppsController: ObservableObject {
    @Published var applications: [ManagedApplication]
    @Published var quickcat = QuickcatStatus(socksAvailable: false, httpAvailable: false)
    @Published var systemProxyEnabled = false
    @Published var connections: [ProxyPortConnection] = []
    @Published var isBusy = false
    @Published var hasRunDiagnostics = false
    @Published var showingError = false
    @Published var errorMessage = ""

    private let manager: ProxyAppsManager

    init(manager: ProxyAppsManager = ProxyAppsManager()) {
        self.manager = manager
        applications = manager.loadApplications()
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

    func monitorStatus() async {
        await refreshQuickcat()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            quickcat = await manager.inspectQuickcat()
        }
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

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }
}
