#!/bin/sh
# t9：概览页数据口径（用户现场逐条）
#   ① 在线 = 路由器视角「正在连接」（hostapd 关联表为准 + 有线邻居表），
#     不是 openNDS 的记录数——ndsctl 把客户端留到空闲超时，人走了记录还在
#   ② 卡片数字与列表条目同源：online 行数 = counts.online，按 AP 筛出的行数 = AP 卡片数
#   ③ 无线接入点卡片按 hostapd ubus 关联终端计数（clientif=br-lan 也能数出来）
#   ④ 客户端列表带 ssid：按 MAC 反查关联表，不依赖 clientif 与 SSID 的直配
#   ⑤ trusted 客户端 ndsctl 不给 ip 时用邻居表补
#   ⑥ 同一 MAC 同时在黑名单和信任名单：黑名单优先，应用后被自动清理
#   ⑦ openNDS 停止后照样能看到在线设备（关联表不经过 openNDS）
. "$(dirname "$0")/lib.sh"
tmp_setup t9

mkdir -p "$S/bin"

# ---- ubus：network.wireless status（radio2 两张 AP）+ hostapd 关联终端 ----
cat >"$S/bin/ubus" <<'UEOF'
#!/bin/sh
if [ "$1" = 'call' ] && [ "$2" = 'network.wireless' ]; then
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
			},
			{
				"section": "wifinet3",
				"ifname": "phy2-ap1",
				"config": {
					"mode": "ap",
					"ssid": "guest"
				}
			}
		]
	}
}
J
fi
# hostapd.<ifname> get_clients：关联终端（AP 计数与客户端 SSID 的权威来源）
# 设置 NDS_NO_HOSTAPD=1 时模拟"固件没带 hostapd ubus 对象"的机器，
# 验证 AP 计数退回按 clientif 计数的兜底路径
if [ -z "$NDS_NO_HOSTAPD" ] && [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap0' ]; then
	cat <<'J'
{
	"num_sta": 4,
	"clients": {
		"AA:BB:CC:DD:EE:01": {
			"address": "aa:bb:cc:dd:ee:01",
			"aid": "1"
		},
		"22:33:44:55:66:77": {
			"address": "22:33:44:55:66:77",
			"aid": "2"
		},
		"AA:BB:CC:DD:EE:09": {
			"address": "aa:bb:cc:dd:ee:09",
			"aid": "3"
		},
		"DC:D8:7B:53:E5:5A": {
			"address": "dc:d8:7b:53:e5:5a",
			"aid": "4"
		}
	}
}
J
fi
if [ -z "$NDS_NO_HOSTAPD" ] && [ "$1" = 'call' ] && [ "$2" = 'hostapd.phy2-ap1' ]; then
	cat <<'J'
{
	"num_sta": 1,
	"clients": {
		"11:22:33:44:55:66": {
			"address": "11:22:33:44:55:66",
			"aid": "1"
		}
	}
}
J
fi
UEOF

# ---- ip：邻居表（trusted 客户端的 IP 只能从这里来）+ 地址 ----
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*)
		printf '%s\n' \
			'10.0.0.9 dev br-lan lladdr 11:22:33:44:55:66 REACHABLE' \
			'10.0.0.8 dev br-lan lladdr aa:bb:cc:dd:ee:08 STALE' \
			'10.0.0.7 dev br-lan lladdr aa:bb:cc:dd:ee:09 REACHABLE' \
			'10.0.0.20 dev br-lan lladdr aa:bb:cc:dd:ee:20 REACHABLE' ;;
	*addr*) printf '%s\n' '2: br-lan    inet 10.0.0.1/24 brd 10.0.0.255 scope global br-lan' ;;
esac
IEOF

