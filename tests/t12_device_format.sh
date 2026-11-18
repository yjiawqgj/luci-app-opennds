#!/bin/sh
# t12：真机输出格式复现（2026-11-18 用户提供 Athena 真机诊断）。
#   设备：hostapd.phy1-ap0 / hostapd.phy2-ap0 / phy2-ap1 / phy2-ap2 都在，
#   iwinfo assoclist、iw station dump 正常。页面上卡片却全 0。
#   本用例按 netifd wireless.c / hostapd ubus / iw / ndsctl 的【真机原样
#   输出】搭桩，复现整条 dashboard 链路，任何一环断了都会在这暴露。
. "$(dirname "$0")/lib.sh"
tmp_setup t12

mkdir -p "$S/bin"

# ---- uci wireless：与真机等价的 4 个 AP section（radio1×1 + radio2×3）----
# mock-uci 是「每 section 一个目录」的结构（见 tests/mock/bin/uci）
mk_dev() { # $1=section $2=band $3=channel
	mkdir -p "$MOCK_UCI_ROOT/wireless/$1"
	printf 'wifi-device' >"$MOCK_UCI_ROOT/wireless/$1/.type"
	printf 'mac80211' >"$MOCK_UCI_ROOT/wireless/$1/type"
	printf '%s' "$2" >"$MOCK_UCI_ROOT/wireless/$1/band"
	printf '%s' "$3" >"$MOCK_UCI_ROOT/wireless/$1/channel"
}
mk_ap() { # $1=section $2=device $3=ssid
	mkdir -p "$MOCK_UCI_ROOT/wireless/$1"
	printf 'wifi-iface' >"$MOCK_UCI_ROOT/wireless/$1/.type"
	printf 'ap' >"$MOCK_UCI_ROOT/wireless/$1/mode"
	printf '%s' "$2" >"$MOCK_UCI_ROOT/wireless/$1/device"
	printf '%s' "$3" >"$MOCK_UCI_ROOT/wireless/$1/ssid"
}
mk_dev radio1 2g 6
mk_ap default_radio1 radio1 'Home'
mk_dev radio2 5g 36
mk_ap default_radio2 radio2 '互联网'
mk_ap wifinet3 radio2 'guest'
mk_ap wifinet4 radio2 'iot'
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'br-lan' >"$MOCK_UCI_ROOT/opennds/opennds/gatewayinterface"

# ---- ubus：network.wireless status —— 按 netifd wireless.c 的
# wireless_interface_status() 键序（section → ifname → config）逐字输出；
# config 是嵌套对象，jsonfilter 解析也要过这一关 ----
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = 'call' ] && [ "$2" = 'network.wireless' ]; then
	cat <<'J'
{
	"radio1": {
		"up": true,
		"pending": false,
		"autostart": true,
		"disabled": false,
		"retry_setup_failed": false,
		"config": {
			"path": "platform/soc/11000000.wmac",
			"channel": "6",
			"band": "2g",
			"htmode": "HT20",
			"disabled": false
		},
		"interfaces": [
			{
				"section": "default_radio1",
				"ifname": "phy1-ap0",
				"config": {
					"mode": "ap",
					"ssid": "Home",
					"encryption": "psk2",
					"network": [
						"lan"
					],
					"mode": "ap"
				}
			}
		]
	},
	"radio2": {
		"up": true,
		"pending": false,
		"autostart": true,
		"disabled": false,
		"retry_setup_failed": false,
		"config": {
			"path": "platform/soc/1a143000.usb",
			"channel": "36",
			"band": "5g",
			"htmode": "VHT80",
			"disabled": false
		},
		"interfaces": [
			{
				"section": "default_radio2",
				"ifname": "phy2-ap0",
				"config": {
					"mode": "ap",
					"ssid": "互联网",
					"encryption": "psk2",
					"network": [
						"lan"
					],
					"mode": "ap"
				}
			},
			{
				"section": "wifinet3",
				"ifname": "phy2-ap1",
				"config": {
					"mode": "ap",
					"ssid": "guest",
					"encryption": "psk2",
					"network": [
						"guest"
					],
					"mode": "ap"
				}
			},
			{
				"section": "wifinet4",
				"ifname": "phy2-ap2",
				"config": {
					"mode": "ap",
					"ssid": "iot",
					"encryption": "psk2",
					"network": [
						"guest"
					],
					"mode": "ap"
				}
			}
		]
	}
}
J
	exit 0
