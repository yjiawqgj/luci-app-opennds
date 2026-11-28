#!/bin/sh
# t29：主题脚本的"有效期内漏恢复客户端重连静默放行"逻辑
#
# 场景：关 NDS 时客户端离线（如手机切 guest），开机那次恢复没赶上；
#       等它重连、openNDS 要弹门户时，主题脚本认出它是漏恢复设备，
#       用 ndsctl auth 按剩余时长静默放行，不弹门户。
# 判据（必须同时满足，避免误放）：
#   1. authlog 里该 MAC 未到期
#   2. binauthlog 末条是 shutdown_deauth / preemptive_auth
#   3. 不在黑名单
# 本用例 mock 掉 ndsctl b64decode / do_ndsctl auth / uci，直接 source 主题脚本
# 并调用 cpd_auto_restore，观察是否放行（AUTH_CALLS 有记录）与是否输出成功页。
. "$(dirname "$0")/lib.sh"
tmp_setup t29

THEME_SRC="$REPO/luci-app-opennds-manager/root/usr/lib/opennds/theme_zone_detect.sh"
TS="$S/theme.sh"
cp "$THEME_SRC" "$TS" || exit 1

# 沙箱里自建 mock bin，放在公共桩之前，覆盖 ndsctl（保留其余）
MB="$S/mockbin"; mkdir -p "$MB"
cp "$HERE/mock/bin/"* "$MB/" 2>/dev/null
cat >"$MB/ndsctl" <<'STUB'
#!/bin/sh
# b64decode：用 python 解码 base64（含补位），其余子命令记录到日志
if [ "$1" = "b64decode" ]; then
	python -c "import sys,base64; s=sys.argv[1]; s+='='*(-len(s)%4); sys.stdout.write(base64.b64decode(s).decode('latin1'))" "$2" 2>/dev/null
	exit 0
fi
[ -n "$NDSCTL_LOG" ] && echo "$1 $2 $3" >>"$NDSCTL_LOG"
exit 0
STUB
chmod +x "$MB/ndsctl"

# 账本目录（zone_logdir 走 CPD_NDSLOG_DIR）
LED="$CPD_NDSLOG_DIR"; mkdir -p "$LED"
AUTHLOG="$LED/authlog.log"; BL="$LED/binauthlog.log"

# MAC A/B64：用 python 生成 authlog 的 base64(mac) 键（无 padding，与 openNDS 一致）
b64mac() { python -c "import sys,base64; print(base64.b64encode(sys.argv[1].encode()).decode().rstrip('='))" "$1"; }
mkrow() { # $1=mac $2=session_end
	printf '%s=%s\n' "$(b64mac "$1")" "$2" >>"$AUTHLOG"
}
mkbl() { # $1=mac $2=method
	printf 'method="%s", clientmac="%s", timestamp=1, session_end=2\n' "$2" "$1" >>"$BL"
}

# source 主题脚本（只取函数定义），mock do_ndsctl / zone_debug
setup_theme() {
	ndspid=1
	. "$TS" >/dev/null 2>&1 || exit 1
	# 覆盖放行函数：记录调用并设置成功状态
	# 真实调用形如 do_ndsctl auth "$mac" "$mins"，故 $1=auth $2=mac $3=分钟
	do_ndsctl() {
		echo "$1 $2 $3" >>"$AUTH_CALLS"
		ndsstatus="authenticated"
	}
	zone_debug() { :; }
}

# 跑一次自动恢复：$1=clientmac；输出成功页则 AUTO=1
run_ar() {
	AUTH_CALLS="$S/auth_calls"; : >"$AUTH_CALLS"
	(
		export PATH="$MB:$PATH" AUTH_CALLS NDSCTL_LOG="$S/ndsctl.log"
		setup_theme
		clientmac="$1"
		out=$(cpd_auto_restore)
		case "$out" in *'<body>OK</body>'*) echo "RESTORE" ;; *) echo "PORTAL" ;; esac
	) 2>/dev/null
}

now=$(date +%s)
MAC_OK='aa:bb:cc:11:22:33'      # 漏恢复：关机下线、未到期（含字母，便于测大小写）
MAC_LOGOUT='11:22:33:44:55:67'  # 主动登出
MAC_EXPIRED='11:22:33:44:55:68' # 已过期
MAC_IDLE='11:22:33:44:55:69'    # 空闲踢
MAC_BL='11:22:33:44:55:70'      # 黑名单
MAC_PRE='11:22:33:44:55:71'     # 恢复记录

echo "== 准备账本 =="
: >"$AUTHLOG"; : >"$BL"
mkrow "$MAC_OK" $((now+3600));     mkbl "$MAC_OK" shutdown_deauth
mkrow "$MAC_LOGOUT" $((now+3600)); mkbl "$MAC_LOGOUT" client_deauth
mkrow "$MAC_EXPIRED" $((now-100)); mkbl "$MAC_EXPIRED" shutdown_deauth
mkrow "$MAC_IDLE" $((now+3600));   mkbl "$MAC_IDLE" idle_deauth
mkrow "$MAC_BL" $((now+3600));     mkbl "$MAC_BL" shutdown_deauth
mkrow "$MAC_PRE" $((now+7200));    mkbl "$MAC_PRE" preemptive_auth
# 黑名单：写入 uci 桩
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"; printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '%s\n' "$MAC_BL" >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"

echo "== C1 漏恢复（关机下线+未到期）→ 静默放行 =="
r=$(run_ar "$MAC_OK"); ck "漏恢复放行了门户" "RESTORE" "$r"
ck "ndsctl auth 调用了且带剩余分钟" "auth $MAC_OK 60" "$(cat "$S/auth_calls")"

echo "== C2 主动登出 → 弹门户 =="
r=$(run_ar "$MAC_LOGOUT"); ck "主动登出不放行" "PORTAL" "$r"

echo "== C3 已过期 → 弹门户 =="
r=$(run_ar "$MAC_EXPIRED"); ck "过期不放行" "PORTAL" "$r"

echo "== C4 空闲踢 → 弹门户 =="
r=$(run_ar "$MAC_IDLE"); ck "空闲踢不放行" "PORTAL" "$r"

echo "== C5 黑名单 → 弹门户（绝不绕过） =="
r=$(run_ar "$MAC_BL"); ck "黑名单不放行" "PORTAL" "$r"

echo "== C6 恢复记录（preemptive_auth）未到期 → 放行 =="
r=$(run_ar "$MAC_PRE"); ck "恢复记录放行" "RESTORE" "$r"

echo "== C7 账本里没有的设备 → 弹门户 =="
r=$(run_ar 'aa:aa:aa:aa:aa:aa'); ck "未知设备不放行" "PORTAL" "$r"

echo "== C8 大写 MAC 输入同样命中（真机 MAC 字母大小写不定） =="
# 账本里 MAC_OK 是小写，这里用全大写输入，判据两边都小写化后应命中
r=$(run_ar 'AA:BB:CC:11:22:33'); ck "大写MAC命中" "RESTORE" "$r"
ck "大写MAC也调用放行" "auth AA:BB:CC:11:22:33 60" "$(cat "$S/auth_calls")"

done_report
