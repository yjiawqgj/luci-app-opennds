#!/bin/sh
# t15：概览页开关（启动/停止）走 openwrt 原生暂存流程后的 worker 行为。
# 开关 = 暂存 opennds.@opennds[0].enabled + zone_detect.main.pending_run，
# 原生 commit 后由 apply_worker 执行。worker 规矩：
#   ① 应用带 pending_run=1 → 启动（含 themespec 缺失补齐），不部署不重启
#   ② 应用带 pending_run=0 → 停止并等进程退出，不部署不重启
#   ③ 普通（无 pending_run）保持老行为：was=1 重启 / was=0 不拉起（t6 已覆盖）
#   ④ worker 干活期间晚到的 pending_run 也要被捞起执行（上限 3 轮）
. "$(dirname "$0")/lib.sh"
tmp_setup t15

# init.d 桩：记录调用序；stop 视为进程退出（pidof 桩看 CPD_PIDOF_CLEAR）
cat >"$S/init.sh" <<'STUB'
#!/bin/sh
echo "$1" >> "$NDS_INIT_LOG"
case "$1" in
	stop) touch "$CPD_PIDOF_CLEAR" ;;
	start) rm -f "$CPD_PIDOF_CLEAR" ;;
esac
exit 0
STUB
chmod +x "$S/init.sh"
export NDS_INIT="$S/init.sh"
export NDS_INIT_LOG="$S/init.log"
export CPD_PIDOF_CLEAR="$S/pidof.clear"
: >"$NDS_INIT_LOG"
rm -f "$CPD_PIDOF_CLEAR"

mk_pr() { # $1=0|1|''
	mkdir -p "$MOCK_UCI_ROOT/zone_detect/main"
	if [ -n "$1" ]; then
		printf '%s' "$1" >"$MOCK_UCI_ROOT/zone_detect/main/pending_run"
	else
		rm -f "$MOCK_UCI_ROOT/zone_detect/main/pending_run"
	fi
}
mk_prestart() { # $1=1|''
	mkdir -p "$MOCK_UCI_ROOT/zone_detect/main"
	if [ -n "$1" ]; then
		printf '%s' "$1" >"$MOCK_UCI_ROOT/zone_detect/main/pending_restart"
	else
		rm -f "$MOCK_UCI_ROOT/zone_detect/main/pending_restart"
	fi
}
clear_delta() { rm -rf "$MOCK_UCI_DELTA" 2>/dev/null; }
wait_term() { # 最多轮 30 次（每次 0.5s）等 worker 写终态
	local i=0
	while [ "$i" -lt 30 ]; do
		grep -q '"done":1' "$CPD_APPLY_STATE" 2>/dev/null && return 0
		sleep 0.5 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	return 1
}

echo "== C1 pending_run=1：worker 启动 openNDS，清掉请求，不重启 =="
mk_pr 1
call apply_worker
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "只调了 start" "start" "$seq"
ck "没有 stop/restart" "start" "$seq"
ck "pending_run 已清掉" '' "$(uci -q get zone_detect.main.pending_run 2>/dev/null)"
grep -q '"running":1' "$CPD_APPLY_STATE" &&
	echo "  OK   终态 running:1" || { echo "  FAIL 终态不是 running:1: $(cat "$CPD_APPLY_STATE")"; fail=1; }

echo "== C2 pending_run=1 + 登录模式 3 但 themespec 缺失 → worker 补齐 =="
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf '3' >"$MOCK_UCI_ROOT/opennds/opennds/login_option_enabled"
rm -f "$MOCK_UCI_ROOT/opennds/opennds/themespec_path"
clear_delta
mk_pr 1
: >"$NDS_INIT_LOG"
call apply_worker
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
ck "补齐 themespec_path" '/usr/lib/opennds/theme_zone_detect.sh' \
	"$(uci -q get opennds.@opennds[0].themespec_path 2>/dev/null)"
ck "已设的不覆盖" '/usr/lib/opennds/theme_zone_detect.sh' \
	"$(uci -q get opennds.@opennds[0].themespec_path 2>/dev/null)"

echo "== C3 pending_run=1 + 用户自己设过 themespec → 不覆盖 =="
printf '/my/own/theme.sh' >"$MOCK_UCI_ROOT/opennds/opennds/themespec_path"
clear_delta
mk_pr 1
: >"$NDS_INIT_LOG"
call apply_worker >/dev/null
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
ck "保留用户自设的 themespec" '/my/own/theme.sh' \
	"$(uci -q get opennds.@opennds[0].themespec_path 2>/dev/null)"

