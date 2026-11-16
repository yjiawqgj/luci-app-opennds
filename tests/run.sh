#!/bin/sh
# 全量离线自检：静态检查 + 后端沙箱用例。
# 本机（Windows/Git Bash、Linux、macOS）和 CI 都能直接跑，不碰真实配置。
#
#   sh tests/run.sh
#
# 退出码 0 = 全绿；非 0 = 有问题，别编译。
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
rc=0

PY=python3
command -v python3 >/dev/null 2>&1 || PY=python

chmod +x "$HERE/mock/bin/"* 2>/dev/null

echo "################ 1/3 静态自检 ################"
"$PY" "$REPO/_selfcheck.py" || rc=1

echo
echo "################ 2/3 后端沙箱用例 ################"
for t in "$HERE"/t[0-9]*_*.sh; do
	[ -f "$t" ] || continue
	echo "======== $(basename "$t") ========"
	sh "$t" || rc=1
	echo
done

echo
echo "################ 3/3 uci 暂存链路（真实 luci uci.js） ################"
# 用官方 uci.js 跑一遍 set/save，确认我们的调用真会下发到 ubus。
# 拿不到源码就跳过（不阻塞编译），能拿到就必须全绿。
if [ -z "$LUCI_SRC" ] && [ -f /tmp/lucisrc/uci.js ]; then
	LUCI_SRC=/tmp/lucisrc
fi
if [ -z "$LUCI_SRC" ] && command -v curl >/dev/null 2>&1; then
	TMPLUCI=$(mktemp -d 2>/dev/null) && mkdir -p "$TMPLUCI" &&
		curl -fsSL --max-time 20 \
			https://raw.githubusercontent.com/openwrt/luci/openwrt-24.10/modules/luci-base/htdocs/luci-static/resources/uci.js \
			-o "$TMPLUCI/uci.js" 2>/dev/null && [ -s "$TMPLUCI/uci.js" ] && LUCI_SRC="$TMPLUCI"
fi
if [ -n "$LUCI_SRC" ] && [ -f "$LUCI_SRC/uci.js" ] && command -v node >/dev/null 2>&1; then
	LUCI_SRC="$LUCI_SRC" node "$HERE/uci_logic.js" || rc=1
else
	echo "（跳过：没有 node 或拿不到 luci 的 uci.js）"
fi

echo
echo "################ 结果 ################"
if [ "$rc" = '0' ]; then
	echo "全部通过"
else
	echo "有问题，先修再编译"
fi
exit $rc
