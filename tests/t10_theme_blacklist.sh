#!/bin/sh
# t10：分发脚本的黑名单分支（真正执行拦截的地方）
#   openNDS 9.4 起废弃 macmechanism/blockedmaclist，主进程不再自己拦 MAC，
#   拦截完全靠 theme_zone_detect.sh：命中 blockedmac 的客户端不出示区域门户，
#   只出示黑名单门户（选中项 zone_detect.main.portal_blacklist，兜底
#   cpd/default/blacklist/default.sh），因此它拿不到"继续"按钮，一直上不了网。
. "$(dirname "$0")/lib.sh"
tmp_setup t10

THEME_SRC="$REPO/luci-app-opennds-cpd/root/usr/lib/opennds/theme_zone_detect.sh"
TS="$S/theme.sh"
cp "$THEME_SRC" "$TS" || exit 1

# 把脚本里的绝对路径指向沙箱
sed -i \
	-e "s#^CPD_ROOT=.*#CPD_ROOT=\"$S/cpd\"#" \
	-e "s#^MARKERS=.*#MARKERS=\"$S/markers\"#" \
	-e "s#^FALLBACK_THEME=.*#FALLBACK_THEME=\"$S/fallback.sh\"#" \
	-e "s#^ZONE_DETECT_CONFIG=.*#ZONE_DETECT_CONFIG=\"$ZONE_DETECT_CONFIG\"#" \
	"$TS"

printf '#!/bin/sh\nuserinfo="fallback"\n' >"$S/fallback.sh"
mkdir -p "$S/cpd/blacklist" "$S/cpd/default/blacklist"
printf '#!/bin/sh\nuserinfo="blacklist-portal"\n' >"$S/cpd/blacklist/my.sh"
printf '#!/bin/sh\nuserinfo="blacklist-default"\n' >"$S/cpd/default/blacklist/default.sh"

# opennds 配置：拉黑 11:22:33:44:55:66
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'aa:bb:cc:dd:ee:01\n22:33:44:55:66:77' >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"

run_theme() { # $1=clientmac → 输出 "zone_type|portal"
	(
		clientmac="$1"
		ndspid=1
		. "$TS" >/dev/null 2>&1
		printf '%s|%s\n' "$zone_type" "$portal"
	)
}

echo "== C1 拉黑客户端 + 已选门户（客户端大写、配置小写）=="
uci set zone_detect.main.portal_blacklist=my.sh >/dev/null 2>&1
r=$(run_theme 'AA:BB:CC:DD:EE:01')
ck "走黑名单分支" "blacklist|$S/cpd/blacklist/my.sh" "$r"

echo "== C2 反向大小写同样命中 =="
r=$(run_theme 'aa:bb:cc:dd:ee:01')
ck "客户端小写也命中" "blacklist|$S/cpd/blacklist/my.sh" "$r"

echo "== C3 拉黑但没选门户 → 类型兜底 default.sh =="
uci -q delete zone_detect.main.portal_blacklist >/dev/null 2>&1
rm -rf "$MOCK_UCI_DELTA"
r=$(run_theme '22:33:44:55:66:77')
ck "回落到 cpd/default/blacklist/default.sh" "blacklist|$S/cpd/default/blacklist/default.sh" "$r"

echo "== C4 未拉黑客户端不受影响 =="
r=$(run_theme 'aa:bb:cc:dd:ee:ff')
case "$r" in
	blacklist*) echo "  FAIL 未拉黑客户端被当成了黑名单"; echo "       实际: $r"; fail=1 ;;
	wireless*|wired*) echo "  OK   未拉黑客户端照常走区域识别（$r）" ;;
	*) echo "  OK   未拉黑客户端未进黑名单分支（$r）" ;;
esac

echo "== C5 名单为空 =="
printf '' >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"
r=$(run_theme '11:22:33:44:55:66')
case "$r" in
	blacklist*) echo "  FAIL 空名单还把客户端当黑名单"; fail=1 ;;
	*) echo "  OK   空名单不拦任何人" ;;
esac

done_report