echo "== C4 pending_run=0：worker 停止 openNDS 并等退出，不 start =="
rm -f "$MOCK_UCI_ROOT/opennds/opennds/themespec_path"
clear_delta
mk_pr 0
: >"$NDS_INIT_LOG"
call apply_worker
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "只调了 stop" "stop" "$seq"
ck "没有 start/restart" "stop" "$seq"
ck "pending_run 已清掉" '' "$(uci -q get zone_detect.main.pending_run 2>/dev/null)"
grep -q '"running":0' "$CPD_APPLY_STATE" &&
	echo "  OK   终态 running:0" || { echo "  FAIL 终态不是 running:0: $(cat "$CPD_APPLY_STATE")"; fail=1; }

echo "== C5 晚到的开关请求：worker 重启期间又来一次 pending_run=0 → 被捞起执行 =="
# was=1、无 pending_run → 正常走重启（stop→start）；重启期间塞进
# pending_run=0，worker 收尾检查要捞起再 stop。让 init 桩的 stop 慢 3 秒，
# 给"塞请求"留出落在重启中途的窗口。
cat >"$S/init.sh" <<'STUB2'
#!/bin/sh
echo "$1" >> "$NDS_INIT_LOG"
case "$1" in
	stop) sleep 3; touch "$CPD_PIDOF_CLEAR" ;;
	start) rm -f "$CPD_PIDOF_CLEAR" ;;
esac
exit 0
STUB2
rm -f "$CPD_PIDOF_CLEAR"
mk_pr ''
: >"$NDS_INIT_LOG"
printf '{"ok":1,"done":0,"phase":"starting","was_running":1,"ts":%s}\n' "$(date +%s)" \
	>"$CPD_APPLY_STATE"
( call apply_worker ) &
wkpid=$!
sleep 1
mk_pr 0
wait "$wkpid" 2>/dev/null
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "晚到的 stop 被捞起执行（stop start stop）" "stop start stop" "$seq"
ck "没有 restart 调用" "stop start stop" "$seq"
ck "只 start 了一次" '1' "$(grep -c '^start$' "$NDS_INIT_LOG")"
ck "pending_run 已清掉" '' "$(uci -q get zone_detect.main.pending_run 2>/dev/null)"
grep -q '"running":0' "$CPD_APPLY_STATE" &&
	echo "  OK   终态 running:0（用户最后的意图生效）" ||
	{ echo "  FAIL 终态不是 running:0: $(cat "$CPD_APPLY_STATE")"; fail=1; }

echo "== C6 pending_restart=1 + NDS 在跑：worker 走完整重启（stop → start） =="
rm -f "$CPD_PIDOF_CLEAR"
mk_pr ''
mk_prestart 1
: >"$NDS_INIT_LOG"
call apply_worker
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "重启序 = stop start" "stop start" "$seq"
ck "没有 restart 调用" "stop start" "$seq"
ck "pending_restart 已清掉" '' "$(uci -q get zone_detect.main.pending_restart 2>/dev/null)"
grep -q '"running":1' "$CPD_APPLY_STATE" &&
	echo "  OK   终态 running:1" || { echo "  FAIL 终态不是 running:1: $(cat "$CPD_APPLY_STATE")"; fail=1; }

echo "== C7 pending_restart=1 + NDS 停着：只拉起（start），不 stop =="
touch "$CPD_PIDOF_CLEAR"
mk_prestart 1
: >"$NDS_INIT_LOG"
call apply_worker
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "停着时重启只 start" "start" "$seq"
ck "pending_restart 已清掉" '' "$(uci -q get zone_detect.main.pending_restart 2>/dev/null)"
rm -f "$CPD_PIDOF_CLEAR"

echo "== C8 晚到的重启请求：worker 收尾检查捞起执行 =="
# 让 stop 慢 3 秒，重启中途塞 pending_restart=1，收尾循环要捞起再重启一轮
cat >"$S/init.sh" <<'STUB3'
#!/bin/sh
echo "$1" >> "$NDS_INIT_LOG"
case "$1" in
	stop) sleep 3; touch "$CPD_PIDOF_CLEAR" ;;
	start) rm -f "$CPD_PIDOF_CLEAR" ;;
esac
exit 0
STUB3
rm -f "$CPD_PIDOF_CLEAR"
mk_prestart ''
: >"$NDS_INIT_LOG"
printf '{"ok":1,"done":0,"phase":"starting","was_running":1,"ts":%s}\n' "$(date +%s)" \
	>"$CPD_APPLY_STATE"
( call apply_worker ) &
wkpid=$!
sleep 1
mk_prestart 1
wait "$wkpid" 2>/dev/null
wait_term || { echo "  FAIL worker 没写终态"; fail=1; }
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "晚到的重启被捞起（stop start stop start）" "stop start stop start" "$seq"
ck "pending_restart 已清掉" '' "$(uci -q get zone_detect.main.pending_restart 2>/dev/null)"
grep -q '"running":1' "$CPD_APPLY_STATE" &&
	echo "  OK   终态 running:1" || { echo "  FAIL 终态不是 running:1: $(cat "$CPD_APPLY_STATE")"; fail=1; }

done_report
