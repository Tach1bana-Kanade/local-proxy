import ProxyAppsCore
import SwiftUI

struct ProxyAppsContentView: View {
    @EnvironmentObject private var controller: ProxyAppsController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                quickcatCard
                applicationsCard
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
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Proxy Apps")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("默认直连，仅代理启动的应用使用 Quickcat")
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

    private var limitations: some View {
        DisclosureGroup("使用限制") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• 只有支持代理环境变量的应用才能使用此方式。")
                Text("• 部分桌面程序、后台服务、UDP 或 QUIC 流量可能不支持。")
                Text("• socks5h 仅在客户端正确支持时提供代理端域名解析。")
                Text("• 本工具不能强制不支持环境变量的应用使用代理。")
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
                Text(application.displayName).font(.headline)
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
