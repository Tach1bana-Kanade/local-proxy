# 智能分流开发与恢复说明

正式依赖是 ProxyAppsCore。历史 LocalProxyCore、CLI、Mihomo 和排除的旧 SwiftUI 文件不参与正式 App。新增核心文件由 SwiftPM 自动发现；App 的原显式 sources 清单不变，资源通过 `.process("Resources")` 进入 `LocalProxy_ProxyAppsCore.bundle`，构建脚本复制到 `.app/Contents/Resources/`。

## 配置与迁移

`routing.json` 的 schemaVersion 为 1。JSON 日期统一使用 Foundation JSONEncoder 默认日期编码：从 2001-01-01T00:00:00Z 起的秒数（可为小数），不混用 Unix 时间或字符串。

```json
{
  "schemaVersion": 1,
  "preferredMode": "smart",
  "confirmation": "loyalsoldier-v1-smart-unknown-direct",
  "automaticUpdates": true,
  "lastSuccessfulCheck": 811296000,
  "manualRules": [{
    "id": "8E7011AB-C7BF-4AE5-B47A-DA85AF92739F",
    "domain": "www.example.com",
    "match": "suffix",
    "action": "direct",
    "enabled": true,
    "createdAt": 811296000,
    "modifiedAt": 811296000,
    "source": "user"
  }]
}
```

confirmation、lastSuccessfulCheck 和规则 reason 可省略。source 是 user / diagnosis / migration。`preferredMode` 为 off/manual/smart，仅为保存偏好；`activeMode` 在内存中，启动总是 off，不静默接管系统。确认只有固定来源、smart、未知直连的本地产品版本相同时才复用。

routing.json 不存在时，读取 websites.json，保留 UUID、原规范域名及 enabled，补 suffix/proxy/migration，时间未知使用 Unix epoch。迁移后偏好 manual，不开 smart。先验证唯一 ID、domain+match 和域名，再完整原子写新文件。旧文件不删除；新文件存在即不再导入。新文件损坏/版本不支持时报错并阻止修改，不能自动覆盖成空数据。

人工修复：先保留单个损坏文件副本，再按上述 schema 修复；需要重新迁移时由用户自行将该单个 routing.json 改名保留，确认旧 websites.json 正确后重启。不要批量删除支持目录。失败写入可能留下 `.pending-UUID` 供诊断，不自动清理。

## 持久化顺序与恢复

配置/规则缓存使用随机临时文件（创建即 0600）→完整写入→fsync→同目录 rename 原子替换；目录 0700。应用进程 umask 077，旧的 App/PAC JSON 继续使用原子写入。rule-cache.json 同一文件中包含 current 和 previous 两份原始数据、哈希、版本、下载时间。启动先验证本地 current/previous，失败则回退随包资源并显示原因；原损坏文件不删除，后续首次写缓存时另存 `rule-cache-corrupt-UUID.json`。SHA-256 不是签名。

活动配置修改的顺序：

1. 获得配置变更锁，读取最新手动配置；后台编译候选 matcher/PAC，先检查 UTF-8 不超过 1048575 字节，再在 JavaScriptCore 执行并校验入口。本地服务健康检查还核对响应码和完整内容哈希。off/manual 下载也额外验证 smart 候选，超限不能替换工作缓存。下载不占用该锁，不能带着过期手动规则提交。
2. 暂存不可变候选 PAC，以完整 SHA-256 作为 revision；此时不改变无 revision 请求的当前内容。服务器精确解析 `/proxy.pac?v=<revision>`，未知 revision 返回 404，不在 GET 中编译。全部事务成功后才激活候选。
3. 首次启用：读取全部目标服务的真正原状态，先写恢复快照，再写各服务 PAC。后续切换：先检查当前服务仍为活动 URL，写入包含原服务状态和旧/新精确 URL 的恢复日志，再写新 URL，不能把自己的旧 PAC 当原设置。
4. 网络切换成功后提交候选规则缓存（有更新时）和 routing.json，再持久化辅助 PAC 设置；全部成功后更新 UI 的配置与 activeMode。
5. 发生异常则恢复上一网络 revision / 原状态与旧配置/缓存。部分服务失败按逆序回滚。回滚失败保留日志并显示“需要恢复”。启动发现日志时禁止新应用；跨文件中途崩溃后通过恢复日志回到真正原 PAC，实际模式保持关闭。磁盘可能已提交候选配置，它只作为下一次用户主动开启时的偏好。
6. 停用/退出：检查所有服务没有外部冲突→恢复原状态→标记实际 off→保存辅助状态→只删除恢复快照单文件。保存/删除失败仍报告需要恢复，不假报仍在分流。

正常退出通过 applicationShouldTerminate 异步等待：阻止新变更、取消下载和探测、等待正在提交的事务完成或回滚，再恢复系统 PAC；恢复失败回复取消退出并保留服务和日志。networksetup 在后台执行，每条命令最多 10 秒、输出最多 64 KiB，避免阻塞主线程。恢复成功但后续磁盘记录写入失败仍取消退出并报告，不声称恢复记录已清除。

