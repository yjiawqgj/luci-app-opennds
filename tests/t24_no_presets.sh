#!/bin/sh
# t24：本轮四项口径
#   A. 配置缺键时后端回空，插件不自带预设；空值=恢复默认（删 uci 键）
#   B. 首次由插件启动 NDS 时强制登录模式 3 + 主题脚本，之后不再改
#   C. 详情超额限速：没设速率就是「取消认证」，不再显示「未单独设置」
#   D. 已认证（手动认证）客户端不显示「编辑」按钮
#   E. 只改运行时待办的应用不重启 NDS（运行卡不闪红）
. "$(dirname "$0")/lib.sh"
tmp_setup t24

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
API="$API_SRC"
has() { if grep -q "$2" "$1" 2>/dev/null; then echo "  OK   $3"; else echo "  FAIL $3"; fail=1; fi; }
no()  { if grep -q "$2" "$1" 2>/dev/null; then echo "  FAIL $3"; fail=1; else echo "  OK   $3"; fi; }

mkdir -p "$MOCK_UCI_ROOT/opennds/opennds" "$MOCK_UCI_ROOT/zone_detect/main"
printf 'opennds' >"$MOCK_UCI_ROOT/opennds/opennds/.type"
printf 'main' >"$MOCK_UCI_ROOT/zone_detect/main/.type"

echo "== A. 配置缺键回空，前端不自带预设 =="
st=$(call settings status)
ck "缺键的 sessiontimeout 回空（不是插件填的值）" '"sessiontimeout":""' "$st"
ck "缺键的 checkinterval 回空" '"checkinterval":""' "$st"
no "$V/settings.js" "def: '" '前端没有写死默认值字段'
no "$V/settings.js" "v || f.def" '保存时不再把预设值写进配置'
has "$V/settings.js" "field.hint" '输入框用官方默认作灰色提示'
has "$V/settings.js" "默认1440" '会话时长提示为官方默认 1440'
has "$V/settings.js" "默认120" '空闲超时提示为官方默认 120'
has "$V/settings.js" "默认15" '检查间隔提示为官方默认 15'
has "$V/settings.js" "if (v === '') continue" '空值不报错，按恢复默认处理'
has "$V/settings.js" "'opt', v));" '空值写空 → stageUci 删掉该 option'
no "$V/settings.js" "请填写%1" '没有未替换的 %1 报错文案'
no "$V/overview.js" "|| 1440" '概览页也不硬编码默认会话时长'

echo "== B. 首次启动强制登录模式 3（只一次）=="
cat >"$S/init.sh" <<'STUB'
#!/bin/sh
case "$1" in
	stop) touch "$CPD_PIDOF_CLEAR" ;;
	start) rm -f "$CPD_PIDOF_CLEAR" ;;
esac
exit 0
STUB
chmod +x "$S/init.sh"
export NDS_INIT="$S/init.sh"
export CPD_PIDOF_CLEAR="$S/pidof.clear"
touch "$CPD_PIDOF_CLEAR"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/login_option_enabled"
rm -f "$MOCK_UCI_ROOT/opennds/opennds/themespec_path"
call run_worker 1
ck "首次启动把登录模式改成 3" '3' \
	"$(uci -q get opennds.@opennds[0].login_option_enabled 2>/dev/null)"
ck "首次启动补上主题脚本路径" '/usr/lib/opennds/theme_zone_detect.sh' \
	"$(uci -q get opennds.@opennds[0].themespec_path 2>/dev/null)"
ck "一次性标记已写" '1' "$(uci -q get zone_detect.main.login_mode_init 2>/dev/null)"
printf '1' >"$MOCK_UCI_ROOT/opennds/opennds/login_option_enabled"
call run_worker 1
ck "第二次启动不再改用户选的模式" '1' \
	"$(uci -q get opennds.@opennds[0].login_option_enabled 2>/dev/null)"

echo "== C. 超额限速显示口径 =="
has "$V/overview.js" "function fupText" '新增超额限速专用文案函数'
has "$V/overview.js" "return _('取消认证')" '没设速率显示取消认证'
has "$V/overview.js" "fupText(lim.overQuotaUploadRate, tr)" '上传超额限速用新文案'
has "$V/overview.js" "fupText(lim.overQuotaDownloadRate, tr)" '下载超额限速用新文案'
no "$V/overview.js" "limText(lim.overQuota" '超额限速不再显示未单独设置'

echo "== D. 已认证客户端不显示编辑按钮 =="
has "$V/overview.js" "=== 't-auth'" '按已认证标签隐藏编辑'
has "$V/overview.js" "var hideEdit = trusted || unauth" '隐藏条件包含已认证'

echo "== E. 只改运行时待办时不重启 NDS =="
rm -f "$CPD_CONF_HASH" "$CPD_APPLY_STATE"
out=$(call sys post_apply)
ck "首次应用仍按配置已变处理" '"need_restart":1' "$(cat "$CPD_APPLY_STATE" 2>/dev/null)"
out=$(call sys post_apply)
ck "配置没变则 need_restart:0（不重启）" '"need_restart":0' "$(cat "$CPD_APPLY_STATE" 2>/dev/null)"
has "$API" '[ "$need" = '"'"'1'"'"' ]' 'worker 按 need_restart 决定是否重启'
printf '\n# config changed\n' >>"$OPENNDS_CONF"
out=$(call sys post_apply)
ck "配置真变了仍要重启" '"need_restart":1' "$(cat "$CPD_APPLY_STATE" 2>/dev/null)"

done_report
