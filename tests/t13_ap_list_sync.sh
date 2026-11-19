#!/bin/sh
# t13：真机复现（用户 2026-11-18 的 selfcheck 原样）
#   AP 卡「互联网」显示 3 个已连接客户端，点开列表却是 0 条；在线客户端也是 0。
#   设备实况：
#     ap_meta  phy2-ap0 → 互联网 / default_radio2（5G，3 个关联终端）
#     ndsctl   只有 1 条：5A:B9:A5:A2:06:0F Preauthenticated，clientif 为空
#     sta_map  3 条（66:0e… / 0c:93… / 50:29…）全都挂在 phy2-ap0
#   ① 关联表里有、ndsctl 没记录的设备必须出行（否则卡片数与列表条数对不上）
#   ② 在线 = 连着且有访问权限；没过门户的算「未认证」，不进在线卡
#   ③ 有线客户端 clientif 为空时用邻居表的设备名兜底（列表显示 br-lan（有线）），
#      且要进「有线」卡片（连接卡，不分身份）
. "$(dirname "$0")/lib.sh"
tmp_setup t13

mkdir -p "$S/bin"

# ---- ubus：network.wireless status（4 个 AP）+ hostapd 关联终端 ----
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = 'call' ] && [ "$2" = 'network.wireless' ]; then
	cat <<'J'
{
	"radio0": {
		"up": true,
		"interfaces": [
			{
				"section": "default_radio1",
				"ifname": "phy1-ap0",
				"config": {
					"mode": "ap",
					"ssid": "互联网 2.4G"
				}
			}
		]
	},
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
			},
			{
				"section": "wifinet3",
				"ifname": "phy2-ap1",
				"config": {
					"mode": "ap",
					"ssid": "guest"
				}
			},
			{
				"section": "wifinet4",
				"ifname": "phy2-ap2",
				"config": {
					"mode": "ap",
					"ssid": "staff"
				}
			}
		]
	}
}
J
fi
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap0' ]; then
	cat <<'J'
{
	"num_sta": 3,
	"clients": {
		"66:0E:56:87:1C:1D": {
			"address": "66:0e:56:87:1c:1d",
			"aid": "1"
		},
		"0C:93:8F:3E:E7:C5": {
			"address": "0c:93:8f:3e:e7:c5",
			"aid": "2"
		},
		"50:29:F5:AB:3D:BB": {
			"address": "50:29:f5:ab:3d:bb",
			"aid": "3"
		}
	}
}
J
fi
# 其余 AP 没有关联终端
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy1-ap0' ]; then
	echo '{"num_sta":0,"clients":{}}'
fi
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap1' ]; then
	echo '{"num_sta":0,"clients":{}}'
fi
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap2' ]; then
	echo '{"num_sta":0,"clients":{}}'
fi
UEOF

# ---- ip：邻居表（3 个无线终端也在 br-lan 邻居里，另加那条有线 Preauth）----
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*)
		printf '%s\n' \
			'10.10.10.68 dev br-lan lladdr 5a:b9:a5:a2:06:0f REACHABLE' \
			'10.10.10.71 dev br-lan lladdr 66:0e:56:87:1c:1d REACHABLE' \
			'10.10.10.72 dev br-lan lladdr 0c:93:8f:3e:e7:c5 STALE' \
			'10.10.10.73 dev br-lan lladdr 50:29:f5:ab:3d:bb REACHABLE' ;;
	*addr*) printf '%s\n' '2: br-lan    inet 10.10.10.1/24 brd 10.10.10.255 scope global br-lan' ;;
esac
IEOF

# ---- ndsctl：只有一条 Preauthenticated，clientif 为空（真机原样）----
cat >"$S/bin/ndsctl" <<'NEOF'
#!/bin/sh
case "$1" in
	status) echo "openNDS daemon v10.2.0"; exit 0 ;;
	json)
		cat <<J
{
  "client_list_length":"1",
  "clients":{
    "5A:B9:A5:A2:06:0F":{
      "gatewayname":"OpenNDS",
      "gatewayaddress":"10.10.10.1",
      "gatewayfqdn":"status.client",
      "version":"10.2.0",
      "client_type":"cpd_can",
      "mac":"5A:B9:A5:A2:06:0F",
      "ip":"10.10.10.68",
      "clientif":"",
      "session_start":"1763000000",
      "session_end":"null",
      "last_active":"1763000100",
      "token":"aaaa0001",
      "state":"Preauthenticated",
      "custom":"none",
      "download_rate_limit_threshold":"null",
      "download_packet_rate":"null",
      "download_bucket_size":"null",
      "upload_rate_limit_threshold":"null",
      "upload_packet_rate":"null",
      "upload_bucket_size":"null",
      "download_quota":"null",
      "upload_quota":"null",
      "download_this_session":"0",
      "download_session_avg":"0.00",
      "upload_this_session":"0",
      "upload_session_avg":"0.00"
    }
  },
  "trusted_list_length":"0",
  "trusted":[
  ]
}
J
		exit 0
		;;
