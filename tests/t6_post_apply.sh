#!/bin/sh
# t6：sys post_apply / apply_state / apply_worker —— 保存并应用的后端收尾链路。
# post_apply 必须秒回（重活在后台 worker），worker 完成、openNDS 状态符合预期
# 才算成功；本来停着的不主动拉起。
. "$(dirname "$0")/lib.sh"
tmp_setup t6

wait_done() { # 最多轮 30 次（每次 0.5s）等 worker 报 done
	local i=0 out
	while [ "$i" -lt 30 ]; do
		out=$(call sys apply_state)
		case "$out" in
			*'"done":1'*) printf '%s' "$out"; return 0 ;;
		esac
		sleep 0.5 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	printf '%s' "$out"
	return 1
}

echo "== C1 post_apply 秒回：立即返回 bg JSON，不做重启等待 =="
uci set zone_detect.main.scope=global >/dev/null 2>&1
uci commit zone_detect >/dev/null 2>&1
t0=$(date +%s)
out=$(call sys post_apply)
t1=$(date +%s)
ck "有 ok 字段" '"ok":1' "$out"
ck "标记为后台" '"bg":1' "$out"
ck "回报 was_running=1" '"was_running":1' "$out"
[ $((t1 - t0)) -le 5 ] && echo "  OK   秒回（${t1}-${t0}≤5s）" || { echo "  FAIL post_apply 耗时 $((t1-t0))s"; fail=1; }
ck "状态文件已建（done:0）" '"done":0' "$(cat "$CPD_APPLY_STATE" 2>/dev/null)"

echo "== C2 apply_state：worker 完成后 done:1 且 openNDS 在跑 =="
out=$(wait_done)
ck "done:1" '"done":1' "$out"
ck "ok:1" '"ok":1' "$out"
ck "running:1（重启后回到运行）" '"running":1' "$out"
ck "was_running:1" '"was_running":1' "$out"

echo "== C3 本来停着：worker 不拉起、也不报错 =="
out=$(NDS_RUNNING=0 call sys post_apply)
ck "was_running=0" '"was_running":0' "$out"
out=$(NDS_RUNNING=0 wait_done)
ck "ok:1（不算失败）" '"ok":1' "$out"
ck "不主动拉起（running:0）" '"running":0' "$out"

echo "== C4 post_apply 不写任何配置 =="
before=$(uci show opennds 2>/dev/null | sort)
call sys post_apply >/dev/null
wait_done >/dev/null
after=$(uci show opennds 2>/dev/null | sort)
if [ "$before" = "$after" ]; then
	echo "  OK   opennds 配置未被改动"
else
	echo "  FAIL 配置被改了"; fail=1
fi

echo "== C5 post_apply 把黑名单 MAC 摘信任 + 踢下线（只动运行时） =="
uci add_list "opennds.@opennds[0].blockedmac=AA:BB:CC:DD:EE:01" >/dev/null 2>&1
uci commit opennds >/dev/null 2>&1
export NDSCTL_LOG="$S/ndsctl.log"
: >"$NDSCTL_LOG"
call sys post_apply >/dev/null
ck "调了 untrust（小写 MAC）" 'untrust aa:bb:cc:dd:ee:01' "$(tr '\n' ' ' <"$NDSCTL_LOG")"
ck "调了 deauth" 'deauth aa:bb:cc:dd:ee:01' "$(tr '\n' ' ' <"$NDSCTL_LOG")"
out=$(wait_done) # 等 C5 的 worker 收尾，别把运行中的 worker 带进 C6/C7

echo "== C6 service_restart 顺序化：stop → 等退出 → start，绝不用 restart 一把梭 =="
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
uci set zone_detect.main.scope=global >/dev/null 2>&1
uci commit zone_detect >/dev/null 2>&1
call sys post_apply >/dev/null
out=$(wait_done)
ck "worker 完成" '"done":1' "$out"
ck "running:1（start 后就绪）" '"running":1' "$out"
seq="$(tr '\n' ' ' <"$NDS_INIT_LOG")"
ck "先 stop 后 start" "stop start" "$seq"
ck "没有 restart 调用" "stop start" "$seq"
[ -e "$CPD_PIDOF_CLEAR" ] && { echo "  FAIL start 之后 pidof 仍应报活"; fail=1; } || echo "  OK   start 后进程恢复"

echo "== C7 worker 单飞：上一轮没跑完时 post_apply 不叠加，只回报 already =="
printf '{"ok":1,"done":0,"phase":"working","was_running":1,"ts":%s}\n' "$(date +%s)" >"$CPD_APPLY_STATE"
out=$(call sys post_apply)
ck "already 标记" '"already":1' "$out"
ck "仍然 ok:1" '"ok":1' "$out"

echo "== C8 sys 未知子命令仍然报错 =="
out=$(call sys nosuchcmd)
ck "未知子命令" '"ok":0' "$out"

echo "== C9 后端不再有 restore_scan / trustedmac.orig / set_themespec =="
if grep -q "restore_scan\|trustedmac.orig\|ov_set_themespec" "$API_SRC"; then
	echo "  FAIL 后端残留已删除的额外机制"; fail=1
else
	echo "  OK   后端无额外机制残留"
fi

echo "== C10 后端残留 zone_blacklist 机制检查（除一次性迁移） =="
if grep -q "zone_blacklist" "$API_SRC" &&
	! grep -q "bl_migrate_legacy" "$API_SRC"; then
	echo "  FAIL 后端残留 zone_blacklist 机制"; fail=1
else
	echo "  OK   黑名单已改用 opennds blockedmac"
fi

done_report
