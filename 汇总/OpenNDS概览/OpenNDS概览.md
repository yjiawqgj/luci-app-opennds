# 开发提示词：openNDS 概览（仪表盘）插件页面

> 本文是一份自包含的开发任务书。按本文内容可直接开发出「openNDS 概览」LuCI 页面，
> 无需向需求方追加提问。文中所有路径、命名、行为规则均为强制约定。
> 同目录 `OpenNDS概览.html` 是**界面事实源**：界面形态（有哪些控件、按钮、文案怎么写）以它为准；功能行为、数据来源、边界条件、异常处理以本文档为准，演示里的模拟数据不代表真实取值。


---

## 0. 任务总述

为 OpenWrt 上的 openNDS LuCI 插件开发「概览」页面（仪表盘），是完整插件的首页。
功能：展示 openNDS 运行状态、客户端统计、网络接口、无线接入点，以及可交互的
客户端列表（筛选/搜索/排序/详情/编辑/免认证/信任/拉黑等管理操作）。

参考资料：
- openNDS 官方文档：https://opennds.readthedocs.io/en/stable/howitworks.html
- openNDS 默认配置（`OpenNDS.config` / `/etc/config/opennds`）：
  关键项——`maxclients`（默认 250）、`preauthidletimeout`（默认 30 分钟）、
  `authidletimeout`（默认 120 分钟）、`sessiontimeout`（默认 1440 分钟）、
  `uploadrate/downloadrate/uploadquota/downloadquota`（默认 0=不限）、
  `fup_upload_throttle_rate / fup_download_throttle_rate`（公平使用政策限速）、
  `trustedmac` 列表、`preemptivemac` 列表（含 mac/sessiontimeout/uploadrate/
  downloadrate/uploadquota/downloadquota/custom 参数）
- `sh/` 目录下 openNDS 自带脚本：`libopennds.sh`、`get_client_interface.sh`、
  `client_params.sh`、`binauth_log.sh` 等
- openNDS 重启后自动重新认证机制：默认 binauth（`binauth_log.sh`）维护已认证
  客户端数据库，重启时 `auth_restore()` 对剩余会话时间的客户端自动重新认证

**交付物按 LuCI 应用源码结构组织**（`usr/`、`etc/` 装到根文件系统，`htdocs/` 装到 `/www/`），页面文件至少包含：

```
luci-app-opennds-cpd/
├── htdocs/luci-static/resources/view/opennds_cpd/
│   └── overview.js                 # 本页 JS 视图
├── usr/lib/opennds/opennds-cpd-api.sh   # 全插件唯一后端脚本（rpcd file.exec 调用）
├── usr/share/luci/menu.d/luci-app-opennds-cpd.json   # 菜单（整包共用一份）
└── usr/share/rpcd/acl.d/luci-app-opennds-cpd.json    # 权限（整包共用一份）
```

---

## 1. 已确认的技术决策（不要再问，直接采用）

| 决策点 | 结论 |
|---|---|
| LuCI 版本 | 现代 JS LuCI（OpenWrt 21.02+），前端 JS 视图 + rpcd `file.exec` 调后端脚本，后端输出 JSON。后端脚本是全插件共用的 `opennds-cpd-api.sh`，本页调用形式 `opennds-cpd-api.sh overview <子命令>` |
| 持久化策略 | **全部持久化**：编辑限制与「免认证」写 `preemptivemac`、信任写 `trustedmac`（均为 uci opennds 配置，重启后仍生效）、拉黑写 `/etc/config/opennds` 的 `blockedmac` 名单（分发脚本每次请求现读）。**唯一纯运行时的是「解除认证」**（`ndsctl deauth`，本来就不该持久——用户重新登录即可恢复） |
| 拉黑的实现机制 | openNDS **9.4.0（2021-12-08）已废弃** `macmechanism` / `allowedmaclist` / `blockedmaclist`（ChangeLog 原文），10.x 源码里没有 `blockedmaclist`，写进配置不报错但没有任何进程执行它；9.x 的 `ndsctl block` 也只是"内存名单 + 当场插 nft 规则"，重启即失效，10.x 已删掉这条命令。所以持久黑名单由插件自建（`opennds.blockedmac` 名单）+ **分发脚本执行拦截**：命中名单的客户端不出示区域门户、只出示黑名单门户，永远认证不了。拉黑 = ① 写 `zone_blacklist` 名单并 commit；② 从 `trustedmac` / `preemptivemac` 里摘掉该 MAC 并 commit（否则重启后又被自动放行/自动认证，名单形同虚设）；③ `ndsctl untrust` 即时撤掉 nft 里的信任规则、`ndsctl deauth` 踢下线；④ **`/etc/init.d/opennds restart`**，让主进程重新读取 `trustedmac` / `preemptivemac` 并重建 nft 链。此后该客户端回到未认证状态，被 openNDS 自身挡在门外，门户请求由分发脚本识别名单后改为出示黑名单门户（这条只在「区域」模式下成立——切回「全局」时 openNDS 用自带的"点一下就过"页面，名单拦不住，见《客户端黑名单.md》§1）。重启的代价是已认证客户端被 `shutdown_deauth` 踢下线，随后按 `authlog.log` 的剩余时长恢复（见 §3.1 锁定态，倒计时按需要重启的 15 秒起算） |
| 编辑弹窗"应用"的含义 | **保存设置并重启 openNDS**。点"应用"→ 校验 → 持久化写入 → `/etc/init.d/opennds restart`，重启后新限制生效 |
| 数据刷新 | 纯自动轮询（10 秒）刷新列表与状态，**不设手动刷新按钮、不设自动刷新开关**。编辑/详情弹窗打开、整页锁定时暂停轮询，关闭/解锁后立刻补拉一次 |
| 禁用 WIFI 的接入点卡片 | **不显示**。无线接入点卡片只展示启用状态的 WIFI |
| 可信任客户端的编辑 | 完全隐藏"编辑"按钮（不是禁用）；点开详情时各限制项显示"不受限制" |
| 页面顶部运行状态 | 绿点+「运行」/ 红点+「未运行」，右侧一个开关 + 一个【重启】按钮。开关 = 启停 openNDS 服务（写 `enabled` 并 stop/start），**停用前必须二次确认**（停用等于放开全部管控，见 §2.1）；重启 = `/etc/init.d/opennds restart`，等 `run_state` 回到运行再收工 |
| 操作串行化（一次只跑一个） | 任何一个会改状态的操作（免认证 / 可信任 / 解除认证 / 拉黑 / 解除拉黑 / 编辑应用 / 启停 / 重启，含各自的「移除…」反向操作）确认后，**整页进入「处理中」锁定态**：遮罩 + 固定文案「正在应用…」+ 倒计时，页面所有可点元素（按钮、开关、统计卡、表格行内操作、弹窗提交）全部禁用，**上一个没结束前不允许发起任何新操作**。解锁只看接口返回，不看倒计时（§3 末尾） |

---

## 2. 页面区块与逻辑（版式参考演示，行为按本文档）

页面从上到下：**标题行 + 五个区块**。标题为「openNDS 概览」，**标题行只有标题，右侧不放任何控件**；
区块间有分隔线，最大宽度 1100px 居中，左右内边距 22px。

### 2.1 运行状态

- 一行控件：状态点 + 状态文字（绿点「运行」/ 红点「未运行」）+ 开关 + 【重启】
  （重启按钮带一个环形箭头图标，执行中文字变「重启中…」并禁用）。
- 判定：后端执行 `/etc/init.d/opennds status` 或 `ndsctl status`，**以 `ndsctl status`
  能否成功返回为准**（进程在跑但 socket 没起来，服务等于不可用）。开关的 `aria-checked`
  与状态文字同源，不各算各的。
- 开关 = 启停服务：
  - 开 → `uci set opennds.@opennds[0].enabled='1'` + commit → `/etc/init.d/opennds start`；
  - 关 → **先弹二次确认**（文案见下）→ `enabled='0'` + commit → `/etc/init.d/opennds stop`。
  - 两个动作都必须同时写 `enabled` 和启停进程：只写 uci 不 stop，会出现"界面显示已停用、
    进程还在跑"；只 stop 不写 uci，重启路由器又自己起来了。
  - 停用确认文案：「停用后 openNDS 立即退出：门户页面消失，免认证、可信任、黑名单、
    限速全部失效，所有设备将直接上网。确定停用？」
  - 启用不需要确认。
