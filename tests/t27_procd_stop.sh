#!/bin/sh
# t27：关停必须先删 procd 实例，再等进程退出
# 真机 2026-11-26 日志：旧进程 Exiting... 后 39 秒冒出新 pid，
# 官方 init 的 respawn 360 20 15 说明实例没删时 procd 会重新拉起。
# 本用例桩一个"stop 后实例仍在"的 procd：补删实例后进程才退出，
# 断言补了 delete、没有在实例还挂着时强杀、终态 running=0。
. "$(dirname "$0")/lib.sh"
tmp_setup t27_procd_stop

mkdir -p "$S/bin"
export UBUS_INSTANCE="$S/ubus.instance"
export UBUS_LOG="$S/ubus.log"
export PATH="$S/bin:$PATH"
: >"$UBUS_LOG"
touch "$UBUS_INSTANCE"

cat >"$S/bin/ubus" <<'UBUS'
#!/bin/sh
[ "$2" = 'service' ] || exit 1
case "$3" in
	list)
		[ -f "$UBUS_INSTANCE" ] &&
			printf '%s\n' '{"opennds":{"instances":{"instance1":{"running":true,"pid":9999}}}}'
		;;
	delete)
		echo delete >>"$UBUS_LOG"
		rm -f "$UBUS_INSTANCE"
		;;
esac
exit 0
UBUS
chmod +x "$S/bin/ubus"

cat >"$S/init.sh" <<'STUB'
#!/bin/sh
echo "$1" >>"$NDS_INIT_LOG"
case "$1" in
	stop) ( sleep 1; touch "$CPD_PIDOF_CLEAR" ) >/dev/null 2>&1 & ;;
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

echo '== A. 实例残留：补删后再收尾 =='
call run_worker 0
wait_run() {
	i=0
	while [ "$i" -lt 60 ]; do
		grep -q '"done":1' "$CPD_RUN_STATE" 2>/dev/null && return 0
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	return 1
}
wait_run || { echo '  FAIL worker 没写终态'; fail=1; }
ck '终态 running:0' '"running":0' "$(cat "$CPD_RUN_STATE" 2>/dev/null)"
ck '补了 procd delete' 'delete' "$(cat "$UBUS_LOG" 2>/dev/null)"
ck '实例已清掉' '' "$(cat "$UBUS_INSTANCE" 2>/dev/null)"

echo '== B. 只调了 stop，没有自己 start =='
ck 'init 只收到 stop' 'stop' "$(tr '\n' ' ' <"$NDS_INIT_LOG")"
if grep -q 'start' "$NDS_INIT_LOG" 2>/dev/null; then
	echo '  FAIL 关停过程自己启动了 NDS'; fail=1
fi

echo '== C. 前端口径仍是看真实进程状态 =='
V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
if grep -F "j.running === 1" "$V/overview.js" >/dev/null 2>&1; then
	echo '  OK   前端按真实 running 收尾'
else
	echo '  FAIL 前端没按 running 收尾'; fail=1
fi

done_report
