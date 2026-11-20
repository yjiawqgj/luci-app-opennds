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
	# 桩必须可执行：Windows 上 checkout 出来的文件常丢 exec 位，
	# CI 里则依赖 git 记录的 100755 —— 这里兜一次，两边都不会挂
	chmod +x "$HERE/mock/bin/"* 2>/dev/null
	export PATH="$HERE/mock/bin:$PATH"
	# pidof 桩的开关：默认 opennds 在跑（与旧 ndsctl status 必成功语义一致）
	export NDS_RUNNING="${NDS_RUNNING:-1}"
	export CPD_ROOT="$S/cpd"
	export ZONE_UP="$S/up"
	export MOCK_UCI_ROOT="$S/uci"
	export MOCK_UCI_DELTA="$S/uci_delta"
	export OPENNDS_CONF="$S/etc/opennds"
	export ZONE_DETECT_CONFIG="$S/etc/zone_detect"
	export ZONE_BLACKLIST_CONF="$S/etc/zone_blacklist"
	# 保存并应用的后台 worker：状态文件 / 锁都搬进沙箱，等待预算压短
	export CPD_APPLY_STATE="$S/apply.state"
	export CPD_APPLY_LOCK="$S/lock/apply.lock"
	export CPD_SESSION_CACHE="$S/sessions"
	export CPD_NDSLOG_DIR="$S/ndslog"   # openNDS 原生认证落盘日志，沙箱隔离
	export CPD_STOP_WAIT="${CPD_STOP_WAIT:-2}"
	export CPD_READY_WAIT="${CPD_READY_WAIT:-2}"
	mkdir -p "$CPD_ROOT" "$ZONE_UP" "$MOCK_UCI_ROOT" "$S/etc" "$S/lock"
	printf 'config opennds\n\toption enabled 0\n' >"$OPENNDS_CONF"
	printf 'config main\n' >"$ZONE_DETECT_CONFIG"
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
