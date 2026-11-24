#!/bin/sh
# t18：按钮操作后的链路回归
#   1) pending_deauth / pending_restart 一次性令牌，残留时二次操作仍有增量
#   2) deauth 失败保留待办、不清落盘日志（避免"先未认证又变回已认证"）
#   3) 跨页面名单写改成差量，不冲掉概览页未应用的暂存
#   4) 2026-11-24 口径：未运行时重启按钮禁用；停服时身份按落盘记录判定，
#      已认证客户端关 NDS 后仍已认证，不串进未认证卡
. "$(dirname "$0")/lib.sh"

assert_has() { # $1=文件 $2=模式 $3=说明
	if grep -q "$2" "$1" 2>/dev/null; then
		echo "  OK   $3"
	else
		echo "  FAIL $3"
		fail=1
	fi
}

echo '== C1 pending_deauth 令牌：按 | 取 MAC，消费后清键 =='
tmp_setup t18c1
MAC='aa:bb:cc:dd:ee:01'
uci set "zone_detect.main.pending_deauth=$MAC|tk1001" 2>/dev/null
uci commit zone_detect 2>/dev/null
export NDSCTL_LOG="$S/ndsctl.log"
out=$(call sys post_apply)
ck 'post_apply 成功' '"ok":1' "$out"
ck 'deauth 用纯 MAC（不吃令牌）' "deauth $MAC" "$(cat "$NDSCTL_LOG" 2>/dev/null)"
left=$(uci -q get zone_detect.main.pending_deauth 2>/dev/null)
[ -z "$left" ] && echo '  OK   待办已清空' || { echo "  FAIL 待办残留: $left"; fail=1; }

echo '== C2 旧版纯 MAC 值兼容 =='
tmp_setup t18c2
MAC='aa:bb:cc:dd:ee:02'
uci set "zone_detect.main.pending_deauth=$MAC" 2>/dev/null
uci commit zone_detect 2>/dev/null
export NDSCTL_LOG="$S/ndsctl.log"
out=$(call sys post_apply)
ck '旧格式仍执行 deauth' "deauth $MAC" "$(cat "$NDSCTL_LOG" 2>/dev/null)"

echo '== C3 deauth 失败：保留待办 + 上报 + 日志不删 =='
tmp_setup t18c3
MAC='aa:bb:cc:dd:ee:03'
mkdir -p "$S/bin" "$CPD_NDSLOG_DIR"
cat >"$S/bin/ndsctl" <<'STUB'
#!/bin/sh
[ -n "$NDSCTL_LOG" ] && echo "$1 $2" >> "$NDSCTL_LOG"
[ "$1" = 'deauth' ] && exit 1
exit 0
STUB
chmod +x "$S/bin/ndsctl"
export PATH="$S/bin:$PATH"
export NDSCTL_LOG="$S/ndsctl.log"
printf 'marker clientmac=%s\n' "$MAC" >"$CPD_NDSLOG_DIR/binauthlog.log"
uci set "zone_detect.main.pending_deauth=$MAC|tk1003" 2>/dev/null
uci commit zone_detect 2>/dev/null
out=$(call sys post_apply)
ck '失败数上报给前端' '"deauth_failed":1' "$out"
left=$(uci -q get zone_detect.main.pending_deauth 2>/dev/null)
ck '失败待办保留（下次应用重试）' "$MAC" "$left"
ck '失败时日志不删（避免未认证假象）' "$MAC" "$(cat "$CPD_NDSLOG_DIR/binauthlog.log" 2>/dev/null)"
export PATH="$HERE/mock/bin:$PATH"

echo '== C4 deauth 成功：清该 MAC 日志、保留其它 MAC =='
tmp_setup t18c4
MAC='aa:bb:cc:dd:ee:04'
OTHER='aa:bb:cc:dd:ee:99'
mkdir -p "$CPD_NDSLOG_DIR"
printf 'other clientmac=%s\ntarget clientmac=%s\n' "$OTHER" "$MAC" >"$CPD_NDSLOG_DIR/binauthlog.log"
uci set "zone_detect.main.pending_deauth=$MAC|tk1004" 2>/dev/null
uci commit zone_detect 2>/dev/null
call sys post_apply >/dev/null 2>&1
log=$(cat "$CPD_NDSLOG_DIR/binauthlog.log" 2>/dev/null)
case "$log" in
	*"$MAC"*) echo '  FAIL 成功时日志没清'; fail=1 ;;
	*) echo '  OK   成功时该 MAC 日志已清' ;;
