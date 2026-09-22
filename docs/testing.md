# 测试与人工验收

## 可复现自动测试

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/localproxy-clang-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/localproxy-swiftpm-module-cache
swift test --disable-sandbox
swift build --disable-sandbox -c release --product LocalProxyApp
./scripts/build-app.sh
git diff --check
```

2026-09-22：基线 39 项通过；补充兼容性与恢复修复后，最终完整回归 74 项通过，0 失败（含 3 项真实回环 socket 测试与 off 更新超限保留缓存测试），总耗时 20.55 秒。系统设置全部使用 fake runner / SystemPACClient，不调用真实 networksetup 写操作；Quickcat 状态、更新下载和探测使用注入适配器。另用真实 `/bin/sleep` 子进程验证取消/截止时间会终止实际操作，而非仅丢弃 UI 结果。没有用 GitHub、Quickcat 或真实外网作为 swift test 前提。

受限环境默认 Swift 缓存路径不可写，需要以上两个缓存环境变量。仍有 SwiftPM 用户级缓存目录不可写的警告，不影响编译和测试。

测试保留所有临时夹具目录。原 Chromium 检测测试的递归删除清理已移除，遵守禁止批量删除约束。

此前 `ProxyApps-20260922-113601-63942.app` 的完整 PAC 超过 Chrome 限制，不作为本轮验收版本。新产物和打包自检记录见本文末尾“本轮交付记录”。

## 验收编号与自动覆盖

| 编号 | 自动验证内容 / 边界 |
| --- | --- |
| A01 | 控制器首次确认、取消无系统写入；确认持久化、重启实际 off |
| A02 | 新临时目录从随包真实快照离线解析，Google/Baidu 路由；缓存损坏回退和诊断副本 |
| A03–A07 | smart/manual/off、未知直连、手动覆盖、具体程度、exact/suffix、停用、冲突 direct、本地 IPv4/IPv6、无 DNS helper 和无 DIRECT fallback |
| A08 | 注入配置写失败后，内存、磁盘和活动 PAC URL 回滚一致；编辑与停用共享提交路径；不逐项模拟所有文件系统错误 |
| A09 | 旧 UUID/域名/disabled 保留、不自动开 smart、幂等、损坏配置不覆盖、0600 权限 |
| A10 | 更新固定同一 SHA、直连失败整次代理重试、并发去重、半下载失败；解析超限/畸形拒绝，SHA 校验 |
| A11 | fake 时钟 24h 和三档退避、成功重置；控制器回退后持久化暂停自动更新 |
| A12 | off 更新不写系统，更新/回退保留手动规则，缓存损坏保留并回退 |
| A13 | JavaScriptCore 执行 PAC，与 Swift 比较全部随包规则及子域名，共 276300 个样本；另测多层例外、exact、手动覆盖、稳定编码 |
| A14 | 100000 条规则编译、体积与 Swift/JavaScript 各 10000 次查询实测，索引按标签查询 |
| A15 | 直连/代理参数不同、fake 请求通道与固定 IP 不同、合并并发、TTL/网络代次、取消不缓存；实际子进程取消/期限。真实 Quickcat 双通路和 Wi-Fi 切换另列人工验收 |
| A16 | 403/429/TLS/重定向无法判断，正常直连优先；只有显式保存规则才写配置 |
| A17 | 原始快照不被 revision 替换；旧/新 URL 崩溃归属、外部冲突、部分失败/回滚失败日志；控制器正常恢复、退出冲突取消终止并保留服务、退出与提交交叠；版本暂存/激活及无引用快照回收 |
| A18 | smart 可零手动规则，off 编辑/更新不写网络，manual 保持白名单行为且允许空规则全直连 |
| A19 | 普通/固定代理/PAC 三种参数；按网站规则启动不混入全代理参数或环境；真实浏览器缓存另验 |
| A20 | release 与 .app 构建，SwiftPM 资源复制及隔离目录命令行资源自检；图形界面与真实网络未验 |

## 性能样本

本机 arm64 macOS，debug 单次样本（不是 Safari/Chrome 真实 PAC 引擎性能保证）：

- 100000 条合成规则，编译+建立 matcher：0.508 秒。
- 合成 PAC UTF-8：453190 字节；完整真实随包 PAC：368485 字节。
- Swift 10000 次域名查询：0.046 秒。
- JavaScriptCore 10000 次域名查询：0.034 秒。
- 完整随包编译、JavaScript 执行和 276300 个样本比较合计：2.702 秒。

性能测试会输出 `BENCH` 行。单次请求仅沿主机标签逐层查表，不随全部规则数量线性扫描。真实浏览器端到端加载记录如下；它不代表所有浏览器的内存或缓存行为。

## 本地 HTTP 与 Chrome 集成（已验证）

```sh
PROXY_APPS_SOCKET_TESTS=1 swift test --disable-sandbox --filter PACServerIntegrationTests
PROXY_APPS_PAC_FIXTURES=/tmp/proxy-pac-fixtures-20260922 swift test --disable-sandbox --filter SmartRoutingTests/testFullBundledPACEquivalenceAndExportFixtures
python3 scripts/test-chrome-pac.py /tmp/proxy-pac-fixtures-20260922
```

受限执行环境需要允许绑定回环 socket 和启动测试 Chrome。脚本使用已安装 Chrome 的 headless 命令行，为每例新建并保留临时 profile；只监听 127.0.0.1，测试域名通过进程参数映射至回环，不修改 DNS、系统 PAC、现有浏览器配置或 Quickcat。自动化控制中的默认浏览器不支持设置隔离实例 PAC，所以此处使用独立的项目 CLI 集成夹具。

Chrome 153.0.8010.53：8/8 通过，逐例核对 PAC 被获取、目标请求实际到达直连/代理服务器，以及完整 HTML 的路由标记。包含 smart Google 代理、Baidu 直连、未知域名直连、两种手动反向覆盖、manual 语义和超过 1 MiB 的负对照。真实生产 PAC 仅将代理端口替换为本地测试服务器随机端口。每例约 0.59–1.29 秒。

负对照 1417066 字节：本例 Chrome 无强制 PAC 要求，加载超限脚本后走直连。这证明“返回值不追加 DIRECT”不能保证 PAC 加载失败时也禁止直连。应用已在发布前拒绝超限/执行失败候选，并验证 off 下载超限规则后仍保留旧缓存与配置。

Chrome 在本机返回完整 DOM 后仍可能保留后台进程，因此夹具等待 DOM 完成后只终止本例创建的独立进程组；不以 Chrome 自然退出作为路由断言，也不终止用户已有 Chrome。保留测试输出及所有临时 profile，不自动删除。

PACServer 实际 socket 测试 3/3：368485 字节并发下载内容哈希一致、旧/新 revision 与未知路径、缓存头与内容类型、端口冲突随机回退、碎片请求、过大请求拒绝、客户端断开、慢客户端不阻塞正常请求且有截止时间。不是长期压力或资源耗尽测试。

## 打包自检

构建脚本输出确切 .app 路径。命令行模式只读取包内资源并打印统计，不加载用户配置、不设置系统代理：

```sh
"/绝对路径/ProxyApps-时间戳-进程号.app/Contents/MacOS/LocalProxy" --verify-bundled-rules
```

还应将该 `.app` 整体复制到一个源码目录之外的独立目录，再执行相同自检，确认 `Contents/Resources/LocalProxy_ProxyAppsCore.bundle` 包含 manifest、两份原始规则、许可与归属 README。SwiftPM Bundle.module 只用于开发环境后备，正常 app 优先从主 bundle 的 Resources 查找。

## 用户真实网络验收：以下仍未验证

自动测试不修改开发机真实网络。本地 Chrome 测试只覆盖显式 PAC 参数和 HTTP 夹具，未运行下列 Safari/Chrome 系统 PAC、HTTPS 真实出口或用户网络场景，不能写“通过”。操作前记录系统设置中所有目标网络服务的原自动代理 URL 和开关；不要改 Quickcat 账号、节点、TUN、DNS 或手动 HTTP/SOCKS 系统代理。

1. **Safari 与 Chrome 智能分流**：Quickcat 纯代理入口可连接，首次确认启用 smart；在两个浏览器分别访问自动代理与自动直连目标，结合自己选定的出口查询服务核实出口。只看页面能打开或本地端口开放不足以证明出口。
2. **未知域名直连**：先在检查框确认显示“未知，默认直连”，再浏览并核实出口；输入完整业务 URL 后确认诊断只请求 https 根路径。
3. **手动覆盖**：对自动代理域名添加手动 direct，对自动直连域名添加手动 proxy；重载验证。分别比较 exact/suffix、停用后自动判断、删除后恢复自动规则。主页面与资源域名分别验收。
4. **更新与长连接**：立即更新、查看版本；确认已建立连接可能沿旧路径，新请求是否重新读取新 PAC；分别比较使用系统 PAC 的 Safari/Chrome 和带固定 `--proxy-pac-url` 启动的 Chrome。必要时完全退出重启浏览器。
5. **Quickcat 中断**：保持 smart 启用后暂停 Quickcat，确认 UI 报入口不可用、代理规则保持，匹配代理的网站不因 PAC `; DIRECT` 自动直连；恢复 Quickcat 后复测。
6. **诊断差异**：分别构造直连成功、重复失败且代理 2xx、403/429、证书错误、跳转及 HEAD 不支持的网站；确认建议措辞保守，确认前没有新增规则。
7. **Wi-Fi 切换**：检查进行中切换网络，旧结果应取消/失效；重新检查不得复用旧网络的缓存。路由规则本身不因此自动改变。
8. **外部 PAC 冲突**：启用后由用户修改一个服务的 PAC，编辑规则/恢复时应拒绝覆盖；核对 UI 当前值与原值后，才可用户明确选择强制恢复。
9. **正常退出与异常恢复**：正常退出核实每个服务恢复原值；强制退出后重新打开，必须显示需要恢复，不自动启用 smart；处理恢复后再主动开启。含原 PAC 本已启用、原 URL 为空、中文服务名、Wi-Fi/有线多个服务。
10. **应用三种启动方式**：目标已运行时提示退出，不杀进程；普通启动没有新增代理环境/参数，全代理参数保留，按网站规则启动只含 PAC 参数；非 Chromium 不显示未验证的 PAC 能力。
11. **PAC 服务长期运行**：上述回环 HTTP 功能测试已通过；长时间运行、大量持续并发和耗尽资源的压力场景未验证。
12. **完整 GUI**：本次完成编译，未在桌面逐控件操作/截图验收；特别检查窗口最小宽度下编辑栏、中文确认卡及大列表滚动。

## 手动恢复

首选 App 的“恢复原网络设置”。若 App 无法启动，根据 `~/Library/Application Support/Proxy Apps/pac-restore-state.json` 的 `services`，在系统设置 → 网络 → 对应服务 → 详细信息 → 代理中逐服务恢复自动代理 URL/开关。`ownedPACURLs` 是本工具发布日志，不是应当恢复的原值。

恢复后保留故障文件以排查；不批量删除应用支持目录。系统网络权限不足、命令失败和恢复冲突都会显示错误，不应仅凭界面开关猜测系统状态。

## 本轮交付记录

- 验收包：`/Applications/it/局部代理/dist/ProxyApps-20260922-121726-69837.app`。
- `./scripts/build-app.sh` 内执行 release 构建（`swift build --disable-sandbox -c release --product LocalProxyApp`），通过；本地 ad-hoc 签名验证通过。最后仅调整退出失败提示文案，重新打包，未改变已测逻辑。
- 源码外副本：`/tmp/proxyapps-delivery-20260922-vot3rlqd/ProxyApps.app`；清空环境运行 `--verify-bundled-rules`，规则统计和 PAC 执行/体积检查通过。
- PAC：368485 字节，生产 revision `1e3424ea396bd16a58d8429e0fc66dd11368c3bc5b59635035b69f399a1b77a3`。
- `PROXY_APPS_SOCKET_TESTS=1 swift test --disable-sandbox`：74 项通过，0 失败。Chrome 独立 HTTP 集成：8 项通过。
- `git diff --check`：通过。
- 本地证据：`artifacts/smart-routing-20260922-1217/` 的测试日志、构建日志、Chrome JSON 报告和打包校验 JSON；artifacts 为忽略目录，不包含用户代理配置。
- 保留原有修改、旧构建和临时夹具，无批量删除。未改开发机系统 PAC、DNS、路由或 Quickcat 配置；未覆盖安装旧 App。

验收时先正常退出旧版，若提示恢复冲突先处理恢复；再打开上述新包，确保 Quickcat HTTP 21081 可连接，开启“智能分流”。本轮不以旧包作为验收依据。
