# Walled Garden · LuCI 页面开发提示词

> 本文档是 openNDS LuCI 插件中「Walled Garden（围栏花园 / 域名白名单）」页面的完整开发规格。同目录 `WalledGarden.html` 是**界面事实源**：界面形态（有哪些控件、按钮、文案怎么写）以它为准；功能行为、数据来源、边界条件、异常处理以本文档为准，演示里的模拟数据不代表真实取值。


> 与《区域识别》《OpenNDS概览》《客户端会话管理》《客户端豁免管理》《客户端黑名单》《路由器访问》各提示词同属一个插件包，后续把所有提示词 + 演示 HTML 一起交给开发者整包开发。合并约定见文末「集成说明」。

---

## 1. 任务总述与页面定位

Walled Garden = 让**未认证**客户端在弹出门户之前就能访问指定的域名 / IP / 端口。页面管理 openNDS 的两条 Walled Garden 实现路径，各对应一个区块：

1. **手动**：维护 `list preauthenticated_users` 的 allow 规则。规则里的域名是**原样写进 nft 命令**的，由 nft 在插入时自己解析：多 IP 域名 nft **只取第一个地址**（并打一条 `Hostname resolves to multiple addresses, only using the first one` 的 warning），域名解析不出来则这条 `nft` 命令直接失败、该条规则没建上。所以**手动区的域名必须只对应一个 IP**，CDN 类多 IP 域名要么只通其中一个 IP、要么整条不生效——正是自动区存在的理由。不需要任何额外依赖包。
  - 连带的运维坑：nft 在 openNDS 启动建链时才解析域名，**开机时 DNS 还没就绪就会 `Could not resolve hostname` 并跳过该条规则**，链建完了也不会补。所以手动区能写 IP 就写 IP；写域名的规则，重启后要实际测一下放行是否还在（这也是自动区用 dnsmasq 动态维护 nftset 更稳的原因）。
2. **自动**：维护 `list walledgarden_fqdn_list` + `list walledgarden_port_list`（Autonomous Walled Garden）。依赖 **dnsmasq-full（支持 nftset）**：域名解析出的所有 IP 由 dnsmasq 动态塞进 `walledgarden` nftset，支持 CDN 类多 IP 域名。

**上游依据**（随包配置 L781–841、`libopennds.sh`）：

- 手动规则建在 `ndsNET` 链（`libopennds.sh:1884`），verdict 只认 `allow`/`passthrough`（→accept）、`block`（→drop）。
- 「An fqdn can be used in place of an ip address (but the fqdn must have only one possible ip address)」——手动区单 IP 限制的出处。
- 自动模式：「If walledgarden_port_list is NOT specified, then Walled Garden access is granted for all protocols (tcp, udp) on ALL ports」；「If walledgarden_port_list IS specified … Specified port numbers apply to ALL FQDNs」——端口作用于**全部域名**（这是"全匹配"的原意），端口留空 = 全协议全端口。
- ⚠️ **但填了端口之后只放行 TCP**，不是"不分协议"。`libopennds.sh:1505-1516` 两个分支：
  ```sh
  if [ -z "$ports" ]; then                                  # 端口留空
      nft insert rule ip nds_filter ndsNET counter ip daddr "@walledgarden" accept
  else                                                      # 端口非空
      nft insert rule ip nds_filter ndsNET counter ip daddr "@walledgarden" tcp dport {"$ports"} accept
  fi
  ```
  端口分支里写死了 `tcp dport`，**UDP 不放行**。所以"不区分 TCP/UDP 协议"这句只在端口留空时成立；填了端口就只对 TCP 生效。这是实现事实（见 §1），界面文案仍按演示原句落地，验收按 §7 第 6 条断言实际 nft 规则。
- 自动模式没有独立的开关键：`main.c:957` 每次启动都无条件执行 `libopennds.sh nftset insert walledgarden`，域名列表为空时规则只是永远不命中。所以本页不需要写任何"启用"选项，§1 的三个键就是全部。
- ⚠️ 上游警告：「Adding port 80 to a walledgarden_port_list can result in the client's built in CPD functionality being defeated and is therefore not recommended.」——手动区写 80 端口同理（HTTP 80 是客户端 CPD 探测通道）。本页对此弹警告但不阻止（决策 #11）。

**本页只允许碰 `opennds.@opennds[0]` 的三个键**：`preauthenticated_users`、`walledgarden_fqdn_list`、`walledgarden_port_list`。不得新建 section、不得重写整个配置文件。

**交付文件**：

```
htdocs/luci-static/resources/view/opennds_cpd/walledgarden.js   # 本页 JS 视图
usr/lib/opennds/opennds-cpd-api.sh                               # 全插件唯一后端脚本（rpcd file.exec，输出 JSON）
```

---

## 2. 已确认决策表（不要再问，直接照做）

