#!/bin/sh
# t17：开机自启服务按钮（overview boot_state / boot_set）
#   自启状态走 OpenWrt 标准 /etc/init.d/opennds enabled|enable|disable，
#   与「此刻跑不跑 / 配置 enabled」是两套独立机制。用桩 init 脚本验证：
#   A. boot_state 读返回码（0=已启用开机自启）
#   B. boot_set 1/0 真调用 enable/disable，并回读真实状态
#   C. boot 状态与 running 互不影响
. "$(dirname "$0")/lib.sh"
tmp_setup t17_boot

# 假 init.d/opennds：状态存在 $S/boot.state（1=已启用自启），
# enabled 按返回码表达，enable/disable 落盘。记录被调用的子命令到 log。
cat >"$S/fake-init" <<'IEOF'
#!/bin/sh
ST="${BOOT_STATE_FILE:-/tmp/boot.state}"
LOG="${BOOT_CALL_LOG:-/tmp/boot.log}"
case "$1" in
	enabled) [ -f "$ST" ] && [ "$(cat "$ST")" = 1 ] && exit 0 || exit 1 ;;
	enable)  echo 1 >"$ST"; echo enable >>"$LOG"; exit 0 ;;
	disable) echo 0 >"$ST"; echo disable >>"$LOG"; exit 0 ;;
	*) exit 1 ;;
esac
IEOF
chmod +x "$S/fake-init"
export NDS_INIT="$S/fake-init"
export BOOT_STATE_FILE="$S/boot.state"
export BOOT_CALL_LOG="$S/boot.log"

echo "== A. boot_state 读开机自启状态 =="
echo 1 >"$BOOT_STATE_FILE"
out=$(call overview boot_state)
ck "已启用开机自启→boot:1" '"ok":1,"boot":1' "$out"
echo 0 >"$BOOT_STATE_FILE"
out=$(call overview boot_state)
ck "未启用开机自启→boot:0" '"ok":1,"boot":0' "$out"
rm -f "$BOOT_STATE_FILE"
out=$(call overview boot_state)
ck "状态文件缺失→boot:0" '"ok":1,"boot":0' "$out"

echo "== B. boot_set 执行 enable/disable 并回读 =="
: >"$BOOT_CALL_LOG"
echo 0 >"$BOOT_STATE_FILE"
out=$(call overview boot_set 1)
ck "boot_set 1→boot:1" '"ok":1,"boot":1' "$out"
ck "真的调用了 enable" 'enable' "$(cat "$BOOT_CALL_LOG")"
ck "状态文件已置1" '1' "$(cat "$BOOT_STATE_FILE")"

: >"$BOOT_CALL_LOG"
out=$(call overview boot_set 0)
ck "boot_set 0→boot:0" '"ok":1,"boot":0' "$out"
ck "真的调用了 disable" 'disable' "$(cat "$BOOT_CALL_LOG")"
ck "状态文件已置0" '0' "$(cat "$BOOT_STATE_FILE")"

out=$(call overview boot_set 9)
ck "非法参数被拒" '"ok":0' "$out"

echo "== C. boot 与 running/enabled 独立 =="
echo 1 >"$BOOT_STATE_FILE"
# NDS_RUNNING=0 且配置 enabled=0，但开机自启仍应是 1
out=$(NDS_RUNNING=0 call overview dashboard)
ck "dashboard 带 boot 字段且=1" '"boot":1' "$out"
ck "此刻运行另算 running:0" '"running":0' "$out"
out=$(call overview run_state)
ck "run_state 不受 boot 影响仍正常" '"ok":1,"running":' "$out"

done_report
