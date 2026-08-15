# Codex 二次开发 PRD 提示词

下面整段内容可以直接复制到 Codex 中执行。

---

你正在维护一个 macOS SwiftUI 项目：

- GitHub：`https://github.com/Tach1bana-Kanade/local-proxy`
- 本地项目名：`Proxy Apps`
- 上游代理：Quickcat
- HTTP 代理：`127.0.0.1:21081`
- SOCKS5 代理：`127.0.0.1:21080`

请阅读完整仓库后，在现有架构上完成“App 白名单 + 网站白名单”的局部代理功能。不要只修改 UI，必须实现规则持久化、PAC 生成、系统配置应用、恢复、错误处理和测试。

## 一、必须遵守的架构约束

1. 保留当前正式版本的 App 代理机制：通过 `NSWorkspace.OpenConfiguration.environment` 给用户选择的 App 注入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 等环境变量。
2. 不得把历史 Mihomo/TUN 原型重新接回正式 App。
3. 不使用 Mihomo、不使用 Clash 内核、不创建 TUN、不修改 DNS和路由。
4. 网站白名单通过 PAC（Proxy Auto-Configuration）实现。
5. 未添加或未启用的网站必须返回 `DIRECT`。
6. 不读取或修改 Quickcat 的账号、订阅、节点和内部配置。
7. 不安装 HTTPS 根证书，不进行 HTTPS 解密。
8. 仓库中 `LocalProxyCore`、`ProxyManager.swift`、`RulesView.swift` 等 Mihomo 历史源码只能作为参考，不得加入正式 `LocalProxyApp` target。
9. 保留现有 App 添加、删除、代理启动、普通启动、Quickcat 端口探测和连接诊断功能。
10. 不批量删除任何文件或目录；不要破坏用户已有修改。

## 二、产品目标

用户可以维护两类代理白名单：

### App 白名单

- 用户添加一个 `.app`。
- 点击“代理启动”后，该 App 获得 Quickcat 代理环境变量。
- 点击“普通启动”后，该 App 不获得代理环境变量。
- 未添加的 App 不受本工具影响。

### 网站白名单

- 用户添加域名或完整 URL。
- 工具提取、标准化并保存域名。
- 启用网站代理后，遵循 macOS 系统 PAC 的应用访问这些域名时使用 Quickcat HTTP 代理。
- 未添加、已停用或已删除的域名始终直连。

两类规则采用“或”关系：

- 加入 App 白名单并通过“代理启动”打开的 App，其支持代理环境变量的流量全部走 Quickcat。
- 加入网站白名单的域名，在任何遵循 macOS PAC 的 App 中走 Quickcat。
- 其他流量直连。

## 三、MVP 用户界面

将主窗口调整为两个主要规则区域，保留现有诊断区域。

### 1. App 区域

保留当前功能和按钮：

- 添加 App
- 代理启动
- 普通启动
- 从列表删除
- App 图标、名称、安装路径

不要改变现有 App 代理语义。

### 2. 网站区域

新增“网站”卡片，包含：

- 域名/网址输入框
- “添加网站”按钮
- 网站规则列表
- 每条规则的启用开关
- 单条删除按钮
- 网站代理总开关
- 当前 PAC 状态：未启用、已启用、应用失败、需要恢复
- 已启用网站数量

输入框应接受：

```text
github.com
www.github.com
https://github.com/openai/codex?tab=readme
```

默认规则语义为“域名及其所有子域名”。例如添加 `github.com` 后，应匹配：

```text
github.com
api.github.com
raw.githubusercontent.com  // 不匹配，因为不是 github.com 的子域
```

### 3. 提示文案

界面必须明确说明：

- App 代理仅对支持代理环境变量的 App 生效。
- 网站代理仅对遵循 macOS 自动代理配置的 App 生效。
- 网站代理会修改 macOS 当前网络服务的自动代理配置。
- 未加入网站列表的域名保持直连。

