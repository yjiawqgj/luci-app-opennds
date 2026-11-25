#!/bin/sh
# t22：新版设置页（基础/高级 tab、客户端全局字段、流量卸载）+ 流量配额解锁口径
#   核心：解锁只看「磁盘已提交」的 fup（fupCommitted），不看暂存（fupEnabled）。
#         用户在高级页点开开关只写 /tmp/.uci，没点保存并应用前，基础页配额必须锁着。
. "$(dirname "$0")/lib.sh"
tmp_setup t22

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
has() { # $1=文件 $2=模式 $3=说明
	if grep -q "$2" "$1" 2>/dev/null; then echo "  OK   $3"
	else echo "  FAIL $3"; fail=1; fi
}
no() { # $1=文件 $2=模式 $3=说明
	if grep -q "$2" "$1" 2>/dev/null; then echo "  FAIL $3"; fail=1
	else echo "  OK   $3"; fi
}

echo "== A. status 带回新设置页需要的字段 =="
mkdir -p "$MOCK_UCI_ROOT/opennds/opennds" "$MOCK_UCI_ROOT/zone_detect/main"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/enabled"
printf '120' >"$MOCK_UCI_ROOT/opennds/opennds/sessiontimeout"
printf '30' >"$MOCK_UCI_ROOT/opennds/opennds/preauthidletimeout"
printf '0' >"$MOCK_UCI_ROOT/opennds/opennds/flow_offloading_enable"
printf '0' >"$MOCK_UCI_ROOT/opennds/opennds/fup_upload_throttle_rate"
printf '0' >"$MOCK_UCI_ROOT/opennds/opennds/fup_download_throttle_rate"

st=$(call settings status)
ck "带回客户端全局字段 sessiontimeout" '"sessiontimeout":"120"' "$st"
ck "带回真实键 preauthidletimeout" '"preauthidletimeout":"30"' "$st"
ck "带回流量卸载 flowEnabled" '"flowEnabled":0' "$st"
ck "带回落盘 fupCommitted" '"fupCommitted":0' "$st"

echo "== B. 磁盘已提交的 fup 状态判定（fupCommitted）=="
# ① 磁盘里 fup_enabled=1 → 落盘开（解锁）
printf '1' >"$MOCK_UCI_ROOT/zone_detect/main/fup_enabled"
st=$(call settings status)
ck "磁盘 fup_enabled=1 → fupCommitted:1" '"fupCommitted":1' "$st"
ck "此时 fupEnabled 也为 1" '"fupEnabled":1' "$st"

# ② 磁盘 rates>0 → 落盘开（优先于上次保存的关）
printf '0' >"$MOCK_UCI_ROOT/zone_detect/main/fup_enabled"
printf '2048' >"$MOCK_UCI_ROOT/opennds/opennds/fup_upload_throttle_rate"
st=$(call settings status)
ck "磁盘限速>0 → fupCommitted:1（覆盖上次关）" '"fupCommitted":1' "$st"

echo "== C. 暂存未应用：fupEnabled 变、fupCommitted 必须不变 =="
printf '0' >"$MOCK_UCI_ROOT/opennds/opennds/fup_upload_throttle_rate"
printf '0' >"$MOCK_UCI_ROOT/zone_detect/main/fup_enabled"
# 只写暂存 delta，不 commit —— 模拟用户在高级页点了开关但没点保存并应用
uci set 'zone_detect.main.fup_enabled'='1' 2>/dev/null
st=$(call settings status)
ck "暂存把 fupEnabled 变 1" '"fupEnabled":1' "$st"
ck "暂存不能改 fupCommitted（仍为 0）" '"fupCommitted":0' "$st"
# commit 后才算已落盘
uci commit zone_detect 2>/dev/null
st=$(call settings status)
ck "commit 后 fupCommitted 才变 1" '"fupCommitted":1' "$st"

echo "== D. 前端：新版设置页结构 =="
has "$V/settings.js" "mode === 'basic'" '基础 tab 渲染分支'
has "$V/settings.js" "mode === 'advanced'" '高级 tab 渲染分支'
has "$V/settings.js" "基础设置" '一级 tab「基础设置」'
has "$V/settings.js" "高级设置" '一级 tab「高级设置」'
has "$V/settings.js" "客户端全局配置" '基础页客户端全局配置区块'
has "$V/settings.js" "preauthidletimeout" '未认证超时用真实键'
has "$V/settings.js" "authidletimeout" '空闲超时用真实键'
has "$V/settings.js" "reauth_interval" '重新认证间隔用真实键'
has "$V/settings.js" "flow_offloading_enable" '流量卸载用真实键'
has "$V/settings.js" "checkinterval" '检查间隔用真实键'

echo "== E. 前端：流量配额锁只看 fupCommitted =="
has "$V/settings.js" "var unlocked = !!state.fupCommitted" '配额解锁读 fupCommitted'
no "$V/settings.js" "var unlocked = !!state.fupEnabled" '配额解锁不能读暂存的 fupEnabled'
has "$V/settings.js" '请先在高级设置里配置' '红字说明存在'
has "$V/settings.js" "quotaHint.style.display = unlocked ? 'none' : ''" '解锁后红字消失'
has "$V/settings.js" "inp.setAttribute('disabled', '')" '锁定时禁用配额输入'
has "$V/settings.js" "inp.removeAttribute('disabled')" '解锁时恢复配额输入'

echo "== F. 真实键名回归（源码事实）=="
SRC="${NDS_SRC:-C:/Users/liuha/AppData/Local/Temp/ndssrc}"
if [ -f "$SRC/conf.c" ]; then
	for k in sessiontimeout preauthidletimeout authidletimeout maxclients \
		checkinterval uploadrate downloadrate uploadquota downloadquota \
		flow_offloading_enable; do
		grep -q "\"$k\"" "$SRC/conf.c" 2>/dev/null || {
			echo "  FAIL 源码里找不到键 $k"; fail=1;
		}
	done
	echo "  OK   10 个键均在 openNDS 11.2.0 conf.c 中出现"
else
	echo "  --   本地无源码副本，跳过键名核对"
fi

done_report