fi
# hostapd.<if> get_clients —— hostapd ubus 真机格式：客户端对象以大写 MAC 为键
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap0' ]; then
	cat <<'J'
{
	"num_sta": 1,
	"clients": {
		"50:29:F5:AB:3D:BB": {
			"aid": "1",
			"auth": "1",
			"assoc": "1",
			"authorized": "1",
			"seq_num": "0",
			"capability": "0x11",
			"signature": "test"
		}
	}
}
J
	exit 0
fi
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap1' ]; then
	printf '{\n\t"num_sta": 0,\n\t"clients": {}\n}\n'
	exit 0
fi
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap2' ]; then
	printf '{\n\t"num_sta": 0,\n\t"clients": {}\n}\n'
	exit 0
fi
if [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy1-ap0' ]; then
	printf '{\n\t"num_sta": 0,\n\t"clients": {}\n}\n'
	exit 0
fi
exit 0
UEOF

# ---- jsonfilter：真机自带。这里用真机等价实现（python 桩，仅测试用）----
cat >"$S/bin/jsonfilter" <<'JEOF'
#!/bin/sh
# 极简 -q -e <expr>：支持 @.a.b.up 这类链式取值
expr=''
while [ $# -gt 0 ]; do
	case "$1" in
		-e) expr="$2"; shift 2 ;;
		-q) shift ;;
		*) shift ;;
	esac
done
python3 - "$expr" <<'PY'
import json, sys
expr = sys.argv[1]
data = json.load(sys.stdin)
cur = data
try:
	path = expr.lstrip('@').lstrip('.')
	for k in path.split('.'):
		cur = cur[k]
	if isinstance(cur, bool):
		print('true' if cur else 'false')
	else:
		print(cur)
except Exception:
	pass
PY
JEOF

# ---- iw：真机格式（iw dev 列表 + info + station dump）----
cat >"$S/bin/iw" <<'WEOF'
#!/bin/sh
case "$1" in
	dev)
		case "$2" in
			'')
				# 真机：radio 下多个 BSS + 无线管理设备混排
				printf '%s\n' \
					'phy#0' \
					'Interface phy0-ap0' \
					$'\tifindex 5' \
					$'\twdev 0x00000002' \
					$'\taddr 00:11:22:33:44:55' \
					$'\ttype managed' \
					'' \
					'phy#1' \
					'Interface phy1-ap0' \
					$'\tifindex 6' \
					$'\twdev 0x10000002' \
					$'\taddr 00:11:22:33:44:56' \
					$'\ttype AP' \
					$'\tchannel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz' \
					'' \
					'phy#2' \
					'Interface phy2-ap0' \
					$'\tifindex 9' \
					$'\twdev 0x20000005' \
					$'\taddr 00:11:22:33:44:60' \
					$'\ttype AP' \
					$'\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
					'Interface phy2-ap1' \
					$'\tifindex 10' \
					$'\twdev 0x20000006' \
					$'\taddr 00:11:22:33:44:61' \
					$'\ttype AP' \
					$'\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
					'Interface phy2-ap2' \
					$'\tifindex 11' \
					$'\twdev 0x20000007' \
					$'\taddr 00:11:22:33:44:62' \
					$'\ttype AP' \
					$'\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz'
				;;
			phy1-ap0)
				:
				;;
			phy2-ap0)
				printf '%s\n' \
					'Interface phy2-ap0' \
					$'\tifindex 9' \
					$'\twdev 0x20000005' \
					$'\taddr 00:11:22:33:44:60' \
					$'\tssid \\xe4\\xba\\x92\\xe8\\x81\\x94\\xe7\\xbd\\x91' \
					$'\ttype AP' \
					$'\twiphy 2' \
					$'\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz'
				;;
			phy2-ap1)
				printf '%s\n' \
					'Interface phy2-ap1' \
					$'\tssid guest' \
					$'\ttype AP' \
					$'\twiphy 2'
				;;
			phy2-ap2)
				printf '%s\n' \
					'Interface phy2-ap2' \
					$'\tssid iot' \
					$'\ttype AP' \
					$'\twiphy 2'
				;;
			phy1-ap0x)
				:
				;;
			*)
				# iw dev <if> info
				printf '%s\n' \
					"Interface $2" \
					$'\tssid Home' \
					$'\ttype AP' \
					$'\twiphy 1'
				;;
		esac
		;;
	station)
		# iw dev <if> station dump —— 3 参形态：iw dev phy2-ap0 station dump
		case "$2" in
			phy2-ap0)
				printf '%s\n' \
					'Station 50:29:f5:ab:3d:bb (on phy2-ap0)' \
					$'\tauthorized:\tyes' \
					$'\tauthenticated:\tyes'
				;;
		esac
		;;
