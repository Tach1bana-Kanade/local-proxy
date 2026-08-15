# Proxy Apps 测试与人工验收

## 自动测试

```bash
CLANG_MODULE_CACHE_PATH=/tmp/localproxy-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/localproxy-swiftpm-module-cache \
swift test --disable-sandbox
```

测试覆盖网址标准化和拒绝规则、重复域名、PAC 根域/子域匹配、相似域名不匹配、本地地址优先直连、空列表、稳定与安全的 JavaScript 编码、JSON 编解码、网络服务输出解析、恢复冲突、部分应用失败回滚。系统配置测试使用 `SystemPACClient` fake，不执行真实 `networksetup` 写操作。

## 系统 PAC 选型

正式 App 使用 `/usr/sbin/networksetup`，而不是直接写 `SystemConfiguration` preferences：

- `networksetup` 是 macOS 自带的固定接口，可枚举本地化名称的网络服务并读取/设置自动代理 URL；
- 每个服务名和 URL 都通过 `Process.arguments` 传递，不经过 Shell 或字符串拼接；
- 只修改自动代理 URL/状态，不修改 HTTP、HTTPS、SOCKS 手动代理；
- 事务层与命令适配层分离，可用 fake 验证回滚，不会在 `swift test` 中改动机器。

当前受限开发环境中的只读 `networksetup -listnetworkserviceorder` 返回 `AuthorizationCreate() failed: -60008`，因此仍需在正常登录的 macOS 图形会话完成以下人工验收。App 会将此类错误显示出来，不会继续半配置。

## 人工验收

测试前在“系统设置 → 网络 → 当前服务 → 详细信息 → 代理”记录自动代理配置 URL 和开关。

1. 将 Quickcat 设为纯代理模式，连接节点，确认 HTTP `127.0.0.1:21081` 和 SOCKS5 `127.0.0.1:21080` 可用。
2. 确认系统自动代理初始关闭；启动 Proxy Apps。
3. 添加 `ipinfo.io` 并打开网站代理。检查 UI 显示“已启用”。
4. 在 Safari 和 Chrome 访问 `ipinfo.io`，确认显示 Quickcat 出口 IP。
5. 访问另一个未添加的 IP 查询网站，确认显示本地直连出口 IP。
6. 添加一个 `.app`，完全退出后分别测试“代理启动”和“普通启动”，确认原 App 功能未回归。
7. 关闭 `ipinfo.io` 规则前，先关闭网站代理总开关；再停用规则并确认网站直连。
8. 重新启用规则和网站代理，然后关闭总开关。确认每个网络服务的原 PAC URL 与开关恢复。
9. 分别在 Wi-Fi、有线网络以及中文服务名环境测试；禁用的服务和没有 Device 的服务不应被修改。
10. 网站代理开启时停止 Quickcat：命中白名单的网站应连接失败，未命中的网站仍应直连，UI 应显示 Quickcat 不可用。
11. 模拟强制退出后重新打开 App：应显示“需要恢复”。点击恢复；若期间手动改变 PAC，首次恢复应拒绝覆盖并展示当前值与原值。

## 恢复方法

首选在 App 中点击“恢复原网络设置”。只有确认期间的新 PAC 设置可以被覆盖时，才使用“强制恢复”。

若 App 无法启动，请打开 macOS“系统设置 → 网络 → 对应网络服务 → 详细信息 → 代理”，根据 `~/Library/Application Support/Proxy Apps/pac-restore-state.json` 中每个服务的 `enabled` 和 `url` 手工恢复“自动代理配置”，完成后保留该文件以便排查，不要随意批量删除应用支持目录。