- 停用到底发生了什么（`src/main.c` 的 `termination_handler()`，按源码实际顺序）：
  1. （`fas_secure_enabled` 为 3 / 4 时）先 `kill` 掉 `authmon.sh`；
  2. `dnsconfig.sh revert` —— `uci revert dhcp`，把之前塞进去的
     `dhcp_option_force='114,http://<gatewayfqdn>'`（CPD 的 114 选项）撤掉；
  3. 删掉 `walledgarden`、`blocklist` 两个 nft 集；
  4. `dnsconfig.sh restart_only` 重启一次 dnsmasq，让撤销生效；
  5. `auth_client_deauth_all()` —— 遍历客户端表，逐个 `auth_change_state(…, FW_MARK_PREAUTHENTICATED,
     "shutdown_deauth", …)`，给每个掉线的已认证客户端记一条 `shutdown_deauth`。
     **这一步在清规则之前**（顺序要紧：`auth_restore` 后面靠的就是这条记录）；
     可信任客户端（`Trusted`）这一步会被状态机拒绝、不写记录——它本来靠 `trustedmac` 在启动时重建，不需要恢复；
  6. `iptables_fw_destroy()` 清空 openNDS 自己的 nft 规则，然后退出。
  所以**停用期间没有任何管控**：未认证的、被拉黑的设备都能直接上网；门户分发脚本也不会
  被调用（它由 openNDS 拉起来），黑名单门户同样失效。这条必须写进确认框，不能含糊。
- 启用 / 重启后会话怎么恢复：openNDS 启动时会调 `libopennds.sh auth_restore`
  （`/etc/config/opennds` 注释：重启后"automatically achieved by a call to the
  auth_restore() library function"）。它读 `authlog.log` 里还挂着的会话，再查 `binauthlog.log`
  中该 MAC 的**最后一条**记录：这条记录里**不含 `deauth`**（认证过、之后没被登出）或者
  是 `shutdown_deauth`（上一次重启踢的），就重新投进预认证队列；只有真正的 `deauth`
  记录（手动登出 / 超时 / 超配额）才不恢复。另外**`preemptivemac` 名单里的客户端会被
  跳过**，由下一个 `checkinterval`（默认 15 秒）的 `preemptivemac` 重新投递，最多
  15 秒空窗。
  这条恢复通道**与 `allow_preemptive_authentication` 无关**：`fw_refresh_client_list()`
  每轮都无条件执行 `libopennds.sh preemptivemac` 并把
  `$mountpoint/ndscids/preemptive_auth/` 里的记录取空（`get_next_preemptive_auth`
  一次读一条、读一条删一条，队列空时退出码为 1，主进程循环调到空为止），`client_auth()` 只要 MAC 在客户端列表里就直接认证。那个开关只作用于
  "客户端还不在客户端列表里、按 MAC 补授权"这一条路径（源码里是
  `if (!id && config->allow_preemptive_authentication == 1)`），所以关掉它不会让重启后的
  客户端集体掉在未认证，只是**还没产生过流量、不在 `ip neigh` 里的设备**要等自己发一次
  请求才会被放行。本页不读这个开关，也不因此改任何计数。
- 启停与重启的横幅：启停成功「openNDS 已启动」/「openNDS 已停止」、重启成功「openNDS 已重启」都用 **3 秒自动消失**的横幅（不需要用户点叉）；「正在重启 openNDS…」这条**不再显示**（按钮自身的「重启中…」态已经足够）。失败/未生效的报错横幅不自动消失。
- 重启按钮：后端同步执行 `/etc/init.d/opennds restart`，**返回 0 只代表脚本跑完**，
  前端要继续轮询 `run_state`，直到进程真的起来（最多 20 秒）；超时提示
  「openNDS 未能在 20 秒内就绪，请查看 openNDS 日志」（日志目录由 `libopennds.sh` 的
  `configure_log_location()` 现探，默认 `/tmp/ndslog/ndslog.log`，设了 `option log_mountpoint`
  就在那个目录下——所以提示里不要把这个路径写死成唯一可能）。执行期间开关和重启
  按钮都禁用，避免连点。
- 未运行时：在线/已认证/免认证/可信任/未认证五张卡归零，黑名单卡仍按名单显示条数
  （名单还在，只是不生效）、最大客户端仍按配置显示；列表清空并显示"暂无符合条件的
  客户端"、行内按钮全部禁用；接入点计数为 0；网络接口卡片的"当前管理状态"改为"未管理"。
  **必须真的清空**，不能沿用上一轮旧数据——停用后 `ndsctl json` 是直接失败的。

### 2.2 客户端统计（同时是列表筛选器）

7 张卡片，分类判定逻辑：

| 卡片 | 判定 |
|---|---|
| 在线客户端 | **当前真的连着的、有访问权限的设备** = `ndsctl json` 里 `state` 为 `Trusted` / `Authenticated` / `AuthBlocked` 的条目（剔除 `blockedmac` 名单内的）；`Preauthenticated`（未认证）**不算在线**，单独一类计数。统计卡片与客户端列表同源（`online` / `authorized` 标记），不会出现卡片数与列表对不上 |
| 已认证客户端 | `state` 为 `Authenticated`，或 `AuthBlocked`（超流量配额被 FUP 限流、身份仍是已认证），且不在 `trustedmac`、也不在 `preemptivemac` 名单内（普通登录用户） |
| 免认证客户端 | **在 `preemptivemac` 名单内、且 `state` 是 `Authenticated` / `AuthBlocked`**（预认证真的登录成功了）。名单内但在线仍是 `Preauthenticated` 的（刚加名单还没到下一轮、没有 DHCP 租约）**不算免认证**，落到未认证——宁可卡片上显示"没生效"，也不要显示成功。openNDS 的 `client_type` 字段**不能**用来判定——它只在"客户端还没进客户端列表、由预认证流程新建条目"时才是 `preemptive`，正常运行时先被 15 秒扫描收进列表的客户端一律是 `cpd_can`。离线设备靠名单补行、只补行不计数。**判定只看 `state` 和名单，不读任何开关值**：`allow_preemptive_authentication` 是豁免页自己的开关，本页不读、不写、不因它改计数 |
| 可信任客户端 | `state == "Trusted"`——openNDS 为 `trustedmac` 里的客户端单独维护的状态，它们**确实在 `clients` 里**，只是状态不是 `Authenticated`。离线设备靠 `trustedmac` 名单（或 json 顶层的 `trusted` 数组）补行 |
| 未认证客户端 | **前面几类都没接走的在线客户端**（实际就是 `state == "Preauthenticated"` 的）。这一类是兜底，不要再拿名单做排除条件，否则"名单里有、但没登录成功"的设备会从所有卡片里消失，四类相加对不上在线数 |
| 黑名单 | **以 `opennds.blockedmac` 名单为准**（不是 ndsctl 状态）。名单内 MAC 无论当前是否在线都计数 |
| 最大客户端 | 静态卡片，取 `uci get opennds.@opennds[0].maxclients`（默认 250） |

点击前 6 张卡片 = 切换列表筛选并滚动到列表；"最大客户端"为静态卡不可点击。
选中卡片高亮（蓝色边框/浅蓝底），按钮带 `aria-pressed` 反映选中态。
点统计卡时**要顺手清掉接入点筛选**（否则会出现"统计选了已认证、列表还被某个 AP 卡着"
的怪状态），但**当前排序保留**，不重置。

> **分类按固定顺序切，切完自然互斥**：① 黑名单（插件名单，openNDS 不知道，优先于一切，
> 命中即从"在线"里剔除）；② 可信任（`state="Trusted"`）；③ 免认证（在 `preemptivemac`
> 名单内**且已登录**，即 `state` 是 `Authenticated` / `AuthBlocked`）；④ 已认证（`state`
> 为 `Authenticated` 或 `AuthBlocked`，且不在前两类）；⑤ 剩下一律算未认证。
> 按这个顺序 `if / else if` 一路切，一个 MAC 只会落进一个桶，
> 不需要额外去重。拉黑时后端会主动把它从 `trustedmac` / `preemptivemac` 摘掉（见 §3），
> 那只是防御性约定。

> 注意 ③ 和 ④ 的 `state` 条件有重叠，靠顺序保证互斥：名单内的客户端即使 `state` 是
> `Authenticated`，也归 ③ 免认证；没登录成功的（`Preauthenticated`）归 ⑤ 未认证。
> 这样"名单里有、但没生效"的设备会明明白白显示在未认证里，而不是被当成免认证藏起来。

> **"在线"和这几类的关系**：可信任、已认证、未认证三种身份直接来自 `ndsctl json` 的
> `state`，免认证来自 `preemptivemac` 名单 + 已登录判定，都是在**同一份 `clients`**（json 里是以
> MAC 为键的**对象**，不是数组——遍历时取值、不要按下标）上
> 切出的四个互斥子集，所以必须满足
> `在线 = 已认证 + 未认证 + 免认证 + 可信任`。加起来不相等就是分类写错了，不是数据问题。
> 唯一的例外是**列表**：可信任 / 免认证 / 黑名单三张名单会额外补出"已离线"的行
> （见本节末尾），这些补出来的行**不计入「在线」**，只在列表里显示、IP 与接入点留"—"。

