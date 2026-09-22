# Proxy Apps

macOS 的 SwiftUI 局部代理工具，沿用 Quickcat HTTP `127.0.0.1:21081` / SOCKS5 `127.0.0.1:21080`。正式 App 使用 `ProxyAppsCore`，不启动 Mihomo、不启用 TUN、不安装证书，不修改 DNS、路由、Quickcat 配置或手动 HTTP/SOCKS 系统代理。

## 构建

要求 macOS 12+、Swift 5.8+（本次实际使用本机 Xcode 工具链）。

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/localproxy-clang-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/localproxy-swiftpm-module-cache
swift test --disable-sandbox
swift build --disable-sandbox -c release --product LocalProxyApp
./scripts/build-app.sh
```

脚本输出 `dist/ProxyApps-时间戳-进程号.app`，包含真实离线规则与许可，使用本地 ad-hoc 签名；保留旧构建，不安装替换现有 App。测试使用临时目录并保留夹具，不递归清理文件。

## 使用智能分流

1. 启动 Quickcat 并确保 HTTP 21081 入口可连接。端口可连接不等于互联网畅通。
2. 打开“智能分流”，首次阅读说明后点击“确定并开启”。取消不会改变模式或系统 PAC。相同来源后续开启不再确认。
3. 工具先保护本地目标，再匹配手动规则、自动规则，未知域名默认直连。通过体积、脚本执行与服务自检且系统 PAC 设置成功后，显示“已配置到系统”；实际分流仍取决于应用遵循 PAC。也可选择“仅手动规则”。
4. 规则库默认每 24 小时自动检查，只在 App 运行时更新；可以立即更新或关闭自动更新。失败继续使用旧规则，按 15 分钟、1 小时、6 小时重试。回退上一版本会暂停自动更新。
5. 遇到问题，在“检查网站”粘贴域名或 HTTP/HTTPS URL。先显示当前命中原因，再并发探测两条路径。只有点击“确认使用代理”或“确认直连”才保存手动规则；默认包含子域名。
6. 在“手动规则”搜索、筛选、编辑动作和范围。停用规则后恢复自动判断；强制直连应设置动作“直连”。分流关闭时编辑只保存，不写系统 PAC。
7. 关闭网站分流或正常退出会恢复接管前的原 PAC。若恢复失败，会取消退出并保留 PAC 服务与恢复记录；处理错误后再退出。下次启动保持实际关闭，点击开启恢复使用。异常退出后须先处理恢复记录；外部 PAC 变更会报告冲突，不自动覆盖。

`exact` 只匹配该主机，`suffix` 匹配该域名及其子域名，带点边界；不会删除 `www` 或自动归并最后两段。手动规则整体优先于规则库，本地保护例外。命中代理只返回 `PROXY 127.0.0.1:21081`，没有 `; DIRECT` 回退。这仅描述 PAC 成功加载并执行后的返回值；客户端忽略 PAC 或加载失败仍可能直连。

主域名、图片、登录和 API 域名各自匹配；不会自动发现或添加关联域名。PAC 只影响遵循它的应用，不能保证全系统防泄漏，也不能保证旧长连接立即改路。更改后必要时重新加载页面。

## 应用启动

| 方式 | 行为 |
| --- | --- |
| 普通启动 | 不注入代理参数/环境变量；仍可能遵循系统 PAC，不代表强制直连 |
| 全部代理启动 | 使用原有代理环境变量；Chromium 另外使用固定 `--proxy-server`，不按网站规则分流 |
| 按网站规则启动 | 仅 Chromium 显示；要求分流已启用且 PAC 自检通过，只传当前 `--proxy-pac-url`，不注入固定代理环境 |

目标 App 已运行时提示先完全退出，不结束进程。固定 PAC URL 参数启动的 Chromium 在规则版本更新后可能需要重启。关闭网站分流不会结束通过“全部代理启动”运行的应用。

## 数据、诊断与恢复

数据位于 `~/Library/Application Support/Proxy Apps/`，目录 `0700`、文件 `0600`：

- `routing.json`：版本化配置，含手动规则、模式偏好、确认记录和更新设置；旧 `websites.json` 首次迁移后保留。
- `rule-cache.json`：当前/上一有效规则快照，合并原子保存。损坏缓存保留诊断副本并回退随包规则。
- `applications.json`：现有 App 列表，保持兼容。
- `pac-settings.json`：PAC 服务端口及恢复辅助状态。
- `pac-restore-state.json`：真正原始 PAC 与精确归属 URL，成功恢复后只删除此单个文件。
- `errors.log`：已有错误日志；不记录完整网站 URL 或探测正文。

新配置损坏时阻止编辑/启用，不静默重建空配置。请保留损坏文件，按 [开发说明](docs/smart-routing-development.md) 修复后重启。恢复冲突先核对错误信息和系统设置；只有确认外部设置可以覆盖时，才使用 App 的“强制恢复”。

探测只访问 `https://规范域名/`，不携带原 URL 路径、查询参数、Cookie、认证头或浏览器会话；保留 TLS 校验，不跟随跳转。两条通道使用独立 curl 进程，明确直连或指定 Quickcat，不使用系统 PAC。直连先解析并拒绝本地/保留地址，再用 `--resolve` 固定已验证地址。采用 HEAD，每路最多两次，8 秒总预算；不支持 HEAD 的网站显示无法判断，不发送业务 GET。仅内存缓存 10 分钟，网络变化后失效。

## 规则来源与限制

随包数据来自 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 的真实 `direct-list.txt`、`proxy-list.txt`，固定提交 `6f3d128827b45e968335e7472737ff59d58902d0`。归并后直连 111169、代理 26981、未支持 159、同级冲突 119；同级冲突选直连。来源仓库声明 GPL-3.0，原始许可、上游归属 README、原始数据和 SHA-256 元数据随包保存。详见 [规则来源](docs/rule-sources.md)。

不执行远程正则/关键词语义，不在线分类，不读取浏览历史，不开发浏览器扩展。字面量私网地址和本地域名可直接保护；普通企业域名解析到私网不会由 PAC 做 DNS 检查，应添加显式直连规则。

完整随包规则生成的 PAC 为 368485 字节；发布前拒绝超过 1048575 字节或脚本执行失败的候选，即使在 off/manual 模式下载新规则也先检查其 smart PAC。旧规则与配置保留。已在 Chrome 153.0.8010.53 的独立本地 HTTP 夹具中验证自动分流、未知直连与手动覆盖，共 8 个场景通过（含超限负对照）。

验证记录与真实浏览器验收步骤见 [测试说明](docs/testing.md)。Safari/Chrome 的真实出口、缓存与系统恢复需要用户环境人工验收，不能由单元测试结果代替。
