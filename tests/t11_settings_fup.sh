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

echo "== 默认门户：黑名单 tab（用户口径：设置页要能管黑名单门户） =="
mkdir -p "$CPD_ROOT/blacklist" "$CPD_ROOT/default/wireless" "$S/up/up1"
printf 'x\n' >"$CPD_ROOT/blacklist/old.sh"
printf '#!/bin/sh\n' >"$S/up/up1/mybl.sh"
out=$(call settings upload_default blacklist up1 file mybl.sh)
ck "上传黑名单门户返回 ok" '"ok":1' "$out"
if [ -f "$CPD_ROOT/blacklist/mybl.sh" ]; then
	echo "  OK   文件落在 cpd/blacklist/mybl.sh"
else
	echo "  FAIL 文件没落到 cpd/blacklist"; fail=1
fi
if [ -f "$CPD_ROOT/blacklist/old.sh" ]; then
	echo "  OK   黑名单门户库不做互斥清理（old.sh 仍在）"
else
	echo "  FAIL 黑名单门户库被互斥清空了"; fail=1
fi

call settings portal_save blacklist mybl.sh >/dev/null
ck "门户选择写入 portal_blacklist" 'mybl.sh' "$(uci -q get zone_detect.main.portal_blacklist)"

st=$(call settings status)
ck "status 带回 blacklist 类型" '"blacklist":{' "$st"
ck "status 里黑名单选中项正确" '"sel":"mybl.sh"' "$st"

out=$(call settings clean_default blacklist mybl.sh)
ck "清理黑名单门户 removed=1" '"removed":1' "$out"
if [ -z "$(uci -q get zone_detect.main.portal_blacklist 2>/dev/null)" ]; then
	echo "  OK   清理后选择回落到内置默认门户"
else
	echo "  FAIL 清理后 portal_blacklist 没清掉"; fail=1
fi

echo "== 无线/有线仍然写各自的目录（不能被黑名单改动带偏） =="
mkdir -p "$S/up/up2"
printf '#!/bin/sh\n' >"$S/up/up2/wl.sh"
call settings upload_default wireless up2 file wl.sh >/dev/null
if [ -f "$CPD_ROOT/default/wireless/wl.sh" ]; then
	echo "  OK   无线门户仍落在 cpd/default/wireless/"
else
	echo "  FAIL 无线门户落错目录"; fail=1
fi

done_report