# ---- ndsctl：三个客户端（已认证 / 可信任 / 未认证）----
cat >"$S/bin/ndsctl" <<'NEOF'
#!/bin/sh
[ -n "$NDSCTL_LOG" ] && echo "$1 $2" >> "$NDSCTL_LOG"
case "$1" in
	status) echo "openNDS daemon v10.0.0"; exit 0 ;;
	json)
		# 与 openNDS src/util.c ndsctl_json_client() 输出格式逐字一致：
		# 客户端键缩进 4 空格，字段缩进 6 空格，冒号后无空格，最后一个字段无逗号
		# 可信任客户端的 clientif：默认 br-lan（没装 iw 的机器）；
		# NDS_NO_HOSTAPD 场景模拟"装了 iw、clientif 是真实接口名"的机器
		TR_CIF='br-lan'
		[ -n "$NDS_NO_HOSTAPD" ] && TR_CIF='phy2-ap1'
		cat <<J
{
  "client_list_length":"5",
  "clients":{
    "AA:BB:CC:DD:EE:01":{
      "gatewayname":"OpenNDS",
      "gatewayaddress":"10.0.0.1",
      "gatewayfqdn":"status.client",
      "version":"10.0.0",
      "client_type":"cpd_can",
      "mac":"AA:BB:CC:DD:EE:01",
      "ip":"10.0.0.2",
      "clientif":"phy2-ap0",
      "session_start":"1700000000",
      "session_end":"null",
      "last_active":"1700000100",
      "token":"aaaa0001",
      "state":"Authenticated",
      "custom":"none",
      "download_rate_limit_threshold":"null",
      "download_packet_rate":"null",
      "download_bucket_size":"null",
      "upload_rate_limit_threshold":"null",
      "upload_packet_rate":"null",
      "upload_bucket_size":"null",
      "download_quota":"1000000",
      "upload_quota":"null",
      "download_this_session":"100",
      "download_session_avg":"0.00",
      "upload_this_session":"50",
      "upload_session_avg":"0.00"
    },
    "11:22:33:44:55:66":{
      "gatewayname":"OpenNDS",
      "gatewayaddress":"10.0.0.1",
      "gatewayfqdn":"status.client",
      "version":"10.0.0",
      "client_type":"cpd_can",
      "mac":"11:22:33:44:55:66",
      "ip":"",
      "clientif":"${TR_CIF}",
      "session_start":"1700000000",
      "session_end":"null",
      "last_active":"1700000100",
      "token":"bbbb0002",
      "state":"Trusted",
      "custom":"none",
      "download_rate_limit_threshold":"null",
      "download_packet_rate":"null",
      "download_bucket_size":"null",
      "upload_rate_limit_threshold":"null",
      "upload_packet_rate":"null",
      "upload_bucket_size":"null",
      "download_quota":"null",
      "upload_quota":"null",
      "download_this_session":"10",
      "download_session_avg":"0.00",
      "upload_this_session":"5",
      "upload_session_avg":"0.00"
    },
    "22:33:44:55:66:77":{
      "gatewayname":"OpenNDS",
      "gatewayaddress":"10.0.0.1",
      "gatewayfqdn":"status.client",
      "version":"10.0.0",
      "client_type":"cpd_can",
      "mac":"22:33:44:55:66:77",
      "ip":"10.0.0.3",
      "clientif":"phy2-ap0",
      "session_start":"1700000000",
      "session_end":"null",
      "last_active":"1700000100",
      "token":"cccc0003",
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
    },
    "AA:BB:CC:DD:EE:07":{
      "gatewayname":"OpenNDS",
      "gatewayaddress":"10.0.0.1",
      "gatewayfqdn":"status.client",
      "version":"10.0.0",
      "client_type":"cpd_can",
      "mac":"AA:BB:CC:DD:EE:07",
      "ip":"10.0.0.6",
      "clientif":"phy2-ap0",
      "session_start":"1700000000",
      "session_end":"null",
      "last_active":"1700000100",
      "token":"dddd0007",
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
      "download_this_session":"0",
      "download_session_avg":"0.00",
      "upload_this_session":"0",
      "upload_session_avg":"0.00"
    },
    "AA:BB:CC:DD:EE:08":{
      "gatewayname":"OpenNDS",
      "gatewayaddress":"10.0.0.1",
      "gatewayfqdn":"status.client",
      "version":"10.0.0",
      "client_type":"cpd_can",
      "mac":"AA:BB:CC:DD:EE:08",
      "ip":"10.0.0.8",
      "clientif":"br-lan",
      "session_start":"1700000000",
      "session_end":"null",
      "last_active":"1700000100",
      "token":"eeee0008",
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
      "download_this_session":"0",
      "download_session_avg":"0.00",
      "upload_this_session":"0",
      "upload_session_avg":"0.00"
    }
  },
  "trusted_list_length":"1",
  "trusted":[
    "11:22:33:44:55:66"
  ]
}
J
		exit 0
		;;