> **`ndsctl json` 的真实结构**（源码 `src/util.c` 的 `ndsctl_json_all()` /
> `ndsctl_json_client()`；这层结构 9.x 与 10.x 完全一致，两份 `util*.c` 里
> `ndsctl_json_client()` 打印的键逐个对得上，版本差异只在 nft 表族与规则管理，见
> 《整包集成与打包.md》§1）：
>
> ```
> {
>   "client_list_length": "3",
>   "clients": {
>     "AA:BB:CC:DD:EE:FF": {
>        "gatewayname": "...", "gatewayaddress": "...", "gatewayfqdn": "...",
>        "version": "...", "client_type": "preemptive" | "cpd_can",
>        "mac": "...", "ip": "...", "clientif": "...",
>        "session_start": "...", "session_end": "null" 或时间戳,
>        "last_active": "...", "token": "...",
>        "state": "Preauthenticated" | "Authenticated" | "AuthBlocked" | "Trusted",
>        "custom": "…", "upload_rate_limit_threshold": ..., ... 固定 26 个键（`custom` 没有自定义串时是 `"none"`）
>     },
>     ...
>   },
>   "trusted_list_length": "1",
>   "trusted": [ "AA:BB:CC:DD:EE:FF" ]
> }
> ```
>
> - `state` 只有四个值：`Preauthenticated`（未认证）、`Authenticated`（已认证）、
>   `AuthBlocked`（超出流量配额、被 FUP 限流，身份仍是已认证）、`Trusted`（可信任）。
>   **可信任客户端就在 `clients` 里，状态是 `Trusted`**，不是被排除在列表外。
> - `client_type` 只有两种值：`preemptive` 或 `cpd_can`（字段为空时源码默认输出这个）。
>   **但它是不可靠的**：`src/auth.c` 里只有「客户端还没进 client list、由预认证流程
>   新建条目」这一条分支才会打 `preemptive`；正常运行中先被 `fw_refresh_client_list()`
>   每 15 秒扫描收进列表的客户端，一律拿不到这个标记。所以**免认证身份必须靠
>   `preemptivemac` 名单判定**，不要用这个字段。
> - 顶层 `trusted` 数组是**配置里 `trustedmac` 的全家，包含已离线的 MAC**。
>   要判断"在不在线"，看 `clients` 里有没有、`state` 是不是 `Trusted`；
>   顶层数组只用来补"配了但当前不在线"的行。
> - ⚠️ **`trusted_list_length` / `trusted` 这两个键只在配置里有 `trustedmac` 时才输出**：
>   源码是 `if (config->trustedmaclist != NULL)` 才打印它们，名单为空时 json 里**根本没有这两个键**
>   （`client_list_length` / `clients` 一定有）。所以解析时不能假定它们存在，取到空/缺键就按
>   空数组处理，别让后端解析在这里崩掉，也别把"没有键"当成"offline 名单有一堆行"。
> - 每个客户端固定 **26 个键**（`src/util.c` 的 `ndsctl_json_client()` 逐条 `fprintf` 出来的）：`gatewayname / gatewayaddress / gatewayfqdn / version / client_type / mac / ip /
>   clientif / session_start / session_end / last_active / token / state / custom /
>   download_rate_limit_threshold / download_packet_rate / download_bucket_size /
>   upload_rate_limit_threshold / upload_packet_rate / upload_bucket_size /
>   download_quota / upload_quota / download_this_session / download_session_avg /
>   upload_this_session / upload_session_avg`。
>   `custom` 也**一定在**：没有自定义串时值是字符串 `"none"`（不是空、也不是缺键）；值真正为空只可能出现在老版本或裁剪过的构建里，解析时把 `"none"` 当"无自定义串"处理即可。
> - **只有 `blocked` 在 json 里没有**，它来自插件读的 `/etc/config/opennds` 的 `blockedmac` 名单。
>   前端需要的 `authenticated / preauth / trusted / blocked` 四个布尔由后端换算，
>   前端不解析 openNDS 内部状态。

**这三类视图的行 = `ndsctl` 里的在线条目 ∪ 名单里的条目**：
先取 `clients` 里 `state=="Trusted"` 的（可信任，在线），以及 `preemptivemac` 名单里
当前在 `clients` 中出现的（免认证，在线），再用两份名单补上没出现的行（即为离线行）；
黑名单只来自 `opennds.blockedmac` 名单。离线行 IP/主机名/接入点显示"—"，状态标签照旧。
理由：名单是持久的，客户端离线后如果从列表里消失，用户就再也找不到、没法撤销了。

### 2.3 网络接口

信息卡：接口名（大字 mono 字体，如 `br-lan`）、IP 地址、当前管理状态
（"正在管理"）。数据来源与区域识别页一致：先 uci 配置，取不到则
`ndsctl status` 提取 `Managed interface:`。⚠️ 这一行有两种格式——
`Managed interface: br-lan` 和 `Managed interface: br-lan - IP address range: 192.168.1.0/24`
（`util.c:987-989` 按有没有 `gw_iprange` 分别打印），所以只取冒号后到**第一个空格**为止的
那段，别把整行剩余部分当接口名（否则接口名会变成 `br-lan - IP address range: …`，
后面所有按接口名的比较、`ip addr show` 全对不上）。

### 2.4 无线接入点

- 卡片来自无线列表（`uci show wireless`），**只显示启用状态的 WIFI**
  （disabled='1' 的不显示，无重名特殊处理需求）。
- 每张卡片：SSID（小字）+ 该接入点下未拉黑客户端数（大字）+ "已连接客户端"标签。计数来源是 **hostapd 的关联终端**（`ubus call hostapd.<接口名> get_clients` 按 MAC 数，剔除黑名单）——openNDS 的 `clientif` 来自 `get_client_interface.sh`，机器没装 iw 时是 `br-lan` 这类网桥名，对不上 `phyN-apM`，按它数永远是 0（"有客户端连接但卡片全 0"的根因）。
- 接口→SSID 反查与区域识别页**共用同一份实现**，顺序也一样：先用 `iw dev <接口> info` 里的
  `ssid` 行直读（免疫 `phyN-apM` 编号变化），读不到才回退 `phyN-apM` → radioN 第 M 个 AP section。
  **不要**自己再写一套序号映射——序号法在"中间某个 AP 被禁用"时会取到相邻 SSID。
- 点击卡片 = 按接入点筛选客户端列表（同时把统计筛选重置回"在线"），并平滑滚动
  到客户端列表；再次点击同一卡片取消筛选。
- 接入点列的显示规则（与演示的 `apName()` 一致）：后端给的是**真实接口名**（`phy2-ap1` / `br-lan`），前端再用 AP 列表把接口名映射成 SSID 显示；接口名等于**当前管理接口**（uci `gatewayinterface`，取不到用 `ndsctl status` 的 `Managed interface:`）的显示 `<接口名>（有线）`——**不要写死 `br-lan`**，管理接口能在「openNDS 设置」页换；既不在无线列表里、也不是当前管理接口的，原样显示接口名。按接入点筛选时也是拿接口名比，不是拿 SSID 比。

### 2.5 客户端列表

- 标题随筛选变化（在线客户端/已认证客户端/未认证客户端/免认证客户端/
  可信任客户端/黑名单），右侧"共 N 个"+（若按接入点筛选）"· 接入点 X"。
- 搜索框：`type="search"`（用浏览器自带的清除按钮，不自己画 ×），
  占位符「搜索主机名、IP 地址或 MAC 地址」；按主机名/IP/MAC 模糊匹配，匹配前做归一化（转小写、去掉
  字母数字和中文以外的字符），三种字段任一命中即显示。
- 列：主机名（下方状态标签）/IP 地址/MAC 地址/接入点/操作。
  - 状态标签规则：一个客户端只挂一个标签，**顺序和 §2.2 的分类顺序完全一致**：
    黑名单 → 「拉黑」（标签文字照演示，就两个字；详情弹窗里那一行才写「已拉黑 / 未拉黑」）；
    `state="Trusted"` → 「可信任」；
    **在 `preemptivemac` 名单内且 `state` 是 `Authenticated`/`AuthBlocked`** → 「免认证」；
    `state` 为 `Authenticated` 或 `AuthBlocked` → 「已认证」（`AuthBlocked` 只是被 FUP
    限了速，身份仍是已认证，**不另设标签**——照演示，列表里只有这五个词）；
    `state="Preauthenticated"` → 「未认证」。名单里但还没登录成功的一律挂「未认证」，
    和卡片计数保持同一套判断，别让标签说"免认证"、卡片说"未认证"。
- 排序：四列表头可点击排序，**只有升序/降序两态来回切换**（再点同一列反向，
  不做"取消排序"的第三态），箭头 ↑/↓ 指示当前方向，`th` 同步 `aria-sort`。
  IP 列按数值排序（按点分段转数值）；其余按 zh-CN locale 字符串比较。
