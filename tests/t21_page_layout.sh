#!/bin/sh
# t21：页面结构与四开关体验修复的静态断言
#  - 导航顺序：概览 → 区域识别 → 自动认证 → 可信任 → 黑名单 → 访问限制 → Walled Garden → 路由器访问 → 设置
#  - 会话管理页已删除；特权客户端改名可信任客户端；自动认证独立成页
#  - 概览四卡去掉说明文字；三卡状态跨刷新缓存；黄灯存活期超时兜底
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
V="$REPO/luci-app-opennds-manager/htdocs/luci-static/resources/view/opennds_manager"
MENU="$REPO/luci-app-opennds-manager/root/usr/share/luci/menu.d/luci-app-opennds-manager.json"
fail=0

ck() {
	if [ "$2" = "$3" ]; then echo "  OK   $1"; else echo "  FAIL $1 (got: $2)"; fail=1; fi
}
has() {
	if grep -q "$2" "$1" 2>/dev/null; then echo "  OK   $3"; else echo "  FAIL $3"; fail=1; fi
}
no() {
	if grep -q "$2" "$1" 2>/dev/null; then echo "  FAIL $3（不该出现）"; fail=1; else echo "  OK   $3"; fi
}

echo '== A. 导航结构 =='
order=$(cd "$REPO" && python -c "
import json
d=json.load(open('luci-app-opennds-manager/root/usr/share/luci/menu.d/luci-app-opennds-manager.json',encoding='utf-8'))
items=[(k.rsplit('/',1)[-1],v.get('order')) for k,v in d.items() if k.count('/')==3]
print(' '.join(k for k,_ in sorted(items,key=lambda x:x[1])))
")
ck '导航顺序' "$order" 'overview zone autoauth exempt blacklist access walledgarden router settings'
if grep -q 'opennds_manager/session' "$MENU"; then echo '  FAIL 会话管理还在导航里'; fail=1; else echo '  OK   会话管理已移除导航'; fi
if [ -f "$V/session.js" ]; then echo '  FAIL session.js 未删除'; fail=1; else echo '  OK   session.js 已删除'; fi
has "$V/exempt.js" "_('可信任客户端')" '可信任页标题'
has "$V/autoauth.js" "_('自动认证')" '自动认证页标题'
no "$V/exempt.js" "_('特权客户端')" '可信任页无旧标题'

echo '== B. 概览文案 =='
no "$V/overview.js" "ovd-ctrl-hint" '四卡说明已去掉'
no "$V/overview.js" "_('免认证客户端')" '无旧卡片文案'
no "$V/overview.js" "_('移除免认证')" '无旧按钮文案'
has "$V/overview.js" "_('自动认证')" '新卡片文案'
has "$V/overview.js" "_('解除自动认证')" '新按钮文案'

echo '== C. 状态缓存与黄灯超时 =='
has "$V/overview.js" "sessionStorage.getItem(CTL_CACHE_KEY)" '三卡状态跨刷新读缓存'
has "$V/overview.js" 'ctlCacheSave()' '三卡状态写缓存'
has "$V/overview.js" 'transitionExpired()' '黄灯存活期超时判断'
has "$V/overview.js" 'TRANS_TTL = 45000' '黄灯超时阈值'

[ "$fail" = '0' ] && echo 't21_page_layout 全部通过' || exit 1
exit 0
