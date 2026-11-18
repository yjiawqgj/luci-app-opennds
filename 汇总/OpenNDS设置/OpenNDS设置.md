# 开发提示词：openNDS 设置（默认门户 / 公平使用策略 / 网络接口）

> 本文是一份自包含的开发任务书。按本文内容可直接开发出「openNDS 设置」LuCI 页面，
> 无需向需求方追加提问。文中所有路径、命名、行为规则均为强制约定。
> 同目录 `OpenNDS设置.html` 是**界面事实源**：界面形态（有哪些控件、按钮、文案怎么写）以它为准；功能行为、数据来源、边界条件、异常处理以本文档为准，演示里的模拟数据不代表真实取值。


---

## 0. 任务总述

「openNDS 设置」是全插件的配置页，管三块内容，从上到下：

1. **默认门户设置**：三个 tab（无线区域 / 有线区域 / 黑名单），每个 tab 上传或清理
   一份 `default.sh`。这是**全局类型默认门户**——当某个区域没有自己的门户时用它，
   也是区域页"设为默认"时指向的那份文件。
2. **公平使用策略（FUP）**：上传/下载两个方向，各自选「限速」或「取消认证」，
   限速时填速率。
3. **网络接口**：以卡片网格列出所有带 IPv4 的接口，点一下把 openNDS 的接管接口
   切过去（二次确认）。

交付物（与其它页同一套包结构）：

```
luci-app-opennds-cpd/
├── htdocs/luci-static/resources/view/opennds_cpd/
│   └── settings.js                          # 本页 JS 视图
├── usr/lib/opennds/opennds-cpd-api.sh       # 全插件唯一后端脚本，本页 page 名 settings
├── usr/lib/opennds/cpd/default/wireless/default.sh    # 本页上传产物（运行时生成）
├── usr/lib/opennds/cpd/default/wired/default.sh       # 同上
└── usr/lib/opennds/cpd/default/blacklist/default.sh   # 同上
```

---

## 1. 关键前提（openNDS 的真实行为，决定了本页怎么实现）

- **FUP 配置项**：`fup_upload_throttle_rate` / `fup_download_throttle_rate`
  （单位 kb/s，整数）。**0 = 超配额直接取消认证；>0 = 降到这个速率**。
  openNDS **启动时读入**，改完必须重启才生效。
- **接口配置项**：`gatewayinterface`，默认 `br-lan`，**值必须是设备名**（如 `br-lan`）。
  配置模板的注释虽然写着"也可以填 `/etc/config/network` 的 section 名"，但基线脚本
  （`libopennds.sh`）是**把它当设备名原样用**的：主程序取网关 IP 走
  `libopennds.sh gatewayip "<gatewayinterface>"`，那条分支先 `wait_for_interface`——
  `ip link show lan` 找不到设备，等满 10 秒后 `ifstatus=down`，直接回 `error`（exit 1），
  后面的 `check_gw_ip` 根本没机会跑；即便跑到了也拦不住（它判的是
  `grep -c "$ifname "`，子串匹配，`lan` 会匹到 `br-lan ` 那行）。就算 gw_ip 侥幸有值，
  `libopennds.sh:1350-1351` 的两条
  `nft insert rule ip nds_filter nds_allow_INP|nds_allow_FWD iifname "$gatewayinterface" counter accept`
  也要求内核里真有一个叫 `lan` 的接口，一个包都命中不了——连"放行网关接口"这条基础规则都失效。
  所以填 section 名的结果是**起不来或门户不可用**。**本页只写设备名**（卡片列表里 `ip -4 -o addr show`
  的接口名），绝不把 section 名写进配置；**接口必须有 IPv4 地址**。
  nft 规则按接口名建立，改完**必须重启** openNDS。
- **门户文件是数据，不是配置**：分发脚本 `theme_zone_detect.sh` 每次客户端请求门户时
  现读 `default.sh` 并 `source` 它。所以上传/清理**立即生效、不需要重启**，
  也不参与底部的「保存 / 应用」。
- **这些默认门户只有在区域模式（`login_option_enabled='3'`）下才起作用**：
  "全局模式"（`login_option_enabled='1'`）用的是 openNDS 自带页面，不经过分发脚本。
  本页不做模式判断（那是「区域识别」页的活），但要在页面顶部用一行灰字说明：
  「默认门户仅在区域识别处于"区域"模式时生效。」