- **进入页面默认不排序**，按后端返回的顺序显示；排序、搜索、筛选三者可叠加
  （先按筛选/接入点取子集 → 再按搜索词过滤 → 最后排序）。
- 空结果时表格显示一行 `暂无符合条件的客户端`，跨全部 5 列居中，不要留一张空表。
- **黑名单视图的数据源不同**：列表来自 `opennds.blockedmac` 名单本身，而不是
  `ndsctl json`。名单里当前不在线的 MAC 照样显示一行，IP 地址与主机名显示
  为"—"、接入点显示"—"、状态标签显示"黑名单"；这类行只保留"解除拉黑"可用，
  其余按钮全部禁用。这样用户拉黑后随时能在本页看到并撤销，不会因为客户端
  被踢下线就"消失得找不到"。

---

## 3. 行内操作规则（最多 6 个按钮，按状态增减）

按钮可用性规则（逐条按下面实现；按钮的集合、次序与文字照演示，**禁用规则以本表为准**）：

| 按钮 | 可用性 | 说明 |
|---|---|---|
| 详情 | 未认证视图、黑名单视图下禁用 | 打开详情弹窗（§5） |
| 免认证 / 移除免认证 | **始终可点，不置灰**（两个例外：可信任客户端见本节末尾的整行特例；**黑名单视图下置灰**，理由见本节末尾的黑名单说明）。尚未免认证 → 按钮文字「免认证」；已免认证 → 文字变「移除免认证」，点它就是撤销 | 免认证 = 无需认证流程即获访问，但仍计流量、受限额。**前提：该客户端必须在 DHCP 租约里**——`preemptivemac()` 先做 `dhcp_check`，租约文件里 `grep -w` 查不到就 `continue`，静态 IP / 无租约的设备点了也不会生效，后端此时要回 warn 提示而不是报成功。**这条前提只用来判断"能不能生效"并决定回 ok 还是 warn**，本页仍然不写、不读、不展示 `allow_preemptive_authentication`（它是「客户端豁免管理」页的独立开关），也不因它改按钮状态与计数 |
| 可信任客户端 / 移除可信任 | **始终可点，不置灰**（例外同上一行：可信任客户端整行特例、**黑名单视图下置灰**）。未信任 → 「可信任客户端」；已信任 → 「移除可信任」。设信任时后端要**顺手清掉该客户端的免认证身份**（可信任优先级更高） | 信任 = 免认证流程且不计流量、不受超时限额 |
| 解除认证 | 未认证且未免认证的禁用；**可信任客户端也置灰**（openNDS 状态机拒绝把 `Trusted` 改成任何其它状态，`auth_change_state()` 直接 `return -1`，`ndsctl deauth` 只会回 `No`） | 解除后需重新认证。**对已免认证的客户端点它 = 移除免认证 + 踢下线**：后端必须同时删掉 `preemptivemac` 条目，只发 `ndsctl deauth` 的话客户端会被自动重新认证，用户看到的是"点了没反应" |
| 编辑 | trusted 客户端**不渲染此按钮**；未认证视图、黑名单视图下禁用 | 打开编辑弹窗（§4） |
| 拉黑 / 解除拉黑 | 始终可用；在黑名单视图下变"解除拉黑"且为普通样式 | 拉黑 = 立即断开并从在线列表移除 |

> **可信任客户端是整行的特例**：它在 `clients` 里（`state="Trusted"`），但 openNDS
> 的状态机明确拒绝把它改成任何其它状态（`src/auth.c` 的 `auth_change_state()` 对
> `TRUSTED → *` 一律 `return -1`），所以 `deauth` 对它必然失败；它的流量不计账、
> 配额与超时都不适用，写 `preemptivemac` 也改不了它的身份。所以这一行
> **只保留【详情】【移除可信任】【拉黑】三个可用按钮**，【编辑】【免认证】不渲染，
> 【解除认证】置灰。

> **黑名单视图下【免认证】【可信任】也要置灰**：这两个按钮写的是 `preemptivemac` /
> `trustedmac`，而拉黑的第一步就是把这台设备从这两份名单里摘掉（§3 的拉黑流程、以及
> 《客户端黑名单.md》决策 #2）——再点一次等于给黑名单客户端重开"自动登录"通道
> （`preemptivemac()` 下一轮就把它投进预认证队列，它照样能上网），黑名单立刻失效。
> 所以黑名单视图里这两列一律置灰，只留【解除拉黑】可用（离线行同理，见 §2.5）；
> 后端 `client_action` 的 `preauth` / `trust` 也要自查：目标 MAC 在黑名单里就
> 直接返回 `{"ok":0,"error":"该客户端在黑名单中，请先解除拉黑"}`，不写任何配置。

**所有状态变更类操作（免认证 / 移除免认证 / 可信任 / 移除可信任 / 解除认证 / 拉黑 /
解除拉黑）必须先弹二次确认框**，
确认框文案照抄演示页（标题、正文、确认按钮文字，拉黑为红色危险按钮）。
操作成功/失败用 toast 反馈（**右下角**固定堆叠，3 秒消失，白底左侧 3px 色条，
ok 绿 / warn 琥珀 / err 红，与插件其它页面一致）。

> **停用服务也算状态变更**：它一次性放开所有客户端（见 §2.1），所以开关从"开"拨到
> "关"必须先弹确认框，文案照 §2.1；从"关"拨到"开"不确认。别因为它是开关就跳过确认。

### 3.1 处理中锁定态：一次只允许一个操作

所有会改状态的操作（免认证 / 移除免认证 / 可信任 / 移除可信任 / 解除认证 / 拉黑 /
解除拉黑 / 编辑弹窗「应用」/ 启停开关 / 【重启】）确认之后，**整页立刻进入锁定态**，直到这次
请求真正返回为止。规则：

1. **遮罩**：`position:fixed; inset:0`，半透明底色（`rgba(0,0,0,.28)`），拦截全部
   指针事件（含键盘 Tab 焦点）。遮罩中央一张小卡片，固定显示：
   - 主文案：**`正在应用…`**——全局统一这一句，**不显示具体操作名，不显示客户端名**。
     拉黑也好、免认证也好、重启也好，都是这一句。
   - 副文案：倒计时 `预计还需 N 秒`（示例 `预计还需 12 秒`——N 从 §3.1 末尾那张表的
     起始值往下数，别把它当成固定文案）
   - 一行小字：`请勿关闭或刷新页面`
2. **锁的是整页，不是几个按钮**：行内按钮、统计卡片筛选、页头开关与【重启】、
   编辑/详情弹窗的提交，全部不可交互。**不允许**
   靠"把按钮置灰"实现——置灰只挡住看得见的那几个，键盘和遮罩外的点击照样能触发。
3. **倒计时只是给用户看的预计时间，不决定解锁**：
   | 操作类型 | 倒计时起始值 |
   |---|---|
   | 需要重启的（编辑「应用」、启停、重启、**拉黑**） | 15 秒 |
   | 不需要重启的（免认证、移除免认证、可信任、移除可信任、解除认证、**解除拉黑**） | 5 秒 |

   数到 0 而接口仍未返回 → 倒计时那行停在 `0 秒`（或直接隐去），**主文案始终是
   `正在应用…` 不变**，继续锁着，**不重发请求、不放开按钮、不换文案**。
4. **解锁只有一个条件：接口返回**（成功或失败都算）。成功则撤遮罩、toast 结果、
   恢复交互、立刻拉一次 `status` 和 `run_state` 校正显示；失败也一样撤遮罩（否则
   用户永远出不来），toast 报错、恢复交互，由用户重试。
5. 锁定期间，10 秒自动轮询暂停；唯一允许的后台请求是 `run_state`
   （重启后判断进程是否真的起来了，1 秒一次）。
6. 锁定态用一个全局标志（如 `ui.busy = {startedAt, timer}`）挡住所有入口，
   而不是在每个按钮的处理函数里各写一遍判断——漏一个就是并发。
7. **遮罩只管本页**。用户开两个标签页时（本页正在拉黑、另一个标签页在 WalledGarden 点应用），
   遮罩拦不住。跨页互斥由后端统一抢锁实现（《整包集成与打包.md》§11.3）：所有写操作
   入口先按该节的模板取锁（`exec 9>/var/lock/opennds-cpd.lock` + `flock -n 9`），抢不到直接返回 `{"ok":0,"busy":1}`，
   本页收到后**不进入遮罩**，只 toast（warn）「等待上一步完成，请稍候重试」；
   `status` 返回 `busy:1` 时页头挂一条同样的提示条。
   顺序固定：**先抢锁 → 再写配置**。本页**不做**《整包集成与打包.md》§11.1 那套 `confirm_enable` 确认——
   本页的启停开关就是唯一的停用入口，停用态下列表已清空、行内按钮全部禁用、编辑弹窗打不开，
   没有"停用态下还能写进配置"的路径（《整包集成与打包.md》§11.1 的适用范围表也把本页列为不适用）。抢到锁后照旧读一次
   `enabled`，但那只是给启停开关显示真实状态用，不参与"要不要继续写"的判断。