| # | 决策点 | 结论 |
|---|--------|------|
| 1 | 配置位置 | 直接写 `/etc/config/opennds` 的 `@opennds[0]`，三键见 §1；不新建插件自有 config |
| 2 | 手动区 ↔ uci | 每行**必须带端口**，展开成 `list preauthenticated_users 'allow … to 目标'`。**带端口必须拆两条**：`端口 目标` → `allow tcp port N to 目标` + `allow udp port N to 目标`；`tcp N 目标` 只出一条 tcp、`udp N 目标` 只出一条 udp。**绝不生成裸目标 `allow to 目标`**，也绝不生成 `allow port N to 目标`——前者在 openNDS 里会退化成无条件全放行，后者会把端口吃掉变成全端口放行，原因见 §5.2 的红字 |
| 3 | 协议位 | 只认 `tcp` / `udp`（大小写不敏感）。**占位符第 2 行 `tcp/udp 663 example.com` 是说明性写法**：这里的 `/` 读作"或"，意思是"想带 tcp 就写 `tcp 663 …`，想带 udp 就写 `udp 663 …`"，它不是可输入的字面量；真把 `tcp/udp` 当协议输进去 → 报格式错误。两个协议都要就走 `端口 目标` 那一档（自动出两条）。`all` / `both` / `tcp,udp` 同样拒绝。与路由器访问页口径一致 |
| 4 | 不支持写法 | 只写目标不带端口（`example.com` / `192.168.1.10`）、端口段（`8000-8100`）、CIDR、IPv6、通配符域名（`*.example.com`）、带协议无端口（`tcp example.com`）、协议前缀（`http://`）、路径。全部按格式错误拒绝 |
| 5 | 单 IP 校验 | **不校验**。页面不解析域名，照常写入。真实后果：多 IP 域名 nft 只取第一个地址（rule 生效、只覆盖一个 IP，其余 IP 不通），解析失败的域名该条 `nft` 命令报错、规则不建。靠区块描述文案提醒用户去用自动区，别在插件里造 DNS 查询（§1 第 1 条） |
| 6 | 保存 / 应用 | **「保存」= 前端内存快照，不碰任何文件**；「应用」= 校验 → 写三个键 → commit → 重启 openNDS。唯一数据源是配置文件，不另存原文。全局红线见 §8 第 6 条（防"保存后未应用、断电重启被动生效"漏洞） |
| 7 | 快照守卫 | 照演示：编辑中点保存/应用 → 拦截；应用时当前内容 ≠ 最后保存的快照 → 拦截「当前配置尚未保存，请先保存后再应用。」；页面加载时快照 = 当前 uci 内容，未修改可直接应用 |
| 8 | 校验时机 | 「保存」不校验（照演示，提示"尚未生效"）；**「应用」时后端整体验证**：任何非法行整次拒绝（不写任何键），toast 报「第 N 行：原因」 |
| 9 | 加载时反解析 | uci 原生条目 → 简写（§5.5）。反解析不了的条目（`block …`、`passthrough …` 等）**原样作为一行显示**，用户应用时按格式错误拒绝，由用户删掉或改对 |
| 10 | 去重与归一化 | 展开结果精确匹配去重（不做子串去重）；域名统一转小写；端口去前导零后十进制比较（防 ash 八进制陷阱）；自动区端口去重 |
| 11 | 80 端口警告 | 手动规则或自动端口里出现 **80** → 应用成功后附加 warn 提示（上游 CPD 击穿警告），**不阻止写入** |
| 12 | dnsmasq 依赖探测 | 打开页面时后端按 §6.4 探测能力，返回 `wg_mode`：`nftset` 可用 / `ipset` 旧式回退可用 / `none` 不可用。只有 `none` 才挂「自动模式不可用」警告条，`ipset` 挂轻警告。**仍可编辑保存** |
| 13 | 应用 = 重启 | 两类规则都是 openNDS 启动时读取（手动建 ndsNET 链、自动写 dnsmasq 配置 + nftset），应用必须重启 openNDS 才生效 |
| 14 | 编辑器按钮文案 | 列表编辑态按钮是「取消」「**完成**」（照演示，不是"保存"）；底部操作区才是「保存」「应用」 |
| 15 | 一行多端口 | 端口位支持**逗号分隔**（`80,443 example.com`），按书写顺序逐端口展开；`tcp 80,443 …` 只出 tcp。**只认逗号**，空格仍是"端口 / 目标"的分隔符，`80 443 example.com` 当格式错误拒绝（避免歧义）。同一行里重复的端口去重 |

---

## 3. 页面布局（版式与交互照演示，功能与边界按本文档）

### 3.1 整体框架
- **页面样式与其它页不同**：灰底（`#eef1f4`）+ 居中白色圆角卡片 `.sheet`（max-width 980px、1px 边框、8px 圆角），照演示 CSS 实现，不要套用路由器访问页的纯白布局。
- 页头 `.topbar`：H1「Walled Garden」+ 灰字 `openNDS · 域名白名单`；描述照抄演示：「为未认证客户端放行指定域名或地址。手动模式要求每个域名仅对应一个 IP；自动模式支持多 IP 域名（如 CDN）。」——演示最后那句"以下为前端布局与交互演示"是演示自用，真页面去掉。
- 手动区与自动区之间 `hr.divider`（1px `--line-soft`）。
- 底部 `.action-bar`：右对齐「保存」（普通）+「应用」（primary）两按钮，顶部分割线、`#fbfcfd` 背景。