恢复日志兼容旧格式：`managedPACURL` 和 `services` 保留；新增可选 `ownedPACURLs` 记录明确生成过的 URL。恢复只接受原状态或日志中精确归属的 URL，不以 localhost 子串识别所有权。强制恢复仍需用户从 UI 明确确认。

版本回退先持久化 automaticUpdates=false，随后事务发布 previous；即使中途崩溃也不会静默更新覆盖用户回退意图。正在下载的任务取消并用 generation 拒绝迟到提交。若回退失败，自动更新仍保持暂停，错误说明网络/配置未应用。

## 匹配与 PAC

索引键为 `e:域名` / `s:域名`，值为动作。单次查询先 exact，再依次去掉最左域名标签查询 suffix；复杂度随域名标签数增长，不遍历规则总表。手动索引优先于自动索引，同级冲突 direct。off 不匹配规则，manual 完全跳过自动索引。

自动规则先按继承动作消除冗余：默认是 direct，同动作后缀及无差异 exact 可省略，所有动作例外必须保留。只压缩 PAC 自动索引，UI/Swift matcher 仍保留完整来源索引和计数；手动 direct 不可按默认值消除，否则会失去覆盖自动 proxy 的能力。将保留键反向排序，对相邻键按 UTF-16 公共前缀编码，记录格式为 `前缀长度(base36):尾部长度(base36):尾部+动作`，整个载荷经 JSON 字符串编码。PAC 初始化解码一次，逐请求仍只沿域名标签查索引。完整数据 276300 个域名/子域名结果与 Swift 交叉一致。

PAC 使用 ES5 兼容语法、稳定 JSON 编码；不调用 dnsResolve/isInNet。本地保护纯字符串与字面量 IP 解析，普通域名解析后的私网识别不在 PAC 中执行。域名字符串不会成为可执行表达式。代理无 DIRECT fallback。

服务只绑定 127.0.0.1；端口冲突回退到系统分配端口。并发客户端上限 8，请求头最多 16 KiB、读取预算 2 秒、写入预算 5 秒，并设置 socket 超时和 SO_NOSIGPIPE。异常/断开客户端不会无限阻塞监听队列。HTTP 响应禁止缓存；客户端仍可能缓存 PAC 或复用长连接，因此不能保证更改即时生效。事务成功或正常回滚后清理不再需要的内存快照，只保留最新版本、当前 URL 和本会话通过“按网站规则启动”且仍在运行的应用固定引用的版本；回滚失败则保留候选供恢复。启动应用期间同样持有配置变更锁，避免它正在启动时旧版本被清理。这是内存回收，不删除文件。

## 更新与探测

更新调度是可注入时间的 UpdateSchedule，成功 24 小时，失败 15 分钟/1 小时/6 小时；App 内循环每 5 秒检查到期，无 launchd/后台守护。RuleSetUpdater 合并并发任务，固定一次解析得到的 SHA 下载两份数据。下载超时 30 秒，每个子进程额外有终止期限；输出受大小上限约束。只尝试明确 direct，失败时可整次经 proxy 重试。未运行 App 不更新。

网络传输使用系统 `/usr/bin/curl`，参数数组而非 shell；清空继承环境，`--disable` 禁用 curlrc，显式 `--noproxy '*' --proxy ''` 或 `--noproxy '' --proxy http://127.0.0.1:21081`。由 macOS curl 保持默认 TLS 证书验证。App 退出先取消更新和探测，恢复成功后停止剩余传输子进程。

诊断使用两个独立进程并发 HEAD。直连先在受限时长的 `/usr/bin/dscacheutil` 子进程内解析域名，拒绝任一解析地址为本地/保留地址，再用 `--resolve` 固定首个地址，保留原域名 SNI/证书校验，避免检查后重新 DNS 解析。代理解析由 Quickcat 完成。本地字面量和本地域名在输入层拒绝；普通域名若代理侧解析到私网，本工具无法检查代理内部解析过程。

总预算 8 秒（DNS 最多 2 秒，单次 HEAD 最多 3 秒且不超过剩余预算），每路最多两次连接尝试。取消会终止实际子进程，DNS 阻塞不能让 UI 无限等待。只使用 HEAD，不回退 GET；HEAD 不支持时无法给确定建议。只测试选定地址，不代表所有 DNS 地址/网络路径均可达。403/429/TLS 错误/跳转不能作为代理必要性证据；两次直连连接失败且代理正常 2xx 才建议代理。实际浏览登录/资源加载仍需人工验证。

ProbeNetworking 可注入；内存缓存键包含规范域名、网络代次、跳过直连标志、代理可用状态，TTL 10 分钟。NWPathMonitor 变化清空缓存并取消旧请求。检查面板输入变化/关闭取消任务，generation 防止迟到结果覆盖新域名。手动确认保存在配置，不随缓存失效。

参考：[Chromium 代理文档](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)、[MDN PAC](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file)。
