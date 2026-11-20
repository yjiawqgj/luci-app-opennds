#!/bin/sh
# t10：分发脚本的黑名单分支 + 全局门户分支（真正执行拦截/分发的地方）
#
# 黑名单（openNDS 9.4 起废弃 macmechanism/blockedmaclist，主进程不再自己拦 MAC，
# 拦截完全靠 theme_zone_detect.sh：命中 blockedmac 的客户端不出示区域门户，
# 只出示黑名单门户，因此它拿不到"继续"按钮，一直上不了网）：
#   兜底链：① zone_detect.main.portal_blacklist_sel（黑名单页选的，cpd/blacklist/）
#           ② 兼容上一版构建的旧键 portal_blacklist（也是 cpd/blacklist/）
#           ③ 设置页「默认门户-黑名单」portal_blacklist 管的 cpd/default/blacklist/
#           ④ 内置 cpd/default/blacklist/default.sh
#
# 全局门户（zone_detect.main.scope = global，区域识别关闭）：
#   zone_detect.main.portal_global（cpd/global/<名>）→ cpd/global/default.sh
#   → 什么都找不到就不提供任何门户（2026-11-20 用户定稿：绝不回落内置主题）；
#   黑名单客户端在全局模式下仍走黑名单分支（优先级更高）。
. "$(dirname "$0")/lib.sh"
tmp_setup t10

THEME_SRC="$REPO/luci-app-opennds-cpd/root/usr/lib/opennds/theme_zone_detect.sh"
TS="$S/theme.sh"
cp "$THEME_SRC" "$TS" || exit 1

# 把脚本里的绝对路径指向沙箱
sed -i \
	-e "s#^CPD_ROOT=.*#CPD_ROOT=\"$S/cpd\"#" \
	-e "s#^MARKERS=.*#MARKERS=\"$S/markers\"#" \
	-e "s#^ZONE_DETECT_CONFIG=.*#ZONE_DETECT_CONFIG=\"$ZONE_DETECT_CONFIG\"#" \
	"$TS"

mkdir -p "$S/cpd/blacklist" "$S/cpd/default/blacklist" "$S/cpd/global"
printf '#!/bin/sh\nuserinfo="blacklist-portal"\n' >"$S/cpd/blacklist/my.sh"
printf '#!/bin/sh\nuserinfo="blacklist-page2"\n' >"$S/cpd/blacklist/other.sh"
printf '#!/bin/sh\nuserinfo="blacklist-default"\n' >"$S/cpd/default/blacklist/default.sh"
printf '#!/bin/sh\nuserinfo="bl-default-sel"\n' >"$S/cpd/default/blacklist/sel.sh"
printf '#!/bin/sh\nuserinfo="global-my"\n' >"$S/cpd/global/my.sh"
printf '#!/bin/sh\nuserinfo="global-default"\n' >"$S/cpd/global/default.sh"

# opennds 配置：拉黑 11:22:33:44:55:66
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'aa:bb:cc:dd:ee:01\n22:33:44:55:66:77' >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"

run_theme() { # $1=clientmac → 输出 "zone_type|portal"
	(
		ndspid=1
		. "$TS" >/dev/null 2>&1
		# 真机顺序（libopennds.sh）：source 分发器时 clientmac 还没解析
		#（FAS 查询串在 source 之后才由 get_arguments 解析）；header() 是
		# 分发发生的最早时机，决策全部在其调用期执行。这里按真机顺序模拟：
		# source（clientmac 未设）→ 赋值 clientmac → 调 header 触发分发。
		clientmac="$1"
		header >/dev/null 2>&1
		printf '%s|%s\n' "$zone_type" "$portal"
	)
}
bl_clear() { # 清掉三个选择键
	uci -q delete zone_detect.main.portal_blacklist_sel >/dev/null 2>&1
	uci -q delete zone_detect.main.portal_blacklist >/dev/null 2>&1
	uci -q delete zone_detect.main.portal_blacklist_sel_x >/dev/null 2>&1
	uci -q delete zone_detect.main.portal_global >/dev/null 2>&1
	rm -rf "$MOCK_UCI_DELTA"
}

echo "== C1 拉黑 + 黑名单页已选门户 portal_blacklist_sel =="
bl_clear
uci set zone_detect.main.portal_blacklist_sel=my.sh >/dev/null 2>&1
r=$(run_theme 'AA:BB:CC:DD:EE:01')
ck "黑名单页选中项生效" "blacklist|$S/cpd/blacklist/my.sh" "$r"

echo "== C2 反向大小写同样命中 =="
r=$(run_theme 'aa:bb:cc:dd:ee:01')
ck "客户端小写也命中" "blacklist|$S/cpd/blacklist/my.sh" "$r"