### 3.2 手动区块
- H2「手动」+ 灰字 `Manual`；描述「可以添加域名，但是添加的域名必须只有一个 IP，否则规则将不会被应用。」照抄。
- 「编辑」按钮（铅笔图标，`aria-expanded` / `aria-controls` 联动）。
- **展示态**：标签「规则列表」+ 说明「**每条配置必须包含 IP/域名 端口，不能只写域名或者IP。**」照抄 + 只读展示区 `.viewer > pre`（`#f5f7f9` 底、内阴影、等宽 13.5px、`white-space:pre-wrap`、`aria-live="polite"`），逐行显示当前文本；内容为空则不渲染 viewer。
- **编辑态**：`textarea`（max-width 600px、min-height 132px、可拉伸、等宽 13px、`spellcheck="false"`），占位符**两行**照抄：
  ```
  663 example.com
  tcp/udp 663 example.com
  ```
  进入编辑态预填当前文本、聚焦。按钮行「取消」「完成（primary）」。
  - **占位符第 2 行读法**（决策 #3）：`tcp/udp` 的 `/` 是"或"，不是可输入的字面量，它只是告诉用户"协议位能写 tcp 或 udp"。用户真输 `tcp/udp 663 example.com` → 按格式错误拒绝，提示「协议只能是 tcp 或 udp；两个协议都要请直接写 `端口 域名或IP`」。
  - **多端口**（决策 #15：`80,443 example.com` 合法）：界面说明里不展开这条，占位符也不加提示，靠 §5.3 的报错文案在写错时兜住（`80 443 example.com` 会提示「多个端口之间用逗号分隔」）。这是有意为之：文案不动，能力照常支持。
  - **完成**：trim 逐行、去空行、回展示态，toast（ok）「规则列表已更新」。
  - **取消**：丢弃改动回展示态，toast「已取消编辑，未保存本次修改」。
  - 编辑中再点「编辑」→ 仅聚焦 textarea，不重复进入。

### 3.3 自动区块
- H2「自动」+ 灰字 `Auto`；描述两句全部照抄，`<br>` 换行保留：「自动配置需要系统已安装dnsmasq-full，且为支持nftset的dnsmasq。<br>域名与端口为全匹配模式，即一个域名可以匹配多个端口，多个端口也可以匹配一个域名，不区分TCP/UDP协议。」（实施说明：自动区端口分支只生成 `tcp dport`，UDP 不放行是源码事实，见 §1；界面文案按上面两句原样落地，测试断言见 §7 第 6 条。）
- **依赖警告条**（决策 #12）：`status` 返回 `"wg_mode":"none"` 时，在本区描述下方插一条警告（琥珀/红描边样式）：「自动模式不可用：需安装 dnsmasq-full（支持 nftset）。安装后本区配置才会生效。」`"ipset"` 时给一条轻警告「当前走旧式 ipset 回退，建议升级 dnsmasq-full」。警告条只提示，不影响编辑。
- 「编辑」按钮 + 展示/编辑两态，标签「域名列表」、说明「一行一个域名」、占位符 `example.com`；完成 toast「域名列表已更新」。逻辑与手动区完全一致。
- **端口输入框**（编辑态与展示态都显示，不随列表编辑态切换）：
  - label「端口」+ 说明「填写允许访问的端口，多个可用逗号分隔（如 80,443）；留空表示不限制端口。」照抄 + `input#autoPorts`（`class="txt"`，与其它输入框同宽，placeholder「留空表示不限制端口」）。
  - 修改即时进前端 state，随底部「保存」一起进快照。
  - 应用时若**域名列表为空、端口非空** → 写入照旧，但后端在返回里带 `warnings`，前端追加一条 warn toast「域名列表为空，端口设置不会生效」（openNDS 的规则是 `ip daddr @walledgarden tcp dport {…}`，集合空则永不命中）。

### 3.4 底部操作
- 「保存」：
  - 编辑中 → toast（warn）「请先完成或取消列表编辑」，不执行；
  - 否则更新快照 + toast（ok）「配置保存成功（尚未生效，请点击应用）」。
- 「应用」：
  - 编辑中 → 同上拦截；
  - 当前内容 ≠ 快照 → toast（warn）「当前配置尚未保存，请先保存后再应用。」，不执行；
  - 否则发 `apply`（手动文本 + 自动域名 + 端口，均 base64）：
    - 校验失败 → toast（err）逐条「第 N 行：原因」，不写任何东西；
    - 成功 → toast（ok）「配置已应用」（照演示原文，不要自己加"已重启"）；返回里带 `warnings` 时**逐条追加** warn toast，成功 toast **照常显示**——`warnings` 是补充提醒，不是失败的替代文案（口径见《整包集成与打包.md》§12）。两条固定文案：含 80 端口 →「警告：放行 80 端口可能击穿客户端系统的强制门户检测（CPD），上游不建议」；域名列表为空且端口非空 →「域名列表为空，端口设置不会生效」。

### 3.5 toast
- 右下角固定、白底卡片、左侧 3px 色条（默认蓝 / ok 绿 / warn 琥珀 / err 红）、8px 圆角、阴影，3 秒淡出，容器 `aria-live="polite"`。与路由器访问页同款，**不要**复用黑名单页的深色胶囊。

### 3.6 移动端
- 640px 断点：`body` 内边距 14/10、`.sec` 20/16、输入框字号 16px（防 iOS 聚焦缩放）、`.txt` max-width 100%、`.ab-right` 占满且按钮均分。照演示 CSS。