> **为什么必须这样**：`/etc/init.d/opennds` 是 procd 脚本，`restart` = stop + start，
> `term_timeout 90`，且 `service_stopped()` 里要轮询 `pidof opennds` **最多 10 秒**
> 才执行 `delete_chains`。所以一次 apply 持续 10 秒上下是正常的。这期间如果又发起
> 一次 restart，两个序列交错：后起的进程刚把 nft 链建好，前一个的 `service_stopped`
> 醒来 `delete_chains` 把它删掉——门户放行规则整片消失，直到下一次重启才回来。

### 3.2 每个操作对应的 openNDS 机制

操作与 openNDS 的对应（后端实现约定）：

| 操作 | openNDS 机制 |
|---|---|
| 免认证 | uci `preemptivemac` 列表追加一条**参数写全的**条目（`sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0`，五个 0 都表示"跟随全局"，见本节末尾"0 的真实含义"）→ commit → **紧接着主动执行一次 `/usr/lib/opennds/libopennds.sh preemptivemac`（不带参数）**。**不需要重启**，但**不能只 commit 就完事**：主进程每轮调的是 `preemptivemac quiet`，而随包的 10.x `libopennds.sh` 只判 `[ -z "$1" ]`，`quiet` 会被当成一个 MAC 名处理（11.0.0 的 ChangeLog 才修：`Preemptivemac not taking config values`），名单根本不会被重读。不带参数调一次 = 现读 `preemptivemac` 列表、把在线的客户端逐个投进预认证队列，下一轮扫描即自动登录。**不要在这里碰 `allow_preemptive_authentication`**——那是豁免页的开关，本页只写名单 |
| 移除免认证 | uci `preemptivemac` 移除该 MAC 对应的整条 → commit → **删掉该 MAC 的预认证队列文件** → `ndsctl deauth` 踢下线。**不需要重启**；但 deauth 与清队列都不能省——客户端已经在 `binauthlog` 里留下认证记录，只删配置它不会自己掉线；队列文件是上一轮 `preemptivemac` 已经投进去的，`get_next_preemptive_auth` 不看名单现况，下一轮照样会把它认证回来 |
| 解除认证 | `ndsctl deauth`（纯运行时，不写配置）；**若该 MAC 在 `preemptivemac` 名单内，同时删条目并删队列文件**，否则下一轮预认证又把它放进来 |
| 可信任 | `ndsctl trust <mac>`（立即改内存名单，并往 nft 的 `ndsTRU` 链里插一条按 MAC 放行的规则，**即时生效、不用重启**）+ uci `trustedmac` 追加（只为重启后还在）+ **同时删掉 `preemptivemac` 里该 MAC 的整条**（两份名单必须互斥，见《整包集成与打包.md》§11.2 第 6 条；不删的话它还悄悄留在免认证名单里，以后一取消信任就立刻变回「免认证」，用户会以为信任没撤干净）。预认证队列里那条残留可以不管——`client_auth()` 只在客户端处于 `Preauthenticated` 时才认证，`Trusted` 的直接跳过 |
| 移除可信任 | `ndsctl untrust <mac>`（立即删掉那条 nft 规则，**即时生效、不用重启**）+ uci `trustedmac` 移除 |
| 拉黑 | ① **读当前** `opennds.blockedmac` 名单 → 追加该 MAC（**存小写**，与黑名单页同一口径，见《整包集成与打包.md》§11.4）→ 写回 commit（**只加这一个，不许整体重写**，否则会冲掉黑名单页刚加的）；② uci 摘除 `trustedmac` / `preemptivemac` 条目并 commit（按 MAC 删整条，不看条目原文）；③ `ndsctl untrust` 撤掉信任规则、**删掉该 MAC 的预认证队列文件**、`ndsctl deauth` 踢下线；④ `/etc/init.d/opennds restart`，让主进程重读两份名单并重建 nft 链；后端按《整包集成与打包.md》§11.1 的判据等就绪（`pidof opennds` 有值 **且** `ndsctl status` 能成功，最多 15 秒）再返回，前端在这期间一直锁着。**全站已认证客户端会短暂断线**，按 `authlog.log` 恢复 |
| 解除拉黑 | **读当前** `opennds.blockedmac` 名单 → **按 MAC 删这一条** → commit（其它条目不动）。客户端下一次请求门户时恢复正常区域门户，需重新认证 |

> **凡是把 MAC 从 `preemptivemac` 摘掉、而它仍可能处于未认证状态的操作（移除免认证、解除认证、拉黑），都要顺手删掉
> 它的预认证队列文件**：`<mountpoint>/ndscids/preemptive_auth/<MAC去冒号>`（`mountpoint` 由
> `libopennds.sh` 的 `configure_log_location()` 现探：在 `/tmp`、`/run`、`/var` 里取第一个
> 挂成 tmpfs 的目录，都探不到就退回 `/tmp`——**不是配置项**，`option log_mountpoint`
> 只改日志目录、不改这条路径）。`preemptivemac()` 只往里写、从不清理，
> `get_next_preemptive_auth` 又是「读一个删一个」且**不核对名单现况**——所以摘配置前已经
> 投进去的那条，下一轮照样会把客户端认证回来，用户看到的是"点了移除，还在线"。
> 队列文件名的大小写取决于当时是谁投进去的（`preemptivemac` 用小写，`auth_restore` 用
> 客户端表里的原始大小写），所以**小写和大写各删一次，删不到不算错**。

> **什么时候才需要重启**（按源码判断，别一刀切）：
> - **改已有客户端的限额参数**（编辑弹窗）→ **需要重启**。`preemptivemac` 的条目只在
>   客户端还没认证时投进预认证队列；一个 `state=Authenticated` 的会话不会因为配置变了
>   就重新读参数。
> - **增删 `preemptivemac` / `trustedmac` 条目** → **不需要**。`trustedmac` 靠 `ndsctl trust/untrust` 当场改 nft 规则；`preemptivemac` 靠**自己调一次不带参数的 `libopennds.sh preemptivemac`** 立刻投递（主进程那轮 `preemptivemac quiet` 在 10.x 脚本里不解析名单，别指望它）。
> - **拉黑** → **需要**（要摘 `trustedmac` / `preemptivemac` 并让主进程按新名单重建 nft 链，见上表）。
> - **解除拉黑** → **不需要**（分发脚本每次请求都现读 `zone_blacklist`，删掉名单条目立刻生效）。
> - **改 `gatewayinterface`、FUP 限速速率、全局超时** → **需要**（nft 规则按接口名建，
>   速率在启动时读入内存）。