- **`default.sh` 会被 `source`**：它只能定义函数和变量，**不能向 stdout 输出任何内容**
  （一旦 echo，就会污染 openNDS 返回给客户端的 HTTP 响应头）。
- **目录约定**（全插件统一，与区域页一致）：
  - 区域门户库：`/usr/lib/opennds/cpd/wireless/<SSID>/`、`/usr/lib/opennds/cpd/wired/<接口名>/`
  - 类型默认门户：`/usr/lib/opennds/cpd/default/{wireless,wired,blacklist}/default.sh`
  - 黑名单门户库：`/usr/lib/opennds/cpd/blacklist/`
  - 本页**只碰 `cpd/default/` 这三个目录**，不碰区域目录、不碰 `cpd/blacklist/` 里的
    其它门户文件（那些归黑名单页）。

---

## 2. 已确认决策表（不要再问，直接照做）

| # | 决策点 | 结论 |
|---|--------|------|
| 1 | 默认门户的文件名 | **固定 `default.sh`**，用户不能改名。演示的上传逻辑就是硬拦：后缀不是 `.sh` → 「只支持上传后缀为 .sh 的脚本」；名字不是 `default.sh` → 「请上传名为 default.sh 的脚本」 |
| 2 | 上传落点 | `cpd/default/<tab>/default.sh`，覆盖写；目录不存在先 `mkdir -p`；落盘后 `chmod 755`（被 source 的脚本，可执行位必须有） |
| 3 | 上传/清理是否参与保存应用 | **不参与**。上传、清理是独立即时动作，不进快照、不受「未保存」守卫限制、点「应用」时也不重写门户文件。原因见 §1 第三条 |
| 4 | 「已上传」状态判定 | **看文件在不在**（后端 `[ -f ... ]`），不靠前端记忆。页面刷新后状态必须仍然正确 |
| 5 | FUP 值与界面的映射 | 「限速」→ 写入速率值（≥1）；「取消认证」→ 写入 **0**。反向读取：值为 0 / 未设 / 空 → 下拉选「取消认证」并隐藏速率行；>0 → 「限速」+ 回填数值 |
| 6 | 切「取消认证」时速率值 | 只是**隐藏**速率行，不清理输入框里的数字（照演示 `toggleQuotaRates` 只切 `hidden`）。写盘时按当前下拉的状态决定写 0 还是写速率 |
| 7 | 接口列表来源 | 只列**有 IPv4 地址**的接口（openNDS 硬性要求）。取 `ip -4 -o addr show` 的第一条 IPv4；顺序按 `ip` 输出顺序，当前接口置顶不置顶都可以，但当前接口必须高亮 |
| 8 | 接口点击行为 | 点当前接口 → 只 toast「当前正在使用 X」，**不弹确认框、不发请求**；点其它接口 → 二次确认后才切换 |
| 9 | 切换接口的后果提示 | 确认框文案已写明"部分自定义规则和客户端可能失效"，不做额外拦截 |
| 10 | 保存 / 应用 | **「保存」= 前端内存快照，不碰任何文件**；「应用」= 校验 → 写 `fup_upload_throttle_rate` / `fup_download_throttle_rate` / `gatewayinterface` → commit → 重启 openNDS。⚠️ openNDS 处于停用状态（`enabled=0`）时先按《整包集成与打包.md》§11.1 弹确认，确认后再顺手 `enabled=1` 并重启 |
| 11 | 应用前的守卫 | 照演示：当前状态 ≠ 最后保存的快照 → 拦下并 toast「当前设置尚未保存，请先保存后再应用。」；页面加载时快照 = 当前配置，未改动可直接应用 |
| 12 | 应用 = 重启 | FUP 与 `gatewayinterface` 都是启动时读取，只有重启才生效，没有"热更新"通道 |
| 13 | 不写 `gatewayport`、`webroot` 等其它项 | 本页只碰决策 #10 列的三个键 + 门户文件，其它 option 一律不动 |
| 14 | 门户上传是否校验内容 | **不校验内容语义**（不解析是不是合法 theme 脚本），只校验文件名、大小上限（512KB）、非空。写坏了是用户的事，但要在 §3 区块描述里提示"必须是 openNDS 门户脚本" |

---

## 3. 页面布局（版式与交互照演示，功能与边界按本文档）