## 四、数据模型与持久化

在 `ProxyAppsCore` 中新增可测试的模型，不要复用 Mihomo 的 `DomainRule`：

```swift
public struct ManagedWebsite: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var domain: String
    public var enabled: Bool
}
```

根据需要新增：

```swift
public struct PACSettings: Codable, Equatable, Sendable
public struct NetworkServiceProxySnapshot: Codable, Equatable, Sendable
```

持久化要求：

- App 列表继续保存在现有 `applications.json`。
- 网站列表保存为 `websites.json`。
- 应用 PAC 前的系统自动代理状态保存为 `pac-restore-state.json`。
- 文件继续位于 `~/Library/Application Support/Proxy Apps/`。
- 目录权限为 `0700`，文件权限为 `0600`。
- JSON 写入使用原子写入。
- 重启 App 后规则、开关状态和待恢复状态不能丢失。

## 五、网址标准化与校验

实现独立、可单元测试的 `WebsiteNormalizer`。

处理规则：

1. 去除首尾空白。
2. 如果输入是完整 URL，只保留 host。
3. 域名转换为小写。
4. 移除末尾的 `.`。
5. 拒绝 scheme 不是 `http` 或 `https` 的完整 URL。
6. 拒绝用户名、密码、空 host、端口替代域名、路径替代域名等异常输入。
7. 拒绝通配符输入；MVP 统一由程序自动匹配根域及子域。
8. 拒绝 `localhost`、`.local`、回环地址和 IP 地址；这些地址保持直连。
9. 校验域名总长度、标签长度、空标签、首尾连字符及非法字符。
10. 相同标准化域名不得重复添加，即使原始输入形式不同。

如果 Swift/Foundation 当前能力可以可靠支持 IDN，则标准化为 ASCII/Punycode；如果不能可靠实现，MVP 应明确拒绝非 ASCII 域名并给出中文错误，不要静默保存错误规则。

## 六、PAC 生成规则

在 `ProxyAppsCore` 中实现纯函数式 `PACGenerator`，输入启用的网站列表，输出 PAC JavaScript 字符串，便于单元测试。

生成结果必须满足：

1. `localhost`、`*.local`、回环地址优先 `DIRECT`。
2. 精确匹配用户域名。
3. 匹配用户域名的所有子域名。
4. 命中时返回 `PROXY 127.0.0.1:21081`。
5. 未命中时返回 `DIRECT`。
6. 不使用 `PROXY ...; DIRECT` 作为命中规则，避免 Quickcat 断开时网站白名单静默泄漏到直连。
7. 用户输入不得直接拼接进 JavaScript；使用安全的字符串编码，防止 PAC/JavaScript 注入。
8. 输出顺序稳定，相同输入必须产生相同结果。
9. 空的启用列表生成全 `DIRECT` PAC。

生成结果的逻辑应等价于：

```javascript
function FindProxyForURL(url, host) {
    host = host.toLowerCase();

    if (isPlainHostName(host) ||
        host === "localhost" ||
        dnsDomainIs(host, ".local") ||
        isInNet(host, "127.0.0.0", "255.0.0.0")) {
        return "DIRECT";
    }

    if (host === "github.com" || dnsDomainIs(host, ".github.com")) {
        return "PROXY 127.0.0.1:21081";
    }

    return "DIRECT";
}
```

这只是逻辑示例，不要硬编码 `github.com`。

## 七、PAC 文件服务

首选实现：由 App 在回环地址提供 PAC 文件。

- 使用系统框架实现最小本地 HTTP 服务，优先考虑 `Network.framework` 的 `NWListener`。
- 只监听 `127.0.0.1`，不得监听局域网地址或 `0.0.0.0`。
- 提供固定路径 `/proxy.pac`。
- 响应 Content-Type 为 `application/x-ns-proxy-autoconfig`。
- PAC 内容从当前启用的网站规则生成。
- 规则改变后，新请求立即返回新 PAC。
- 对非 `/proxy.pac` 请求返回 404。
- 限制请求大小，不记录完整 URL、Cookie 或其他隐私数据。
- 端口应可靠确定并持久化；如果默认端口被占用，应报告清晰错误或选择可用端口并同步更新系统 PAC URL。