esac
ck '其它客户端日志保留' "$OTHER" "$log"

echo '== C5 pending_restart 令牌被 worker 消费 =='
tmp_setup t18c5
uci set 'zone_detect.main.pending_restart=restart-tk1005' 2>/dev/null
uci commit zone_detect 2>/dev/null
printf '#!/bin/sh\nexit 0\n' >"$S/init.sh"
chmod +x "$S/init.sh"
export NDS_INIT="$S/init.sh"
call apply_worker >/dev/null 2>&1
left=$(uci -q get zone_detect.main.pending_restart 2>/dev/null)
[ -z "$left" ] && echo '  OK   restart 令牌已消费清键' || { echo "  FAIL restart 令牌残留: $left"; fail=1; }

echo '== C6 前端全链路静态断言 =='
V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
assert_has "$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/opennds_manager/common.js" 'deauthToken: function (mac)' '公共令牌函数存在'
n=$(grep -c 'arr.concat(\[CPD.deauthToken(lm)\])' "$V/overview.js" 2>/dev/null)
[ "$n" = '3' ] && echo '  OK   解除认证/取消信任/移除免认证三处都写令牌' || { echo "  FAIL 令牌写入处数=$n"; fail=1; }
assert_has "$V/exempt.js" 'return stageDeauthFor(\[mac\])' '特权页移除身份时同时写踢下线待办'
assert_has "$V/exempt.js" 'stageDeauthFor(removed)' '特权页整表编辑移除多客户端也写待办'
assert_has "$V/overview.js" "'restart-' + Date.now().toString(36)" '重启写一次性令牌'
assert_has "$V/overview.js" 'authorized: false' '本地覆盖同步访问权限位'
assert_has "$V/overview.js" 'state.clients.map(decorated)' '列表筛选与显示同口径'
assert_has "$V/overview.js" 'var n = previewCounts();' '卡片数字本地预览'
assert_has "$V/overview.js" '.ovd-boot-btn.on.on-disabled' '禁用按钮保留色相'
assert_has "$V/overview.js" "sessionStorage.getItem('cpd_deauth_failed')" '跨刷新显示踢下线失败'
assert_has "$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/opennds_manager/common.js" 'stageListSync: function' '公共差量写函数存在'
for p in exempt blacklist session; do
	assert_has "$V/$p.js" 'stageListSync(' "$p 页改用差量写，不冲概览暂存"
done

echo '== C7 2026-11-24 口径：未运行禁用重启 + 停服时身份判定与 NDS 运行无关 =='
API="$REPO/luci-app-opennds-manager/root/usr/lib/opennds/opennds-manager-api.sh"
assert_has "$V/overview.js" 'restartBtn.disabled = !on' 'NDS 未运行时重启按钮禁用'
assert_has "$V/overview.js" 'return online && !c.authenticated && !c.trusted &&' '停服时未认证筛选按身份（已认证不入未认证卡）'
if grep -q 'if (!state.running) return online;' "$V/overview.js" 2>/dev/null; then
	echo '  FAIL 旧的「停服连着就算未认证」一刀切还在'; fail=1
else
	echo '  OK   停服已认证客户端不再被划进未认证卡'
fi
if grep -q 'N_UN=\$n_conn' "$API" 2>/dev/null; then
	echo '  FAIL 后端旧的「停服未认证按连接数覆盖」还在'; fail=1
else
	echo '  OK   后端未认证卡统一按身份统计，不再按连接数覆盖'
fi
if grep -q '当前未运行，确认启动' "$V/overview.js" 2>/dev/null; then
	echo '  FAIL 旧的「未运行弹确认启动」分支还在'; fail=1
else
	echo '  OK   未运行不再弹确认启动，按钮直接禁用'
fi

echo '== C8 路由器访问页：控制开关语义反转 + 说明文本补句号 =='
R="$V/router.js"
assert_has "$R" "CPD.section(_('控制'))" '区块标题由接管改成控制'
assert_has "$R" "state.controlOn ? '0' : '1'" '开关打开写 passthrough=0'
assert_has "$R" 'Number(j.passthrough) === 0' '回读 passthrough=0 为打开(绿色)'
assert_has "$R" "_('控制客户端访问路由器。')" '副标题补句号'
assert_has "$R" "_('22、53、443端口自动放行。')" '端口说明补句号'
if grep -q '接管' "$R" 2>/dev/null; then
	echo '  FAIL 旧的「接管」字样还在'; fail=1
else
	echo '  OK   旧「关闭接管」字样已删除'
fi

done_report