### 3.1 整体框架
- 灰底 + 居中白色圆角卡片 `.sheet`（max-width 980px、1px 边框、8px 圆角），
  与 WalledGarden 页同一套视觉，不要套用概览页的纯白布局。
- 页头 `.topbar`：H1「openNDS 设置」；标题后面的英文小字已按要求删除；
  描述一行：**「默认门户、公平使用策略与网络接口设置。」**
  （正式页面不要出现"演示""不连接真实服务"这类原型字样。）
- 三个 `.sec` 区块之间 `hr.divider`。
- 底部固定 `.action-bar`：「保存」（普通） + 「应用」（primary）。

### 3.2 默认门户设置
- H2「默认门户设置」。
- 三个 tab（`role="tablist"`）：**无线区域 / 有线区域 / 黑名单**，默认选中「无线区域」。
  - tab 支持左右方向键循环切换（`role="tab"` + `aria-selected` + `aria-controls="portalPanel"`），
    面板 `aria-labelledby` 跟随当前 tab。
  - 切换 tab **不丢状态**：三个 tab 各自的已上传状态独立保存，切回来还是原样。
- 面板 `.tab-panel#portalPanel` 内容（每个 tab 一样，只是目标目录不同）：
  - **上传按钮**：
    - 未上传：描边按钮 + 上传图标 + 文案「上传」。
    - 已上传：按钮加 `uploaded` 样式 + 对勾图标 + 文案「已上传」+ `disabled`。
    - 点击 → 打开文件选择器（`<input type="file" accept=".sh" hidden>`）。
  - **清理按钮**：危险色文字按钮 + 垃圾桶图标 + 文案「清理」；未上传时 `disabled`。
- 上传后立即 toast「已上传 default.sh」；清理确认后 toast
  「已清理「无线区域」的 default.sh，可重新上传」。
- 面板下方一行灰字提示（必须加，避免用户乱传）：
  「只接受名为 default.sh 的脚本；该文件会被 openNDS 直接 source，不能有输出语句。」

### 3.3 公平使用策略
- H2「公平使用策略」。
- 区块标题下一条红色小字警告：**「下载配额检查优于上传配额检查。」**（照抄）
- 两列网格 `.quota-grid`（窄屏单列），每列：
  - 标签「上传」/「下载」
  - 下拉框 `select`，两个选项：`限速` / `取消认证`
  - 速率行 `.rate-line`：小标签「速率」+ 数字输入框（`min=1 step=1`，placeholder
    「例如 2048」/「例如 4096」）+ 单位「Kb/s」
  - 选「取消认证」时速率行 `hidden`；选回「限速」时恢复显示，原数值还在。
- 不要在界面上写 0 这个值：用户只需要选"限速还是取消认证"，0 是后端的事。

### 3.4 网络接口
- H2「网络接口」。
- 区块标题下红色小字警告（照演示，修正原文语病）：
  **「更改网络接口，某些自定义规则和客户端将会失效，请先调整好相关配置再更改。」**
- 卡片网格 `.iface-grid`，每张卡（`<button>`，`aria-pressed`）：
  - 第一行：接口名（等宽字体）+ 当前接口额外显示徽章「● 正在使用中」
  - 第二行：「对应 IP」+ 地址
  - 当前接口卡片 `active` 高亮（边框 + 浅色底）
- toast 照演示：点当前接口 →「当前正在使用 <接口名>」；确认切换 →「网络接口已切换为 <接口名>」（ok）。
  ⚠️ 这里的"切换"指**前端把选中项换到新卡片**（高亮与「正在使用中」徽章跟着走），
  `gatewayinterface` 仍然只在底部「应用」里写（决策 #10）。所以点完接口要「保存」→「应用」
  两步才会真正生效；toast 文案照演示不改，但它不代表已经写盘。
- 空列表（极端情况：没有任何带 IPv4 的接口）→ 显示一行灰字
  「未找到带 IPv4 地址的网络接口。」

### 3.5 二次确认弹窗
- 遮罩 + 居中小卡片：标题 / 正文 / 「取消」+「确认」。
- 确认按钮：清理操作用 `danger-text`（红字），切换接口用 `primary`（蓝底）。
- 打开时焦点移到确认按钮，关闭后焦点还给触发元素；点遮罩或 Esc 关闭。
- 文案（照抄）：
  - 清理：标题「清理 default.sh？」，正文「将删除「<tab 中文名>」指定目录中的
    default.sh。删除后上传按钮会恢复为「上传」。」，按钮「清理」。
  - 切换：标题「切换网络接口？」，正文「将 openNDS 接管接口从「<当前>」切换到
    「<目标>」。切换后部分自定义规则和客户端可能失效。」，按钮「切换」。

