#!/bin/sh
# 沙箱后端测试的公共骨架：把 api 脚本拷进临时目录，桩掉 uci/flock/iw/ndsctl，
# 每个用例都在自己的临时目录里跑，互不影响，可以直接在 CI / 本机 / 路由器上跑。
#
# 用法（在用例脚本里）：
#   . "$(dirname "$0")/lib.sh"
#   tmp_setup t6          # → S / API / conf 目录 / 桩 PATH 全部就绪
#   call exempt status    # → 调后端，拿到一行 JSON
#   ck "名称" '期望子串' "$out"

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
API_SRC="$REPO/luci-app-opennds-cpd/root/usr/lib/opennds/opennds-cpd-api.sh"

fail=0

tmp_setup() { # $1=用例名
	name="$1"
	# 不用 $TMPDIR：Windows 下它常是 C:\Users\...\Temp，拼出来是非法路径
	S=$(mktemp -d /tmp/cpdtest.XXXXXX 2>/dev/null) || S=$(mktemp -d) || exit 1
	trap 'rm -rf "$S" 2>/dev/null' EXIT INT TERM
	API="$S/api.sh"
	cp "$API_SRC" "$API" || exit 1
	export PATH="$HERE/mock/bin:$PATH"
	export CPD_ROOT="$S/cpd"
	export ZONE_UP="$S/up"
	export MOCK_UCI_ROOT="$S/uci"
	export MOCK_UCI_DELTA="$S/uci_delta"
	export OPENNDS_CONF="$S/etc/opennds"
	export ZONE_DETECT_CONFIG="$S/etc/zone_detect"
	export ZONE_BLACKLIST_CONFIG="$S/etc/zone_blacklist"
	mkdir -p "$CPD_ROOT" "$ZONE_UP" "$MOCK_UCI_ROOT" "$S/etc"
	printf 'config opennds\n\toption enabled 0\n' >"$OPENNDS_CONF"
	printf 'config main\n' >"$ZONE_DETECT_CONFIG"
	printf 'config main\n' >"$ZONE_BLACKLIST_CONFIG"
}

call() { sh "$API" "$@" 2>/dev/null; }

ck() { # $1=名称 $2=期望子串 $3=实际
	case "$3" in
		*"$2"*) echo "  OK   $1" ;;
		*) echo "  FAIL $1"; echo "       期望含: $2"; echo "       实际: $3"; fail=1 ;;
	esac
}

done_report() {
	echo "---"
	[ "$fail" = '0' ] && echo "$name 全部通过" || echo "$name 有失败项"
	exit $fail
}
