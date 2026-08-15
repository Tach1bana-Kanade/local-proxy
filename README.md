# Proxy Apps

Proxy Apps 是一个 macOS SwiftUI 局部代理工具，使用 Quickcat 的本机 HTTP/SOCKS5 端口，并提供两种彼此独立的白名单：

- **App 白名单**：通过“代理启动”给选定 App 注入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 等环境变量；“普通启动”不注入。
- **网站白名单**：通过仅监听 `127.0.0.1` 的 PAC 服务，使遵循 macOS 自动代理配置的 App 只代理已启用域名及其子域名。

未加入网站列表的域名始终由 PAC 返回 `DIRECT`。命中规则只返回 `PROXY 127.0.0.1:21081`，Quickcat 断开时不会静默回退直连。

正式 `LocalProxyApp` 不依赖或启动 Mihomo，不创建 TUN，不修改 DNS、路由、Quickcat 账号、订阅、节点或内部配置，也不安装 HTTPS 根证书。

## 环境与构建

要求 macOS 12 或更新版本。Quickcat 需要处于纯代理模式并提供：

- HTTP：`127.0.0.1:21081`
- SOCKS5：`127.0.0.1:21080`

```bash
swift test --disable-sandbox
./scripts/build-app.sh
```

构建脚本会在 `dist/` 创建带时间戳的 `ProxyApps-*.app`，不会覆盖旧构建。

## 使用

### App 白名单

1. 点击“添加应用”选择 `.app`。
2. 确保目标 App 已完全退出。
3. 点击“代理启动”注入 Quickcat 环境变量，或点击“普通启动”不使用这些变量。

这种方式只对支持代理环境变量的 App 生效，不会影响未添加的 App。

### 网站白名单

1. 输入 `github.com`、`www.github.com` 或完整的 `https://github.com/path`，点击“添加网站”。
2. 通过单条开关决定规则是否参与 PAC。
3. 确保 Quickcat HTTP 端口可用，打开“网站代理”总开关。
4. App 会保存所有当前启用、有网络接口的网络服务原 PAC 状态，然后设置本机 PAC URL。
5. 关闭总开关或正常退出 App 时，原设置会恢复。

网站代理只对遵循 macOS 自动代理配置的 App 生效。应用会拒绝 IP、localhost、`.local`、通配符、凭据、端口、非法域名和非 ASCII 域名；当前版本可输入 IDN 的 ASCII/Punycode 形式。

如果 App 异常退出，下一次启动会显示“需要恢复”。恢复前会确认当前 PAC 仍是本工具设置；若其他程序或用户已经修改 PAC，App 不会自动覆盖，并会显示冲突值供确认。

## 数据和权限

数据位于 `~/Library/Application Support/Proxy Apps/`：

- `applications.json`：App 列表
- `websites.json`：网站规则
- `pac-settings.json`：网站代理开关与 PAC 端口
- `pac-restore-state.json`：应用 PAC 前的恢复快照（成功恢复后删除）
- `errors.log`：截断保留的少量错误日志

目录权限为 `0700`，文件权限为 `0600`，JSON 使用原子写入。系统 PAC 使用 `/usr/sbin/networksetup` 的固定参数数组操作，不拼接 Shell 命令，也不改动 HTTP、HTTPS、SOCKS 手动代理。

## 架构

```text
Sources/ProxyAppsCore/    网站模型、标准化、PAC 生成、系统 PAC 事务与解析
Sources/LocalProxyApp/    SwiftUI、App 启动、持久化、回环 PAC 服务、networksetup 适配
Sources/LocalProxyCore/   仅保留的历史原型核心，不属于正式 App 依赖
Tests/                    纯逻辑和 fake 系统 PAC 测试，不修改开发机网络
```

仓库中的 `LocalProxyCore`、CLI、Mihomo 配置生成器及旧 SwiftUI 文件仅为历史技术验证资料。`Package.swift` 明确排除旧 `ProxyManager.swift`、`RulesView.swift` 等文件，正式 App 不会调用它们。

详细人工验收与恢复步骤见 [docs/testing.md](docs/testing.md)。
