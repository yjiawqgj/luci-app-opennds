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

echo "################ 1/2 静态自检 ################"
python3 "$REPO/_selfcheck.py" || rc=1

echo
echo "################ 2/2 后端沙箱用例 ################"
for t in "$HERE"/t[0-9]*_*.sh; do
	[ -f "$t" ] || continue
	echo "======== $(basename "$t") ========"
	sh "$t" || rc=1
	echo
done

echo "################ 结果 ################"
if [ "$rc" = '0' ]; then
	echo "全部通过"
else
	echo "有问题，先修再编译"
fi
exit $rc