esac
exit 0
WEOF

# ---- iwinfo：真机格式 ----
cat >"$S/bin/iwinfo" <<'IEOF'
#!/bin/sh
case "$1" in
	phy2-ap0)
		case "$2" in
			assoclist)
				printf '%s\n' \
					'50:29:F5:AB:3D:BB  -73 dBm / -106 dBm (SNR 33)  303770 ms ago' \
					'RX: 351.0 MBit/s, VHT-MCS 4, 80MHz, VHT-NSS 2       152 Pkts.'
				;;
			info)
				printf '%s\n' \
					'phy2-ap0' \
					'  ESSID: "互联网"' \
					'  Access Point: 00:11:22:33:44:60' \
					'  Mode: Master'
				;;
		esac
		;;
	'')
		printf '%s\n' \
			'phy1-ap0  ESSID: "Home"' \
			'phy2-ap0  ESSID: "互联网"' \
			'phy2-ap1  ESSID: "guest"' \
			'phy2-ap2  ESSID: "iot"'
		;;
esac
exit 0
IEOF

# ---- ip：br-lan 地址 + 邻居表（真机格式，MAC 大写）----
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*)
		printf '%s\n' \
			'192.168.8.197 dev br-lan lladdr 50:29:F5:AB:3D:BB REACHABLE' ;;
	*addr*)
		printf '%s\n' '2: br-lan    inet 192.168.8.1/24 brd 192.168.8.255 scope global br-lan' ;;
esac
IEOF

# ---- ndsctl：openNDS 已启动，已认证客户端一条（clientif=phy2-ap0）----
cat >"$S/bin/ndsctl" <<'NEOF'
#!/bin/sh
case "$1" in
	status)
		printf '%s\n' \
			'type or paste code here' \
			'' \
			'openNDS is running, engaged.' \
			'' \
			'Managed interface: br-lan' \
			'' \
			'Preemptive authentication is enabled for 0 clients'
		;;
	json)
		cat <<J
{
  "client_list_length":"1",
  "clients":{
    "50:29:F5:AB:3D:BB":{
      "gatewayname":"Athena",
      "gatewayaddress":"192.168.8.1",
      "gatewayfqdn":"status.client",
      "version":"10.4.0",
      "client_type":"cpd_can",
      "mac":"50:29:F5:AB:3D:BB",
      "ip":"192.168.8.197",
      "clientif":"phy2-ap0",
      "session_start":"1763400000",
      "session_end":"null",
      "last_active":"1763400100",
      "token":"aaaa0001",
      "state":"Authenticated",
      "custom":"none",
      "download_rate_limit_threshold":"null",
      "download_packet_rate":"null",
      "download_bucket_size":"null",
      "upload_rate_limit_threshold":"null",
      "upload_packet_rate":"null",
      "upload_bucket_size":"null",
      "download_quota":"null",
      "upload_quota":"null",
      "download_this_session":"123456",
      "download_session_avg":"10.00",
      "upload_this_session":"1234",
      "upload_session_avg":"1.00"
    }
  },
  "trusted_list_length":"0"
}
J
		;;
esac
NEOF

# openNDS 配置已在上面布置（enabled=1）
export PATH="$S/bin:$PATH"

out=$(call overview dashboard)

echo "== AP 卡片 =="
ck "互联网 AP iface=phy2-ap0" '"iface":"phy2-ap0"' "$out"
ck "互联网 AP ssid=互联网" '"ssid":"互联网"' "$out"
ck "互联网 AP 计数=1（真机 50:29:F5:AB:3D:BB 在线）" '"count":1' "$out"
ck "guest AP 计数=0" '"ssid":"guest","section":"wifinet3","count":0' "$out"

echo "== 统计卡片 =="
counts=$(printf '%s' "$out" | grep -o '"counts":{[^}]*}')
ck "在线=1" '"online":1' "$counts"
ck "已认证=1" '"authenticated":1' "$counts"

echo "== 客户端列表 =="
ck "客户端行有 ssid=互联网（接入点列显示 WiFi 名）" '"ssid":"互联网"' "$out"
ck "客户端行 apsec=default_radio2" '"apsec":"default_radio2"' "$out"
ck "客户端行 online=true" '"online":true' "$out"
ck "客户端行 authorized=true" '"authorized":true' "$out"

done_report
