# Proxy Apps

Proxy Apps 是一个仅供个人使用的 macOS 本地工具。电脑默认保持直连；只有从本工具点击“代理启动”的应用会收到 Quickcat 代理环境变量。

新版 SwiftUI 入口不使用 Mihomo、不使用 TUN、不需要管理员权限，也不会修改 Quickcat、系统代理、DNS、路由、Shell 配置或 `launchctl` 全局环境。

## 使用

要求 macOS 12 或更新版本。先手动配置 Quickcat：纯代理、全局模式、节点已连接，SOCKS5 为 `127.0.0.1:21080`，HTTP 为 `127.0.0.1:21081`，系统代理和 TUN 均关闭。

```bash
./scripts/build-app.sh
```

脚本会在 `dist/` 创建带时间戳的 `ProxyApps-*.app`。应用会按 Bundle ID `com.openai.codex` 查找本机 Codex，并允许添加其他 `.app`。

- “代理启动”仅为目标应用及其子进程设置 HTTP、HTTPS、ALL 和 NO_PROXY 的大小写环境变量。
- “普通启动”不设置任何代理变量。
- 应用已经运行时不会自动结束，而会提示完全退出后重试。
- “检查连接”只读调用 `scutil --proxy` 和 `lsof`。
- 应用列表和少量错误日志保存在 `~/Library/Application Support/Proxy Apps/`。

## 限制

只有支持代理环境变量的应用才能正常使用。部分桌面程序、后台服务、UDP 或 QUIC 流量可能不支持。`socks5h` 只对正确支持它的客户端提供代理端域名解析，本工具不能强制不支持环境变量的应用走代理。

## 历史 Mihomo/TUN 原型

仓库仍保留早期 LocalProxy 阶段验证源码和测试，便于参考与回溯，但新版 Proxy Apps 应用入口不调用这些代码。

LocalProxy 原型是一个面向 macOS 的“默认直连、按规则代理”技术验证：提供 Swift 命令行原型，用于维护规则、生成 Mihomo TUN 配置，以及诊断本机 Quickcat 入口。

## 历史原型能力

- JSON 规则模型：网站、IP/CIDR、应用可执行路径。
- 规则动作：`QUICKCAT`、`DIRECT`、`REJECT`。
- 输入标准化：移除 URL scheme、路径、查询参数并转为小写。
- 拒绝非法域名、非法 IP、过宽 CIDR 和可能注入配置的应用路径。
- 按固定优先级生成 Mihomo YAML，最终规则始终为 `MATCH,DIRECT`。
- Quickcat、Mihomo、本地、局域网和保留地址优先直连。
- 控制 API 仅监听回环地址，每次生成随机 256-bit 令牌。
- SOCKS5 UDP 默认关闭；防泄漏策略仅拒绝命中代理规则的 UDP，不影响未命中流量直连。
- 生成文件使用 `0600` 权限且不覆盖已有文件。

## 开始使用

要求：macOS、Apple Silicon、Swift 5.8 或更新版本。产品目标仍为 Swift 6；阶段 0 暂时兼容当前机器上的 Swift 5.8。

```bash
swift build
swift run localproxy init localproxy.json
swift run localproxy validate localproxy.json
swift run localproxy diagnose localproxy.json
swift run localproxy generate localproxy.json mihomo.yaml
```

生成配置不会启动 Mihomo。安装 Mihomo 后，可先执行其只读配置检查：

```bash
mihomo -t -f mihomo.yaml
```

## 图形界面

生成可双击运行的 macOS 应用：

```bash
./scripts/build-app.sh
```

脚本会在 `dist/` 中创建一个带时间戳的新 `.app`，不会覆盖已有应用。打开应用后：

1. 保持 Quickcat 已连接，并选择“纯代理”；Quickcat 的 TUN 和系统代理都应关闭。
2. 确认界面的 Quickcat 与系统代理状态正常。
3. 点击“一键开启局部代理”，通过 macOS 管理员授权。
4. 点击“停止并恢复直连”会校验进程身份后终止 Mihomo。

“规则”页可以添加应用和域名。首轮默认包含 ChatGPT/Codex 相关进程，避免关闭 Quickcat 系统代理后 Codex 无法连接。

当前 GUI 是个人技术验证版本，使用 macOS 管理员授权将固定 Mihomo 命令提交给临时 `launchd` 服务；关闭管理员会话不会终止核心。停止按钮会校验进程身份并移除该服务。产品化版本仍需改用签名的最小权限 Helper。

在配置检查、基线记录和人工确认全部完成前，不要以管理员权限启动 TUN。参考 [阶段 0 测试说明](docs/testing.md)。

## 项目结构

```text
Sources/LocalProxyCore/   规则、校验、端口探测、配置生成
Sources/LocalProxyCLI/    阶段 0 命令行入口
Tests/                    单元测试
docs/                     架构、安全、规则和测试说明
scripts/                  只读诊断与网络快照脚本
```

## 开发环境备注（2026-08-09）

- 2026-08-09 已验证 Xcode 26.6、Swift 6.3.3 与 Mihomo 1.19.29（darwin/arm64）。
- 项目完整构建通过，8 个单元测试全部通过。
- 生成的阶段 0 配置已通过 `mihomo -t` 校验。
- Quickcat 端口状态会随连接状态变化，请以 `./scripts/diagnose.sh` 的即时结果为准。

## 安全边界

本项目不读取或修改 Quickcat 的账号、订阅和内部文件，不安装 HTTPS 根证书，不解密流量。阶段 0 只负责生成配置和诊断；真正启停 TUN 与最小权限 Helper 留在后续阶段实现。
