#!/bin/sh
# t7：被禁用的无线必须显示「未启用」
#   ① radio 级 wireless.<radio>.disabled=1 → disabled=1 / radioDisabled=1
#   ② 接口级 wireless.<iface>.disabled=1   → disabled=1
#   ③ 接口级 disabled=on（不是 '1' 也要认） → disabled=1
#   ④ ubus 运行时视图里 config.disabled=true（uci 没写） → disabled=1
#   ⑤ 都没禁用                              → disabled=0
#
# 现场还原（这就是用户报的 bug）：uci 里 radio0 已经 disabled=1，但
# `ubus call network.wireless status` 的运行时视图仍然是 up=true、
# config.disabled=false。旧实现 ubus 优先 → 把已关掉的 radio 报成「已启用」。
. "$(dirname "$0")/lib.sh"
tmp_setup t7

# 覆盖默认桩：运行时 up=true；接口级 config.disabled 只对 IFACE_DIS 里列出的返回 true
mkdir -p "$S/bin"
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
printf '%s' '{"radio0":{"up":true},"radio1":{"up":true}}'
UEOF
cat >"$S/bin/jsonfilter" <<'JEOF'
#!/bin/sh
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
		*'.interfaces['*'.config.disabled'*)
			# 形如 @.radio1.interfaces[@.section="wifinet3"].config.disabled
			rad=$(printf '%s' "$e" | sed -n 's/^@\.\([A-Za-z0-9_]*\)\.interfaces.*/\1/p')
			sec=$(printf '%s' "$e" | sed -n 's/.*\[@\.section="\([^"]*\)"\].*/\1/p')
			case " ${IFACE_DIS:-} " in
				*" $rad:$sec "*) printf 'true\n' ;;
				*) : ;;
			esac
			;;
		*.up) printf 'true\n' ;;
		*.disabled) printf 'false\n' ;;
		*) : ;;
	esac
done
JEOF
chmod +x "$S/bin/ubus" "$S/bin/jsonfilter"
export PATH="$S/bin:$PATH"
export IFACE_DIS='radio1:wifi-iface-3'

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
mk_iface wifi-iface-3 radio1 OFF_RUNTIME ''
mk_iface wifi-iface-4 radio1 OFF_BY_ON 'on'

echo "== 卡片启用状态 =="
out=$(call zone status)
ck "返回 ok" '{"ok":1' "$out"

seg() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"section\":\"$2\""; }
s0=$(seg "$out" wifi-iface-0)
s1=$(seg "$out" wifi-iface-1)
s2=$(seg "$out" wifi-iface-2)
s3=$(seg "$out" wifi-iface-3)
s4=$(seg "$out" wifi-iface-4)

ck "radio 被禁用的 AP → disabled=1" '"disabled":1' "$s0"
ck "radio 被禁用的 AP → radioDisabled=1" '"radioDisabled":1' "$s0"
ck "正常 AP → disabled=0" '"disabled":0' "$s1"
ck "正常 AP → radioDisabled=0" '"radioDisabled":0' "$s1"
ck "接口自己 disabled=1 → disabled=1" '"disabled":1' "$s2"
ck "接口禁用但 radio 正常 → radioDisabled=0" '"radioDisabled":0' "$s2"
ck "disabled=on 也认 → disabled=1" '"disabled":1' "$s4"
ck "只有运行时 config.disabled → disabled=1" '"disabled":1' "$s3"
ck "只有运行时禁用不算 radio 禁用" '"radioDisabled":0' "$s3"

done_report
