#!/bin/sh
# t20：概览四开关口径（运行状态 → 休眠 → 启用 → 服务）
#   A. auto_run 缺键按 openNDS 11.2.0 官方默认 0（页面显示已休眠）
#   B. enabled_set 只写 option enabled，保留原有配置、不停进程
#   C. 运行状态与重启只动进程，不写 enabled（前后端都查）
#   D. 前端四张卡片顺序、标题文案与各自独立的开关链路
. "$(dirname "$0")/lib.sh"
tmp_setup t20_switches

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
API="$API_SRC"

assert_has() { # $1=文件 $2=模式 $3=说明
	if grep -q "$2" "$1" 2>/dev/null; then
		echo "  OK   $3"
	else
		echo "  FAIL $3"
		fail=1
	fi
}

assert_fixed() { # $1=文件 $2=字面串 $3=说明
	if grep -F "$2" "$1" >/dev/null 2>&1; then
		echo "  OK   $3"
	else
		echo "  FAIL $3"
		fail=1
	fi
}

echo "== A. auto_run 缺键按官方默认休眠 =="
rm -rf "$MOCK_UCI_ROOT/opennds" "$MOCK_UCI_DELTA/opennds"
out=$(call overview autorun_state)
ck "缺键→autorun:0" '"ok":1,"autorun":0' "$out"
uci set 'opennds.@opennds[0].auto_run=1'
out=$(call overview autorun_state)
ck "显式1→autorun:1" '"ok":1,"autorun":1' "$out"

echo "== B. enabled_set 只写 enabled，不动其它键、不调 init =="
mkdir -p "$S/bin20"
cat >"$S/bin20/init.sh" <<'STUB'
#!/bin/sh
echo "$1" >> "$NDS_INIT_LOG"
exit 0
STUB
chmod +x "$S/bin20/init.sh"
export NDS_INIT="$S/bin20/init.sh"
export NDS_INIT_LOG="$S/init.log"
: >"$NDS_INIT_LOG"
uci set 'opennds.@opennds[0].gatewayinterface=br-lan'
uci set 'opennds.@opennds[0].auto_run=1'
uci set 'opennds.@opennds[0].enabled=1'
uci commit opennds
out=$(call overview enabled_set 0)
ck "enabled_set 0 回读" '"ok":1,"enabled":0' "$out"
ck "原有 gatewayinterface 保留" 'br-lan' \
	"$(uci -q get 'opennds.@opennds[0].gatewayinterface' 2>/dev/null)"
ck "auto_run 没被顺手改掉" '1' \
	"$(uci -q get 'opennds.@opennds[0].auto_run' 2>/dev/null)"
ck "停用时不调 init 脚本" '' "$(cat "$NDS_INIT_LOG" 2>/dev/null)"
out=$(call overview enabled_set 9)
ck "非法参数被拒" '"ok":0' "$out"
out=$(call overview enabled_set 1)
ck "enabled_set 1 回读" '"ok":1,"enabled":1' "$out"
ck "整个停用/启用过程 init 没被调用" '' "$(cat "$NDS_INIT_LOG" 2>/dev/null)"

echo "== C. 运行状态与重启不写 enabled =="
# 前端：运行状态开关只暂存 pending_run，不再暂存 enabled
if grep -F "CPD.stageUci('opennds', '@opennds[0]', 'enabled'" "$V/overview.js" >/dev/null 2>&1; then
	echo '  FAIL 运行状态开关仍在写 enabled'; fail=1
else
	echo '  OK   运行状态开关不写 enabled'
fi
# 后端：restart_exec 不再因为 enabled=0 偷偷把它改回 1
restart_body=$(sed -n '/^restart_exec()/,/^}/p' "$API")
case "$restart_body" in
	*"uci set"*opennds*) echo '  FAIL restart_exec 仍在写配置'; fail=1 ;;
	*) echo '  OK   restart_exec 不写配置' ;;
esac

echo "== C2. 运行开关直连 start/stop，不再走保存并应用 =="
assert_fixed "$V/overview.js" "CPD.api('overview', 'run_set', [want])" '运行开关调 run_set'
assert_fixed "$V/overview.js" "CPD.api('overview', 'run_state')" '前端轮询 run_state'
toggle_body=$(sed -n '/function doToggle/,/^		}/p' "$V/overview.js")
case "$toggle_body" in
	*applyStaged*) echo '  FAIL doToggle 仍在走保存并应用'; fail=1 ;;
	*) echo '  OK   doToggle 不再走保存并应用' ;;
esac
case "$toggle_body" in
	*"CPD.stageUci('zone_detect', 'main', 'pending_run'"*) echo '  FAIL doToggle 仍在写 pending_run'; fail=1 ;;
	*) echo '  OK   doToggle 不再写 pending_run' ;;
esac

echo "== D. 四张卡片的顺序与联动 =="
labels=$(grep "ovd-ctrl-name" "$V/overview.js" |
	sed -n "s/.*_('\([^']*\)').*/\1/p" | tr '\n' ' ')
ck "顺序=运行状态 休眠 启用 服务" '运行状态 休眠 启用 服务' "$labels"
assert_has "$V/overview.js" 'bootText.textContent = on ? _('"'"'已开启'"'"') : _('"'"'已关闭'"'"')' '服务标题 已开启/已关闭'
assert_has "$V/overview.js" 'autorunText.textContent = on ? _('"'"'已唤醒'"'"') : _('"'"'已休眠'"'"')' '休眠标题 已唤醒/已休眠'
assert_has "$V/overview.js" 'enabledText.textContent = on ? _('"'"'启用'"'"') : _('"'"'未启用'"'"')' '启用标题 启用/未启用'
assert_fixed "$V/overview.js" "CPD.api('overview', 'autorun_set', [want])" '休眠开关只调 autorun_set'
assert_fixed "$V/overview.js" "CPD.api('overview', 'enabled_set', [want])" '启用开关只调 enabled_set'
assert_fixed "$V/overview.js" "CPD.api('overview', 'boot_set', [want])" '服务开关只调 boot_set'

done_report
