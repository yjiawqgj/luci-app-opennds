#!/bin/sh
# t16：本轮口径回归
#   A. 认证身份读 openNDS 原生落盘记录（authlog.log）：NDS 停了 / 刚重启
#      ndsctl 没数据时，认证还在有效期内的客户端仍算已认证；关→开不进未认证卡；
#      有效期外/主动登出的不算。已认证卡不管在线不在线都统计。
#   B. 设置页四个 tab：脚本任意 .sh；文件夹必须含 default.sh 主入口；
#      settings status 的 items 即前端「已配置」的数据源
#   C. 分发器 portal_from_name 认文件夹里的 default.sh（兼容旧 theme.sh）
. "$(dirname "$0")/lib.sh"
tmp_setup t16

mkdir -p "$S/bin"
# ---- ubus：网络接口 + hostapd 关联表 ----
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = network.wireless ]; then
cat <<'J'
{
	"radio2": {
		"up": true,
		"interfaces": [
			{
				"section": "default_radio2",
				"ifname": "phy2-ap0",
				"config": {
					"mode": "ap",
					"ssid": "互联网"
				}
			}
		]
	}
}
J
fi
if [ "$1" = call ] && [ "$2" = hostapd.phy2-ap0 ]; then
cat <<'J'
{
	"num_sta": 2,
	"clients": {
		"AA:BB:CC:DD:EE:01": {
			"address": "aa:bb:cc:dd:ee:01"
		},
		"22:33:44:55:66:77": {
			"address": "22:33:44:55:66:77"
		}
	}
}
J
fi
UEOF
# ---- ip：邻居表 ----
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*) printf '%s\n' '10.0.0.9 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE' '10.0.0.3 dev br-lan lladdr 22:33:44:55:66:77 REACHABLE' ;;
	*addr*) printf '%s\n' '2: br-lan    inet 10.0.0.1/24 brd 10.0.0.255 scope global br-lan' ;;
esac
IEOF
# ---- ndsctl：NDSCTL_EMPTY=1 模拟停了/刚重启还没就绪 ----
NOW=$(date +%s)
EXP=$((NOW + 600))
cat >"$S/bin/ndsctl" <<NEOF
#!/bin/sh
case "\$1" in
	status) echo 'openNDS daemon v10.0.0'; exit 0 ;;
	json)
		[ -n "\$NDSCTL_EMPTY" ] && { echo '{"client_list_length":"0","clients":{}}'; exit 0; }
		cat <<J
{"client_list_length":"2","clients":{
"AA:BB:CC:DD:EE:01": {
"mac":"AA:BB:CC:DD:EE:01",
"ip":"10.0.0.9",
"clientif":"phy2-ap0",
"state":"Authenticated",
"session_start":"$NOW",
"session_end":"$EXP",
"last_active":"$NOW",
"download_this_session":"1",
"upload_this_session":"1"
},
"22:33:44:55:66:77": {
"mac":"22:33:44:55:66:77",
"ip":"10.0.0.3",
"clientif":"phy2-ap0",
"state":"Preauthenticated",
"session_start":"$NOW",
"session_end":"null",
"last_active":"$NOW"
}
}}
J
		exit 0 ;;
esac
exit 0
NEOF
chmod +x "$S/bin/"*
export PATH="$S/bin:$PATH"

mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'br-lan' >"$MOCK_UCI_ROOT/opennds/opennds/gatewayinterface"
printf '120' >"$MOCK_UCI_ROOT/opennds/opennds/authidletimeout"

mkdir -p "$MOCK_UCI_ROOT/wireless/default_radio2"
printf 'wifi-iface' >"$MOCK_UCI_ROOT/wireless/default_radio2/.type"
printf 'ap' >"$MOCK_UCI_ROOT/wireless/default_radio2/mode"
printf 'radio2' >"$MOCK_UCI_ROOT/wireless/default_radio2/device"
printf '互联网' >"$MOCK_UCI_ROOT/wireless/default_radio2/ssid"

row() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"mac\":\"$2\""; }

# ---- openNDS 原生落盘：authlog.log（base64 mac 去等号=到期时间戳）
# aa:bb:cc:dd:ee:01 认证到 $EXP（有效）；22:33:44:55:66:77 不在 authlog（从没认证）
mkdir -p "$CPD_NDSLOG_DIR"
B1=$(printf 'aa:bb:cc:dd:ee:01' | base64 | tr -d '=')
printf '%s=%s\n' "$B1" "$EXP" >"$CPD_NDSLOG_DIR/authlog.log"
: >"$CPD_NDSLOG_DIR/binauthlog.log"

