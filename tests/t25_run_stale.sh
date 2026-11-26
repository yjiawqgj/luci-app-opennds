#!/bin/sh
# t25：会话过期重登后关停卡黄灯、红横幅不消失
#   A. worker 中途消失后残留的 done:0 不再算忙，run_set 会重新派发
#   B. 活着的 worker 仍算忙，不会被新点击覆盖
#   C. 前端以"进程实际到位"为准，失败横幅可在状态改正后撤掉
. "$(dirname "$0")/lib.sh"
tmp_setup t25_run_stale

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
COMMON="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/opennds_manager/common.js"
has() { if grep -q "$2" "$1" 2>/dev/null; then echo "  OK   $3"; else echo "  FAIL $3"; fail=1; fi; }
no()  { if grep -q "$2" "$1" 2>/dev/null; then echo "  FAIL $3"; fail=1; else echo "  OK   $3"; fi; }

cat >"$S/init.sh" <<'STUB'
#!/bin/sh
case "$1" in
	stop) touch "$CPD_PIDOF_CLEAR" ;;
	start) rm -f "$CPD_PIDOF_CLEAR" ;;
esac
exit 0
STUB
chmod +x "$S/init.sh"
export NDS_INIT="$S/init.sh"
export CPD_PIDOF_CLEAR="$S/pidof.clear"
rm -f "$CPD_PIDOF_CLEAR"

wait_run() {
	i=0
	while [ "$i" -lt 40 ]; do
		grep -q '"done":1' "$CPD_RUN_STATE" 2>/dev/null && return 0
		sleep 0.2 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	return 1
}

echo "== A. worker 消失后的残留忙碌 =="
now=$(date +%s)
printf '{"ok":1,"busy":1,"done":0,"target":0,"running":1,"phase":"working","pid":99999999,"ts":%s}\n' "$now" >"$CPD_RUN_STATE"
out=$(call overview run_state)
ck "残留 done:0 不算忙" '"busy":0,"done":1' "$out"
ck "进程状态照实回" '"running":1' "$out"
out=$(call overview run_set 0)
ck "重新派发关闭" '"target":0' "$out"
wait_run || { echo '  FAIL 新 worker 没写终态'; fail=1; }
state=$(cat "$CPD_RUN_STATE" 2>/dev/null)
ck "worker 写下自己的 pid" '"pid":' "$state"
ck "终态真的停住" '"target":0,"running":0' "$state"

echo "== B. 活着的 worker 不能被新点击顶掉 =="
printf '{"ok":1,"busy":1,"done":0,"target":0,"running":1,"phase":"working","pid":%s,"ts":%s}\n' \
	"$$" "$(date +%s)" >"$CPD_RUN_STATE"
out=$(call overview run_state)
ck "pid 活着算忙" '"busy":1,"done":0' "$out"
out=$(call overview run_set 1)
ck "忙碌时保留旧目标" '"target":"0"' "$out"

echo "== C. 前端口径 =="
no "$V/overview.js" "if (j.busy === 1 && Date.now()" '不再只认 busy 死等'
has "$V/overview.js" "running === (want === '1')" '进程到位就算完成'
has "$V/overview.js" "j.done === 1 || Date.now() - startedAt >= 60000" '真失败才报错'
has "$V/overview.js" "maybeClearRunNotice()" '状态改正后撤横幅'
has "$V/overview.js" "runNotice = CPD.notify(" '横幅节点被记住'
has "$COMMON" "dismissNotice: function" '通知支持主动撤销'
has "$API" 'kill -0 "$pid"' '后端用 pid 判活'
has "$API" 'run_state_read' '启停前统一判定状态文件有效性'

done_report
