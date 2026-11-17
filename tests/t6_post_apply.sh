#!/bin/sh
# t6：sys post_apply —— 原生 commit 之后的运行时同步，绝不写配置
. "$(dirname "$0")/lib.sh"
tmp_setup t6

echo "== C1 post_apply：global 作用域 → 走重启分支，输出合法 JSON =="
uci set zone_detect.main.scope=global >/dev/null 2>&1
uci commit zone_detect >/dev/null 2>&1
out=$(call sys post_apply)
ck "有 ok 字段" '"ok":' "$out"
ck "zone 标记为 0" '"zone":0' "$out"

echo "== C2 post_apply：zone 作用域但区域缓存为空 → 不退化成错误 JSON =="
uci set zone_detect.main.scope=zone >/dev/null 2>&1
uci commit zone_detect >/dev/null 2>&1
out=$(call sys post_apply)
ck "仍有 ok 字段" '"ok":' "$out"

echo "== C3 post_apply 不写任何配置 =="
before=$(uci show opennds 2>/dev/null | sort)
call sys post_apply >/dev/null
after=$(uci show opennds 2>/dev/null | sort)
if [ "$before" = "$after" ]; then
	echo "  OK   opennds 配置未被 post_apply 改动"
else
	echo "  FAIL 配置被 post_apply 改了"; fail=1
fi

echo "== C4 post_apply 把黑名单 MAC 摘信任 + 踢下线（只动运行时） =="
uci add_list "zone_blacklist.main.mac=AA:BB:CC:DD:EE:01" >/dev/null 2>&1
uci commit zone_blacklist >/dev/null 2>&1
export NDSCTL_LOG="$S/ndsctl.log"
: >"$NDSCTL_LOG"
call sys post_apply >/dev/null
ck "调了 untrust（小写 MAC）" 'untrust aa:bb:cc:dd:ee:01' "$(tr '\n' ' ' <"$NDSCTL_LOG")"
ck "调了 deauth" 'deauth aa:bb:cc:dd:ee:01' "$(tr '\n' ' ' <"$NDSCTL_LOG")"

echo "== C5 sys 未知子命令仍然报错 =="
out=$(call sys nosuchcmd)
ck "未知子命令" '"ok":0' "$out"

echo "== C6 后端不再有 restore_scan / trustedmac.orig / set_themespec =="
if grep -q "restore_scan\|trustedmac.orig\|ov_set_themespec" "$API_SRC"; then
	echo "  FAIL 后端残留已删除的额外机制"; fail=1
else
	echo "  OK   后端无额外机制残留"
fi

done_report