esac
exit 0
NEOF
chmod +x "$S/bin/"*
export PATH="$S/bin:$PATH"

# ---- 配置：wireless（radio2 + 两张 AP）----
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
mk_radio radio2
mk_iface default_radio2 radio2 '互联网'
mk_iface wifinet3 radio2 'guest'

# ---- opennds 配置：信任名单里有 dc:d8:...（同时也在黑名单里，属于历史脏数据）----
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'br-lan' >"$MOCK_UCI_ROOT/opennds/opennds/gatewayinterface"
printf 'block' >"$MOCK_UCI_ROOT/opennds/opennds/macmechanism"
printf '11:22:33:44:55:66\ndc:d8:7b:53:e5:5a\naa:bb:cc:dd:ee:20' >"$MOCK_UCI_ROOT/opennds/opennds/trustedmac"
printf 'dc:d8:7b:53:e5:5a' >"$MOCK_UCI_ROOT/opennds/opennds/blockedmac"

out=$(call overview dashboard)
ck "dashboard 返回 ok" '{"ok":1' "$out"

# ① 统计口径。在线 = 连着且有访问权限（已认证 / 免认证已登录 / 可信任）：
#    aa01 + 11:22（无线）+ ee08 + ee20（有线）= 4；22:33、ee09 没过门户 → 只进未认证卡；
#    ee07 已离线（记录在人不在）不算；黑名单不算
counts=$(printf '%s' "$out" | grep -o '"counts":{[^}]*}')
ck "在线=3（有访问权限才算在线；未认证/离线/黑名单不算；ee08 STALE 不算在线）" '"online":3' "$counts"
ck "有线=1（只有 ee20 REACHABLE 台式机；ee08 STALE 残留不算有线）" '"wired":1' "$counts"
# 已认证卡改为"有效期内就算、不管在线"：ee07 虽离线但仍是已认证会话 → 计入
ck "已认证=3（aa01 + ee07 离线但会话有效 + dc:d8 黑名单除外另算；按有效期内口径）" '"authenticated":3' "$counts"
ck "未认证=2（22:33 未过门户 + ee09 门户外关联设备）" '"unauthenticated":2' "$counts"
ck "可信任=2（11:22 + ee20；黑名单里的重复条目不算）" '"trusted":2' "$counts"
ck "黑名单=1" '"blacklist":1' "$counts"

# ② 卡片数与列表同源：online 行 = 未认证卡 2 条 + 在线卡 4 条
n=$(printf '%s' "$out" | grep -o '"online":true' | wc -l | tr -d ' ')
ck "列表里 online=true 的行数=6（在线卡 3 + 未认证卡 2 + 黑名单客户端连着也算；ee08 STALE 不算）" '6' "$n"
# 有权限的是 4 条（aa01 / 11:22 / ee08 / ee20）：未认证的两条不算 authorized
n2=$(printf '%s' "$out" | grep -o '"online":true,"authorized":true' | wc -l | tr -d ' ')
ck "列表里 online+authorized 行数=3（=在线卡）" '3' "$n2"
n3=$(printf '%s' "$out" | grep -o '"wired":true' | wc -l | tr -d ' ')
ck "列表里 wired=true 的行数=1（=有线卡；ee08 STALE 不算）" '1' "$n3"

# ③ 无线接入点计数（ubus 映射：phy2-ap0 / phy2-ap1）
ap_seg() { printf '%s' "$1" | tr '}' '\n' | grep -F "\"ssid\":\"$2\""; }
a0=$(ap_seg "$out" '互联网')
a1=$(ap_seg "$out" 'guest')
ck "互联网 AP 运行时接口=phy2-ap0" '"iface":"phy2-ap0"' "$a0"
ck "guest AP 运行时接口=phy2-ap1" '"iface":"phy2-ap1"' "$a1"
ck "互联网 AP 计数=4（hostapd 关联终端；黑名单客户端连着 WIFI 也计入——
已连上就有 IP，卡片不依赖 NDS 运行，2026-11-21 用户口径）" '"count":4' "$a0"
ck "guest AP 计数=1（clientif=br-lan 也按 MAC 查到）" '"count":1' "$a1"