---

## 4. 交互与校验细则

### 4.1 上传
1. 用户选文件 → 前端先校验：后缀必须 `.sh`（大小写不敏感），文件名必须正好是
   `default.sh`。任一不符 → toast 对应文案，不发请求。
2. 通过 → **先 `upload_begin <id>` 让后端建好临时目录**（`/tmp/zone_up/<id>/`，与区域识别页
   同一套两段式上传）→ 前端 `fs.write` 写 `/tmp/zone_up/<id>/default.sh` → 再调后端
   `upload_default <tab> <id>` 校验并搬移。
   ⚠️ **不允许把文件内容塞进 exec 的参数**：Linux 单个 argv 上限 128KB（`MAX_ARG_STRLEN`），
   512KB 文件 base64 后 ≈683KB，`file.exec` 会直接 `E2BIG`，而页面上只会表现成"上传失败"。
   传 id 这种几十字节的字符串没问题，传内容不行。这也是区域识别页用 `upload_begin` /
   `upload_store` 两段式的原因——本页复用同一套机制（`upload_begin` 共用，落点那一步因为目标
   不同而叫 `upload_default`），不另造一套。
3. 后端二次校验（前端校验只是体验，安全在后端）：
   - 文件名白名单（只允许 `default.sh`，防止路径穿越）
   - 大小 ≤ 512KB、内容非空（**在后端按文件大小判断，不按参数长度**）
   - 校验通过 → `mkdir -p` 目标目录 → 从临时目录 `mv` 覆盖 → `chmod 755` → 清掉临时目录
4. 成功 → 按钮变「已上传」、清理变可用、toast「已上传 default.sh」。
5. 失败 → toast 具体原因（磁盘满、无权限等），按钮状态不变。
6. **覆盖不是错误**：目标已有 `default.sh` 时直接覆盖（决策 #2），后端**不返回"已存在"**
   ——真返回了说明实现写成了"新建"语义，属 bug。清理掉的空目录、并发上传同一 tab 都走
   `mv` 覆盖，最后落盘的总是最后一次点击的内容。

### 4.2 清理
1. 点「清理」→ 二次确认 → 确认后调 `clean_default <tab>`。
2. 后端删除 `default.sh`（**只删这一个文件**，不要 `rm -rf` 目录，目录里的其它东西
   可能不是我们放的；若目录空了可以顺手 `rmdir`，失败忽略）。
3. 成功 → 按钮回到「上传」、清理禁用、先 toast 演示原文
   「已清理「<tab 中文名>」的 default.sh，可重新上传」，**再追加一条 warn toast**
   「已删除默认门户，标记为"默认"的区域将回退到 openNDS 官方页面」（原因见 §8 第 2 条）。

### 4.3 公平使用策略的校验（点「应用」时）
| 情况 | 提示 |
|---|---|
| 选「限速」但速率为空 | 「请填写速率」 |
| 速率为 0 或负数 / 非整数 | 「速率必须是大于 0 的整数」 |
| 速率超过 10000000（10 Gb/s，明显手误） | 「速率过大，请检查单位是否为 Kb/s」 |
| 选「取消认证」 | 不校验速率（值为空也无所谓，写 0） |

### 4.4 保存 / 应用
- 「保存」：把 `{uploadAction, uploadRate, downloadAction, downloadRate, activeIface}`
  序列化成前端快照，toast「设置已保存（尚未生效，请点击应用）」。
  **不写任何文件、不发任何请求。**
  > 快照里**不放三个 tab 的上传态**：上传/清理是即时动作、不参与保存与应用（决策 #3）。
  > 一旦把它算进快照，"先保存 → 再上传或清理 default.sh → 点应用"就会被
  > 「当前设置尚未保存」无故拦住，而用户其实没改任何需要应用的设置。