echo "== A1 NDS 运行中、ndsctl 有数据：dashboard 正常 =="
out1=$(NDS_RUNNING=1 call overview dashboard)
ck "dashboard 正常返回" '"ok":1' "$out1"
ck "已认证客户端为已认证" '"authenticated":true' "$(row "$out1" 'aa:bb:cc:dd:ee:01')"
ck "未认证客户端照旧未认证" '"authenticated":false' "$(row "$out1" '22:33:44:55:66:77')"

echo "== A2 NDS 关闭、ndsctl 无数据：读原生 authlog → 仍显示已认证 =="
out2=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
r2=$(row "$out2" 'aa:bb:cc:dd:ee:01')
ck "已认证客户端不再标未认证" '"authenticated":true' "$r2"
r3=$(row "$out2" '22:33:44:55:66:77')
ck "本来未认证的照旧" '"authenticated":false' "$r3"
cnt2=$(printf '%s' "$out2" | grep -o '"counts":{[^}]*}')
ck "已认证卡=1（NDS 停也统计有效期内）" '"authenticated":1' "$cnt2"

echo "== A3 从关切到开、ndsctl 还没就绪：已认证客户端直接进已认证卡 =="
out3=$(NDS_RUNNING=1 NDSCTL_EMPTY=1 call overview dashboard)
cnt3=$(printf '%s' "$out3" | grep -o '"counts":{[^}]*}')
ck "已认证卡=1（不落进未认证卡）" '"authenticated":1' "$cnt3"
ck "未认证卡只留真正未认证的那台" '"unauthenticated":1' "$cnt3"
ck "行身份仍是已认证" '"authenticated":true' "$(row "$out3" 'aa:bb:cc:dd:ee:01')"

echo "== A4 已过期会话不再算已认证 =="
BOLD=$(printf 'aa:bb:cc:dd:ee:01' | base64 | tr -d '=')
printf '%s=%s\n' "$BOLD" '1' >"$CPD_NDSLOG_DIR/authlog.log"
out4=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
ck "过期会话恢复为未认证" '"authenticated":false' "$(row "$out4" 'aa:bb:cc:dd:ee:01')"
# 恢复有效记录供后续用例
printf '%s=%s\n' "$B1" "$EXP" >"$CPD_NDSLOG_DIR/authlog.log"

echo "== A5 主动登出（binauthlog 末尾 ndsctl_deauth）不算已认证 =="
# 真机 binauth_log.sh 写的是无引号 method=xxx（不是 method="xxx"）。
# 这条用工整的真机格式，专门卡住「带引号 sed 匹配不到 → deauth 没被排除」的 bug。
NOW5=$(date +%s)
printf 'Wed Nov 21 10:00:00 2026, method=client_auth, clientmac=aa:bb:cc:dd:ee:01, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=y\n' "$((NOW5-600))" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
printf 'Wed Nov 21 17:30:00 2026, method=ndsctl_deauth, clientmac=aa:bb:cc:dd:ee:01, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=y\n' "$((NOW5-600))" "$EXP" >>"$CPD_NDSLOG_DIR/binauthlog.log"
out5=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
ck "ndsctl deauth 后不算已认证" '"authenticated":false' "$(row "$out5" 'aa:bb:cc:dd:ee:01')"
# 对照：shutdown_deauth 是停 NDS 造成的，官方 auth_restore 仍恢复认证
printf 'Wed Nov 21 17:30:00 2026, method=shutdown_deauth, clientmac=aa:bb:cc:dd:ee:01, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=y\n' "$((NOW5-600))" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
out5b=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
ck "shutdown_deauth 仍算已认证" '"authenticated":true' "$(row "$out5b" 'aa:bb:cc:dd:ee:01')"
: >"$CPD_NDSLOG_DIR/binauthlog.log"

echo "== A6 ARP 残留（STALE）不算在线有线，接入点不显示 br-lan =="
# 造一台只在 STALE ARP 里、没连 WiFi、不在名单里的设备
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*) printf '%s\n' \
		'10.0.0.9 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE' \
		'10.0.0.3 dev br-lan lladdr 22:33:44:55:66:77 REACHABLE' \
		'10.0.0.50 dev br-lan lladdr 0c:93:8f:3e:e7:c5 REACHABLE' \
		'10.0.0.99 dev br-lan lladdr de:ad:be:ef:00:99 STALE' ;;
	*addr*) printf '%s\n' '2: br-lan    inet 10.0.0.1/24 brd 10.0.0.255 scope global br-lan' ;;