# ④⑤ 客户端行：SSID + 邻居表补 IP（trusted 的 clientif 是 br-lan，SSID 只能靠关联表）
seg() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"mac\":\"$2\""; }
r1=$(seg "$out" 'aa:bb:cc:dd:ee:01')
r2=$(seg "$out" '11:22:33:44:55:66')
r3=$(seg "$out" '22:33:44:55:66:77')
ck "已认证客户端 ssid=互联网" '"ssid":"互联网"' "$r1"
ck "可信任客户端按关联表补 ssid=guest" '"ssid":"guest"' "$r2"
# 同一 SSID 可能同时开在 2.4G/5G 上（两个段名）：列表要带段名，卡片才能精确筛选
ck "已认证客户端 apsec=default_radio2" '"apsec":"default_radio2"' "$r1"
ck "可信任客户端 apsec=wifinet3" '"apsec":"wifinet3"' "$r2"
ck "可信任客户端用邻居表补到 IP" '"ip":"10.0.0.9"' "$r2"
ck "可信任客户端 authorized=true" '"authorized":true' "$r2"
ck "预授权客户端行 online=true（人确实连着）" '"online":true' "$r3"
ck "预授权客户端 authorized=false（不计入在线卡）" '"authorized":false' "$r3"

# ⑧ 离线判定：ee07 在 openNDS 记录里但已不在关联表 → online=false
r7=$(seg "$out" 'aa:bb:cc:dd:ee:07')
ck "已离线客户端（记录还在人走了）online=false" '"online":false' "$r7"

# ⑨ STALE 的 ARP 残留（ee08）：只挂在邻居表里、状态 STALE（设备可能已走）
#    → 不算在线有线、接入点不显示 br-lan（2026-11-20 用户口径：非有线不显示成有线）
r8=$(seg "$out" 'aa:bb:cc:dd:ee:08')
ck "STALE 残留 online=false" '"online":false' "$r8"
ck "STALE 残留 wired=false" '"wired":false' "$r8"

# ⑨b 可信任有线台式机（ee20）：ndsctl json 里根本没有（trusted 不过门户），
#    只在邻居表里——按 openNDS 记录找有线永远找不到它（真机反馈：有线卡 0）
r20=$(seg "$out" 'aa:bb:cc:dd:ee:20')
ck "可信任有线台式机出行" '"mac":"aa:bb:cc:dd:ee:20"' "$r20"
ck "可信任有线台式机 online=true" '"online":true' "$r20"
ck "可信任有线台式机 wired=true" '"wired":true' "$r20"
ck "可信任有线台式机 trusted=true" '"trusted":true' "$r20"
ck "可信任有线台式机进在线卡" '"authorized":true' "$r20"

# ⑩ 连着但没碰过门户的设备（ee09，hostapd 有关联、ndsctl 没记录）：
#    必须出现在客户端列表里（未认证）——否则 AP 卡片显示 3、点开却是空的
r9=$(seg "$out" 'aa:bb:cc:dd:ee:09')
ck "门户外关联设备出行（AP 卡片数才与列表对得上）" '"mac":"aa:bb:cc:dd:ee:09"' "$r9"
ck "门户外关联设备 online=true（人确实连着）" '"online":true' "$r9"
ck "门户外关联设备 authorized=false（算未认证）" '"authorized":false' "$r9"
ck "门户外关联设备 apsec=default_radio2（点该卡片能筛出来）" '"apsec":"default_radio2"' "$r9"
ck "门户外关联设备带 ssid=互联网" '"ssid":"互联网"' "$r9"
ck "门户外关联设备用邻居表补 IP" '"ip":"10.0.0.7"' "$r9"

# ⑪ AP 卡片计数 = 点开该卡片能看到的行数（用户现场：卡片 3、列表 0）
n_ap=$(printf '%s' "$out" | tr '{' '\n' | grep -F '"apsec":"default_radio2"' |
	grep -c '"online":true')
ck "互联网卡片计数(4) = 按该 AP 筛出的行数（黑名单客户端同口径）" '4' "$n_ap"