- 「应用」：
  1. 快照不存在或当前状态 ≠ 快照 → toast「当前设置尚未保存，请先保存后再应用。」并中止。
     页面加载时会按决策 #11 用当前配置初始化快照，所以"快照不存在"只在 `status`
     读取失败、页面没拿到初值时才出现，同样按未保存中止。
  2. 校验 FUP（§4.3）。
  3. 调后端 `apply`，参数：四个 FUP 字段 + `gatewayinterface`。
  4. 后端写 uci → `uci commit opennds` → `/etc/init.d/opennds restart` →
     轮询确认服务真的就绪（`pidof opennds` 有值 **且** `ndsctl status` 能成功，最多 15 秒、30 次 × 0.5 秒）才算成功——只看 `pidof` 会把"刚拉起来就因配置错误退出"误判成成功。
  5. 成功 → toast「设置已应用」；失败 → 把后端 `error` 原样 toast（err 样式）即可，
     不要再叠一条自定义提示——后端那句已经是「配置已写入，但 openNDS 未能启动，请检查日志」。
- 应用成功后再取一次快照（否则用户再点应用又会被"未保存"拦住）。

---

## 5. 数据来源映射

| 页面数据 | 来源 |
|---|---|
| 三个 tab 的已上传状态 | `[ -f /usr/lib/opennds/cpd/default/<tab>/default.sh ]` |
| 上传/清理目标目录 | `cpd/default/{wireless,wired,blacklist}/` |
| FUP 上传动作 | `uci -q get opennds.@opennds[0].fup_upload_throttle_rate`；0/空 → 取消认证，>0 → 限速 |
| FUP 下载动作 | 同上，`fup_download_throttle_rate` |
| 当前接管接口 | `uci -q get opennds.@opennds[0].gatewayinterface`，空则默认 `br-lan` |
| 接口卡片列表 | `ip -4 -o addr show`，取每行 `$2` 为接口名、`$4` 去掉 `/前缀` 为 IP；同名接口只取第一条 IPv4 |
| 接口高亮 | 配置值是设备名 → 直接比；配置值对不上任何卡片（含有人手工把配置写成 network section 名的情况）→ 试着用 `uci -q get network.<值>.device` 换成设备名再比，只为容错高亮、**不反写配置**；还换不出来就**不高亮任何卡片**，并在网格上方补一行**纯文字提示**（不是卡片、不可点、没有 `aria-pressed`）：「当前配置的接口「<值>」不在本机接口列表里，点击下方任一接口即可切换」。别把它做成一比一复刻的卡片：那张"卡"一旦能点，就会把 `gatewayinterface` 写成 `lan` 这种 section 名，正是 §1 要避免的 |

---

## 6. 后端 API（`opennds-cpd-api.sh settings …`）

POSIX sh，输出 JSON（成功 `{"ok":1,…}` / 失败 `{"ok":0,"error":"…"}`，信封统一见《整包集成与打包.md》§12）。
本页 page 名固定 `settings`。

| 子命令 | 参数 | 返回 |
|---|---|---|
| `status` | — | `{"ok":1,"enabled":1,"portals":{"wireless":true,"wired":false,"blacklist":false},"fup":{"upAction":"limit","upRate":2048,"downAction":"reject","downRate":0},"iface":"br-lan","ifaces":[{"name":"br-lan","ip":"192.168.1.1"}]}` |
| `upload_begin` | `<id>` | `{"ok":1}`，建 `/tmp/zone_up/<id>/`（已存在则清空重建） |
| `upload_default` | `<wireless\|wired\|blacklist> <id>`（文件已由前端写到 `/tmp/zone_up/<id>/default.sh`） | `{"ok":1}`；失败 `{"ok":0,"error":"…"}` |
| `clean_default` | `<wireless\|wired\|blacklist>` | `{"ok":1}` |
| `apply` | `up_action up_rate down_action down_rate iface` | `{"ok":1,"restarted":1}` |

实现要点：
- tab 参数只接受三个固定值，其它一律拒绝（防目录穿越）。
- `id` 只接受 `[A-Za-z0-9]`（区域识别页生成的那套格式）；只在该 id 的临时目录里找 `default.sh`，
  路径自己拼，**绝不接受前端传来的路径**。
- 临时目录 `rm -rf` 之前先确认它在 `/tmp/zone_up/` 下且 id 合法，别把 `$id` 直接拼进 `rm -rf` 路径。
- 写文件用 `umask 022` + 临时文件 `default.sh.tmp` + `mv`，避免 openNDS 正好在 source
  时读到半截文件。
