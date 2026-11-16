#!/bin/sh
# t6：本轮新增的后端路径
#   ① exempt restore_scan：把随包提供的原始信任名单和当前配置做差集（只读）
#   ② sys post_apply：原生 commit 之后的运行时同步，绝不写配置
#   ③ sys 未知子命令仍然报错
. "$(dirname "$0")/lib.sh"
tmp_setup t6

ORIG="$REPO/luci-app-opennds-cpd/root/usr/lib/opennds/cpd/trustedmac.orig"
[ -f "$ORIG" ] || { echo "  FAIL 包里没带 trustedmac.orig"; exit 1; }

echo "== C1 名单文件还没落地 → 空数组，不报错 =="
out=$(call exempt restore_scan)
ck "返回 ok" '{"ok":1' "$out"
ck "空结果" '"macs":[]' "$out"

echo "== C2 落地随包名单、配置里一条都没有 → 6 条全返回 =="
cp "$ORIG" "$CPD_ROOT/trustedmac.orig"
out=$(call exempt restore_scan)
ck "总数 6" '"total":6' "$out"
ck "MAC 已归一为小写" '66:0e:56:87:1c:1d' "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"

echo "== C3 配置里已有 2 条 → 只返回缺的 4 条 =="
uci add_list "opennds.@opennds[0].trustedmac=50:29:F5:AB:3D:BB" >/dev/null 2>&1
uci add_list "opennds.@opennds[0].trustedmac=0C:93:8F:3E:E7:C5" >/dev/null 2>&1
uci commit opennds >/dev/null 2>&1
out=$(call exempt restore_scan)
ck "总数 4" '"total":4' "$out"
case "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" in
	*50:29:f5*) echo "  FAIL 已配置的 MAC 不该再出现在待恢复列表里"; fail=1 ;;
	*) echo "  OK   已配置的 MAC 不在待恢复列表里" ;;
esac

echo "== C4 post_apply：global 作用域 → 走重启分支，输出合法 JSON =="
uci set zone_detect.main.scope=global >/dev/null 2>&1
uci commit zone_detect >/dev/null 2>&1
out=$(call sys post_apply)
ck "有 ok 字段" '"ok":' "$out"
ck "zone 标记为 0" '"zone":0' "$out"

echo "== C5 post_apply：zone 作用域但区域缓存为空 → 不退化成错误 JSON =="
uci set zone_detect.main.scope=zone >/dev/null 2>&1
uci commit zone_detect >/dev/null 2>&1
out=$(call sys post_apply)
ck "仍有 ok 字段" '"ok":' "$out"

echo "== C6 post_apply 不写任何配置 =="
before=$(uci show opennds 2>/dev/null | sort)
call sys post_apply >/dev/null
after=$(uci show opennds 2>/dev/null | sort)
if [ "$before" = "$after" ]; then
	echo "  OK   opennds 配置未被 post_apply 改动"
else
	echo "  FAIL 配置被 post_apply 改了"; fail=1
fi

echo "== C7 post_apply 把黑名单 MAC 摘信任 + 踢下线（只动运行时） =="
uci add_list "zone_blacklist.main.mac=AA:BB:CC:DD:EE:01" >/dev/null 2>&1
uci commit zone_blacklist >/dev/null 2>&1
export NDSCTL_LOG="$S/ndsctl.log"
: >"$NDSCTL_LOG"
call sys post_apply >/dev/null
ck "调了 untrust（小写 MAC）" 'untrust aa:bb:cc:dd:ee:01' "$(tr '\n' ' ' <"$NDSCTL_LOG")"
ck "调了 deauth" 'deauth aa:bb:cc:dd:ee:01' "$(tr '\n' ' ' <"$NDSCTL_LOG")"

echo "== C8 sys 未知子命令仍然报错 =="
out=$(call sys nosuchcmd)
ck "未知子命令" '"ok":0' "$out"

done_report
