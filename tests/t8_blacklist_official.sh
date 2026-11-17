#!/bin/sh
# t8：黑名单 = openNDS 官方机制（/etc/config/opennds 的 blockedmac + macmechanism）
#   ① blacklist status 读 blockedmac
#   ② 概览页「拉黑」写 blockedmac + 未设置时补 macmechanism='block'
#   ③ 用户已设 macmechanism='allow' 时不覆盖
#   ④ 旧配置 /etc/config/zone_blacklist 一次性迁移进 blockedmac 并删除旧文件
. "$(dirname "$0")/lib.sh"
tmp_setup t8

sec_dir="$MOCK_UCI_ROOT/opennds/@opennds[0]"
mkdir -p "$sec_dir"

echo "== B1 blacklist status 读 blockedmac =="
printf 'aa:bb:cc:dd:ee:01\nbb:cc:dd:ee:ff:02\n' >"$sec_dir/blockedmac"
printf 'block' >"$sec_dir/macmechanism"
out=$(call blacklist status)
ck "返回 ok" '{"ok":1' "$out"
ck "macs 含第一条" '"macs":["aa:bb:cc:dd:ee:01","bb:cc:dd:ee:ff:02"]' "$out"
ck "mechanism=block" '"mechanism":"block"' "$out"

echo "== B2 概览页拉黑 → blockedmac + macmechanism 补 block =="
uci add_list "opennds.@opennds[0].trustedmac=11:22:33:44:55:66" >/dev/null 2>&1
uci commit opennds >/dev/null 2>&1
export NDSCTL_LOG="$S/ndsctl.log"
: >"$NDSCTL_LOG"
out=$(call overview client_action block 11:22:33:44:55:66)
ck "返回 ok" '"ok":1' "$out"
grep -qx '11:22:33:44:55:66' "$MOCK_UCI_ROOT/opennds/@opennds[0]/blockedmac" &&
	echo "  OK   写入 blockedmac" || { echo "  FAIL blockedmac 没写入"; fail=1; }
grep -qx 'block' "$MOCK_UCI_ROOT/opennds/@opennds[0]/macmechanism" &&
	echo "  OK   macmechanism 补成 block" || { echo "  FAIL macmechanism 未写入"; fail=1; }
if [ ! -f "$sec_dir/trustedmac" ] || ! grep -qx '11:22:33:44:55:66' "$sec_dir/trustedmac"; then
	echo "  OK   已从 trustedmac 摘除"
else
	echo "  FAIL trustedmac 未摘除"; fail=1
fi
ck "踢下线" 'deauth 11:22:33:44:55:66' "$(tr '\n' ' ' <"$NDSCTL_LOG")"

echo "== B3 用户自设 macmechanism=allow → 不覆盖 =="
: >"$sec_dir/blockedmac"; : >"$sec_dir/macmechanism"
printf 'allow' >"$sec_dir/macmechanism"
rm -rf "$MOCK_UCI_DELTA" 2>/dev/null
call overview client_action block 11:22:33:44:55:66 >/dev/null
[ "$(cat "$MOCK_UCI_ROOT/opennds/@opennds[0]/macmechanism")" = 'allow' ] &&
	echo "  OK   保留 allow" || { echo "  FAIL allow 被改写"; fail=1; }

echo "== B4 旧配置迁移：zone_blacklist MAC → blockedmac，旧文件删除 =="
rm -rf "$MOCK_UCI_DELTA" 2>/dev/null
: >"$sec_dir/blockedmac"; : >"$sec_dir/macmechanism"
mkdir -p "$MOCK_UCI_ROOT/zone_blacklist/main"
printf 'main' >"$MOCK_UCI_ROOT/zone_blacklist/main/.type"
printf 'dc:d8:7b:53:e5:5a' >"$MOCK_UCI_ROOT/zone_blacklist/main/mac"
printf 'x' >"$ZONE_BLACKLIST_CONF"
out=$(call blacklist status)
grep -qx 'dc:d8:7b:53:e5:5a' "$sec_dir/blockedmac" &&
	echo "  OK   旧 MAC 迁入 blockedmac" || { echo "  FAIL 迁移失败"; fail=1; }
