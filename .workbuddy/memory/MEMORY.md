# OpenNDS LuCI 插件 · 项目长期约定

## 1. 演示与文档的关系（用户定调，最高优先级）

- `汇总/*/*.html` 是**用户手改的 UI 事实源**，助手**只读不改**，任何改动都必须由用户自己做。
- **开发文档永远围绕演示 HTML 和操作逻辑来写**。演示变了，文档跟着改；不是让演示迁就文档。
- **禁止**说「演示没有画」「演示未体现」「演示与文档对不上」这类话，也不要把这类对比写进文档正文。文档直接陈述要求即可。
- 发现演示与源码行为不一致时，只在回复里说明事实，由用户决定改不改 HTML。

## 2. 事实判断必须查证

涉及 openNDS 行为的结论，必须查 `opennds`（配置）、`sh/` 脚本、openNDS 源码（`src/auth.c`、`fw_iptables.c`、`conf.c`、`main.c`、`init.d/opennds`）或官方文档，不允许凭印象。流程要自己模拟跑一遍（写 Python/shell 脚本复现）再下结论。

## 3. 交互约定

- 提问一个一个来，不要一次抛多个待定项。
- 用大白话解释，例子单独框出来（`> 📌 例子`），框外是解释。

## 4. 定名（不变）

- 包名 `luci-app-opennds-cpd`
- 后端脚本 `/usr/lib/opennds/opennds-cpd-api.sh`（唯一，argv[1]=页面名）
- 视图 `view/opennds_cpd/{overview,zone,session,exempt,blacklist,router,walledgarden,settings}.js`（8 个）
- 门户库 `/usr/lib/opennds/cpd/{wireless,wired,blacklist}/` + `cpd/default/*/default.sh`
- 分发脚本 `theme_zone_detect.sh`
- 黑名单配置 `/etc/config/zone_blacklist`
- 区域缓存 `/etc/config/zone_detect`（键 `scope` / `wireless` / `wired` = 区域识别页，`session_scope` / `session_snapshot` = 会话页；`zone_markers` 是 `/usr/lib/opennds/zone_markers` 文件，不是 uci 键）