esac
IEOF
chmod +x "$S/bin/ip"
out6=$(NDS_RUNNING=0 call overview dashboard)
r6=$(row "$out6" 'de:ad:be:ef:00:99')
if [ -z "$r6" ]; then
	echo "  OK   STALE 残留设备不进客户端列表（不显示成 br-lan 有线）"
else
	echo "  FAIL STALE 残留设备仍出现在列表: $r6"; fail=1
fi
# 0c:93 是 REACHABLE 且不在关联表 → 真有线算 1；STALE 的 de:ad 不算
cnt6=$(printf '%s' "$out6" | grep -o '"wired":[0-9]*')
ck "有线卡=1（只算 REACHABLE 的真有线，STALE 残留不算）" '"wired":1' "$cnt6"
# 真有线设备照常在列表里、接入点显示 br-lan
ck "REACHABLE 有线设备接入点=br-lan" '"iface":"br-lan"' "$(row "$out6" '0c:93:8f:3e:e7:c5')"
# 恢复原 ip 桩
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*) printf '%s\n' '10.0.0.9 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE' '10.0.0.3 dev br-lan lladdr 22:33:44:55:66:77 REACHABLE' ;;
	*addr*) printf '%s\n' '2: br-lan    inet 10.0.0.1/24 brd 10.0.0.255 scope global br-lan' ;;
esac
IEOF
chmod +x "$S/bin/ip"

echo "== A7 详情时间：认证时间取最近一次认证；上线时间由关联时长倒推；默认会话时长 =="
# binauthlog：真机 binauth_log.sh 认证成功写的是 method=client_auth（末段才是
# auth），不是 method=auth。aa:bb:..:01 有两条（首次 T1、后来 T2），按用户口径
# 「认证时间只认本次认证」取最近的 T2。
T1=$((NOW - 3600))
T2=$((NOW - 600))
printf 'Wed Nov 20 10:00:00 2024, method=client_auth, clientmac=aa:bb:cc:dd:ee:01, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=y\n' "$T1" "$T1" >"$CPD_NDSLOG_DIR/binauthlog.log"
printf 'Wed Nov 20 11:00:00 2024, method=client_auth, clientmac=aa:bb:cc:dd:ee:01, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=y\n' "$T2" "$T2" >>"$CPD_NDSLOG_DIR/binauthlog.log"
# hostapd 桩带 connected_time=120 秒（aa:bb..01 已连 120 秒）
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = network.wireless ]; then
cat <<'J'
{
	"radio2": {
		"up": true,
		"interfaces": [
			{
				"section": "default_radio2",
				"ifname": "phy2-ap0",
				"config": {
					"mode": "ap",
					"ssid": "互联网"
				}
			}
		]
	}
}
J
fi
if [ "$1" = call ] && [ "$2" = hostapd.phy2-ap0 ]; then
cat <<'J'
{
	"num_sta": 2,
	"clients": {
		"AA:BB:CC:DD:EE:01": {
			"address": "aa:bb:cc:dd:ee:01",
			"connected_time": 120
		},
		"22:33:44:55:66:77": {
			"address": "22:33:44:55:66:77",
			"connected_time": 30
		}
	}
}
J
fi
UEOF
chmod +x "$S/bin/ubus"
# 全局默认会话时长
printf '600' >"$MOCK_UCI_ROOT/opennds/opennds/sessiontimeout"
out7=$(NDS_RUNNING=1 call overview dashboard)
r7=$(row "$out7" 'aa:bb:cc:dd:ee:01')
case "$r7" in *'"authTime":"20'*) echo "  OK   认证时间有值（不再是—）";; *) echo "  FAIL 认证时间有值"; echo "       $r7"; fail=1;; esac
case "$r7" in *'"onlineTime":"20'*) echo "  OK   上线时间有值（关联时长倒推）";; *) echo "  FAIL 上线时间有值"; echo "       $r7"; fail=1;; esac
ck "默认会话时长=600" '"defaultSession":600' "$out7"
# 认证时间必须等于最近一次 T2（不是最早 T1），用 fmt 后的具体字符串核对
T2FMT=$(date -d "@$T2" '+%Y-%m-%d %H:%M' 2>/dev/null)
ck "认证时间=最近一次认证时刻（client_auth）" "\"authTime\":\"$T2FMT\"" "$r7"

echo "== A8 NDS 关闭：已认证客户端详情认证时间/到期时间都不为 — =="
# 关 NDS 后走补行路径，ss/se 从 ndsctl 拿不到；认证时间取落盘 binauthlog，
# 到期时间从 authlog.log 的 session_end 兜底，两个都不能是空。
out8=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
r8=$(row "$out8" 'aa:bb:cc:dd:ee:01')
case "$r8" in *'"authTime":"20'*) echo "  OK   关 NDS 后认证时间仍显示落盘值";; *) echo "  FAIL 关 NDS 后认证时间为空"; echo "       $r8"; fail=1;; esac
EXP_FMT=$(date -d "@$EXP" '+%Y-%m-%d %H:%M' 2>/dev/null)
ck "关 NDS 后到期时间=authlog 的 session_end" "\"expires\":\"$EXP_FMT\"" "$r8"

