# 开发任务：为 Chromium 系应用附加 --proxy-server 启动参数

> 用法（Codex CLI）：在本项目根目录启动 `codex`，然后把本文件全文粘贴为任务指令；
> 或直接运行 `codex "$(cat docs/chromium-proxy-server-增强开发提示词.md)"`。
> 本文件按 Codex 提示词习惯组织：背景与相关文件 → 需求 → 约束 → 验收标准。
> 项目路径：`/Applications/it/局部代理`
> 日期：2026-08-15

---

## 一、背景（请先阅读这些文件再动手）

这是一个 macOS 局部代理工具（Swift 6 + SwiftUI），默认全部直连，只有白名单里的应用/网站走 Quickcat 代理（SOCKS5 `127.0.0.1:21080`，HTTP `127.0.0.1:21081`）。

开始编码前，请先阅读以下文件了解现状：

- `Sources/LocalProxyApp/ProxyAppsManager.swift` —— 重点看 `launch(_:usingProxy:)` 方法（约 118 行），目前通过 `NSWorkspace.OpenConfiguration` 的 `environment` 注入 `HTTP_PROXY` 等环境变量来让走代理。
- `Sources/LocalProxyCore/ProxyAppsModels.swift` —— `ManagedApplication` 数据模型和 `ProxyEnvironment`。
- `Sources/LocalProxyApp/ProxyAppsController.swift` —— UI 层对 launch 的调用。
- `Sources/LocalProxyApp/ProxyAppsContentView.swift` —— 应用规则列表界面（约 328 行有"走代理/直连"启动按钮）。
- `局部代理项目方案.md` 第 5.3 节 —— 应用规则的原始设计。

## 二、要解决的问题

环境变量方案（`HTTP_PROXY`/`HTTPS_PROXY`）对很多应用有效，但 **Chromium 系应用（Chrome、Edge 及所有 Electron 应用，如 VS Code、飞书、Discord）有自己独立的网络栈，经常忽略环境变量**，导致白名单对它们不生效。

Chromium 内核原生支持命令行参数 `--proxy-server=<url>`，优先级高且应用自身无法绕过。在启动时附加该参数，即可强制这类应用的全部流量走指定代理。

## 三、开发需求

### 3.1 核心功能

在"以代理模式启动应用"时（即 `launch(_:usingProxy: true)` 路径），如果目标应用是 Chromium 系应用，除了现有的环境变量注入外，再通过 `NSWorkspace.OpenConfiguration` 的 `arguments` 属性附加：

```
--proxy-server=http://127.0.0.1:21081
```

注意点：

- 代理地址不要硬编码，应与现有 `ProxyEnvironment.values` 中的 HTTP 代理地址保持同一来源（如后续有设置项则读取设置）。
- 只在 `usingProxy == true` 时附加；直连启动行为完全不变。
- 如果应用本身已有其他启动参数需求，应追加而非覆盖（当前代码未使用 `arguments`，直接设置即可）。

### 3.2 Chromium 系应用识别

在 `ProxyAppsManager` 或 `LocalProxyCore` 中新增一个检测方法，判断一个 `.app` 是否为 Chromium 系。建议的判定方式（按可靠性排序，命中其一即可）：

1. bundle 内存在 `Contents/Frameworks/Electron Framework.framework`（Electron 应用）。
2. `Info.plist` 的 bundle identifier 属于已知 Chromium 系（如 `com.google.Chrome`、`com.microsoft.edgemac`、`com.brave.Browser`、`com.operasoftware.Opera` 等）。
3. bundle 内存在 Chromium 特征文件，如 `Contents/Frameworks/* Chromium Framework*` 或可执行文件旁存在 `chrome_crashpad_handler` 等。

识别逻辑做成独立、可单元测试的纯函数/方法（输入 bundle 路径，输出布尔值或枚举），放在 `LocalProxyCore` 中，方便 CLI 和 App 复用。

### 3.3 兼容性兜底

- 非 Chromium 系应用：保持现有行为（仅环境变量），**不要**附加 `--proxy-server`（部分非 Chromium 应用会把未知参数当文件路径打开，造成异常）。
- 识别失败或读不到 bundle 信息时：保守处理，不附加参数，并记录一条日志到现有 `errors.log`。
- `applicationAlreadyRunning` 的现有保护逻辑保持不变（应用已在运行时 `openApplication` 不会应用新参数，这点维持现状即可，但建议在错误提示中补一句"请先完全退出该应用再从本工具启动，代理参数才能生效"）。

### 3.4 界面提示（小改动）

在应用规则列表（`ProxyAppsContentView.swift`）中，对被识别为 Chromium 系的应用，在名称旁或详情处显示一个小标记（如"Chromium 内核 · 代理参数生效"之类的文案），让用户知道该应用使用了更强的代理注入方式。样式保持与现有 UI 一致，不要大改布局。

### 3.5 测试

在 `Tests/` 中补充单元测试：

- Chromium 识别逻辑：构造假的 bundle 目录结构（含/不含 Electron Framework），验证判定结果。
- 启动参数构造：`usingProxy: true` 且 Chromium 系 → configuration 包含 `--proxy-server=http://127.0.0.1:21081`；非 Chromium 系或直连启动 → 不包含。

## 四、约束（必须遵守）

- 不改动现有 PAC、Mihomo、launchd 相关代码。
- 不改动 `ManagedApplication` 的 JSON 存储结构（如确需新增字段，必须保证旧 `applications.json` 能无损解码，并在输出中说明迁移逻辑）。
- 所有新代码注释和 UI 文案使用简体中文。
- 改动范围尽量聚焦，不要做与任务无关的重构。
- 完成后运行 `swift build` 和 `swift test` 确认通过；如本机无法构建，在最终输出中明确说明。

## 五、验收标准

1. `swift build` 和 `swift test` 全部通过。
2. 白名单中添加一个 Electron 应用（如 VS Code），从本工具以代理模式启动后，`lsof -i :21081` 能看到该应用进程的连接。
3. 同一个应用正常双击启动（不经本工具）时，不产生任何到 21080/21081 的连接。
4. 非 Chromium 应用（如 Safari）的启动行为与改动前完全一致。

## 六、交付物（在 Codex 最终输出中给出）

- 修改/新增的代码文件清单及说明。
- `swift build` / `swift test` 结果摘要。
- 如有设计取舍（例如识别名单的取舍），用几句话解释原因。