---

## 4. 数据来源与显示来源

| 页面数据 | 来源 |
|---|---|
| 手动区文本初值 | `uci -q show opennds.@opennds[0].preauthenticated_users` 全部 list 值（保持顺序）→ §5.5 反解析 |
| 自动域名初值 | `uci -q show opennds.@opennds[0].walledgarden_fqdn_list` → 逐条一行 |
| 自动端口初值 | `uci -q show opennds.@opennds[0].walledgarden_port_list` → 逗号连接（空 = 输入框留空） |
| dnsmasq 探测 | §6.4 能力探测，`status` 返回 `"wg_mode":"nftset"\|"ipset"\|"none"` |

**显示来源**：会话内显示用户原文（编辑器「完成」后即前端 state）；重新打开页面从 uci 反解析。唯一数据源 = 配置文件，不另存副本（理由同路由器访问页：避免 SSH 等旁路修改后页面显示失真）。

---

## 5. 解析 / 生成规格（本页核心，必须严格照做）

### 5.1 手动区输入语法（逐行；大小写不敏感；多空格/Tab 视为一个分隔符）

```
line     := portlist SP target        # 只写端口：每个端口 tcp + udp 各一条
          | proto SP portlist SP target  # 指定协议：每个端口一条
proto    := "tcp" | "udp"             # tcp/udp 是"或"的说明写法，不是字面量
portlist := port ("," port)*          # 逗号分隔，中间不许有空格
port     := 1..65535 的十进制整数（去前导零后比较）
target   := 域名 | 点分四段 IPv4
```

- **端口必填，没有"只写目标"这一档**。`allow to X` 在 openNDS 里会退化成无条件全放行（§5.2），所以入口直接堵死：只写域名或 IP 就是格式错误。想放行整站只能逐行写端口（openNDS 不支持端口段，多端口写多行）。
- 域名部分转小写后校验；不允许 `*`、`/`、`:`、`http://` 前缀、路径、空格；单段 ≤63、总长 ≤253。
- IP 只允许 `[0-9.]`，四段各 0–255。
- 明确不支持：`tcp/udp`（说明性写法，输入即报错）、`all`、`both`、端口段、CIDR、IPv6、带协议无端口、`block`（页面只生成 allow；用户手输 block 在应用时被 §5.3 拒绝——它属于反解析保留的原文，见 §5.5）。
- 空行忽略；行首尾 trim；`\r\n` 接受。

### 5.2 手动区展开规则（简写 → uci 条目）

| 输入 | 展开 |
|---|---|
| `663 example.com` | `allow tcp port 663 to example.com`<br>`allow udp port 663 to example.com`（**两条**） |
| `80,443 example.com` | 四个端口条目按书写顺序展开：tcp 80、udp 80、tcp 443、udp 443（**四条**，openNDS 只认单端口，逐个 `add_list`） |
| `tcp 80,443 example.com` | `allow tcp port 80 to example.com`<br>`allow tcp port 443 to example.com`（**两条**，只 tcp） |
| `tcp 443 example.com` | `allow tcp port 443 to example.com` |
| `udp 8020 112.122.123.124` | `allow udp port 8020 to 112.122.123.124` |
| `tcp/udp 663 example.com` | ❌ 报错：`/` 只是"或"的说明写法（决策 #3） |
| `example.com` / `192.168.1.10` | ❌ 报错：必须写端口（理由见下面第一条红线） |

- 🔴 **红线一：永远不要生成 `allow to X`（只写目标）**。`create_client_ruleset()`
  （`libopennds.sh:1774-1948`，判断目标的 `$to` / `$from` 那几行在 1838）里判断目标用的是 `$to` / `$from` 两个**从未赋值的变量**
  （真正存方向的是 `$to_from`）：
  ```sh
  if [ "$to" = "to" ] || [ "$from" = "from" ]; then   # $to/$from 永远是空
      ipaddr=$param
  fi
  ```
  所以 `allow to example.com` 拿不到 `ipaddr`，落到 nft 上是
  `nft insert rule ip nds_filter ndsNET index 2 counter accept`——**没有 daddr，
  等于给所有未认证客户端开了全外网全端口**。这就是本页强制"必须带端口"的原因。
  对比 `allow all to X`（多一个 `all`）能正确走到 `count=3` 分支拿到 `ipaddr`，
  但页面不需要它，因为端口必填的写法本身就带 `to` + 端口，走的是安全路径。
- 🔴 **红线二：永远不要生成 `allow port N to X`（无协议带端口）**：
  ```sh
  if [ "$proto" = "all" ] || [ -z "$proto" ] || [ "$port" != "port" ]; then
      proto=""; sdport=""; portnum=""
  fi
  ```
  协议为空时 `portnum` 被一并清空，`allow port 663 to X` 变成
  `ip daddr X counter accept`——**端口丢了，整站全端口放行**。所以"两个协议都要"
  只能拆成 tcp + udp 两条。
