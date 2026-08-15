import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ProxyController

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                header

                TabView {
                    overview
                        .tabItem { Label("概览", systemImage: "gauge.with.dots.needle.67percent") }
                    RulesView()
                        .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
                }
            }
            .padding(24)
        }
        .alert("操作失败", isPresented: $controller.showingError) {
            Button("好") {}
        } message: {
            Text(controller.errorMessage)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("局部代理")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("未命中规则的流量始终直连")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await controller.refreshStatus() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isBusy)
        }
    }

    private var overview: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                StatusCard(
                    title: "Quickcat",
                    detail: controller.quickcatAvailable
                        ? "SOCKS5 \(controller.upstreamEndpointDescription) 可用"
                        : "未连接到 \(controller.upstreamEndpointDescription)",
                    symbol: "bolt.horizontal.circle",
                    healthy: controller.quickcatAvailable
                )
                StatusCard(
                    title: "系统代理",
                    detail: controller.systemProxyEnabled ? "仍然开启，请切换纯代理" : "已关闭，适合启动 TUN",
                    symbol: "gearshape.2",
                    healthy: !controller.systemProxyEnabled
                )
                StatusCard(
                    title: "Mihomo",
                    detail: controller.isRunning ? "局部代理运行中" : "当前未运行",
                    symbol: "network.badge.shield.half.filled",
                    healthy: controller.isRunning
                )
            }

            VStack(spacing: 14) {
                Image(systemName: controller.isRunning ? "checkmark.shield.fill" : "power.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(controller.isRunning ? .green : Color.accentColor)

                Text(controller.isRunning ? "局部代理已开启" : "准备开启局部代理")
                    .font(.title2.bold())

                Text(controller.statusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                Button {
                    Task { await controller.toggleProxy() }
                } label: {
                    HStack(spacing: 10) {
                        if controller.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: controller.isRunning ? "stop.fill" : "play.fill")
                        }
                        Text(controller.isRunning ? "停止并恢复直连" : "一键开启局部代理")
                    }
                    .font(.headline)
                    .frame(minWidth: 220)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRunning ? .red : .accentColor)
                .controlSize(.large)
                .disabled(controller.isBusy || (!controller.isRunning && !controller.canStart))

                if !controller.isRunning && controller.systemProxyEnabled {
                    Text("请先在 Quickcat 选择“纯代理”并关闭其 TUN，然后点击刷新。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(.vertical, 8)
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String
    let symbol: String
    let healthy: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(healthy ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var controller: ProxyController

    var body: some View {
        Text(controller.isRunning ? "局部代理运行中" : "局部代理已停止")
        Divider()
        Button("打开主窗口") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
        Button(controller.isRunning ? "停止并恢复直连" : "开启局部代理") {
            Task { await controller.toggleProxy() }
        }
        .disabled(controller.isBusy || (!controller.isRunning && !controller.canStart))
        Button("刷新状态") {
            Task { await controller.refreshStatus() }
        }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
            .disabled(controller.isRunning)
    }
}
