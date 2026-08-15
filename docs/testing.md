# 阶段 0 测试说明

## 自动测试

```bash
swift test
```

测试覆盖 URL 标准化、IP/CIDR、危险 CIDR、应用路径、规则顺序、默认直连、禁用规则和 UDP 防泄漏回退。

## 安全的本机诊断

```bash
./scripts/diagnose.sh
./scripts/verify-network.sh before
swift run localproxy diagnose localproxy.json
mihomo -t -f mihomo.yaml
```

这些命令不修改网络。`verify-network.sh` 将路由、DNS 和监听端口快照写入 `artifacts/network-<标签>.txt`，用于启停 TUN 前后人工比对。

## 尚需人工执行的网络验证

安装 Mihomo 并通过 `mihomo -t` 后，才进入显式 TUN 测试。测试前后各保存一次快照，至少确认：

1. 未命中网站和应用保持直连。
2. 测试域名命中 `QUICKCAT`。
3. Quickcat 与 Mihomo 不形成循环。
4. Quickcat 退出时，命中代理规则的连接按策略阻止或直连。
5. Mihomo 正常退出与异常退出后，默认路由和 DNS 与基线一致。
6. 分别验证 TCP、UDP、IPv4、IPv6、普通 DNS、DoH、QUIC。

24 小时稳定性测试以及睡眠/唤醒、切换 Wi-Fi 的恢复测试在能够安全启动 TUN 后进行。

## 无 TUN 烟雾测试

`examples/localproxy.smoke.json` 明确设置 `tunEnabled=false`，并将 Mihomo mixed 入口限制到 `127.0.0.1:17890`。它用于在不修改路由和 DNS 的情况下，先验证真实请求的规则命中与 Quickcat 上游。此配置仅用于阶段 0 诊断，不是产品运行配置。