- 🔴 **红线三：协议位必须白名单校验后再小写化，绝不原样透传**：`libopennds.sh`
  的 `count=1` 分支是**严格区分大小写**的 `case`（`"tcp")` / `"udp")` / `"all")`），
  不认识的值走 `*) ;;` 被**静默忽略**，`proto` 保持空 → 又踩中上面那条
  `[ -z "$proto" ]` → `portnum` 清空。更糟的是指针也跟着错位：`allow TCP 443 X`
  里 `443` 落到 `count=2` 的"占位"位置（那里只有 `$port = "port"` 才赋 `portnum`），
  `X` 又因为 `to_from` 一直是空、拿不到 `ipaddr`。两者一起丢，最终生成
  `nft insert rule ip nds_filter ndsNET index 2 counter accept`——**连目标都没了，
  是所有外网地址、所有端口全放行**，比只写目标还宽。`udp6 443 X`、`icmp 443 X`、
  `TCP 443 X` 都是这个结果。前端必须只接受归一化后的 `tcp` / `udp` 两种字符串，
  其它一律在应用前报错拒绝（不能"先写进去再说"）。
- 顺序：uci 按输入行顺序 `add_list`，反解析也按 uci 顺序读回，两边一致。但**运行时链内顺序是反的**：`libopennds.sh` 对 `ndsNET` 用 `nft insert rule … index 2`，后插的排在前面，所以 uci 里 `A、B、C` 在链里是 `C、B、A`。本页只生成 `accept`，反序不影响结果；但别在注释或文档里承诺"链内顺序与输入一致"——如果同一目标同时存在手工写的 `block`，谁先命中由这个反序决定（这也是 §5.5 第 5 类条目原样保留、不自动改写的另一个理由）。
- 去重发生在展开之后：`80 example.com` 与 `tcp 80 example.com` 会产生重复的
  tcp 条目，按 §5.4 精确去重合并，只留一条。

### 5.3 校验与错误文案（应用时整次拒绝，返回全部错误行，前端展示第一条并定位）

| 情况 | 提示（拼成「第 N 行：…」） |
|---|---|
| 分词段数超过 3，或段位无法识别 | 「格式不正确，支持 `端口 域名或IP`、`协议 端口 域名或IP`」 |
| 只写目标、没有端口（`example.com`、`192.168.1.10`） | 「必须指定端口：openNDS 里只写目标会变成全端口全协议放行，请写成 `端口 域名或IP`」 |
| 协议不认识（`tcp/udp`、`all`、`both`、`tcp,udp`…） | 「协议只能是 tcp 或 udp；两个协议都要请直接写 `端口 域名或IP`」 |
| 带协议但缺端口（`tcp example.com`） | 「`tcp` / `udp` 后必须跟端口号」 |
| 端口非数字 / 越界 | 「端口必须是数字」 / 「端口必须在 1-65535 之间」 |
| 端口列表有空项（`80,,443`、`80,`、`,443`） | 「端口列表格式不正确，用逗号分隔，如 `80,443`」 |
| 第一段是数字、看着像"空格分隔的多端口"（`80 443 example.com`） | 「多个端口之间用逗号分隔，如 `80,443`」（别回"协议只能是 tcp 或 udp"，那句会把人带偏） |
| 目标缺失（`tcp 443`） | 「缺少域名或 IP」 |
| 域名字符非法 / 超长 / 含通配符或路径 | 「域名格式不正确」 |
| IP 段数 / 数值非法 | 「IP 地址格式不正确」 |

自动区同理：域名行校验复用域名规则（错误行号按域名列表行号），**另外必须拒绝 IP 字面量**——`walledgarden_fqdn_list` 里的地址是靠 dnsmasq 解析域名后动态塞进 nftset 的，写 `192.168.1.10` 或 `2001:db8::1` 不会被解析、永远进不了集合，规则看着配好了却永不命中。提示「自动区只接受域名；IP 请填到手动区」；端口字段非 `数字(逗号/空格分隔)` → 「端口格式不正确，多个用逗号分隔（如 80,443）」。

### 5.4 去重与归一化
- 手动区展开结果精确匹配去重（保留首次出现）；**不做**子串去重。`80 a.com` 会展开出 tcp/udp 两条，再写一行 `tcp 80 a.com` 就与其中 tcp 那条重复，按精确匹配合并成一条。
- 域名统一转小写后写入与比较。
- 同一行内重复端口（`80,80`、`80,080`）先去前导零再数值去重，只展开一次。
- 自动区：域名行小写去重；端口去前导零、数值去重，按输入顺序写 `walledgarden_port_list`（一端口一条 list）。
- 自动区的端口**只对 TCP 生效**（openNDS 生成的规则是 `tcp dport {…}`）：界面文案照演示原句落地，实现与验收以 §1、§7 第 6 条为准。
- `walledgarden_fqdn_list` 一域名一条 list 与上游示例的 `list … 'a.com b.com'`（一条 list 里多个域名）**等价**：`get_list_from_config()`（`libopennds.sh:1077`）把全部 list 元素用空格拼成一个串，再 `for fqdn in $fqdns` 按空格切。本页统一「一条一个」，便于增删和按行反解析。

### 5.5 反解析（uci 原生条目 → 简写，用于页面首次加载）

**手动区**：按 `preauthenticated_users` list 顺序逐条：

1. `allow tcp port N to T` → `tcp N T`；`allow udp port N to T` → `udp N T`。
2. **连续一对** `allow tcp port N to T` + `allow udp port N to T`（同 N 同 T）
   → 合并成一行 `N T`；不成对的保持上一条的单协议写法，不要瞎合并。
