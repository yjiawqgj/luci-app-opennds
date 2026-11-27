#!/bin/sh
# t28：自动认证页开关首次点击回弹修复 + 文案口径
#   A. 用户点过开关后置 userTouched，异步 refresh 不再用后端旧值覆盖
#   B. 复位时清 userTouched，让 refresh 重新以后端为准
#   C. 区块标题改「启用状态」，删除旧说明段
#   D. 会话时长弹窗按钮为「立即应用 / 全局立即应用」
. "$(dirname "$0")/lib.sh"
tmp_setup t28

V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
has() { if grep -q "$2" "$1" 2>/dev/null; then echo "  OK   $3"; else echo "  FAIL $3"; fail=1; fi; }
no()  { if grep -q "$2" "$1" 2>/dev/null; then echo "  FAIL $3"; fail=1; else echo "  OK   $3"; fi; }

echo "== A. 开关点击后不被异步 refresh 覆盖 =="
has "$V/autoauth.js" 'userTouched: false' 'userTouched 标记初始为 false'
has "$V/autoauth.js" 'state.userTouched = true;' '开关点击置 userTouched'
has "$V/autoauth.js" 'if (!state.userTouched)' 'refresh 回填前检查标记'
has "$V/autoauth.js" 'state.preemptEnabled = on ? 1 : 0;' '点击时本地值立即翻转'

echo "== B. 复位清标记 =="
has "$V/autoauth.js" 'state.userTouched = false;
				refresh();' '复位时清标记后再 refresh'

echo "== C. 自动认证页文案 =="
has "$V/autoauth.js" "CPD.section(_('启用状态')" '区块标题改为启用状态'
no "$V/autoauth.js" '可以为无法进行强制门户认证的设备自动放行' '旧说明段已删除'
no "$V/autoauth.js" "CPD.section(_('自动认证客户端')" '旧标题不再出现'

echo "== D. 会话时长弹窗按钮 =="
has "$V/settings.js" "_('立即应用')" '按钮：立即应用'
has "$V/settings.js" "_('全局立即应用')" '按钮：全局立即应用'
no "$V/settings.js" "_('直接应用')" '旧按钮「直接应用」不再出现'
no "$V/settings.js" "_('全局直接应用')" '旧按钮「全局直接应用」不再出现'

echo "---"
if [ "${fail:-0}" = 0 ]; then echo "t28_switch_rebound 全部通过"; else echo "t28_switch_rebound 有失败"; fi
exit ${fail:-0}