如果经过验证，macOS 对本地 `file://` PAC 的兼容性明显更可靠，也可以改用原子写入的本地 PAC 文件。但必须通过 Safari、Chrome 和系统网络栈的人工测试后才能采用，不能未经验证直接假设。

## 八、macOS 自动代理配置管理

实现独立的 `SystemPACManager`，负责读取、应用和恢复系统 PAC 配置。

要求：

1. 应用前枚举当前可用的 macOS 网络服务。
2. 不要硬编码服务名为 `Wi-Fi`，因为用户可能使用中文服务名、有线网络、热点或 VPN。
3. 仅处理当前启用且具备网络接口的服务。
4. 修改前记录每个服务原有的：
   - 自动代理是否启用；
   - 原自动代理 URL；
   - 需要恢复的服务标识或稳定名称。
5. 不修改用户原有的 HTTP、HTTPS、SOCKS 手动代理配置。
6. 应用本工具 PAC 时，把 URL 设置为本机 `/proxy.pac` 地址并启用自动代理。
7. 用户关闭网站代理时，准确恢复每个服务原有的 PAC URL 和启用状态。
8. 如果只有部分服务修改成功，必须回滚已修改的服务，并显示错误。
9. 只有全部恢复成功后才能删除恢复快照。
10. App 启动时如果发现 `pac-restore-state.json`，应检测系统当前状态，并提示“恢复原网络设置”或自动进行安全恢复。
11. 不要用字符串拼接执行任意 Shell 命令；所有网络服务名和参数必须通过 `Process.arguments` 或严格转义的固定命令传递。
12. 如果系统修改确实需要管理员权限，只能为固定的 PAC 设置/恢复操作请求授权，并在界面提前说明。不得提供任意命令执行能力。
13. 不要因为窗口关闭就立即恢复 PAC；网站代理总开关开启期间，PAC 应持续有效。用户显式关闭网站代理或退出整个 App 时，再按产品状态执行恢复。

优先调查并选择以下实现中安全、稳定的一种：

- `SystemConfiguration` 框架；
- `/usr/sbin/networksetup` 的固定参数调用。

先用只读调用验证当前网络服务和权限行为，再实施写入。把选型理由记录在文档中。

## 九、状态与故障处理

### 启用网站代理前

- 检查 Quickcat HTTP 端口 `127.0.0.1:21081` 是否可连接。
- 检查至少存在一条启用的网站规则。
- 启动 PAC 服务并确认 PAC URL 可读取。
- 保存原系统 PAC 状态。
- 最后应用系统 PAC。

任何一步失败都不能留下半配置状态。

### Quickcat 运行中断开

- 网站白名单请求应失败，不得自动回退到直连。
- UI 显示 Quickcat 不可用。
- 未命中 PAC 白名单的网站继续 `DIRECT`。

### App 异常退出或下次启动

- 通过恢复快照识别是否留下本工具的 PAC 设置。
- 提供明确恢复流程。
- 不得覆盖用户在此期间主动修改的新 PAC 设置；检测到冲突时停止自动覆盖，并展示当前值与原快照，等待用户确认。

## 十、建议代码结构

可以根据现有工程调整命名，但职责必须分离：

```text
Sources/ProxyAppsCore/
├── ProxyAppsCore.swift
├── ManagedWebsite.swift
├── WebsiteNormalizer.swift
└── PACGenerator.swift

Sources/LocalProxyApp/
├── LocalProxyApp.swift
├── ProxyAppsContentView.swift
├── ProxyAppsController.swift
├── ProxyAppsManager.swift
├── PACServer.swift
└── SystemPACManager.swift
```

