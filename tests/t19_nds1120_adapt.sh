#!/bin/sh
# t19：openNDS 11.2.0 适配专项
#   A. auto_run（休眠开关）状态读取：缺键回退1、显式0/1
#   B. autorun_set 写 auto_run 并回读
#   C. dashboard 带 autorun 字段，且与 running/boot 独立
#   D. 具名段自愈：ensure_opennds_conf / sys_ensure_sec 建成 config opennds 'setup'
#   E. binauthlog 格式兼容：11.2.0 带引号+timestamp 与 10.3.1 无引号都能判已认证；
#      两种格式的主动 deauth 都能排除（含 11.2.0 的 "shutdown_deauth"）
. "$(dirname "$0")/lib.sh"
tmp_setup t19_nds1120

mkdir -p "$S/bin"

# 用 mock uci 命令写值（不手工建文件），保证 @opennds[0] 解析路径正确
uci_set() { env MOCK_UCI_ROOT="$MOCK_UCI_ROOT" MOCK_UCI_DELTA="$MOCK_UCI_DELTA" \
	PATH="$HERE/mock/bin:$PATH" uci set "$1"="$2"; }

echo "== A. auto_run 状态读取（nds_autorun 缺键回退1）=="
# 初始配置只有 config opennds / enabled 0，无 auto_run → 缺键按1（老版本兼容）
out=$(call overview autorun_state)
ck "缺键→autorun:1（老版本不误判休眠）" '"ok":1,"autorun":1' "$out"

uci_set opennds.@opennds[0].auto_run 0
out=$(call overview autorun_state)
ck "显式0→autorun:0" '"ok":1,"autorun":0' "$out"

echo "== B. autorun_set 写值并回读 =="
out=$(call overview autorun_set 1)
ck "autorun_set 1→autorun:1" '"ok":1,"autorun":1' "$out"
out=$(call overview autorun_set 0)
ck "autorun_set 0→autorun:0" '"ok":1,"autorun":0' "$out"
out=$(call overview autorun_set 9)
ck "非法参数被拒" '"ok":0' "$out"

echo "== C. dashboard 带 autorun 字段且与运行态独立 =="
uci_set opennds.@opennds[0].auto_run 1
out=$(NDS_RUNNING=0 call overview dashboard)
ck "dashboard 带 autorun:1" '"autorun":1' "$out"
ck "running 另算仍为0" '"running":0' "$out"

echo "== D. 具名段自愈（setup）=="
# 清空现有 opennds 配置/增量，模拟极简安装无配置节 → autorun_set 触发 ensure_opennds_conf
rm -rf "$MOCK_UCI_ROOT/opennds" "$MOCK_UCI_DELTA/opennds"
: >"$OPENNDS_CONF"
out=$(call overview autorun_set 1)
ck "自愈后 autorun_set 成功" '"ok":1,"autorun":1' "$out"
# autorun_set 内有 uci commit，delta 已合并进 R：具名段的 .type 落在 R 树
ck "补建的是具名 setup 段" 'opennds' "$(cat "$MOCK_UCI_ROOT/opennds/setup/.type" 2>/dev/null)"

echo "== E. binauthlog 格式兼容（认证判定）=="
# ndsctl json 桩：返回一个已连接客户端，带 session_end（未来）与 ip/mac
cat >"$S/bin/ndsctl" <<'NEOF'
#!/bin/sh
if [ "$1" = 'status' ]; then echo "openNDS daemon v11.2.0"; exit 0; fi
if [ "$1" = 'json' ] && [ -z "$2" ]; then
	cat <<'J'
{"clients":[{"mac":"aa:bb:cc:dd:ee:01","ip":"10.0.0.11","session_start":100,"session_end":9999999999,"state":"authenticated"}],"trusted":[]}
J
	exit 0
fi
exit 0
NEOF
chmod +x "$S/bin/ndsctl"
export PATH="$S/bin:$PATH"

NOW=$(date +%s); EXP=$((NOW+3600)); START=$((NOW-600))
B64=$(printf '%s' 'aa:bb:cc:dd:ee:01' | base64 | tr -d '=')
mkdir -p "$CPD_NDSLOG_DIR"
printf '%s=%s\n' "$B64" "$EXP" >"$CPD_NDSLOG_DIR/authlog.log"

# E1: 11.2.0 格式（带引号 + timestamp）的 client_auth → 应判已认证
printf 'method="client_auth", clientmac="aa:bb:cc:dd:ee:01", timestamp=%s, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=""\n' "$NOW" "$START" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
out=$(call overview dashboard)
ck "dashboard 出客户端" '"mac":"aa:bb:cc:dd:ee:01"' "$out"
ck "11.2.0带引号格式→已认证" '"authenticated":true' "$out"

# E2: 只有 shutdown_deauth（带引号）→ 仍算已认证（停NDS不清除）。重置文件避免叠加
printf 'method="client_auth", clientmac="aa:bb:cc:dd:ee:01", timestamp=%s, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=""\n' "$NOW" "$START" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
printf 'method="shutdown_deauth", clientmac="aa:bb:cc:dd:ee:01", timestamp=%s, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=""\n' "$NOW" "$START" "$EXP" >>"$CPD_NDSLOG_DIR/binauthlog.log"
out=$(call overview dashboard)
ck "11.2.0 shutdown_deauth(引号)→仍已认证" '"authenticated":true' "$out"

# E3: 只有 client_auth + ndsctl_deauth（都带引号）→ 主动踢下线，不算已认证
printf 'method="client_auth", clientmac="aa:bb:cc:dd:ee:01", timestamp=%s, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=""\n' "$NOW" "$START" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
printf 'method="ndsctl_deauth", clientmac="aa:bb:cc:dd:ee:01", timestamp=%s, bytes_incoming=0, bytes_outgoing=0, session_start=%s, session_end=%s, token=x, custom=""\n' "$NOW" "$START" "$EXP" >>"$CPD_NDSLOG_DIR/binauthlog.log"
out=$(call overview dashboard)
ck "11.2.0 ndsctl_deauth(引号)→未认证" '"authenticated":0' "$out"

# E4: 回到 10.3.1 无引号格式 client_auth → 仍判已认证（老格式不回归）
printf 'method=client_auth, clientmac=aa:bb:cc:dd:ee:01, session_start=%s, session_end=%s\n' "$START" "$EXP" >"$CPD_NDSLOG_DIR/binauthlog.log"
out=$(call overview dashboard)
ck "10.3.1无引号格式→已认证(不回归)" '"authenticated":true' "$out"

done_report
