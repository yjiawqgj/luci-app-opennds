#!/bin/sh
# t11：设置页「公平使用策略」开关初始状态（用户口径）
#   ① openNDS 配置里 fup_upload/download_throttle_rate 任一 > 0 → 开（最高优先）
#   ② 都是 0 时看 zone_detect.main.fup_enabled 上次保存的状态
#   ③ 都没有（首次安装）→ 关
. "$(dirname "$0")/lib.sh"
tmp_setup t11

# opennds 节（rates 按场景改）+ zone_detect main 节
mk_conf() { # $1=up $2=down $3=fup_enabled（''=不写）
	mkdir -p "$MOCK_UCI_ROOT/opennds/opennds" "$MOCK_UCI_ROOT/zone_detect/main"
	printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
	printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
	printf '%s' "$1" >"$MOCK_UCI_ROOT/opennds/opennds/fup_upload_throttle_rate"
	printf '%s' "$2" >"$MOCK_UCI_ROOT/opennds/opennds/fup_download_throttle_rate"
	if [ -n "$3" ]; then
		printf '%s' "$3" >"$MOCK_UCI_ROOT/zone_detect/main/fup_enabled"
	else
		rm -f "$MOCK_UCI_ROOT/zone_detect/main/fup_enabled"
	fi
}

fe() { call settings status 2>/dev/null | grep -o '"fupEnabled":[01]' | head -1; }

# ① 首次安装：rates 全 0（或没写）→ 关
mk_conf 0 0 ''
ck "首次安装 rates=0 → 关" '"fupEnabled":0' "$(fe)"

# ② 首次安装：任一 rate > 0 → 开
mk_conf 2048 0 ''
ck "首次安装 上行限速>0 → 开" '"fupEnabled":1' "$(fe)"
mk_conf 0 4096 ''
ck "首次安装 下行限速>0 → 开" '"fupEnabled":1' "$(fe)"

# ③ 非首次：rates=0，按上次保存的开关状态
mk_conf 0 0 1
ck "上次保存为开（rates=0）→ 开" '"fupEnabled":1' "$(fe)"
mk_conf 0 0 0
ck "上次保存为关（rates=0）→ 关" '"fupEnabled":0' "$(fe)"

# ④ rates>0 但上次保存为关 → 速率优先，开
mk_conf 2048 0 0
ck "rates>0 优先于上次保存的关 → 开" '"fupEnabled":1' "$(fe)"

# ⑤ 脏值按 0 处理
mk_conf abc 0 1
ck "rates 脏值按 0 → 看上次状态（开）" '"fupEnabled":1' "$(fe)"

done_report