# 上线时间 = now - 120，允许 2 秒误差：这里只校验格式与存在，精确值由前端展示
: >"$CPD_NDSLOG_DIR/binauthlog.log"
printf '120' >"$MOCK_UCI_ROOT/opennds/opennds/sessiontimeout"
# 恢复无 connected_time 的 ubus 桩（用原样重建）
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = network.wireless ]; then
cat <<'J'
{
	"radio2": {
		"up": true,
		"interfaces": [ { "section": "default_radio2", "ifname": "phy2-ap0", "config": { "mode": "ap", "ssid": "互联网" } } ]
	}
}
J
fi
if [ "$1" = call ] && [ "$2" = hostapd.phy2-ap0 ]; then
cat <<'J'
{ "num_sta": 2, "clients": {
 "AA:BB:CC:DD:EE:01": { "address": "aa:bb:cc:dd:ee:01" },
 "22:33:44:55:66:77": { "address": "22:33:44:55:66:77" }
} }
J
fi
UEOF
chmod +x "$S/bin/ubus"

echo "== A9 ubus 无 connected_time 时，iw station dump 兜底出上线时间 =="
# 真机 hostapd ubus get_clients 是多行 pretty-print、且不带 connected_time。
# 重建多行 ubus 桩（紧凑单行会让 awk 只解析出一个 MAC），让 iw 桩给出时长。
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = network.wireless ]; then
cat <<'J'
{
	"radio2": {
		"up": true,
		"interfaces": [
			{
				"section": "default_radio2",
				"ifname": "phy2-ap0",
				"config": {
					"mode": "ap",
					"ssid": "互联网"
				}
			}
		]
	}
}
J
fi
if [ "$1" = call ] && [ "$2" = hostapd.phy2-ap0 ]; then
cat <<'J'
{
	"num_sta": 2,
	"clients": {
		"AA:BB:CC:DD:EE:01": { "address": "aa:bb:cc:dd:ee:01" },
		"22:33:44:55:66:77": { "address": "22:33:44:55:66:77" }
	}
}
J
fi
UEOF
chmod +x "$S/bin/ubus"
cat >"$S/bin/iw" <<'IEOF'
#!/bin/sh
case "$*" in
"dev phy2-ap0 station dump")
	printf '%s\n' \
		'Station aa:bb:cc:dd:ee:01 (on phy2-ap0)' \
		'\tconnected time:  90 seconds' \
		'\tsignal: -50 dBm' \
		'Station 22:33:44:55:66:77 (on phy2-ap0)' \
		'\tconnected time:  30 seconds'
		;;
"dev phy2-ap0 info") printf '\tssid "互联网"\n' ;;
"dev") printf '\tInterface phy2-ap0\n' ;;
esac
IEOF
chmod +x "$S/bin/iw"
out9=$(NDS_RUNNING=1 call overview dashboard)
r9=$(row "$out9" 'aa:bb:cc:dd:ee:01')
case "$r9" in *'"onlineTime":"20'*) echo "  OK   ubus 无时长时 iw 兜底出上线时间";; *) echo "  FAIL iw 兜底上线时间"; echo "       $r9"; fail=1;; esac
# 恢复原 iw 桩
cat >"$S/bin/iw" <<'IEOF'
#!/bin/sh
case "$*" in
"dev phy0-ap0 info") echo "	ssid Guest WiFi" ;;
"dev") printf '\tInterface phy0-ap0\n' ;;
*) : ;;
esac
IEOF
chmod +x "$S/bin/iw"

