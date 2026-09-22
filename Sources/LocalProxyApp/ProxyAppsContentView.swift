import ProxyAppsCore
import SwiftUI

struct ProxyAppsContentView: View {
    @EnvironmentObject private var controller: ProxyAppsController
    @State private var websiteInput = ""
    @State private var ruleAction: RuleAction = .proxy
    @State private var ruleMatch: RuleMatch = .suffix
    @State private var editingID: UUID?
    @State private var search = ""
    @State private var filter = "all"
    @State private var showingForceRestoreConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                quickcatCard
                smartCard
                rulesCard
                checkCard
                websitesCard
                applicationsCard
                diagnosticsCard
                limitations
            }
            .padding(24)
        }
        .disabled(controller.preparingToQuit)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .confirmationDialog("开启智能分流", isPresented: $controller.showingConsent, titleVisibility: .visible) {
            Button("确定并开启") { controller.confirmSmart() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后，工具将根据域名规则自动选择直连或 Quickcat 代理。未收录网站默认直连，你的手动规则优先。规则库会定期更新，后续更新自动应用。此功能只影响遵循本工具自动代理配置的应用。")
        }
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
                Text("手动规则优先，智能分流中的未知网站默认直连")
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

    private var smartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("智能分流").font(.title2.bold())
                Spacer()
                Toggle("智能分流", isOn: Binding(get: { controller.activeMode == .smart }, set: controller.requestSmart))
                    .toggleStyle(.switch)
                    .disabled(controller.configurationBusy || controller.loadingRules || controller.parsedRules == nil || controller.websitePACStatus == .needsRestore)
            }
            Text(controller.websitePACStatusText).font(.headline)
            if controller.isWebsiteProxyEnabled {
                Text("PAC \(controller.pacByteCount) 字节，已通过体积与脚本检查。实际出口取决于应用是否遵循系统 PAC。").font(.caption).foregroundStyle(.secondary)
            }
            if controller.preparingToQuit { ProgressView("正在恢复原网络设置，完成后退出…") }
            HStack {
                Button("仅手动规则") { Task { await controller.setMode(.manual) } }
                Button("关闭网站分流") { Task { await controller.setMode(.off) } }
            }.disabled(controller.configurationBusy || controller.websitePACStatus == .needsRestore)
            Text("关闭时恢复原 PAC；不会结束固定全部代理启动的应用。下次启动需手动开启，已确认的来源无需再次确认。")
                .font(.caption).foregroundStyle(.secondary)
            if !controller.notice.isEmpty { Text(controller.notice).font(.callout).foregroundStyle(.secondary) }
            if controller.websitePACStatus == .needsRestore {
                Text("存在待处理恢复记录。恢复前禁止重新应用配置；外部 PAC 变更不会自动覆盖。").foregroundStyle(.orange)
                HStack {
                    Button("恢复原网络设置") { Task { await controller.restoreOriginalNetworkSettings() } }
                    Button("强制恢复…") { showingForceRestoreConfirmation = true }
                }.disabled(controller.configurationBusy)
            }
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("规则库 · Loyalsoldier/v2ray-rules-dat").font(.title2.bold())
            if controller.loadingRules { ProgressView("正在载入离线规则…") }
            if let snapshot = controller.ruleCache?.current, let rules = controller.parsedRules {
                Text("版本：\(snapshot.version)").font(.caption.monospaced()).textSelection(.enabled)
                Text("快照下载：\(snapshot.downloadedAt.formatted())")
                Text("直连 \(rules.directCount) · 代理 \(rules.proxyCount) · 未支持 \(rules.unsupported) · 冲突 \(rules.conflicts)")
                if let date = controller.configuration.lastSuccessfulCheck { Text("最近成功检查：\(date.formatted())").font(.caption) }
            }
            HStack {
                Button(controller.updatingRules ? "正在更新…" : "立即更新 / 修复") { Task { await controller.updateRules() } }
                    .disabled(controller.updatingRules || controller.loadingRules)
                Toggle("自动更新（每 24 小时）", isOn: Binding(get: { controller.configuration.automaticUpdates }, set: controller.setAutomaticUpdates))
                    .disabled(controller.configurationBusy)
                if controller.ruleCache?.previous != nil {
                    Button("回退上一版本") { Task { await controller.rollbackRules() } }.disabled(controller.configurationBusy)
                }
            }
            if let error = controller.ruleError { Text(error).font(.callout).foregroundStyle(.orange) }
            Text("只在本 App 运行时更新。未支持的 regexp / keyword 等规则不参与分流；完全同级冲突选直连。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("检查网站").font(.title2.bold())
            HStack {
                TextField("域名或 HTTP/HTTPS URL", text: $controller.checkInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: controller.checkInput) { _ in controller.cancelCheck() }
                    .onSubmit { controller.checkWebsite() }
                Button("检查") { controller.checkWebsite() }.disabled(controller.loadingRules)
                Button("关闭结果") { controller.cancelCheck() }
            }
            if let decision = controller.checkDecision {
                Text("\(controller.checkDomain)：\(decision.action == .direct ? "直连" : "代理") · \(decision.reason)")
                Text("规则库未支持条目：\(controller.parsedRules?.unsupported ?? 0)（不执行正则或关键词规则）").font(.caption)
            }
            if controller.checking { ProgressView("正在并发检查两条路径，预算 8 秒…") }
            if let result = controller.checkResult {
                Text("直连：\(result.direct.text)")
                Text("代理：\(result.proxy.text)")
                Text(result.suggestion).font(.headline)
                HStack {
                    Button("确认使用代理") { Task { _ = await controller.saveRule(result.domain, action: .proxy, match: .suffix, source: .diagnosis) } }
                    Button("确认直连") { Task { _ = await controller.saveRule(result.domain, action: .direct, match: .suffix, source: .diagnosis) } }
                }.disabled(controller.configurationBusy)
                Text("确认后保存为包含子域名的手动规则；可在下方修改范围。").font(.caption)
            }
            Text("只探测 https://域名/，不发送原路径、Cookie 或认证信息，不跟随跳转。主域名与图片、登录、API 等资源域名分别匹配。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private var websitesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("手动规则").font(.title2.bold())
            HStack {
                TextField("域名或 URL", text: $websiteInput).textFieldStyle(.roundedBorder)
                Picker("动作", selection: $ruleAction) { Text("代理").tag(RuleAction.proxy); Text("直连").tag(RuleAction.direct) }.frame(width: 130)
                Picker("范围", selection: $ruleMatch) { Text("包含子域名").tag(RuleMatch.suffix); Text("仅此域名").tag(RuleMatch.exact) }.frame(width: 180)
                Button(editingID == nil ? "保存规则" : "保存编辑") { saveWebsite() }
                if editingID != nil { Button("取消编辑") { editingID = nil; websiteInput = "" } }
            }.disabled(controller.configurationBusy)
            HStack {
                TextField("搜索手动规则", text: $search).textFieldStyle(.roundedBorder)
                Picker("筛选", selection: $filter) { Text("全部").tag("all"); Text("直连").tag("direct"); Text("代理").tag("proxy") }.frame(width: 150)
            }
            Text("手动规则整体优先。停用后恢复自动判断；强制直连请将动作设为直连。").font(.caption).foregroundStyle(.secondary)
            ForEach(controller.websites.filter { (search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search)) && (filter == "all" || $0.action.rawValue == filter) }) { website in
                HStack {
                    Toggle("", isOn: Binding(get: { website.enabled }, set: { controller.setWebsiteEnabled(website, enabled: $0) })).labelsHidden()
                    Text(website.domain).textSelection(.enabled)
                    Text("\(website.action == .proxy ? "代理" : "直连") · \(website.match == .suffix ? "包含子域名" : "仅此域名")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("编辑") { editingID = website.id; websiteInput = website.domain; ruleAction = website.action; ruleMatch = website.match }
                    Button("删除", role: .destructive) { controller.removeWebsite(website) }
                }.disabled(controller.configurationBusy)
            }
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private func saveWebsite() {
        Task {
            if await controller.saveRule(websiteInput, action: ruleAction, match: ruleMatch, id: editingID) { websiteInput = ""; editingID = nil }
        }
    }

    private var limitations: some View {
        DisclosureGroup("使用限制") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• 全部代理启动使用固定代理；按网站规则启动只传 PAC 参数。普通启动仍可能遵循系统 PAC，不是强制直连。")
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
            Button("全部代理启动") {
                Task { await controller.launch(application, usingProxy: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isBusy)
            if controller.isChromiumApplication(application) {
                Button("按网站规则启动") { Task { await controller.launchWithRules(application) } }
                    .disabled(!controller.isWebsiteProxyEnabled || controller.configurationBusy)
            }
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