3. `allow port N to T`（无协议带端口，历史遗留/手写配置）→ 输出 `tcp N T` 和
   `udp N T` 两行。**必须纠正成两条**：这条规则在 openNDS 里实际跑的是"整站
   全端口放行"，用户看到 `N T` 会以为端口生效了。用户下次点「应用」时就写成
   两条正确的规则，隐患自动消失。
4. `allow to T`（只写目标的旧式规则，本页从不生成，只可能来自手工改配置）→ 按决策 #9 走：
   **原样输出 `allow to T` 一行**，不转成 `T`（`T` 在新语法里非法，转过去只会看到"必须指定端口"，
   反而看不出原文长什么样），应用时报错并整次拒绝。
5. 其它任何写法（`block …`、`passthrough …`、`allow all to X`、带 `from`、缺 `to` 等）→ **原样作为一行输出**（决策 #9：不丢、加载时不拦，应用时按 §5.3 拒绝并报行号）。

**自动区**：`walledgarden_fqdn_list` 逐条一行；`walledgarden_port_list` 各值逗号连接填入输入框；两个 list 都空 = 全空。

### 5.6 应用时的写回

三个键独立处理，每个键都是「先 delete 整个 list，再逐条 `uci add_list`」：

```
uci delete opennds.@opennds[0].preauthenticated_users
uci delete opennds.@opennds[0].walledgarden_fqdn_list
uci delete opennds.@opennds[0].walledgarden_port_list
# 手动区：逐条 add_list 'allow … to …'
# 自动区：逐条 add_list 域名；端口非空时逐条 add_list 端口（留空 = 不写 = 全端口全协议）
```

- **禁止** `uci set` 一把写 list（会降级成单值、静默丢规则）。
- 任一键写入失败 → 备份整体回滚（§6.2），不留部分结果。
- 最后 `uci commit opennds`。

---

## 6. 后端 API 约定（`opennds-cpd-api.sh walledgarden …`）

rpcd `file.exec` 调用，调用形式 `opennds-cpd-api.sh walledgarden <子命令> [参数…]`（本页 page 名固定为 `walledgarden`）；stdout 只输出 JSON（日志走 stderr / `logger`）；错误统一 `{"ok":0,"error":"…"}`（信封见《整包集成与打包.md》§12）。

| 子命令 | 参数 | 返回 | 行为 |
|---|---|---|---|
| `status` | — | `{"ok":1,"enabled":1,"manual":"allow to a.com\ntcp 443 b.com","domains":"a.com\nb.com","ports":"80,443","wg_mode":"nftset"}` | 读 uci + §5.5 反解析 + §6.4 探测 |
| `validate` | `manual_b64=<base64> domains_b64=<base64> ports=<明文>`（三个独立参数，**不要**拼成 `a=…&b=…`，口径见《整包集成与打包.md》§12） | `{"ok":1,"manual_rules":[…],"fqdns":[…],"ports":[…],"port80":0}` 或 `{"ok":0,"errors":[{"line":2,"msg":"…"}]}` | §5.1–5.4 全部校验，不写任何东西 |
| `apply` | 同 validate | `{"ok":1,"restarted":1,"warnings":["80端口…","域名列表为空…"]}`（`warnings` 恒为数组，可为空数组）或 `{"ok":0,"errors":[…]}` 或 `{"ok":0,"error":"…"}` | validate（有错直接返回，不落盘）→ 备份 → 写三键 → commit → 重启 → 校验进程 |

### 6.1 传输编码
两个 textarea 内容统一前端 `btoa(unescape(encodeURIComponent(text)))` → 后端 base64 解码（无 `base64` 工具时依次尝试 `openssl base64 -d`、`uudecode`，都无则 `{"ok":0,"error":"缺少 base64 工具"}`）。解码后各限 64KB。`ports` 参数为明文，仅允许 `[0-9, 空格]` 字符。

### 6.2 写配置与失败处理
与路由器访问页同一套：
1. `mkdir -p /tmp/zone-router`；按《整包集成与打包.md》§11.3 的模板取锁（`exec 9>锁文件` + `flock -n 9`，**不是** `flock -n /path/to/lock`——那种写法没有持锁进程，锁等于没加）。
2. `cp /etc/config/opennds /tmp/zone-router/opennds.bak`。
3. 写 uci；任一步非 0 → **先 `uci revert opennds` 丢掉本次暂存增量** → 再用 `cp /tmp/zone-router/opennds.bak /etc/config/opennds` 放回原位 → **不要再 `uci commit`**（先 commit 会把半成品增量写回刚还原的文件，回滚就白做了）→ `{"ok":0,"error":"写入配置失败，已回滚"}`。
4. `/etc/init.d/opennds restart`；最多 15 秒轮询（30 次 × 0.5 秒），**`pidof opennds` 有值且 `ndsctl status` 能成功**才算就绪。
5. 重启失败 → `{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}`（**不回滚**）。

### 6.3 并发
- 全插件共用 `/var/lock/opennds-cpd.lock`（`flock -n` 非阻塞）：抢不到立即返回 `{"ok":0,"busy":1}`，前端提示「等待上一步完成，请稍候重试」，**不排队、不进入遮罩**。

### 6.4 dnsmasq 能力探测（照上游的判法，别自己发明）

