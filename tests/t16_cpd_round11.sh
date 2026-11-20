#!/bin/sh
# t16：本轮口径回归
#   A. 已认证会话缓存：NDS 停了 / 刚重启 ndsctl 没数据时，之前认证过且
#      还在有效期内的客户端不能被标成未认证（关→开切换也不进未认证卡）
#   B. 设置页四个 tab：脚本任意 .sh；文件夹必须含 default.sh 主入口；
#      settings status 的 items 即前端「已上传」的数据源
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

echo "== A1 NDS 运行中：把仍有效的已认证会话写进缓存 =="
out1=$(NDS_RUNNING=1 call overview dashboard)
ck "dashboard 正常返回" '"ok":1' "$out1"
ck "缓存记下已认证客户端" 'aa:bb:cc:dd:ee:01' "$(cat "$CPD_SESSION_CACHE" 2>/dev/null)"
case "$(cat "$CPD_SESSION_CACHE" 2>/dev/null)" in
	*22:33:44:55:66:77*) echo "  FAIL 未认证的客户端不该进缓存"; fail=1 ;;
	*) echo "  OK   未认证的客户端不进缓存" ;;
esac

echo "== A2 NDS 关闭、ndsctl 无数据：之前认证过且有效期内 → 仍显示已认证 =="
out2=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
r2=$(row "$out2" 'aa:bb:cc:dd:ee:01')
ck "已认证客户端不再标未认证" '"authenticated":true' "$r2"
r3=$(row "$out2" '22:33:44:55:66:77')
ck "本来未认证的照旧" '"authenticated":false' "$r3"

echo "== A3 从关切到开、ndsctl 还没就绪：已认证客户端直接进已认证卡 =="
out3=$(NDS_RUNNING=1 NDSCTL_EMPTY=1 call overview dashboard)
cnt3=$(printf '%s' "$out3" | grep -o '"counts":{[^}]*}')
ck "已认证卡=1（不落进未认证卡）" '"authenticated":1' "$cnt3"
ck "未认证卡只留真正未认证的那台" '"unauthenticated":1' "$cnt3"
ck "行身份仍是已认证" '"authenticated":true' "$(row "$out3" 'aa:bb:cc:dd:ee:01')"

echo "== A4 过期会话不再恢复 =="
printf 'aa:bb:cc:dd:ee:01\t1\n' >"$CPD_SESSION_CACHE"
out4=$(NDS_RUNNING=0 NDSCTL_EMPTY=1 call overview dashboard)
ck "过期会话恢复为未认证" '"authenticated":false' "$(row "$out4" 'aa:bb:cc:dd:ee:01')"

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
cp "$REPO/luci-app-opennds-cpd/root/usr/lib/opennds/theme_zone_detect.sh" "$TS"
sed -i -e "s#^CPD_ROOT=.*#CPD_ROOT=\"$CPD_ROOT\"#" "$TS"
mkdir -p "$CPD_ROOT/global/newfolder" "$CPD_ROOT/global/oldfolder"
printf '#!/bin/sh\necho new\n' >"$CPD_ROOT/global/newfolder/default.sh"
printf '#!/bin/sh\necho old\n' >"$CPD_ROOT/global/oldfolder/theme.sh"
p1=$( ( . "$TS" >/dev/null 2>&1; portal_from_name "$CPD_ROOT/global" newfolder ) )
p2=$( ( . "$TS" >/dev/null 2>&1; portal_from_name "$CPD_ROOT/global" oldfolder ) )
ck "文件夹 default.sh 被解析为主入口" '/newfolder/default.sh' "$p1"
ck "旧 theme.sh 仍兼容" '/oldfolder/theme.sh' "$p2"

done_report
