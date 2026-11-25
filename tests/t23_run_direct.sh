#!/bin/sh
# t23：概览页运行开关直连 start/stop（不再走保存并应用）
#   A. run_set 立即返回 busy=1，并写 run.state；不碰 uci
#   B. run_worker 停止：只调 init stop，终态 running=0
#   C. run_worker 启动：只调 init start，终态 running=1；登录模式 3 缺路径时补齐
. "$(dirname "$0")/lib.sh"
tmp_setup t23_run

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
API="$API_SRC"

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

wait_run() { # 等 run.state 写终态
	local i=0
	while [ "$i" -lt 40 ]; do
		grep -q '"done":1' "$CPD_RUN_STATE" 2>/dev/null && return 0
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	return 1
}

echo "== A. run_set 立即返回，不写 uci =="
uci set 'opennds.@opennds[0].enabled=1'
uci commit opennds
rm -f "$CPD_PIDOF_CLEAR"
out=$(call overview run_set 0)
ck "run_set 回 busy/target" '"ok":1,"busy":1,"target":0' "$out"
ck "状态文件先写 busy" '"done":0' "$(cat "$CPD_RUN_STATE" 2>/dev/null)"
ck "没有写 pending_run" '' "$(uci -q get zone_detect.main.pending_run 2>/dev/null)"
ck "enabled 没被运行开关改掉" '1' \
	"$(uci -q get opennds.@opennds[0].enabled 2>/dev/null)"
wait_run || { echo '  FAIL worker 没写终态'; fail=1; }
ck "停止终态 running:0" '"running":0' "$(cat "$CPD_RUN_STATE" 2>/dev/null)"
ck "只调了 stop" 'stop' "$(tr '\n' ' ' <"$NDS_INIT_LOG")"

echo "== B. run_worker 启动 =="
: >"$NDS_INIT_LOG"
touch "$CPD_PIDOF_CLEAR"
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf '3' >"$MOCK_UCI_ROOT/opennds/opennds/login_option_enabled"
rm -f "$MOCK_UCI_ROOT/opennds/opennds/themespec_path"
call run_worker 1
ck "启动终态 running:1" '"running":1' "$(cat "$CPD_RUN_STATE" 2>/dev/null)"
ck "只调了 start" 'start' "$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "登录模式 3 缺路径时补齐" '/usr/lib/opennds/theme_zone_detect.sh' \
	"$(uci -q get opennds.@opennds[0].themespec_path 2>/dev/null)"

echo "== C. 前端不再走保存并应用 =="
if grep -F "CPD.api('overview', 'run_set', [want])" "$V/overview.js" >/dev/null 2>&1; then
	echo '  OK   前端调 run_set'
else
	echo '  FAIL 前端没调 run_set'; fail=1
fi
if grep -F "CPD.api('overview', 'run_state')" "$V/overview.js" >/dev/null 2>&1; then
	echo '  OK   前端轮询 run_state'
else
	echo '  FAIL 前端没轮询 run_state'; fail=1
fi

done_report