不检查包名（发行版包名多变），直接用 openNDS 自己用的那条命令（`libopennds.sh:1393-1430`）：

```
dnsmasq --version | grep -q ' nftset '   # 支持 nft 集合
dnsmasq --version | grep -q ' ipset '    # 支持旧式 ipset
command -v ipset >/dev/null              # ipset 工具在不在
```

判定：

- 有 `nftset` → `"wg_mode":"nftset"`，可用（推荐路径，OpenWrt 上的 `dnsmasq-full` 就是这样）。
- 没有 `nftset`、但有 `ipset` 且 `ipset` 工具存在 → `"wg_mode":"ipset"`，**仍然可用**（openNDS 会退到旧式 ipset，日志里会 warn "deprecated legacy ipset"）。
- 两条都不通 → `"wg_mode":"none"`，自动区顶部挂警告条「自动模式不可用：需安装 dnsmasq-full（支持 nftset）。」
- `dnsmasq` 不存在 / 命令失败 → 按 `none` 处理。

`status` 每次现算，不缓存到 uci。

> ⚠️ 旧版本这里写的是 `nftset=/wg-probe.invalid/4:198.51.100.1` + `dnsmasq --test`，**这是错的**：dnsmasq 的 nftset 语法是 `/(6|4)#[family#]table#set`（分隔符是 `#`，且必须是"表#集合"，不是 IP），`4:198.51.100.1` 根本不合语法，任何 dnsmasq 跑 `--test` 都会失败，页面会永远提示"自动模式不可用"。别再用 `--test` 造临时配置这条路。

### 6.5 环境兼容
- `uci` 不存在或 `opennds` 配置缺失 → `{"ok":0,"error":"未找到 openNDS 配置"}`；`@opennds[0]` 不存在 → 同样报错，**不要**自动创建 section。

---

## 7. 实现质量要求

- **POSIX sh / busybox**：只用 ash 兼容语法；管道内 `while` 是子 shell（计数/拼串用 `$(…)` 或临时文件回传）；`$'\n'` 不可用；`tr` 不支持 `\xNN`。
- **端口校验**：先字符白名单再比较大小；**先去前导零**再十进制比较（ash `$((0443))` 会按八进制算成 291）。
- **安全**：不 `eval` 拼接用户输入；`add_list` 前转义单引号；域名/IP 严格字符白名单；base64 解码前先查长度。
- **规范**：`uci` 调用带 `-q` 并逐条判断 `$?`；只碰 §1 的三个键，不改其它 option，不 `uci reorder` / `uci rename`。
- **冒烟测试清单**（交付前用 uci/dnsmasq/ndsctl 桩 + 假 `init.d/opennds` 验证）：
  1. `example.com` / `192.168.1.10`（只写目标）→ **整次拒绝**，报「必须指定端口…」；断言库里永远不会出现 `allow to …`；
  2. `663 example.com` → `allow tcp port 663 to example.com` + `allow udp port 663 to example.com`（两条）；断言**结果里不存在** `allow port 663 to …` 这种无协议带端口的写法；
  3. `tcp 443 example.com` / `udp 8020 112.122.123.124` 各出一条；
  4. `tcp/udp 663 example.com` / `all 443 example.com` / `icmp 443 example.com` / `8000-8100` / `*.example.com` / `tcp example.com` / `1.2.3.4/24` 全部整次拒绝且 `line` 正确；**大写协议 `TCP 443 example.com` 不拒**——§5.1 写的是"大小写不敏感"，按小写归一后正常写入，断言 uci 里是 `allow tcp port 443 to example.com`、**绝不会出现 `TCP`**（源码 `case` 区分大小写，原样透传会退化成全放行，红线三要防的正是这个）；
  5. 重复行 / 重复域名 / 重复端口只留一条，域名统一小写（`80 a.com` 与 `tcp 80 a.com` 合并成两条而非三条）；
  6. 端口留空 → `walledgarden_port_list` 被清空（= 全端口全协议）；填 `80,443` → 两条 list；断言实际 nft 规则是 `tcp dport {80,443}`（只有 TCP）；
  7. 手动区空 + 自动区空 → 三个键全部 delete（`preauthenticated_users` 清空后若本插件无其它来源即为空链规则，正常）；
  8. 反解析：`allow tcp port 443 to a.com`→`tcp 443 a.com`；一对 `allow tcp port 663 to b.com` + `allow udp port 663 to b.com`→`663 b.com`；**单独一条** `allow port 663 to c.com`（历史遗留）→`tcp 663 c.com` 与 `udp 663 c.com` 两行；`allow to 1.2.3.4` → 原样显示一行，应用时报「必须指定端口」并整次拒绝；`block tcp port 443 to evil.com` → 原样显示、应用时报该行；
  9. 含 80 端口 → apply 返回 warnings 且正常写入；
  10. 能力探测桩：`dnsmasq --version` 输出含 `nftset` → `nftset`；只含 `ipset` 且 `ipset` 在 → `ipset`；都不含 → `none`；
  11. uci 写入失败 → 回滚后配置逐字节一致；重启后 `pidof opennds` 有值**且** `ndsctl status` 成功才返回 ok；
  12. 编辑中/未保存点保存或应用 → 前端拦截，无网络请求；
  13. 多端口：`80,443 example.com` → 四条（80 的 tcp/udp、443 的 tcp/udp，顺序按书写）；`tcp 80,443 a.com` → 两条 tcp；`80,80` 只出两条；`80,,443` / `80,` / `,443` / `80 443 example.com` 全部拒绝。
  14. **落地校验（重启后真查一遍链）**：`nft list chain ip nds_filter ndsNET` 里必须能看到刚写的规则——手动区断言 `ip daddr <目标>` + `tcp/udp dport <端口>` 都在；自动区断言 `ip daddr @walledgarden` 那条还在。域名解析失败（开机 DNS 未就绪）会表现成"配置写对了但链里没这条"，只看 `pidof` / 返回码查不出来。
  15. **集合非空**：`nft list set ip nds_filter walledgarden` 必须已经含有客户端刚查过的域名解析结果。集合是空的但规则在，等于永远不命中——`dnsmasq` 没加载 `dhcp.nds_walledgarden` 段时就是这样（表现为自动区"配了没用"，手动区正常）。查完域名后仍为空 → `service dnsmasq restart` 再看一次；还是空就说明 `dnsmasq-full` 的 nftset 支持没编译进去，`status` 的 `wg_mode` 字段会是 `ipset`/`none`。