echo "== C3 只留旧键 portal_blacklist（兼容上一版构建） =="
bl_clear
uci set zone_detect.main.portal_blacklist=other.sh >/dev/null 2>&1
r=$(run_theme '22:33:44:55:66:77')
ck "旧键兜底仍指向 cpd/blacklist/" "blacklist|$S/cpd/blacklist/other.sh" "$r"

echo "== C4 两键皆无 + 设置页选了默认黑名单门户 =="
bl_clear
uci set zone_detect.main.portal_blacklist=sel.sh >/dev/null 2>&1
r=$(run_theme 'aa:bb:cc:dd:ee:01')
ck "回落设置页默认黑名单门户" "blacklist|$S/cpd/default/blacklist/sel.sh" "$r"

echo "== C5 全都没有 → 内置 default.sh =="
bl_clear
r=$(run_theme '22:33:44:55:66:77')
ck "回落到 cpd/default/blacklist/default.sh" "blacklist|$S/cpd/default/blacklist/default.sh" "$r"

echo "== C6 未拉黑客户端不受影响 =="
r=$(run_theme 'aa:bb:cc:dd:ee:ff')
case "$r" in
	blacklist*) echo "  FAIL 未拉黑客户端被当成了黑名单"; echo "       实际: $r"; fail=1 ;;
	wireless*|wired*) echo "  OK   未拉黑客户端照常走区域识别（$r）" ;;
	*) echo "  OK   未拉黑客户端未进黑名单分支（$r）" ;;
esac

echo "== C7 名单为空 =="
printf '' >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"
r=$(run_theme '11:22:33:44:55:66')
case "$r" in
	blacklist*) echo "  FAIL 空名单还把客户端当黑名单"; fail=1 ;;
	*) echo "  OK   空名单不拦任何人" ;;
esac
printf 'aa:bb:cc:dd:ee:01\n22:33:44:55:66:77' >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"

echo "== C8 全局模式 + portal_global=my.sh =="
bl_clear
uci set zone_detect.main.scope=global >/dev/null 2>&1
uci set zone_detect.main.portal_global=my.sh >/dev/null 2>&1
r=$(run_theme 'aa:bb:cc:dd:ee:ff')
ck "全局模式出 cpd/global/my.sh" "global|$S/cpd/global/my.sh" "$r"

echo "== C9 全局模式没选门户 → cpd/global/default.sh =="
uci -q delete zone_detect.main.portal_global >/dev/null 2>&1
rm -rf "$MOCK_UCI_DELTA"
uci set zone_detect.main.scope=global >/dev/null 2>&1
r=$(run_theme 'aa:bb:cc:dd:ee:ff')
ck "全局模式回落 default.sh" "global|$S/cpd/global/default.sh" "$r"

echo "== C10 全局门户文件全缺失 → 不提供任何门户（不回落内置主题） =="
mv "$S/cpd/global" "$S/cpd/global.bak"
uci set zone_detect.main.scope=global >/dev/null 2>&1
r=$(run_theme 'aa:bb:cc:dd:ee:ff')
ck "全局门户缺失不出门户" "global|" "$r"
mv "$S/cpd/global.bak" "$S/cpd/global"

echo "== C11 全局模式下黑名单客户端仍走黑名单分支 =="
uci set zone_detect.main.portal_global=my.sh >/dev/null 2>&1
uci set zone_detect.main.portal_blacklist_sel=my.sh >/dev/null 2>&1
r=$(run_theme 'AA:BB:CC:DD:EE:01')
ck "黑名单优先于全局门户" "blacklist|$S/cpd/blacklist/my.sh" "$r"

echo "== C12 scope 不是 global → 不走全局分支 =="
bl_clear
uci set zone_detect.main.scope=session >/dev/null 2>&1
r=$(run_theme 'aa:bb:cc:dd:ee:ff')
case "$r" in
	global*) echo "  FAIL scope=session 还进了全局分支: $r"; fail=1 ;;
	*) echo "  OK   scope=session 照常区域识别（$r）" ;;
esac

echo "== C13 门户缺 generate_splash_sequence/header/footer 时不死循环 =="
# t10 的门户文件都只设 userinfo、不定义任何函数 —— run_theme 调 header
# 已经走了"门户缺函数 → 兜底"路径。这里再补 generate_splash_sequence 全链：
# 应输出无按钮提示页（而非递归或 Invalid ThemeSpec 错误页）
bl_clear
r=$(
	ndspid=1
	. "$TS" >/dev/null 2>&1
	clientmac='22:33:44:55:66:77'
	header >/dev/null 2>&1
	generate_splash_sequence 2>/dev/null
)
case "$r" in
	*未提供认证门户*) echo "  OK   兜底提示页输出（无认证按钮）" ;;
	*) echo "  FAIL 门户缺函数时输出异常: $(printf '%s' "$r" | head -3)"; fail=1 ;;
esac

done_report
