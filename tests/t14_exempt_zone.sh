#!/bin/sh
# t14：特权客户端页（原「客户端豁免管理」）——名单里的客户端必须显示网络区域
#
# 可信任 / 自动认证名单里的客户端在 openNDS 记录里根本没有（openNDS 不给它们
# 建会话），区域只能靠无线关联表 / 邻居表判断。用户反馈：同一个列表里只有个别
# 客户端显示区域（那些恰好被 ndsctl 记录到的），其余全是「—」。
. "$(dirname "$0")/lib.sh"
tmp_setup t14

# ---- ip：邻居表（一台在 br-lan 上、一台在 wan 上）----
mkdir -p "$S/bin"
cat >"$S/bin/ip" <<'IEOF'
#!/bin/sh
case "$*" in
	*neigh*)
		printf '%s\n' \
			'10.0.0.8 dev br-lan lladdr aa:bb:cc:dd:ee:08 REACHABLE' \
			'10.0.0.9 dev wan lladdr aa:bb:cc:dd:ee:99 REACHABLE' \
			'10.0.0.7 dev br-lan lladdr aa:bb:cc:dd:ee:07 FAILED' ;;
	*addr*) printf '%s\n' '3: br-lan    inet 10.0.0.1/24 scope global br-lan' ;;
esac
IEOF
chmod +x "$S/bin/ip"
export PATH="$S/bin:$PATH"

# ---- opennds 配置：管理接口 br-lan；信任 3 台、自动认证 1 台 ----
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds" "$MOCK_UCI_ROOT/zone_detect/main"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf 'br-lan' >"$MOCK_UCI_ROOT/opennds/opennds/gatewayinterface"
printf 'aa:bb:cc:dd:ee:08 aa:bb:cc:dd:ee:11 aa:bb:cc:dd:ee:99 aa:bb:cc:dd:ee:07' \
	>"$MOCK_UCI_ROOT/opennds/opennds/trustedmac"
printf 'mac=aa:bb:cc:dd:ee:08;sessiontimeout=0' \
	>"$MOCK_UCI_ROOT/opennds/opennds/preemptivemac"

frag() { # $1=mac → 该 MAC 在 clients 里的 JSON 片段
	printf '%s\n' "$2" | grep -o "\"$1\":{[^}]*}" | head -1
}

echo "== C1 NDS 运行中：名单里的有线在线客户端显示 br-lan（有线） =="
out=$(call exempt status)
f8=$(frag aa:bb:cc:dd:ee:08 "$out")
ck "有线在线 → 区域 br-lan（有线）" '"zone":"br-lan（有线）"' "$f8"
ck "有线在线 → online=1" '"online":1' "$f8"
ck "有线在线 → IP 从邻居表补全" '"ip":"10.0.0.8"' "$f8"

echo "== C2 名单里但不在线 → 区域留空、online=0 =="
f11=$(frag aa:bb:cc:dd:ee:11 "$out")
ck "离线 → 区域为空" '"zone":""' "$f11"
ck "离线 → online=0" '"online":0' "$f11"

echo "== C3 WAN 侧邻居不算客户端（运营商网关不能标成有线） =="
f99=$(frag aa:bb:cc:dd:ee:99 "$out")
ck "只有 WAN 侧邻居 → 区域为空" '"zone":""' "$f99"
ck "只有 WAN 侧邻居 → online=0" '"online":0' "$f99"

echo "== C4 FAILED 的邻居条目不算在线 =="
f7=$(frag aa:bb:cc:dd:ee:07 "$out")
ck "FAILED 邻居 → 区域为空" '"zone":""' "$f7"
ck "FAILED 邻居 → online=0" '"online":0' "$f7"

echo "== C5 NDS 未运行：名单区域照样能判断（不依赖 openNDS） =="
out2=$(NDS_RUNNING=0 sh "$API" exempt status 2>/dev/null)
f8b=$(frag aa:bb:cc:dd:ee:08 "$out2")
ck "未运行 → 区域仍是 br-lan（有线）" '"zone":"br-lan（有线）"' "$f8b"
ck "未运行 → online 仍为 1" '"online":1' "$f8b"

echo "== C6 六列里的主机名/IP 不因未运行而丢 =="
ck "未运行 → IP 仍在" '"ip":"10.0.0.8"' "$f8b"

done_report
