# 规则模型

规则文件是 `LocalProxyConfiguration` 的 JSON 编码。

网站规则支持：

- `exact`：生成 `DOMAIN`。
- `suffix`：生成 `DOMAIN-SUFFIX`。
- `wildcard`：生成 `DOMAIN-WILDCARD`。
- `ip-cidr`：生成 `IP-CIDR` 或 `IP-CIDR6`。

动作支持 `QUICKCAT`、`DIRECT`、`REJECT`。关闭的规则不会进入 Mihomo 配置。

IPv4 前缀短于 `/8`、IPv6 前缀短于 `/32` 会被视为危险的大范围输入并拒绝。单个 IPv4/IPv6 地址会分别标准化为 `/32` 和 `/128`。

应用规则优先编译绝对 `PROCESS-PATH`，随后编译精确 `PROCESS-NAME` 作为应用更新后的兜底。模型已保留 Bundle ID 和辅助进程开关；在尚未实现代码签名与 Helper 枚举前，不生成通配符或正则进程名规则。

ChatGPT/Codex 需要主应用、CLI、Codex Service 和 `ChatGPTHelper` 协同联网。配置迁移器在检测到已有 ChatGPT/Codex 规则时会幂等补充 `ChatGPTHelper`，避免部分请求落入默认直连。

`failurePolicy=block` 且 UDP 未确认可用时，生成器会在每一条代理规则后添加同条件的 UDP 拒绝回退。这样代理 UDP 不会穿透到最终 `MATCH,DIRECT`，未命中代理规则的 UDP 仍然直连。