grep -qx 'block' "$sec_dir/macmechanism" &&
	echo "  OK   迁移时补 macmechanism=block" || { echo "  FAIL macmechanism 未补"; fail=1; }
[ ! -f "$ZONE_BLACKLIST_CONF" ] &&
	echo "  OK   旧文件已删除" || { echo "  FAIL 旧文件还在"; fail=1; }

echo "== B5 /etc/config/opennds 缺失 → status 自动补建官方配置节 =="
rm -f "$OPENNDS_CONF"
rm -rf "$MOCK_UCI_ROOT/opennds" "$MOCK_UCI_DELTA" 2>/dev/null
out=$(call blacklist status)
ck "返回 ok" '"ok":1' "$out"
[ -f "$OPENNDS_CONF" ] &&
	echo "  OK   配置文件已补建" || { echo "  FAIL 配置文件没补建"; fail=1; }
[ -d "$MOCK_UCI_ROOT/opennds" ] &&
	echo "  OK   opennds 节已补建" || { echo "  FAIL opennds 节没补建"; fail=1; }

echo "== B6 黑名单门户：列表 / 删除 / 选中保护 / 上传 =="
BLD="$CPD_ROOT/blacklist"
mkdir -p "$BLD/folder" "$BLD/notportal"
printf '#!/bin/sh\n' >"$BLD/a.sh"
printf '#!/bin/sh\n' >"$BLD/default.sh"
printf '#!/bin/sh\n' >"$BLD/folder/theme.sh"
printf '#!/bin/sh\n' >"$BLD/b.sh"

out=$(call blacklist status)
ck "门户列表含 .sh 门户" '"name":"a.sh","kind":"file"' "$out"
ck "门户列表含文件夹门户" '"name":"folder","kind":"dir"' "$out"
ck "返回门户目录" "\"dir\":\"$CPD_ROOT/blacklist\"" "$out"
case "$out" in
	*'"name":"default.sh"'*) echo "  FAIL 兜底 default.sh 不该列进门户列表"; fail=1 ;;
	*) echo "  OK   兜底 default.sh 已跳过" ;;
esac
case "$out" in
	*'"name":"notportal"'*) echo "  FAIL 没有 theme.sh 的文件夹不该算门户"; fail=1 ;;
	*) echo "  OK   没有 theme.sh 的文件夹已跳过" ;;
esac

out=$(call blacklist portal_delete 'name=a.sh')
ck "删除已上传门户" '"ok":1' "$out"
[ -f "$BLD/a.sh" ] && { echo "  FAIL a.sh 没被删掉"; fail=1; } || echo "  OK   a.sh 已删除"

uci set zone_detect.main.portal_blacklist=b.sh 2>/dev/null
out=$(call blacklist portal_delete 'name=b.sh')
ck "选中中的门户拒绝删除" '正在使用中' "$out"
[ -f "$BLD/b.sh" ] && echo "  OK   选中中的门户文件保留" || { echo "  FAIL b.sh 被删了"; fail=1; }

out=$(call blacklist portal_delete 'name=default.sh')
ck "兜底 default.sh 不能删" '不能删除' "$out"

out=$(call blacklist upload_begin t9u1)
ck "上传会话建立" '"ok":1' "$out"
mkdir -p "$ZONE_UP/t9u1"
printf '#!/bin/sh\n# portal\n' >"$ZONE_UP/t9u1/new.sh"
out=$(call blacklist upload_store t9u1 new.sh)
ck "上传落盘" '"ok":1' "$out"
[ -f "$BLD/new.sh" ] && echo "  OK   new.sh 已进入门户库" || { echo "  FAIL new.sh 没落盘"; fail=1; }

out=$(call blacklist upload_begin t9u2)
mkdir -p "$ZONE_UP/t9u2"
printf '#!/bin/sh\n' >"$ZONE_UP/t9u2/default.sh"
out=$(call blacklist upload_store t9u2 default.sh)
ck "拒绝上传 default.sh" '不能上传名为 default.sh' "$out"

out=$(call blacklist save_macs add=aa:bb:cc:dd:ee:09)
ck "旧 save_macs 已不存在" '"ok":0' "$out"

done_report