esac
exit 0
NEOF
chmod +x "$S/bin/"*

# ---- 配置：4 个 AP ----
mk_radio() {
	mkdir -p "$MOCK_UCI_ROOT/wireless/$1"
	printf 'wifi-device' >"$MOCK_UCI_ROOT/wireless/$1/.type"
}
mk_iface() { # $1=sec $2=device $3=ssid
	mkdir -p "$MOCK_UCI_ROOT/wireless/$1"
	printf 'wifi-iface' >"$MOCK_UCI_ROOT/wireless/$1/.type"
	printf 'ap' >"$MOCK_UCI_ROOT/wireless/$1/mode"
	printf '%s' "$2" >"$MOCK_UCI_ROOT/wireless/$1/device"
	printf '%s' "$3" >"$MOCK_UCI_ROOT/wireless/$1/ssid"
}
mk_radio radio0
mk_radio radio2
mk_iface default_radio1 radio0 '互联网 2.4G'
mk_iface default_radio2 radio2 '互联网'
mk_iface wifinet3 radio2 'guest'
mk_iface wifinet4 radio2 'staff'

mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'br-lan' >"$MOCK_UCI_ROOT/opennds/opennds/gatewayinterface"

export PATH="$S/bin:$PATH"

out=$(call overview dashboard)

echo "== 接入点卡片 =="
ap_seg() { printf '%s' "$1" | tr '}' '\n' | grep -F "\"ssid\":\"$2\""; }
a5=$(ap_seg "$out" '互联网')
ck "互联网 5G 卡片计数=3（hostapd 关联终端）" '"count":3' "$a5"
ck "guest 卡片计数=0" '"ssid":"guest","section":"wifinet3","count":0' "$out"

echo "== 卡片数 = 点开后的列表条数 =="
# 按段名筛（前端 apFilterMatch 用的就是 apsec），数 online 行
n_ap=$(printf '%s' "$out" | tr '{' '\n' | grep -F '"apsec":"default_radio2"' |
	grep -c '"online":true')
ck "互联网卡片 3 = 按该 AP 筛出 3 条" '3' "$n_ap"

echo "== 客户端列表 =="
seg() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"mac\":\"$2\""; }
for m in 66:0e:56:87:1c:1d 0c:93:8f:3e:e7:c5 50:29:f5:ab:3d:bb; do
	r=$(seg "$out" "$m")
	ck "关联终端 $m 出行" "\"mac\":\"$m\"" "$r"
	ck "关联终端 $m online=true（连着就在线）" '"online":true' "$r"
	ck "关联终端 $m 未认证（authorized=false）" '"authorized":false' "$r"
done
r5=$(seg "$out" '5a:b9:a5:a2:06:0f')
ck "有线客户端 clientif 空 → 邻居表补 iface=br-lan" '"iface":"br-lan"' "$r5"
ck "有线客户端 ip 保留" '"ip":"10.10.10.68"' "$r5"

echo "== 统计卡片 =="
counts=$(printf '%s' "$out" | grep -o '"counts":{[^}]*}')
ck "在线=0（都没过门户：在线卡只算有访问权限的）" '"online":0' "$counts"
ck "有线=1（br-lan 邻居表里的那条 Preauth）" '"wired":1' "$counts"
ck "未认证=4（都没过门户）" '"unauthenticated":4' "$counts"
ck "已认证=0" '"authenticated":0' "$counts"

echo "== 有线标记 =="
ck "有线客户端行 wired=true" '"online":true,"authorized":false,"wired":true' "$r5"
n_wd=$(printf '%s' "$out" | grep -o '"wired":true' | wc -l | tr -d ' ')
ck "列表 wired=true 行数=1" '1' "$n_wd"

echo "== 连接卡 = 列表条数 =="
# 未认证卡与有线卡都是「连着就算」的口径，各自与列表条数同源
n_on=$(printf '%s' "$out" | grep -o '"online":true' | wc -l | tr -d ' ')
ck "列表 online=true 行数=4（=未认证卡）" '4' "$n_on"

done_report