> **`ndsctl` 的子命令随版本不同**：10.x 是 `status` / `json` / `stop` / `auth` / `deauth` /
> `trust` / `untrust` / `debuglevel` / `b64encode` / `b64decode`（`b64*` 两个由客户端本地
> 算，不发给守护进程）；9.x 还多 `block` / `unblock` / `allow` / `unallow`。
> 但 9.x 的 `block` **不是持久黑名单**：`auth_client_block()` 只往进程内存里那份 blocked
> 名单加一条、再当场插一条 nft 规则，重启即失效，也不会让分发脚本改出示黑名单门户；
> 而且这些 MAC 不会出现在 `ndsctl json` 的固定字段里。openNDS 配置里同样没有按 MAC 的
> 黑名单项（只有 FQDN/端口维度的 `blocklist_fqdn_list`，且只对已认证用户生效）。
> 所以拉黑必须按上表由插件自建，**不要用 `ndsctl block` 顶替 `zone_blacklist`**。
>
> **「免认证」为什么写 `preemptivemac` 而不是 `ndsctl auth`**：`ndsctl auth` 只是
> 替客户端登录一次，重启就没了，而且在 `ndsctl json` 里它跟普通登录用户一模一样——
> 都是 `state="Authenticated"`、`client_type="cpd_can"`，完全分不出来。`preemptivemac`
> 是 openNDS 官方的 Pre-emptive Clients：接入即自动登录、不弹门户，流量照计、配额与超时
> 照管，而且**有一份持久名单可用于判定身份**——跟演示里"免认证"的定义逐字对应。
>
> **写 `preemptivemac` 必须把 6 个参数写全**。openNDS 的 `preemptivemac()` 用
> `eval` 逐条解析，循环里只重置 `mac`，其余五个变量**不重置**——所以**省略**的字段
> 不会按"0 = 用全局"处理，而是**继承上一条客户端留下的值**（第一条才是函数开头
> 从全局配置读进来的默认值）。少写一个字段，这条客户端就会莫名其妙套上别人的
> 限速或会话时长。
>
> **「0」的真实含义：0 就是"用全局/默认值"，五个参数都成立**（配置注释原话："List parameters set
> to 0 or omitted are set to the global or default value"，省略之所以不成立，是上面
> 那个 `eval` 不重置变量的 bug）。回落发生在两处，都在认证流程里：
> - `sessiontimeout`：解析认证串时 `if (custom_seconds > 0) seconds = custom_seconds;`，
>   0 不覆盖，沿用全局 `sessiontimeout`（9.x `src/ndsctl_thread.c` 的 `ndsctl_auth()`，
>   10.x `src/auth.c` 的 `get_quotas_by_mac` 之后同一段判断）。
> - `uploadrate` / `downloadrate` / `uploadquota` / `downloadquota`：`auth_change_state()`
>   在 `Preauthenticated → Authenticated` 那一支里逐个补齐——`if (client->upload_rate == 0)
>   client->upload_rate = config->upload_rate;`（其余三个同形，9.x / 10.x 都有这段）。
>   所以 0 拿到的是全局 `uploadrate` / `downloadrate` / `uploadquota` / `downloadquota`。
>
> 结论：**0 = 跟随全局**。全局这四项出厂都是 0（= 不限速、不限量），所以 0 通常
> 就表现为"不限制"；但管理员一旦给全局设了速率/配额，写 0 的客户端就会拿到那个
> 全局值——**不是**"这个客户端单独解限"。新增条目（免认证、批量添加）五个参数
> 全写 0 即可：既符合"免认证仍受配额、限速、会话时长管理"，又能跟随后续全局调整。
> 反过来，想给某个客户端**固定**一个和全局不同的值，就写具体数字（编辑弹窗的行为，见 §4）。
>
> **MAC 一律小写，条目只由 `mac=` 加 5 个纯数字参数组成**。大小写不能含糊：
> `dhcp_check()` 用 `grep -w "$mac"` 去比租约文件，而租约里的 MAC 是小写，写成大写
> 这条客户端永远进不了预认证队列（界面上却显示已免认证）。
> 空格本身不会把条目拆开——`get_list_from_config()` 先把整份 list 拼接后 `urlencode`，
> 条目内的空格变成 `%20`，`for listblock in $param` 拿到手的仍是一条（实测
> `custom=hello world` 到 `eval` 时是 `custom=hello%20world`，不会被拆成两条）；
> 但**别指望空格原样读回来**，所以自定义串里不要靠空格表达含义。
> 真正要守的是：整条最终交给 `eval` 执行，`;` 是字段分隔符，值里多一个 `;` 就等于凭空
> 多一个赋值（甚至一条命令）；`"` `'` `` ` `` `$` `<` `>` 虽然会被 urlencode 转义，
> 也不要依赖这层转义。结论：**MAC 与 5 个参数值都必须先过白名单（纯 MAC / 纯整数）再拼条目**，
> 绝不把用户输入的原样拼进去。

> **本页不碰 `allow_preemptive_authentication`**。它只是「客户端豁免管理」页上的
> 一个独立开关，和名单增删没有绑定关系：本页不读它、不写它，也不因它改变任何
> 卡片计数、按钮可用性或页头提示。写 `preemptivemac` 时就只写名单，不要顺手
> 改开关，也不要拿开关值去反推"免认证有没有生效"——生效与否只看 `state`。

---

## 4. 编辑弹窗（5 项限制）

- 标题「客户端编辑」；副标题：`主机名 · IP · MAC`。三个分区：
  1. **连接时间**：连接时长限制（分钟）
  2. **网络速度**：上传速度限制（kb/s）、下载速度限制（kb/s）
  3. **流量限制**：上传流量限制（kB）、下载流量限制（kB）
- 每项为数字输入框（min=0 step=1），**占位符 `0`**，右侧单位标签，下方注释
  "设置值为 0 时表示不限制。"；空值按 0 处理。
  > 这句注释是界面文案，实际写进 uci 的 0 在 openNDS 里是"**跟随全局**"（见 §3 末尾）：
  > 全局 `uploadrate` / `downloadrate` / `uploadquota` / `downloadquota` 出厂都是 0，
  > 所以填 0 通常就等于不限制；只有管理员给全局设了值，0 才会拿到那个全局值。
  > 后端照原值写 0、不要自作聪明换算成别的数，也不要拦掉 0。
- **流量限制分区顶部有红色警告文案（照抄）**：
  "设置完流量配额后需要到设置页 公平使用策略 里设置限速，否则流量耗尽将会被取消认证。"
  （提示完整插件的"设置页"里有"公平使用策略"区块，见 §9。）
- 分区说明文案照抄演示页：
  - 连接时间："设置该客户端允许保持登录状态的最长时间。"
  - 网络速度："上传与下载速度分别独立设置，可只限制其中一个方向。"
  - 流量限制："上传与下载流量额度分别独立设置；达到额度后，NDS 会对该客户端执行相应的流量控制。"
- 校验：任一项非数字、含有小数点、或小于 0 → toast 警告（文案照抄）并阻止提交。
  **只收整数**：openNDS 这几项参数（`sessiontimeout` / `uploadrate` / `downloadrate` /
  `uploadquota` / `downloadquota`）都是整数，`1.5` 这种值写进 uci 不会报错，
  但 openNDS 解析时会被截断或算错，所以前端就拦掉。
- **底部按钮："取消" / "应用"**。
  - 取消：关闭弹窗，toast"已取消编辑，未应用本次修改"。
  - 关闭方式：`Esc` 等同取消（不写任何配置）；**点遮罩不关闭**——编辑到一半手滑点空白
    就丢内容更烦人。详情弹窗和确认框相反，点遮罩可以关（只读/无输入，没有丢数据的风险）。
  - **应用** = 保存设置并重启 openNDS：校验通过 → 把该 MAC 的 5 项限制
    写入 uci `preemptivemac` 列表条目
    （格式 `mac=<MAC>;sessiontimeout=…;uploadrate=…;downloadrate=…;uploadquota=…;downloadquota=…`），
    commit → 执行 `/etc/init.d/opennds restart` → 关闭弹窗、恢复轮询、
    toast"已应用「主机名」的客户端设置"。**只写这一条名单条目，不碰
    `allow_preemptive_authentication`**（它是豁免页的独立开关，本页任何操作都不改写它）。
  - 语义说明（已知副作用，接受）：写进 `preemptivemac` 的客户端从此就是
    openNDS 的 Pre-emptive Client——**下次接入会自动登录、不再弹门户**，
    因此在概览统计里会从"已认证"变成"免认证"。**实现要求**：编辑弹窗「应用」成功后
    （这时已经重启、客户端正在重新登录），前端可以乐观地把这条按「免认证」显示，但
    **必须同时把 `authenticated` 当 `true`**——只置 `preauth` 不置 `authenticated`，
    按 §2.2 的 ③⑤ 顺序它会被归到未认证卡片，出现"刚设完限制就变成未认证"的怪象。
    下一轮 `clients` 回来一律以真实 `state` 覆盖，不要长期留着乐观值。
    另外这条记录**必须是完整的 6 个参数**（`mac` + 5 个限制），
    缺项会继承上一条客户端的值，详见 §3 末尾的警告。**该条目原来若带第 7 个字段
    `custom=…`（openNDS 支持它），原样保留在末尾**，别在重排字段时抹掉。若「客户端会话管理」页
    的"配置范围"处于**覆盖**状态（读 `zone_detect.main.session_scope == 'override'`，键缺失按 `default`），则本弹窗的 `sessiontimeout` 一律写 `0`
    （表示遵循全局配置），而不是省略该参数——省略同样会继承别人的值。
    这种情况下**弹窗里的「连接时间」输入框要置灰只读**，下方补一行提示
    「当前为「覆盖」模式：所有客户端的会话时长统一跟随「客户端会话管理」页的全局设置」——
    否则用户填了 180 分钟、后端却写 0，界面还提示"已应用"，等于把用户的输入悄悄丢掉。
    同样受"必须有 DHCP 租约"限制：无租约的客户端写进去也不会被 `preemptivemac()`
    取用，应用成功后要在 toast 里补一句「该客户端没有 DHCP 租约，预认证不会生效」。
- 打开编辑弹窗时自动暂停 10 秒轮询，关闭（取消/应用）后恢复。

---

## 5. 详情弹窗（只读）

标题「客户端详情」；副标题 `主机名 · IP`。分区、字段顺序与标签照演示，**取值规则以本表为准**：

- **状态**：拉黑状态（已拉黑/未拉黑）
- **基本信息**：主机名 / IP 地址 / MAC 地址 / 接入点 / 认证状态
  （认证状态 = 基础身份 + 可选的信任标记：先取基础身份——在 `preemptivemac` 名单内 →
  「免认证」，`authenticated` →「已认证」，否则「未认证」；`trusted` 为真再追加
  「 · 可信任」。因为 openNDS 里 `Trusted` 是独立状态、不算 `Authenticated`（后端按 §6
  换算 `authenticated=false`），真实的可信任客户端会显示「未认证 · 可信任」——它确实没走
  认证流程、只是被信任放行，这是准确表述，不要为了好看改成「已认证」）
- **时间与超时**：加入时间（`session_start`）；到期时间（`session_end` 按 `YYYY-MM-DD HH:mm`
  显示；trusted→"不受限制"；未认证（`!authenticated`）→"—"；**已认证但 `session_end`
  是 0 / `"null"` 也显示"—"**——`sessiontimeout=0`（全局或该客户端条目）= 永不超时，
  `auth.c` 里就是把它置 0、超时循环只看 `> 0`，别拿 0 去格式化成年份。免认证客户端
  一般有到期时间，`sessiontimeout=0` 时同样是"—"）；
  中断超时（分钟）（**全局 `authidletimeout`，所有客户端同值、只读**；不是每客户端设置，
  编辑弹窗里也没有这一项；trusted→"不受限制"）；
  最大会话时间（分钟）（未单独设置→"未单独设置"；trusted→"不受限制"）
- **速度限制**：上传/下载速度限制（Kb/s）（未设置→"未单独设置"；trusted→"不受限制"）
- **流量总量**：上传/下载总量（**后端先换成字节**再交前端做 B/KB/MB/GB 自适应格式化——`ndsctl json` 的 `upload_this_session` / `download_this_session` 给的是 **kB**（源码里已经是 `bytes / 1024`），不乘 1024 的话所有流量都会显示成实际的 1/1024；trusted→"不受限制"）
- **超额限速**：上传/下载超额限速（Kb/s）（对应 FUP 的 fup throttle rate）
- 底部仅"关闭"按钮；点遮罩或 Esc 可关闭。

---

## 6. 数据来源映射（后端实现约定）

| 页面数据 | 来源 |
|---|---|
| 客户端列表 | `ndsctl json`（MAC/IP/状态/到期/流量计数/限速参数）；主机名从 DHCP 租约（`/tmp/dhcp.leases` 等）或 ndsctl 输出补全 |
| 客户端接入点 | `ndsctl json` 的 `clientif` 就是 openNDS 内部调用 `/usr/lib/opennds/get_client_interface.sh <mac>` 的结果（`src/util.c` 的 `get_client_interface()`），可直接用；**是原样输出、没有编码**（`get_client_interface()` 走的是 `execute_ret_url_encoded()`，这名字是历史遗留，函数体就是 `popen` + `fread`，不做任何转义），mesh 场景带两段（`phy2-ap0 <mesh节点MAC>`），**按空格取第一段**即可。取不到时是空串（客户端不在 `ip neigh`），此时退回 uci / `ndsctl status` 的管理接口按有线处理。SSID 仍自己反查：`iw dev <if> info` 直读，读不到才回退 `phyN-apM` 序号映射——与区域识别页/豁免页共用同一份实现 |
| 运行状态 | `ndsctl status` 成败（不看 init 脚本的 exit code，也不看 `pidof`）；`enabled` 读 `uci -q get opennds.@opennds[0].enabled`（缺省按 1） |
| 门户接管状态 | `engaged`：`uci -q get opennds.@opennds[0].login_option_enabled` 为 `3` **且** `themespec_path` 等于 `/usr/lib/opennds/theme_zone_detect.sh`；其它情况一律 `0`（口径与区域识别页同源） |
| 管理接口与 IP | uci → `ndsctl status` 的 Managed interface → `ip addr show` |
| 无线接入点 | `uci show wireless`（仅 enabled 的 AP section） |
| 最大客户端 | `uci -q get opennds.@opennds[0].maxclients`，默认 250 |
| 全局超时 | `uci` 的 preauthidletimeout/authidletimeout/sessiontimeout |
| 会话配置范围 | `uci -q get zone_detect.main.session_scope`：`override` 时编辑弹窗的 `sessiontimeout` 写 `0`、并把「连接时间」置灰；`default`／键缺失按 `default` 处理。来源与写入方都是「客户端会话管理」页，本页只读 |
| 每客户端限制 | **5 项一律只认 uci `preemptivemac` 条目**（`limits.maxSession` / `uploadRate` / `downloadRate` / `uploadQuota` / `downloadQuota`）：该 MAC 的条目里有这个参数且 >0 才算"单独设置"，条目不存在或值为 0 一律 `enabled:false`（界面显示"未单独设置"）。`session_end - session_start` 只是**本次会话的实际长度**，别拿它冒充 per-client 设置——它分不出"单独设的"还是"全局 timeout 兜出来的"，照它填会让每个客户端都显示成单独设置过。⚠️ `ndsctl json` 的 `upload_rate_limit_threshold` / `download_rate_limit_threshold` / `upload_quota` / `download_quota` 是**本会话实际生效值**（认证时 `auth_change_state()` 已经把全局值补进 `client->*`），**全局一设限速，每个客户端都非 `"null"`**——拿它判断"有没有单独设置"同样会把所有人判成设置过，它只能用来核对"实际跑的是多少"，不参与 §5 详情弹窗的"未单独设置"判定。另外这几个值在客户端侧为 0 时**输出的是字符串 `"null"`**（`download_rate_limit_threshold` / `download_packet_rate` / `download_bucket_size` / `upload_*` / `*_quota` 全一样），解析时必须把 `"null"` 当"没有值"，不能直接塞进 Number。这 5 项只有「免认证」和「编辑过」的客户端才有持久配置，普通门户登录的客户端参数由 FAS/BinAuth 在登录时下发、不回写 uci，详情里显示"未单独设置"即可，不要臆造 |
| 可信任名单 | 在线的：`ndsctl json` 的 `clients` 里 `state=="Trusted"` 的条目（openNDS 为 trustedmac 客户端单独标这个状态）；离线的：json 顶层 `trusted` 数组，或 `uci -q get opennds.@opennds[0].trustedmac` |
| 免认证名单 | `uci -q get opennds.@opennds[0].preemptivemac`，逐条取 `mac=` 之后到第一个 `;` 之前的部分（条目是 `mac=…;sessiontimeout=…;…`），**不能整条当 MAC 比较**。在不在线看 `ndsctl json` 的 `clients` 里有没有这个 MAC；`client_type` 不能用来判定身份（理由见 §2.2）。写条目时 MAC 一律小写、5 个参数值必须是纯整数、条目里不要出现多余的 `;`（`preemptivemac()` 用 `grep -w` 比租约、整条交给 `eval`，见 §3 末尾） |
| 黑名单 | **`/etc/config/zone_blacklist`**（`config main 'main'` + `list mac '…'`），插件自有，与黑名单页共用同一份名单；`blocked` 字段由它推导，不来自 ndsctl。出厂模板有一条 `list mac ''`，读到空串/纯空白要过滤掉，否则黑名单卡会多算一条 |

ndsctl 的 json 字段名以上面 §2.2 列的那 26 个键为准（`custom` 一定在，无自定义串时值为 `"none"`）。后端解析后输出统一
JSON 给前端，前端字段命名对齐演示页数据模型：host/ip/mac/iface/expires/joined/
timeout/trafficUp/trafficDown/authenticated/preauth/trusted/blocked/limits。

两个容易踩的字段语义：

- `authenticated` = `state` 为 `Authenticated` **或** `AuthBlocked`（超配额被 FUP 限流的
  客户端身份仍是已认证，只是限速，列表和详情都照「已认证」显示，**不另设标签、不加字段**）。
  **免认证客户端的 `authenticated` 也是 `true`**——预认证登录成功后 openNDS 给的就是
  `Authenticated`，"免认证"只是身份来自名单，不代表没登录。`state="Trusted"` 的客户端
  **不算** `authenticated`（openNDS 给它的就是独立状态 `Trusted`，没走认证流程），所以
  「未认证」判 `!authenticated && !trusted`（外加不在黑名单）就够，**不要再加 `&& !preauth`**
  ——名单里但没登录成功的设备会因此从所有卡片里漏掉，四类相加对不上在线数。
- 分类仍按 §2.2 的互斥优先序（黑名单 > 可信任 > 免认证 > 已认证 > 未认证）。
  `preauth=true` 且 `authenticated=true` 时算免认证，不算已认证。

`limits` 不要漏字段，它是对象、固定 7 个键：

```
limits.maxSession / uploadRate / downloadRate / uploadQuota / downloadQuota
        = { enabled: true|false, value: "字符串形式的非负整数" }   ← 可写（编辑弹窗那 5 项）