- `apply` 里 `up_action=reject` → 写 `0`；`limit` → 写速率值。写之前校验是纯数字。
- 重启后就绪检查：`pidof opennds` 有值 **且** `ndsctl status` 能成功，最多等 15 秒（30 次 0.5 秒），等不到就返回
  `{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}`（与其它页同一句，前端原样 toast）。
- 不写 `/etc/config/opennds` 的其它任何键。

---

## 7. 实现质量要求

1. shell 过 `sh -n`；JS 过语法检查；JSON 可解析。
2. 冒烟测试（stub `uci` / `ip` / `init.d/opennds`）：
   - 三个 tab 的已上传状态各自独立、刷新后正确；
   - 上传非 `.sh`、非 `default.sh` 被前端拦；后端直调也被拦；
   - 上传后文件存在、权限 755、内容逐字节一致；
   - 清理只删 `default.sh`，同目录其它文件不动；
   - FUP 0 → 取消认证、2048 → 限速 2048，双向映射都对；
   - 选「取消认证」时速率行隐藏但输入值保留；
   - 未保存直接点应用 → 被拦且无请求；
   - 切换接口后 uci 值正确、重启被调用；
   - 配置被手工写成 section 名（`lan`）时，卡片按 `network.lan.device` 换算出 `br-lan` 并高亮；
     本页自己**永远只写设备名**。
3. busybox ash 坑：管道内 while 是子 shell；`$'\n'` 不可用；`$(())` 前导零按八进制
   （端口/速率先 `sed 's/^0*//'`）。
4. 界面文案中文，样式（卡片、tab、栅格、弹窗、toast）照搬演示 CSS。
5. rpcd ACL 需放行：`opennds-cpd-api.sh` 执行、`/etc/config/opennds` 读写、
   `cpd/default/` 目录的 read/list/write。
6. **并发**：`apply` / `upload_default` / `clean_default` 入口都先按《整包集成与打包.md》§11.3
   取全局锁（`exec 9>` + `flock -n 9`），抢不到返回 `{"ok":0,"busy":1}`；`status` 只读、不加锁。

---

## 8. 与其它页面的关系（必须在开发时守住）

1. **与「区域识别」页不重叠**：区域页管 `cpd/wireless/<SSID>/` 和 `cpd/wired/<接口>/`
   里的**区域专属门户**（且有自己的 `+1` 改名映射、多门户列表、应用态）；本页只管
   `cpd/default/<类型>/default.sh` 这一份**全局兜底**。本页不提供"多门户选择"，
   也不写 `.portal_map`。
2. **与「区域识别」页的"设为默认"是同一份文件**：区域页标记某区域为默认时，
   分发脚本直接跳到本页上传的 `cpd/default/wireless/default.sh`。所以本页删掉
   `default.sh` 后，所有"设为默认"的区域会退到官方 `theme_click-to-continue-basic.sh`——
   这是允许的，但要在清理确认框之后追加一条 warn toast：
   「已删除默认门户，标记为"默认"的区域将回退到 openNDS 官方页面」。
3. **与「客户端黑名单」页共用 `blacklist` tab**：本页「黑名单」tab 上传的就是
   黑名单页下拉框里的「默认门户」。黑名单页只读不写它。
4. **与「概览」页编辑弹窗的红色警告对应**：概览页提示"设置完流量配额后需要到设置页
   公平使用策略里设置限速，否则流量耗尽将会被取消认证"——说的就是本页 §3.3。
   FUP 值为 0（取消认证）时，那句话描述的行为才会发生。
5. **后端仍是唯一一个 `opennds-cpd-api.sh`**，本页第一参数固定 `settings`；
   禁止另建 `settings-api.sh`。菜单与 ACL 全包共用
   `luci-app-opennds-cpd.json`。

---

## 9. 保存/应用 全局红线（与其它页一致）

任何页面的「保存」都不得写入会被 openNDS 或分发脚本运行时读取的配置
（`/etc/config/opennds`、`zone_blacklist`、`cpd/**` 下的门户文件）。
允许写的只有两类：① 纯暂存缓存 `zone_detect`（无运行时读取者）；
② 前端内存快照（不碰文件）。

**本页的唯一例外**：门户的「上传」「清理」是**即时动作**，不是"保存"。
它们直接写 `cpd/default/`，因为分发脚本每次请求现读文件，不存在"保存后被开机
被动生效"的问题——文件生效的时刻就是用户点上传的那一刻，这正是演示的行为。
除此之外，FUP 与接口配置必须走「应用」。
