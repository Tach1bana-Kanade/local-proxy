import ProxyAppsCore
import SwiftUI

struct ProxyAppsContentView: View {
    @EnvironmentObject private var controller: ProxyAppsController
    @State private var websiteInput = ""
    @State private var showingForceRestoreConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                quickcatCard
                applicationsCard
                websitesCard
                diagnosticsCard
                limitations
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .alert("操作失败", isPresented: $controller.showingError) {
            Button("好") {}
        } message: {
            Text(controller.errorMessage)
        }
        .confirmationDialog(
            "覆盖当前 PAC 设置并恢复？",
            isPresented: $showingForceRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("强制恢复原设置", role: .destructive) {
                Task { await controller.restoreOriginalNetworkSettings(allowConflicts: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅当错误信息显示的当前值可以被覆盖时使用。此操作会按保存的快照恢复网络服务。")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Proxy Apps")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("App 与网站白名单之外的流量保持直连")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await controller.refreshQuickcat() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isBusy)
        }
    }

    private var quickcatCard: some View {
        HStack(spacing: 14) {
            Image(systemName: controller.quickcat.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(controller.quickcat.isAvailable ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.statusText).font(.headline)
                Text(controller.statusDetail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                portStatus("SOCKS5 127.0.0.1:21080", available: controller.quickcat.socksAvailable)
                portStatus("HTTP 127.0.0.1:21081", available: controller.quickcat.httpAvailable)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func portStatus(_ label: String, available: Bool) -> some View {
        Label(label, systemImage: available ? "circle.fill" : "circle")
            .font(.caption.monospacedDigit())
            .foregroundStyle(available ? .green : .secondary)
    }

    private var applicationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用").font(.title2.bold())
                    Text("应用必须完全退出后才能选择新的启动方式。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: controller.chooseApplication) {
                    Label("添加应用", systemImage: "plus.app")
                }
            }

            if controller.applications.isEmpty {
                Text("未找到 Codex。请点击“添加应用”选择 Codex.app 或其他应用。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ForEach(controller.applications) { application in
                    ApplicationRow(application: application)
                    if application.id != controller.applications.last?.id { Divider() }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接诊断").font(.title2.bold())
                    Text("只读执行端口探测、scutil --proxy 和 lsof。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await controller.checkConnection() }
                } label: {
                    if controller.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("检查连接", systemImage: "stethoscope")
                    }
                }
                .disabled(controller.isBusy)
            }

            if controller.hasRunDiagnostics {
                if controller.systemProxyEnabled {
                    Label("检测到系统代理已开启，其他应用也可能使用代理。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("macOS 系统代理未开启", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                }

                Divider()
                Text("连接 21080 或 21081 的进程").font(.headline)
                if controller.connections.isEmpty {
                    Text("当前未发现连接。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.connections) { connection in
                        HStack(alignment: .top) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(connection.processName)（PID \(connection.pid)）")
                                Text(connection.endpoint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if !controller.unlistedConnections.isEmpty {
                    Label(
                        "发现列表外进程：\(controller.unlistedConnections.map(\.processName).uniqued().joined(separator: "、"))，请确认是否符合预期。",
                        systemImage: "eye.trianglebadge.exclamationmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var websitesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("网站").font(.title2.bold())
                    Text("命中域名及其子域名时使用 Quickcat HTTP 代理；其他网站保持直连。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Toggle("网站代理", isOn: Binding(
                        get: { controller.isWebsiteProxyEnabled },
                        set: { value in Task { await controller.setWebsiteProxyEnabled(value) } }
                    ))
                    .toggleStyle(.switch)
                    .disabled(controller.isBusy || controller.websitePACStatus == .needsRestore)
                    Text("\(controller.websitePACStatusText) · 已启用 \(controller.enabledWebsiteCount) 个")
                        .font(.caption)
                        .foregroundStyle(websiteStatusColor)
                }
            }

            HStack {
                TextField("github.com 或 https://github.com/path", text: $websiteInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWebsite)
                Button(action: addWebsite) {
                    Label("添加网站", systemImage: "plus")
                }
                .disabled(websiteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if controller.websitePACStatus == .needsRestore {
                HStack(alignment: .top) {
                    Label("检测到上次留下的 PAC 恢复快照。请先恢复原网络设置。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("恢复原网络设置") {
                        Task { await controller.restoreOriginalNetworkSettings() }
                    }
                    .disabled(controller.isBusy)
                    Button("强制恢复…") { showingForceRestoreConfirmation = true }
                        .disabled(controller.isBusy)
                }
            }
            if case .failed(let detail) = controller.websitePACStatus {
                Label(detail, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if controller.websites.isEmpty {
                Text("尚未添加网站。支持输入域名或完整的 http/https 网址。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ForEach(controller.websites) { website in
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(website.domain).font(.headline)
                            Text("包含 \(website.domain) 的所有子域名")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("启用", isOn: Binding(
                            get: { website.enabled },
                            set: { controller.setWebsiteEnabled(website, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        Button(role: .destructive) {
                            controller.removeWebsite(website)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("删除网站")
                    }
                    if website.id != controller.websites.last?.id { Divider() }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("网站代理会修改 macOS 当前网络服务的自动代理配置，关闭总开关或退出 App 时恢复原设置。")
                Text("仅对遵循 macOS 自动代理配置的 App 生效；未加入或未启用的网站始终直连。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var websiteStatusColor: Color {
        switch controller.websitePACStatus {
        case .enabled: return .green
        case .failed, .needsRestore: return .orange
        case .disabled: return .secondary
        }
    }

    private func addWebsite() {
        if controller.addWebsite(websiteInput) { websiteInput = "" }
    }

    private var limitations: some View {
        DisclosureGroup("使用限制") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• Chromium 内核应用会同时使用启动参数和代理环境变量。")
                Text("• 部分桌面程序、后台服务、UDP 或 QUIC 流量可能不支持。")
                Text("• socks5h 仅在客户端正确支持时提供代理端域名解析。")
                Text("• 非 Chromium 应用仍需自身支持代理环境变量。")
                Text("• 网站代理只对遵循 macOS 自动代理配置的应用生效。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }
}

private struct ApplicationRow: View {
    @EnvironmentObject private var controller: ProxyAppsController
    let application: ManagedApplication

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: controller.icon(for: application))
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(application.displayName).font(.headline)
                    if controller.isChromiumApplication(application) {
                        Text("Chromium 内核 · 代理参数生效")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(application.bundlePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("代理启动") {
                Task { await controller.launch(application, usingProxy: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isBusy)
            Button("普通启动") {
                Task { await controller.launch(application, usingProxy: false) }
            }
            .disabled(controller.isBusy)
            Button(role: .destructive) {
                controller.remove(application)
            } label: {
                Image(systemName: "trash")
            }
            .help("从列表中删除")
            .disabled(controller.isBusy)
        }
        .padding(.vertical, 4)
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
