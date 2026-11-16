#!/bin/sh
# t7：被禁用的无线必须显示「未启用」
#   ① radio 级 wireless.<radio>.disabled=1 → disabled=1 / radioDisabled=1
#   ② 接口级 wireless.<iface>.disabled=1   → disabled=1
#   ③ 都没禁用                              → disabled=0
#
# 现场还原（这就是用户报的 bug）：uci 里 radio0 已经 disabled=1，但
# `ubus call network.wireless status` 的运行时视图仍然是 up=true、
# config.disabled=false。旧实现 ubus 优先 → 把已关掉的 radio 报成「已启用」。
. "$(dirname "$0")/lib.sh"
tmp_setup t7

# 覆盖默认桩：让 ubus/jsonfilter 报「运行时 up=true、config.disabled=false」
mkdir -p "$S/bin"
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
printf '%s' '{"radio0":{"up":true},"radio1":{"up":true}}'
UEOF
cat >"$S/bin/jsonfilter" <<'JEOF'
#!/bin/sh
# 支持多个 -e，按表达式逐个输出（与真 jsonfilter 一致）
exprs=''
while [ $# -gt 0 ]; do
	case "$1" in
		-e) exprs="$exprs
$2"; shift 2 ;;
		-q) shift ;;
		*) shift ;;
	esac
done
cat >/dev/null
printf '%s\n' "$exprs" | while IFS= read -r e; do
	[ -n "$e" ] || continue
	case "$e" in
		*.up) printf 'true\n' ;;
		*.disabled) printf 'false\n' ;;
		*) : ;;
	esac
done
JEOF
chmod +x "$S/bin/ubus" "$S/bin/jsonfilter"
export PATH="$S/bin:$PATH"

# wireless 配置：radio0 明确 disabled=1（用户已在 LuCI 里关掉）；radio1 正常
mkdir -p "$MOCK_UCI_ROOT/wireless/radio0" "$MOCK_UCI_ROOT/wireless/radio1"
printf 'radio0' >"$MOCK_UCI_ROOT/wireless/radio0/.type"
printf '1' >"$MOCK_UCI_ROOT/wireless/radio0/disabled"
printf 'radio1' >"$MOCK_UCI_ROOT/wireless/radio1/.type"

mk_iface() { # $1=sec $2=device $3=ssid $4=disabled
	mkdir -p "$MOCK_UCI_ROOT/wireless/$1"
	printf 'wifi-iface' >"$MOCK_UCI_ROOT/wireless/$1/.type"
	printf 'ap' >"$MOCK_UCI_ROOT/wireless/$1/mode"
	printf '%s' "$2" >"$MOCK_UCI_ROOT/wireless/$1/device"
	printf '%s' "$3" >"$MOCK_UCI_ROOT/wireless/$1/ssid"
	[ -n "$4" ] && printf '%s' "$4" >"$MOCK_UCI_ROOT/wireless/$1/disabled"
	return 0
}
mk_iface wifi-iface-0 radio0 OFF_AP ''
mk_iface wifi-iface-1 radio1 ON_AP ''
mk_iface wifi-iface-2 radio1 OFF_IFACE '1'

echo "== 卡片启用状态 =="
out=$(call zone status)
ck "返回 ok" '{"ok":1' "$out"

seg() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"section\":\"$2\""; }
s0=$(seg "$out" wifi-iface-0)
s1=$(seg "$out" wifi-iface-1)
s2=$(seg "$out" wifi-iface-2)

ck "radio 被禁用的 AP → disabled=1" '"disabled":1' "$s0"
ck "radio 被禁用的 AP → radioDisabled=1" '"radioDisabled":1' "$s0"
ck "正常 AP → disabled=0" '"disabled":0' "$s1"
ck "正常 AP → radioDisabled=0" '"radioDisabled":0' "$s1"
ck "接口自己 disabled=1 → disabled=1" '"disabled":1' "$s2"
ck "接口禁用但 radio 正常 → radioDisabled=0" '"radioDisabled":0' "$s2"

done_report
