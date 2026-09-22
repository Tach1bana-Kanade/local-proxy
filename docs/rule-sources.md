# 智能分流规则来源

唯一自动规则来源：[Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)。只消费 direct-list.txt 和 proxy-list.txt，不包含广告拒绝列表、GeoIP 或在线分类。

随包 release 提交：`6f3d128827b45e968335e7472737ff59d58902d0`。

- 原始数据地址：`https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/<commit>/direct-list.txt`、同路径 proxy-list.txt。
- 构建环境 raw 域名直连不可达，首次快照通过 GitHub 官方 Git Trees / Git Blobs API 获取：direct blob `31eb2fe21c7b359c969f5f5937f7a62368cb8c07`，proxy blob `942e0d0b7a9d9b70688971e7717b24b1aae6ce24`；均从上述同一 release 提交树解析，没有使用其他规则来源。
- App 更新先通过 `https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/commits/release` 解析提交，再读取固定提交的两份 raw 文件。直连失败且 Quickcat 入口可用时，整次更新明确经 Quickcat 重试，不混合提交或依赖系统 PAC。
- 不使用 GitHub Token。API 限流、下载失败/超时、内容畸形、超限、任一文件缺失都不发布候选快照。

## 格式与统计

实测裸域名为 suffix，`full:` 为 exact；额外支持 `domain:` suffix。规则库可含裸 TLD（例如 `cn`）；手动输入仍要求合法的至少两段域名。注释/空行忽略，regexp/keyword/其他带类型前缀的未支持语义只计数，不执行或误当域名。

| 项目 | 随包数值 |
| --- | ---: |
| direct 文件字节 | 1414688 |
| proxy 文件字节 | 411821 |
| 原始非空条目 | 138428 |
| 归并后直连 | 111169 |
| 归并后代理 | 26981 |
| 未支持 regexp | 159 |
| 同级直连/代理冲突 | 119 |

单文件 20 MiB、单行 4096 字节、合计 500000 个解析条目，均保留需求默认上限。两份文件须分别有有效规则；去重、同级冲突处理与 SHA-256 校验后才可发布。

## 许可与归属

上游仓库附带 GNU GPL version 3 许可，未替换成 MIT 等其他许可。资源目录保留：

- `LICENSE-upstream.txt`：上游原始许可全文。
- `UPSTREAM-README.md`：上游完整归属和数据生成来源说明，包含 domain-list-community、domain-list-custom、dnsmasq-china-list、GFWList 等来源链接；其中广告和 GeoIP 描述属于上游完整项目，App 不消费那些产物。
- `manifest.json`：上游提交、下载时间、原始两份文件 SHA-256、统计与许可/README 的 Git blob 标识。
- 两份未改写的原始域名列表，可复现本项目解析结果。解析器与 PAC 生成代码位于 ProxyAppsCore。

资源随 SwiftPM bundle 和 release .app 分发。校验用于发现传输/缓存损坏，不构成独立签名认证。运行期更新沿用该固定来源与许可说明；不支持添加其他来源。