---

## 8. 集成说明（与其它页面合并成完整插件）

1. **rpcd 模式统一**：所有页面后端都是 `file.exec` + JSON；本页沿用同一套 `rc` 包装与错误格式。
2. **菜单 / ACL 合并**：「Walled Garden」作为独立菜单项并入 `luci-app-opennds-cpd.json`；ACL 需含 `/etc/config/opennds` 读写、`opennds-cpd-api.sh` exec。锁文件**不需要**单独的 ACL 条目——脚本以 root 身份在内部持有它（《整包集成与打包.md》§4）。全包只保留一个后端脚本，本页 page 名为 `walledgarden`。
3. **uci 键不重叠**：本页独占 `preauthenticated_users` / `walledgarden_fqdn_list` / `walledgarden_port_list`，与区域识别页（`login_option_enabled` / `themespec_path`）、路由器访问页（`users_to_router*`）、豁免页（`trustedmac` / `preemptivemac`）、会话管理页互不重叠。全插件只有本页写 `preauthenticated_users`。
4. **与分发脚本无关**：Walled Garden 由 openNDS 自身防火墙（ndsNET 链 / nftset）实现，作用在 preauth 阶段；`theme_zone_detect.sh` 无需任何改动，也读不到本页配置。
5. **与豁免 / 黑名单无耦合**：豁免管"跳过认证"、黑名单管"永不认证"、本页管"认证前能访问什么"。被豁免（trusted/preempt）的客户端不经过 preauth 阶段，本页规则对其无意义；被拉黑客户端停在门户，同样只受本页规则影响——三套机制独立，不写跨页钩子。
6. **保存/应用全局红线（防"重启被动生效"漏洞）**：任何页面的「保存」都不得写入会被 openNDS 或分发脚本运行时读取的配置（`/etc/config/opennds`、`zone_blacklist`）。允许写的只有两类：① 纯暂存缓存 `zone_detect`（无运行时读取者，生效完全依赖「应用」阶段的写正式配置动作）；② 前端内存快照（不碰文件）。本页「保存」= 内存快照（②）。「应用」= 校验 → 写正式配置 → commit → 重启 openNDS（是否重启见下条；黑名单页的拉黑流程同样只在「应用」里写 `zone_blacklist`）。任何绕过「应用」直接写正式配置的路径都视为实现错误——否则用户保存后未应用就断电/重启，配置会在开机时被动生效。
7. **「应用」语义**：各页点应用 = 写配置 + commit，**是否重启按操作类型决定**，不要一刀切（重启会踢掉全站在线客户端，能免则免）：必须重启的是改全局参数（`gatewayinterface`、FUP 限速速率、全局超时）、改已在线客户端的 per-client 限制参数、**拉黑**（名单变更后要让主进程重建 nft 链）；不必重启的是增删 `trustedmac` / `preemptivemac` 条目（`trustedmac` 配合 `ndsctl trust/untrust` 即时同步；`preemptivemac` 需在 commit 后主动调一次不带参数的 `libopennds.sh preemptivemac`，主进程那轮 `preemptivemac quiet` 在 10.x 脚本里不解析名单）、门户选择（运行时读文件）。**本页必须重启**：`preauthenticated_users` / `walledgarden_*` 只在启动时用来建 nft 规则，运行时不重读。⚠️ 若 openNDS 处于停用状态（`enabled=0`），先按《整包集成与打包.md》§11.1 弹确认，确认后再顺手 `enabled=1` 并重启（否则轮询 `pidof` 会白等满 15 秒后报失败，而配置其实已写入）。（`allow_preemptive_authentication` 只归「客户端豁免管理」页管，本页与其它页都不要读写它。）
8. **与路由器访问页的语法口径一致**：两页都是"协议 + 端口"的简写语法，都不接受 `tcp/udp` 字面量——`/` 只是"或"的说明写法（决策 #3，路由器访问页决策 #6 同）。占位符里出现 `tcp/udp` 是给用户读的，不是能敲进去的语法；两页解析器可以共用同一套分词与校验逻辑，别各写一份。
