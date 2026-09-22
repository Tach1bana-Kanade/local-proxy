# 阶段 0 架构

> 本文保留阶段 0 的历史原型说明，不适用于当前正式 App。正式智能分流使用 ProxyAppsCore + PAC，参见 [README](../README.md) 和 [智能分流开发说明](smart-routing-development.md)，不会启用此处的 Mihomo、TUN 或 fake-ip。

```text
localproxy.json
      │ 解码、标准化、校验
      ▼
LocalProxyCore ──────→ mihomo.yaml（0600，随机 API 令牌）
      │
      └──────────────→ Quickcat TCP 端口与本机可执行文件诊断
```

`LocalProxyCore` 不执行管理员命令，不改变系统网络状态。`LocalProxyCLI` 也只创建新文件，拒绝覆盖已有配置。

规则编译顺序固定为：安全直连规则 → Quickcat/Mihomo 直连 → 用户拒绝 → 用户强制直连 → 用户代理 → `MATCH,DIRECT`。Mihomo 规则按从上到下顺序匹配，因此安全规则必须保持在用户规则之前。

内置 DNS 使用 fake-ip 辅助保留域名信息。代理解析器通过 `QUICKCAT` 访问 Cloudflare DoH，直连出口与 Quickcat 本地 IP 的解析使用系统 DNS；`.local`、`.lan` 和 `localhost` 不使用 fake-ip。此设计仍须通过阶段 0 的真实 DNS 泄漏测试验证。

阶段 1 将在核心稳定后增加 SwiftUI 菜单栏应用。特权 Helper 不应提供任意命令执行接口，只能对经过哈希校验的固定 Mihomo 二进制执行有限的启动、停止和恢复操作。
