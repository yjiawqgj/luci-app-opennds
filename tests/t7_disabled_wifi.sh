#!/bin/sh
# t7：被禁用的无线必须显示「未启用」
#   ① radio 级 wireless.<radio>.disabled=1 → disabled=1 / radioDisabled=1
#   ② 接口级 wireless.<iface>.disabled=1   → disabled=1
#   ③ 接口级 disabled=on（不是 '1' 也要认） → disabled=1
#   ④ ubus 运行时视图里 config.disabled=true（uci 没写） → disabled=1
#   ⑤ radio 运行时 up=false（uci 没写）    → disabled=1 / radioDisabled=1
#   ⑥ radio up=true 但该 section 没有运行时接口（uci 全启用、接口没起来，
#      用户现场：uci disabled=0 却被关掉的 Wi-Fi 仍显示已启用） → disabled=1
#   ⑦ 都没禁用且接口真实存在                → disabled=0
#
# 现场还原（用户报的 bug）：uci 里一切 disabled=0，运行时视图 up=false 或
# 接口没建立。旧实现只看 uci/ubus 的 disabled 字段 → 把没在跑的 Wi-Fi 报成「已启用」。
. "$(dirname "$0")/lib.sh"
tmp_setup t7

# 覆盖默认桩：运行时 up 默认 true（RADIO_DOWN 里列出的除外）；
# 接口级 config.disabled 只对 IFACE_DIS 里列出的返回 true；
# 运行时接口名只对 IFACE_NO_IF 里列出的返回空（接口没建立）
mkdir -p "$S/bin"
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
printf '%s' '{"radio0":{"up":true},"radio1":{"up":true},"radio3":{"up":false}}'
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
		*'.interfaces['*'.ifname'*)
			# 形如 @.radio1.interfaces[@.section="wifi-iface-1"].ifname
			rad=$(printf '%s' "$e" | sed -n 's/^@\.\([A-Za-z0-9_]*\)\.interfaces.*/\1/p')
			sec=$(printf '%s' "$e" | sed -n 's/.*\[@\.section="\([^"]*\)"\].*/\1/p')
			case " ${IFACE_NO_IF:-} " in
				*" $rad:$sec "*) : ;;
				*) printf 'phy0-ap0\n' ;;
			esac
			;;
		*.up)
			rad=$(printf '%s' "$e" | sed -n 's/^@\.\([A-Za-z0-9_]*\)\.up$/\1/p')
			case " ${RADIO_DOWN:-} " in
				*" $rad "*) printf 'false\n' ;;
				*) printf 'true\n' ;;
			esac
			;;
		*.disabled) printf 'false\n' ;;
		*) : ;;
	esac
done
JEOF
chmod +x "$S/bin/ubus" "$S/bin/jsonfilter"
export PATH="$S/bin:$PATH"
export IFACE_DIS='radio1:wifi-iface-3'
export IFACE_NO_IF='radio1:wifi-iface-5'
export RADIO_DOWN='radio3'

# wireless 配置：radio0 明确 disabled=1（用户已在 LuCI 里关掉）；radio1 正常
mkdir -p "$MOCK_UCI_ROOT/wireless/radio0" "$MOCK_UCI_ROOT/wireless/radio1" "$MOCK_UCI_ROOT/wireless/radio3"
printf 'radio0' >"$MOCK_UCI_ROOT/wireless/radio0/.type"
printf '1' >"$MOCK_UCI_ROOT/wireless/radio0/disabled"
printf 'radio1' >"$MOCK_UCI_ROOT/wireless/radio1/.type"
printf 'radio3' >"$MOCK_UCI_ROOT/wireless/radio3/.type"

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
mk_iface wifi-iface-5 radio1 NO_RUNTIME_IF ''
mk_iface wifi-iface-6 radio3 RADIO_DOWN ''

echo "== 卡片启用状态 =="
out=$(call zone status)
ck "返回 ok" '{"ok":1' "$out"

seg() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"section\":\"$2\""; }
s0=$(seg "$out" wifi-iface-0)
s1=$(seg "$out" wifi-iface-1)
s2=$(seg "$out" wifi-iface-2)
s3=$(seg "$out" wifi-iface-3)
s4=$(seg "$out" wifi-iface-4)
s5=$(seg "$out" wifi-iface-5)
s6=$(seg "$out" wifi-iface-6)

ck "radio 被禁用的 AP → disabled=1" '"disabled":1' "$s0"
ck "radio 被禁用的 AP → radioDisabled=1" '"radioDisabled":1' "$s0"
ck "正常 AP → disabled=0" '"disabled":0' "$s1"
ck "正常 AP → radioDisabled=0" '"radioDisabled":0' "$s1"
ck "接口自己 disabled=1 → disabled=1" '"disabled":1' "$s2"
ck "接口禁用但 radio 正常 → radioDisabled=0" '"radioDisabled":0' "$s2"
ck "disabled=on 也认 → disabled=1" '"disabled":1' "$s4"
ck "只有运行时 config.disabled → disabled=1" '"disabled":1' "$s3"
ck "只有运行时禁用不算 radio 禁用" '"radioDisabled":0' "$s3"
ck "radio up 但接口没建立 → disabled=1" '"disabled":1' "$s5"
ck "radio up 但接口没建立 → radioDisabled=0" '"radioDisabled":0' "$s5"
ck "radio 运行时 down → disabled=1" '"disabled":1' "$s6"
ck "radio 运行时 down → radioDisabled=1" '"radioDisabled":1' "$s6"

done_report