不要把域名校验、PAC JavaScript 生成、系统代理修改和 SwiftUI 状态全部堆进 `ProxyAppsController`。

## 十一、测试要求

### 单元测试

至少增加以下测试：

1. 完整 URL 标准化为 host。
2. 域名大小写和末尾点标准化。
3. 拒绝非法 URL、IP、localhost、通配符和注入字符。
4. 标准化后的重复域名被识别。
5. PAC 精确匹配根域。
6. PAC 匹配子域。
7. 相似但不属于该域的地址不匹配，例如 `notgithub.com` 不匹配 `github.com`。
8. 空列表全部直连。
9. 本地地址优先直连。
10. PAC 中不存在 `PROXY 127.0.0.1:21081; DIRECT`。
11. PAC 字符串编码不能被域名输入打断。
12. 网站列表 JSON 编解码。
13. 系统代理状态解析和恢复计划测试。
14. 部分应用失败时的回滚逻辑测试。

系统 PAC 的自动化测试必须使用抽象接口和 fake/mock，不得在执行 `swift test` 时真实修改开发机器的系统代理。

### 人工验收

完成后提供人工验收脚本或文档，覆盖：

1. Quickcat 纯代理模式已连接，系统代理初始关闭。
2. 添加 `ipinfo.io`，启用网站代理。
3. Safari/Chrome 访问 `ipinfo.io`，确认显示 Quickcat 出口 IP。
4. 访问未添加的 IP 查询网站，确认显示本地直连出口 IP。
5. 添加 App 并通过“代理启动”，确认现有 App 功能没有回归。
6. 停用网站规则后确认该网站恢复直连。
7. 关闭网站代理总开关，确认系统 PAC 恢复到原状态。
8. 测试 App 强制退出后重新打开的恢复提示。
9. 测试 Wi-Fi 与有线网络服务名。
10. 测试 Quickcat 中途断开时，白名单网站不会静默直连。

## 十二、验收标准

以下条件全部满足才算完成：

- 正式 App 不依赖、不启动、不检测 Mihomo。
- 正式 App 不创建 TUN，不修改 DNS 和路由。
- 原 App 代理启动/普通启动行为保持不变。
- 可以添加、启用、停用、删除网站规则。
- 完整 URL 能正确转换为域名规则。
- PAC 只代理启用的网站，其余返回 `DIRECT`。
- PAC 仅指向 Quickcat HTTP `127.0.0.1:21081`。
- 系统原有 PAC 设置能够准确恢复。
- 部分失败不会留下半配置状态。
- 自动化测试不会真实修改系统代理。
- `swift test` 通过。
- `./scripts/build-app.sh` 能生成可打开的 `.app`。
- README 更新为当前真实架构，并删除容易让用户误解为正式功能的 Mihomo 使用说明，或将其明确移动到历史文档。

## 十三、Codex 执行方式

请按以下顺序工作：

1. 阅读 `README.md`、`Package.swift` 和所有 `ProxyApps*` 正式源码及相关测试。
2. 明确列出当前架构和将修改的文件。
3. 先实现纯模型、网址标准化和 PAC 生成器及单元测试。
4. 再实现网站规则持久化和 SwiftUI 管理界面。
5. 以可替换接口实现 PAC 服务与系统 PAC 管理器。
6. 先进行只读系统调查，再实现 PAC 设置与恢复。
7. 完成错误回滚和异常恢复。
8. 运行全部测试和 release 构建。
9. 对生成的 App 做基本启动验证。
10. 更新 README 和测试说明。

不要在遇到普通实现细节时停下来询问；在不改变上述产品语义和安全边界的前提下做合理决定并继续。只有当 macOS 权限机制导致必须选择完全不同的产品交互时，才停止并说明证据、可选方案和影响。

最终回复需要包含：

- 完成的功能；
- 主要架构决策；
- 修改的文件；
- 测试和构建结果；
- 尚未解决的系统限制；
- 用户如何启用、验证和恢复网站代理。

---