echo "== A10 身份变更（deauth）清除该 mac 两份落盘日志，其他 mac 保留 =="
# 用户口径：任何改变客户端身份的动作，先清原状态再应用新状态。
# deauth 是统一落点（解除认证/移出免认证/移出信任/拉黑都汇到这里）。
B1=$(printf 'aa:bb:cc:dd:ee:01' | base64 | tr -d '=')
B2=$(printf '22:33:44:55:66:77' | base64 | tr -d '=')
printf '%s=%s\n%s=%s\n' "$B1" "$EXP" "$B2" "$EXP" >"$CPD_NDSLOG_DIR/authlog.log"
printf 'method=client_auth, clientmac=aa:bb:cc:dd:ee:01, session_start=1, session_end=%s\nmethod=client_auth, clientmac=22:33:44:55:66:77, session_start=2, session_end=%s\n' "$EXP" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
NDS_RUNNING=1 call overview client_action deauth aa:bb:cc:dd:ee:01 >/dev/null
# authlog：目标 mac 解码后不再出现，无关 mac 仍在
if grep -qF "$B1" "$CPD_NDSLOG_DIR/authlog.log"; then echo "  FAIL authlog 目标 mac 未清"; fail=1; else echo "  OK   authlog 目标 mac 已清"; fi
if grep -qF "$B2" "$CPD_NDSLOG_DIR/authlog.log"; then echo "  OK   authlog 无关 mac 保留"; else echo "  FAIL authlog 无关 mac 被误删"; fail=1; fi
# binauthlog：目标 mac 行不在，无关 mac 行仍在
if grep -qF 'clientmac=aa:bb:cc:dd:ee:01' "$CPD_NDSLOG_DIR/binauthlog.log"; then echo "  FAIL binauthlog 目标 mac 未清"; fail=1; else echo "  OK   binauthlog 目标 mac 已清"; fi
if grep -qF 'clientmac=22:33:44:55:66:77' "$CPD_NDSLOG_DIR/binauthlog.log"; then echo "  OK   binauthlog 无关 mac 保留"; else echo "  FAIL binauthlog 无关 mac 被误删"; fail=1; fi
# 清日志后，NDS 停服也不再把这个 mac 算成已认证（auth_restore 遍历不到它）
out10=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
ck "清日志后目标 mac 不再已认证" '"authenticated":false' "$(row "$out10" 'aa:bb:cc:dd:ee:01')"

echo "== B1 设置页：脚本任意 .sh，文件夹必须含 default.sh =="
mkdir -p "$CPD_ROOT/default/wireless" "$S/up/d1/foo" "$S/up/df/foo" "$S/up/d2/bar"
printf '#!/bin/sh\necho foo\n' >"$S/up/d1/foo/default.sh"
printf '#!/bin/sh\necho foo\n' >"$S/up/df/foo/default.sh"
printf '#!/bin/sh\necho bar\n' >"$S/up/d2/bar/theme.sh"
printf '#!/bin/sh\necho any-name\n' >"$S/up/d1/any-name.sh"
out=$(call settings upload_default wireless d1 file any-name.sh)
ck "任意名称 .sh 可上传" '"ok":1' "$out"
[ -f "$CPD_ROOT/default/wireless/any-name.sh" ] &&
	echo "  OK   门户按原名落盘" || { echo "  FAIL 文件没落盘"; fail=1; }
out=$(call settings upload_default wireless df dir foo)
ck "含 default.sh 的文件夹可上传" '"ok":1' "$out"
[ -f "$CPD_ROOT/default/wireless/foo/default.sh" ] &&
	echo "  OK   文件夹主入口落盘" || { echo "  FAIL 文件夹没落盘"; fail=1; }
out=$(call settings upload_default wireless d2 dir bar)
ck "只有 theme.sh 的文件夹被拒绝" '"ok":0' "$out"
ck "拒绝原因说清 default.sh" 'default.sh' "$out"

echo "== B2 settings status 的 items 带上门户（前端「已上传」数据源） =="
call settings portal_save wireless foo >/dev/null
st=$(call settings status)
ck "status 列出文件夹门户" '"foo"' "$st"
ck "status 选中文件夹门户" '"sel":"foo"' "$st"

echo "== C 分发器认文件夹里的 default.sh（旧 theme.sh 仍兼容） =="
TS="$S/theme.sh"
cp "$REPO/luci-app-opennds-manager/root/usr/lib/opennds/theme_zone_detect.sh" "$TS"
sed -i -e "s#^CPD_ROOT=.*#CPD_ROOT=\"$CPD_ROOT\"#" "$TS"
mkdir -p "$CPD_ROOT/global/newfolder" "$CPD_ROOT/global/oldfolder"
printf '#!/bin/sh\necho new\n' >"$CPD_ROOT/global/newfolder/default.sh"
printf '#!/bin/sh\necho old\n' >"$CPD_ROOT/global/oldfolder/theme.sh"
p1=$( ( . "$TS" >/dev/null 2>&1; portal_from_name "$CPD_ROOT/global" newfolder ) )
p2=$( ( . "$TS" >/dev/null 2>&1; portal_from_name "$CPD_ROOT/global" oldfolder ) )
ck "文件夹 default.sh 被解析为主入口" '/newfolder/default.sh' "$p1"
ck "旧 theme.sh 仍兼容" '/oldfolder/theme.sh' "$p2"

done_report
