#!/bin/sh
# t26：会话时长改动的四选项确认 + FUP/IPv4 文案 + 会话过期不误报
#   A. 直接应用：踢认证/自动认证客户端，跳过单独设会话时长的
#   B. 全局直接应用：单独设的也恢复全局并解除认证
#   C. 前端静态口径：四行文案/四按钮、FUP 显示、IPv4 后缀、SessionError
. "$(dirname "$0")/lib.sh"
tmp_setup t26_session_apply

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
COMMON="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/opennds_manager/common.js"
has() { if grep -q "$2" "$1" 2>/dev/null; then echo "  OK   $3"; else echo "  FAIL $3"; fail=1; fi; }
no()  { if grep -q "$2" "$1" 2>/dev/null; then echo "  FAIL $3"; fail=1; else echo "  OK   $3"; fi; }

mkdir -p "$MOCK_UCI_ROOT/opennds/opennds" "$MOCK_UCI_ROOT/zone_detect/main" "$CPD_NDSLOG_DIR"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf 'main' >"$MOCK_UCI_ROOT/zone_detect/main/.type"
cat >"$S/init.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$S/init.sh"
export NDS_INIT="$S/init.sh"
export NDSCTL_LOG="$S/ndsctl.log"
: >"$NDSCTL_LOG"

M1='aa:bb:cc:dd:ee:01'
M2='aa:bb:cc:dd:ee:02'
M3='aa:bb:cc:dd:ee:03'
EXP=$(( $(date +%s) + 3600 ))

seed_logs() {
	: >"$CPD_NDSLOG_DIR/authlog.log"
	: >"$CPD_NDSLOG_DIR/binauthlog.log"
	for m in "$M1" "$M2" "$M3"; do
		printf '%s=%s\n' "$(printf '%s' "$m" | base64 | tr -d '=')" "$EXP" >>"$CPD_NDSLOG_DIR/authlog.log"
		printf 'method=client_auth, clientmac=%s, session_start=1, session_end=%s\n' "$m" "$EXP" >>"$CPD_NDSLOG_DIR/binauthlog.log"
	done
}
seed_lists() {
	uci -q delete 'opennds.@opennds[0].preemptivemac' >/dev/null 2>&1
	uci add_list "opennds.@opennds[0].preemptivemac=mac=$M2;sessiontimeout=60;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0" >/dev/null
	uci add_list "opennds.@opennds[0].preemptivemac=mac=$M3;sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0" >/dev/null
	uci commit opennds >/dev/null
}

echo "== A. 直接应用：跳过单独设置会话时长的客户端 =="
seed_logs; seed_lists
uci set zone_detect.main.session_apply_mode=apply >/dev/null
uci commit zone_detect >/dev/null
call sys post_apply >/dev/null
sleep 1
ck "踢掉普通已认证" "deauth $M1" "$(cat "$NDSCTL_LOG")"
ck "跳过单独设置时长" '' "$(grep -F "deauth $M2" "$NDSCTL_LOG" 2>/dev/null)"
ck "踢掉自动认证(全局时长)" "deauth $M3" "$(cat "$NDSCTL_LOG")"
ck "单独设置者日志保留" "$(printf '%s' "$M2" | base64 | tr -d '=')" "$(cat "$CPD_NDSLOG_DIR/authlog.log")"
ck "普通已认证日志已清" '' "$(grep -F "$M1" "$CPD_NDSLOG_DIR/authlog.log" 2>/dev/null)"
ck "一次性待办已删除" '' "$(uci -q get zone_detect.main.session_apply_mode 2>/dev/null)"

echo "== B. 全局直接应用：单独设置者恢复全局并解除 =="
: >"$NDSCTL_LOG"
seed_logs; seed_lists
uci set zone_detect.main.session_apply_mode=global >/dev/null
uci commit zone_detect >/dev/null
call sys post_apply >/dev/null
sleep 1
ck "单独设置者也被踢" "deauth $M2" "$(cat "$NDSCTL_LOG")"
ck "条目恢复全局(sessiontimeout=0)" 'mac=' "$(uci -q get 'opennds.@opennds[0].preemptivemac' 2>/dev/null)"
if uci -q get 'opennds.@opennds[0].preemptivemac' 2>/dev/null | grep -q 'sessiontimeout=60'; then
	echo '  FAIL 单独会话时长未改回 0'; fail=1
else
	echo '  OK   单独会话时长已改回 0'
fi
ck "全局待办已删除" '' "$(uci -q get zone_detect.main.session_apply_mode 2>/dev/null)"

echo "== C. 前端口径 =="
has "$V/settings.js" 'sessionChanged() ? askSessionApply()' '只有会话时长改动才弹确认'
for txt in \
	'更改会话时长不会即时影响已经通过认证并且在认证有效期的客户端。' \
	'更改：等待已认证客户端认证到期后再次触发认证时应用。' \
	'立即应用：将会把已通过认证并且在有效期内的客户端解除认证，并让客户端重新触发认证。' \
	'全局立即应用：将会把已通过认证并且在有效期内的客户端解除认证，包括单独设置会话时长的客户端。'; do
	has "$V/settings.js" "$txt" "确认文案：$txt"
done
for btn in '更改' '立即应用' '全局立即应用' '取消'; do
	has "$V/settings.js" "_('$btn')" "按钮：$btn"
done
has "$V/settings.js" 'session_apply_mode' '应用方式写入一次性待办'
has "$V/overview.js" "if (!state.fupEnabled) return _('未配置公平使用策略')" 'FUP 关闭不显示取消认证'
has "$V/overview.js" "流量配额（只支持IPV4流量）" '详情流量配额文案'
has "$V/settings.js" "速率（只支持IPV4流量）" '基础速率文案'
has "$V/settings.js" "流量配额（只支持IPV4流量）" '基础流量配额文案'
has "$V/settings.js" "（只支持IPV4流量）" '高级限速选项提示'
has "$COMMON" 'name: (e && e.name)' '保留 LuCI 错误名'
has "$V/overview.js" "e.name === 'SessionError'" '会话过期单独处理'
has "$V/overview.js" 'sessionInterrupted(); return;' '会话过期不弹失败横幅'

done_report