# ⑥ 名单互斥：黑名单里的 MAC 即便写在 trustedmac 里也不算可信任
r4=$(seg "$out" 'dc:d8:7b:53:e5:5a')
ck "黑名单 MAC 不算可信任" '"trusted":false' "$r4"
ck "黑名单 MAC 标记 blocked" '"blocked":true' "$r4"
# 黑名单客户端已连上 WIFI（关联表里有它）：照样出行且算在线——
# AP 卡片按连接计数、不依赖 NDS（2026-11-21 用户口径）
ck "黑名单客户端 online=true（连着 WIFI 就算在线）" '"online":true' "$r4"
ck "黑名单客户端 apsec=default_radio2（点 AP 卡片能筛出来）" '"apsec":"default_radio2"' "$r4"

echo "== 应用后自动清理重复条目 =="
call sys post_apply >/dev/null
tr_list=$(uci -q get 'opennds.@opennds[0].trustedmac' 2>/dev/null)
bl_list=$(uci -q get 'opennds.@opennds[0].blockedmac' 2>/dev/null)
ck "trustedmac 保留正常条目" '11:22:33:44:55:66' "$tr_list"
case "$tr_list" in
	*dc:d8:7b:53:e5:5a*) echo "  FAIL trustedmac 里的黑名单条目没被清理"; fail=1 ;;
	*) echo "  OK   trustedmac 里的黑名单条目已清除" ;;
esac
ck "blockedmac 原样保留" 'dc:d8:7b:53:e5:5a' "$bl_list"

echo "== openNDS 停止：接入点卡片照常计数，客户端列表清空 =="
out3=$(NDS_RUNNING=0 call overview dashboard)
counts3=$(printf '%s' "$out3" | grep -o '"counts":{[^}]*}')
ck "停止后在线=0（openNDS 没在管，不判在线）" '"online":0' "$counts3"
ck "停止后已认证=0" '"authenticated":0' "$counts3"
ck "停止后未认证=0" '"unauthenticated":0' "$counts3"
ck "停止后可信任卡仍按名单显示" '"trusted":2' "$counts3"
ck "停止后有线卡仍按邻居表显示=1（ee20 REACHABLE；ee08 STALE 不算）" '"wired":1' "$counts3"
ck "停止后黑名单卡仍按名单显示" '"blacklist":1' "$counts3"
# 关联表里的设备照样出行（AP 卡片点开要有列表，不依赖 openNDS）
seg3() { printf '%s' "$1" | tr '{' '\n' | grep -F "\"mac\":\"$2\""; }
r3s=$(seg3 "$out3" 'aa:bb:cc:dd:ee:01')
ck "停止后关联设备仍出行" '"mac":"aa:bb:cc:dd:ee:01"' "$r3s"
ck "停止后关联设备 online=true（人连着）" '"online":true' "$r3s"
s0=$(ap_seg "$out3" '互联网')
ck "停止后 AP 计数不变（关联表不经过 openNDS，含黑名单客户端）" '"count":4' "$s0"

echo "== 兜底：hostapd ubus 不可用，退回按 clientif 计数 =="
# 模拟固件没带 hostapd ubus 对象的机器：关联表拿不到，但装了 iw，
# openNDS 的 clientif 是真实运行时接口名（phy2-ap0 / phy2-ap1）
out2=$(NDS_NO_HOSTAPD=1 call overview dashboard)
b0=$(ap_seg "$out2" '互联网')
b1=$(ap_seg "$out2" 'guest')
ck "兜底：互联网 AP 计数=3（clientif=phy2-ap0 的 3 个）" '"count":3' "$b0"
ck "兜底：guest AP 计数=1（clientif=phy2-ap1）" '"count":1' "$b1"
r5=$(seg "$out2" 'aa:bb:cc:dd:ee:01')
ck "兜底：已认证客户端 ssid=互联网（clientif 直配）" '"ssid":"互联网"' "$r5"
counts2=$(printf '%s' "$out2" | grep -o '"counts":{[^}]*}')
ck "兜底：在线=4（关联表拿不到时按 openNDS 记录算：aa01/11:22/ee07/ee08）" '"online":4' "$counts2"

done_report