limits.overQuotaUploadRate / overQuotaDownloadRate
        = { enabled, value }                                      ← 只读，来自 uci 的
                                                                    fup_upload_throttle_rate /
                                                                    fup_download_throttle_rate
```

`expires` / `joined` 是 `YYYY-MM-DD HH:mm` 字符串（没有就空串），`timeout` 是**全局
`authidletimeout` 的分钟整数**（所有客户端同值、只读；`ndsctl json` 里没有这个字段，
`preemptivemac` 也没有对应参数，别去找"每客户端空闲超时"），`trafficUp` / `trafficDown`
是**字节整数**（后端把 ndsctl 的 kB 值乘 1024 换成字节），由前端自己格式化成 B/KB/MB/GB；`ndsctl json` 里的 `*_session_avg` 单位是 kb/s、`*_this_session` 单位是 kB，别当字节直接用。

**`preauth` / `trusted` / `blocked` 这三个布尔值由后端按名单算出来再输出，`authenticated`
由 `state` 算**，前端不碰 uci、也不该知道 openNDS 内部长什么样。

---

## 7. 后端 API（`opennds-cpd-api.sh overview …`）子命令约定

POSIX sh，输出 JSON（成功 `{"ok":1,…}` / 失败 `{"ok":0,"error":"…"}`，信封统一见《整包集成与打包.md》§12）。
调用形式：`opennds-cpd-api.sh overview <子命令> [参数…]`（本页 page 名固定为 `overview`）。
至少提供：

| 子命令 | 功能 |
|---|---|
| `status` | `running`（`ndsctl status` 成败）、`enabled`（openNDS 服务的 uci 启停开关）、`engaged`（门户是否已由本插件接管：`login_option_enabled=='3'` 且 `themespec_path=='/usr/lib/opennds/theme_zone_detect.sh'`，为 `0` 时页头挂一条「门户尚未由本插件接管，以下配置暂不影响客户端」提示条并给区域识别页链接，见《整包集成与打包.md》§9）、`busy`（是否有其它页面正在应用，见 §3.1 第 7 条）、`session_scope`（读 `zone_detect.main.session_scope`，`default`/`override`，键缺失按 `default`——编辑弹窗据此决定「连接时间」是否置灰，见 §4）、统计计数、管理接口/IP、AP 列表（含各自客户端数）、maxclients。**不返回 `allow_preemptive_authentication`**——那是豁免页自己的开关，与本页无关。停用时除 `running`/`enabled`/`engaged`/黑名单条数/maxclients 外，其余计数一律给 0，**不要返回上一轮的缓存** |
| `run_state` | 只回 `{running, enabled}`，供开关和状态文字用。轮询它比拉整个 `status` 轻，重启后前端 1 秒一次问到就绪为止 |
| `set_run <0\|1>` | 写 `opennds.@opennds[0].enabled` + commit，再 `/etc/init.d/opennds stop\|start`；返回执行后的**真实** `{running, enabled}`。停用没停掉（进程还在）就如实回 `running=1`，不许乐观置 0 |
| `restart` | `/etc/init.d/opennds restart`。返回 0 只代表脚本跑完，就绪与否由前端轮询 `run_state` 判定（最多 20 秒） |
| `clients` | 客户端全量列表（含 §6 的统一字段模型） |
| `client_detail <mac>` | 单客户端详情所需字段 |
| `client_action <action> <mac>` | action ∈ `preauth` / `unpreauth` / `deauth` / `trust` / `untrust` / `block` / `unblock`（前端按钮文字是"免认证 / 移除免认证"、"可信任客户端 / 移除可信任"）。`preauth`/`unpreauth` 写 `preemptivemac`，**不重启**；`unpreauth` 还要删该 MAC 的预认证队列文件并 `ndsctl deauth`。`trust`/`untrust` = `ndsctl trust\|untrust` + 写 `trustedmac`，**不重启**（`trust` 同时清掉该 MAC 的 `preemptivemac` 条目）。`block` = 写 `zone_blacklist` + 摘两份名单 + `untrust` + `deauth` + **`/etc/init.d/opennds restart`**，返回 `{"ok":1,"restarted":1}`；`unblock` = 从 `zone_blacklist` 移除 + commit（不重启）。`deauth` 纯运行时，若该 MAC 在 `preemptivemac` 里则一并删条目。`preauth` 若该 MAC 没有 DHCP 租约，返回 `{"ok":1,"warnings":["该客户端没有 DHCP 租约，预认证不会生效"]}`（只显示 warn toast，**不报成功 toast**；`warnings` 恒为数组，口径见《整包集成与打包.md》§12。**不看** `allow_preemptive_authentication`，那是豁免页的开关）。`preauth` / `trust` 入口先查 `zone_blacklist`：目标 MAC 在黑名单里就返回 `{"ok":0,"error":"该客户端在黑名单中，请先解除拉黑"}`，不写任何配置（见 §3 末尾） |
| `client_edit <mac> <k=v>…` | 5 项限制持久化写入 preemptivemac 并 `restart` |

> 不需要 `client_restore`：拉黑改为名单制后，`zone_blacklist` 本身就是持久的，
> 客户端重启后依旧是"未认证 + 分发脚本出示黑名单门户"，没有需要重新下发的运行时状态。

安全要求：MAC 参数做格式校验（防注入）；所有 shell 参数引用加引号。

---

## 8. 实现质量要求

1. shell 通过 `sh -n`；JS 通过语法检查；JSON 可解析。
2. 冒烟测试：搭 stub 沙箱（stub `ndsctl`/`uci`/`ip`/`get_client_interface.sh`/`/etc/init.d/opennds`），
   覆盖：status 统计分类计数（含"名单内但未登录"落未认证、四类之和=在线）、clients 字段模型、
   筛选/搜索归一化/排序逻辑、每种 client_action 的 ndsctl 调用与持久化写入（含 block 的
   互斥清理）、client_edit 的 preemptivemac 条目格式与重启调用、MAC 校验拦截、
   **写进 preemptivemac 的 MAC 是小写、条目是 `mac=…;` 加 5 个纯数字参数的 6 字段格式**、**无 DHCP 租约时 preauth 返回 `warnings`**、
   **set_run 0/1 与 restart 的真实状态回传**、**停用后 status 计数全 0 且不返回旧缓存**、
   **`unpreauth` / `deauth` / `block` 都删掉了该 MAC 的预认证队列文件（大小写各一次）**。
3. busybox ash 坑位注意（管道子进程变量失效、`$'\n'` 不支持等），与区域识别页开发时相同。
4. rpcd ACL 需放行 `opennds-cpd-api.sh` 执行及 opennds 配置读写相关路径。
5. 界面文案中文，样式跟随演示布局（CSS 变量、卡片、表格、弹窗、toast 均照搬原型）。
6. 自动轮询在请求进行中时跳过下一次（避免叠加），页面不可见时（可选）暂停。

---

## 9. 与其它页面的集成说明

- **统一包名 `luci-app-opennds-cpd`**：本页 JS 为
  `view/opennds_cpd/overview.js`；菜单与 ACL 全包各只留
  `luci-app-opennds-cpd.json` 一份；概览页为插件首页菜单项。
- 后端只有**一个** `opennds-cpd-api.sh`，本页调用时第一参数固定 `overview`；
  禁止另建 `overview-api.sh`。
- **无线列表识别、SSID↔接口反查、管理接口获取**的逻辑与"区域识别"页共用，
  在同一个后端脚本内抽成共用函数，避免两份拷贝。
- **「openNDS 设置」页的「公平使用策略/FUP」区块**属于完整插件的另一个页面：概览页编辑
  弹窗的红色警告文案指向它；本页不实现 FUP 编辑，只留文案。
- openNDS 登录模式概念归区域识别页主导，概览页不涉及模式切换。
- **概览页的启停开关是全局的**：停用后 openNDS 进程退出，门户分发脚本（ThemeSpec）
  不会被调用，黑名单门户、免认证、可信任全部失效。**这条只在本页体现**（开关与状态文字）；
  其它页面**不为它另挂横幅**，停用态统一按《整包集成与打包.md》§11.1 处理——只读接口返回
  `enabled`，用户点「应用」时弹一次确认框，不会给"改了会生效"的错觉。
- **保存/应用 全局红线（防"重启被动生效"漏洞）**：任何页面的「保存」都不得写入会被 openNDS 或分发脚本运行时读取的配置（`/etc/config/opennds`、`zone_blacklist`）。允许写的只有两类：① 纯暂存缓存 `zone_detect`（无运行时读取者，生效完全依赖「应用」阶段的写正式配置动作）；② 前端内存快照（不碰文件）。「应用」= 校验 → 写正式配置 → commit → **编辑客户端限制时必须重启**（已在线会话的参数只能靠重启重新读入）；免认证 / 移除免认证 / 信任 / 解除认证不必重启，**拉黑必须重启**（见 §3 操作表）。任何绕过「应用」直接写正式配置的路径都视为实现错误——否则用户保存后未应用就断电/重启，配置会在开机时被动生效。
