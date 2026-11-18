#!/bin/sh
# luci-app-opennds-cpd 唯一后端脚本
# 调用形式：opennds-cpd-api.sh <页面名> <子命令> [参数…]
# 参数一律按位置逐个传，每个 k=v 是一个独立元素（不拼 &）。
# 信封：成功 {"ok":1,…} / 失败 {"ok":0,"error":…} / 忙 {"ok":0,"busy":1,"page":…}
# 成败一律看 ok，不看退出码；业务失败（含 busy）统一 exit 0，
# 只有脚本起不来（缺 flock 等）才用非 0 退出码，且仍输出一行 JSON。
# 纯文本日志走 stderr / logger，stdout 只允许出现一行 JSON。
#
# 实现依据：《整包集成与打包.md》§11-§12、各页面开发文档 §7。

PAGE="${1:-}"

# ============================================================
# 基础工具
# ============================================================

# JSON 字符串转义：反斜杠、双引号；换行/回车/制表折成空格
json_escape() {
	printf '%s' "$1" \
		| tr '\n\r\t' '   ' \
		| sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

out_err() {
	printf '{"ok":0,"error":"%s"}\n' "$(json_escape "$1")"
	exit 0
}

# stderr 日志
log() {
	printf '%s\n' "$*" >&2
	logger -t opennds-cpd "$*" 2>/dev/null
}

# 写配置失败的定位信息（rt/wg/ac/st 四个 apply 用）
FAIL_STEP=''
fail_at() {
	FAIL_STEP="$1"
	log "uci 写入失败：$1"
}

# uci 只读
uci_get() {
	uci -q get "$1" 2>/dev/null
}
uci_val() { # $1=键 $2=默认值
	local v
	v=$(uci -q get "$1" 2>/dev/null)
	if [ -n "$v" ]; then
		printf '%s' "$v"
	else
		printf '%s' "$2"
	fi
}

# openNDS 主配置是否可用：只要配置文件存在就继续（缺配置节时页面按默认值显示，
# 用户点保存时会自动建节）；只有配置文件完全不存在才报「未找到配置」
nds_conf_ok() {
	[ -f "${OPENNDS_CONF:-/etc/config/opennds}" ] && return 0
	uci -q show 'opennds.@opennds[0]' 2>/dev/null | grep -q . && return 0
	return 1
}

# MAC：格式校验 + 大小写归一
mac_valid() {
	printf '%s' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}
mac_lower() {
	printf '%s' "$1" | tr 'A-Z' 'a-z'
}
mac_upper() {
	printf '%s' "$1" | tr 'a-z' 'A-Z'
}
mac_nocolon() {
	printf '%s' "$1" | tr -d ':'
}

# 纯非负整数校验
int_valid() {
	case "$1" in
		'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

# epoch → "YYYY-MM-DD HH:mm"；"null"/空/非数字 → 空
fmt_time() {
	local e="$1" t
	case "$e" in
		'' | null | 0) return 1 ;;
	esac
	case "$e" in
		*[!0-9]*) return 1 ;;
	esac
	t=$(date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null) ||
		t=$(date -D %s -d "$e" '+%Y-%m-%d %H:%M' 2>/dev/null) || return 1
	printf '%s' "$t"
}

# JSON 字符串转义，换行输出为 \n（多行文本字段用；tabs 原样保留）
json_escape_nl() {
	printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
		gsub(/\\/, "\\\\")
		gsub(/"/, "\\\"")
		if (NR > 1) printf "\\n"
		printf "%s", $0
	}'
}

# 名单读取：uci get 对 list 返回空格分隔单行
list_of() {
	uci -q get "$1" 2>/dev/null
}

mac_in_list() { # $1=list 值 $2=小写 mac
	case " $1 " in
		*" $2 "*) return 0 ;;
	esac
	return 1
}

# 在 preemptivemac 名单里找某 MAC 的整条条目
entry_for_mac() { # $1=list 值 $2=小写 mac
	local e
	for e in $1; do
		case "$e" in
			"mac=$2;"* | "mac=$2")
				printf '%s' "$e"
				return 0
				;;
		esac
	done
	return 1
}

# ============================================================
# 常用状态读取
# ============================================================

nds_enabled() { # 空/缺键按 1（官方默认启用）
	local v
	v=$(uci -q get 'opennds.@opennds[0].enabled' 2>/dev/null)
	case "$v" in
		'') printf '1' ;;
		*) printf '%s' "$v" ;;
	esac
}

nds_engaged() { # login_option_enabled=='3' 且 themespec_path 指向本插件脚本 → 1
	local lo tp
	lo=$(uci_get 'opennds.@opennds[0].login_option_enabled')
	tp=$(uci_get 'opennds.@opennds[0].themespec_path')
	if [ "$lo" = '3' ] && [ "$tp" = '/usr/lib/opennds/theme_zone_detect.sh' ]; then
		printf '1'
	else
		printf '0'
	fi
}

managed_iface() { # 先 uci，取不到再从 ndsctl status 的 Managed interface 取，都没有回退 br-lan
	local v
	v=$(uci_get 'opennds.@opennds[0].gatewayinterface')
	if [ -n "$v" ]; then
		printf '%s' "$v"
		return 0
	fi
	v=$(ndsctl_run status |
		awk '/^Managed interface:/ {split($2, a, " "); print a[1]; exit}')
	if [ -n "$v" ]; then
		printf '%s' "$v"
		return 0
	fi
	# openNDS 未运行 / ndsctl 不可用时按默认管理接口展示，概览与有线区域卡片才有内容
	printf 'br-lan'
	return 0
}

iface_ip() { # $1=接口名 → 首个 IPv4
	ip -4 addr show dev "$1" 2>/dev/null |
		awk '/inet / {split($2, a, "/"); print a[1]; exit}'
}

# ============================================================
# 跨页互斥锁（《整包集成与打包.md》§11.3）
# ============================================================

acquire_lock() {
	command -v flock >/dev/null 2>&1 || {
		printf '{"ok":0,"error":"系统缺少 flock 命令，请先安装 flock 包"}\n'
		exit 1
	}
	mkdir -p /var/lock 2>/dev/null
	# 预检不走重定向：exec/: 的重定向失败在 POSIX sh 里会直接退出整个脚本
	if [ ! -d /var/lock ] || [ ! -w /var/lock ]; then
		printf '{"ok":0,"error":"无法创建锁文件 /var/lock/opennds-cpd.lock"}\n'
		exit 1
	fi
	if [ -e /var/lock/opennds-cpd.lock ] && [ ! -f /var/lock/opennds-cpd.lock ]; then
		printf '{"ok":0,"error":"锁文件路径异常 /var/lock/opennds-cpd.lock"}\n'
		exit 1
	fi
	exec 9>/var/lock/opennds-cpd.lock
	if ! flock -n 9; then
		printf '{"ok":0,"busy":1,"page":"%s"}\n' "$(json_escape "$PAGE")"
		exit 0
	fi
	mkdir -p /var/run 2>/dev/null
	printf '%s %s %s\n' "$$" "$(date +%s)" "$PAGE" > /var/run/opennds-cpd.busy 2>/dev/null
	trap 'rm -f /var/run/opennds-cpd.busy 2>/dev/null' EXIT
}

# 只读 status 用：试抢即放（拿到立刻放开），busy=1 才算忙
busy_probe() {
	local b=1
	command -v flock >/dev/null 2>&1 || {
		printf '0'
		return 0
	}
	mkdir -p /var/lock 2>/dev/null
	# 目录不可用或缺 flock 时按"不忙"处理，绝不让重定向失败杀死脚本
	if [ ! -d /var/lock ] || [ ! -w /var/lock ]; then
		printf '0'
		return 0
	fi
	if [ -e /var/lock/opennds-cpd.lock ] && [ ! -f /var/lock/opennds-cpd.lock ]; then
		printf '0'
		return 0
	fi
	exec 9>/var/lock/opennds-cpd.lock 2>/dev/null
	if flock -n 9 2>/dev/null; then
		flock -u 9 2>/dev/null
		b=0
	fi
	printf '%s' "$b"
}

# ============================================================
# ndsctl / 服务操作（《整包集成与打包.md》§11.4）
# ============================================================

# 运行时动作：小写失败转大写重试一次
ndsctl_mac() { # $1=子命令 $2=小写 mac
	ndsctl "$1" "$2" >/dev/null 2>&1 && return 0
	ndsctl "$1" "$(mac_upper "$2")" >/dev/null 2>&1
	return 0
}

# 就绪判据：pidof 有值 且 ndsctl status 能成功，最多 15 秒（30 次 × 0.5 秒）
wait_ready() {
	# 总预算约 13 秒（6 次 × 单次限时 2 秒 + 间隔），别把 20 秒的 RPC 超时撑爆
	local i=0
	while [ "$i" -lt 6 ]; do
		if [ -n "$(pidof opennds 2>/dev/null)" ] &&
			NDSCTL_TIMEOUT=2 ndsctl_run status >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.5 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	return 1
}

nds_running() { # openNDS 进程在跑 → 0
	pidof opennds >/dev/null 2>&1 && return 0
	local p c
	for p in /proc/[0-9]*/comm; do
		[ -r "$p" ] || continue
		read -r c <"$p" 2>/dev/null || continue
		[ "$c" = 'opennds' ] && return 0
	done
	return 1
}

# ndsctl 限时执行：openNDS 忙（刚启动/在生成门户资源）时，ndsctl 可能长时间
# 拿不到应答。不限时的话一次轮询里的多次 ndsctl 调用会把整个请求拖过 LuCI
# 的 RPC 超时（官方 rpc.js 默认 20 秒），页面上表现为连续的
# 「XHR request timed out」红色横幅。有 timeout 命令就限时执行
# （默认 8 秒；就绪探测用 NDSCTL_TIMEOUT=2 的短限时）。
ndsctl_run() {
	local t="${NDSCTL_TIMEOUT:-8}"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$t" ndsctl "$@" 2>/dev/null
	else
		ndsctl "$@" 2>/dev/null
	fi
}

# SR_RESTARTED=1 表示本次真的重启了；0 表示 openNDS 未运行、只写配置没拉起。
# 决策：应用设置时不主动启动 openNDS，启动只由概览页的启停开关负责。
SR_RESTARTED=0
service_restart() {
	SR_RESTARTED=0
	nds_running || return 0
	SR_RESTARTED=1
	/etc/init.d/opennds restart 9>&- >/dev/null 2>&1
	wait_ready
}

# 预认证队列文件删除：mountpoint 由 configure_log_location() 现探
# （/tmp /run /var 里第一个 tmpfs，探不到退 /tmp）；大小写各删一次，删不到不算错
preauth_mountpoint() {
	local d
	for d in /tmp /run /var; do
		if mount 2>/dev/null | grep -q "on $d type tmpfs"; then
			printf '%s' "$d"
			return 0
		fi
	done
	printf '/tmp'
}

remove_preauth_queue() { # $1=mac（任意大小写）
	local mp
	mp=$(preauth_mountpoint)
	rm -f "$mp/ndscids/preemptive_auth/$(mac_nocolon "$(mac_lower "$1")")" \
		"$mp/ndscids/preemptive_auth/$(mac_nocolon "$(mac_upper "$1")")" 2>/dev/null
	return 0
}

# commit 后主动投递预认证：不带参数调一次
# （10.x 主进程那轮调的是 preemptivemac quiet，随包脚本不解析名单）
kick_preemptive() {
	/usr/lib/opennds/libopennds.sh preemptivemac 9>&- >/dev/null 2>&1
	return 0
}

# ============================================================
# ndsctl json 解析（单 awk 遍历）
# 摘要行（S）：mac state ip clientif ss se la dl_kb ul_kb davg uavg
#              client_type dl_rate ul_rate dl_quota ul_quota custom
# trusted 行（T）：mac
# ============================================================

NDSCTL_JSON_AWK='
/^[ \t]*"[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]"[ \t]*:[ \t]*\{[ \t]*$/ {
	line = $0
	sub(/\{[ \t]*$/, "", line)
	sub(/[ \t]*:[ \t]*$/, "", line)
	sub(/^[ \t]*"/, "", line)
	sub(/"[ \t]*$/, "", line)
	cur = line; in_c = 1
	next
}
in_c && /^[ \t]*\}[ \t]*,?[ \t]*$/ {
	printf "S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
		cur, st[cur], ip[cur], cif[cur], ss[cur], se[cur], la[cur], \
		dlt[cur], ult[cur], davg[cur], uavg[cur], cty[cur], \
		drt[cur], urt[cur], dq[cur], uq[cur], cu[cur]
	in_c = 0; cur = ""
	next
}
in_c {
	s = $0
	sub(/^[ \t]+/, "", s)
	sub(/,[ \t]*$/, "", s)
	if (match(s, /^"[a-zA-Z_0-9]+"[ \t]*:[ \t]*".*"$/)) {
		kv = substr(s, RSTART, RLENGTH)
		sub(/^"/, "", kv)
		i = index(kv, "\"")
		k = (i > 0) ? substr(kv, 1, i - 1) : ""
		v = (i > 0) ? substr(kv, i + 1) : ""
		sub(/^[ \t]*:[ \t]*"/, "", v)
		sub(/"$/, "", v)
		if (k == "state") st[cur] = v
		else if (k == "ip") ip[cur] = v
		else if (k == "clientif") cif[cur] = v
		else if (k == "session_start") ss[cur] = v
		else if (k == "session_end") se[cur] = v
		else if (k == "last_active") la[cur] = v
		else if (k == "download_this_session") dlt[cur] = v
		else if (k == "upload_this_session") ult[cur] = v
		else if (k == "download_session_avg") davg[cur] = v
		else if (k == "upload_session_avg") uavg[cur] = v
		else if (k == "client_type") cty[cur] = v
		else if (k == "download_rate_limit_threshold") drt[cur] = v
		else if (k == "upload_rate_limit_threshold") urt[cur] = v
		else if (k == "download_quota") dq[cur] = v
		else if (k == "upload_quota") uq[cur] = v
		else if (k == "custom") cu[cur] = v
	}
	next
}
/^[ \t]*"trusted"[ \t]*:[ \t]*\[[ \t]*$/ { in_t = 1; next }
in_t && /^[ \t]*\][ \t]*,?[ \t]*$/ { in_t = 0; next }
in_t {
	s = $0
	sub(/^[ \t]+/, "", s)
	sub(/,[ \t]*$/, "", s)
	gsub(/"/, "", s)
	if (s != "") printf "T\t%s\n", s
	next
}
'

parse_clients() {
	ndsctl_run json | awk "$NDSCTL_JSON_AWK"
}

# ============================================================
# 无线：SSID 反查（iw dev <if> info 直读，回退 uci 序号映射）
# ============================================================

ssid_for_if() { # $1=运行时接口名
	local s
	[ -z "$1" ] && return 1
	s=$(iw dev "$1" info 2>/dev/null | awk '/^[ \t]*ssid / {print $2; exit}')
	if [ -n "$s" ]; then
		printf '%s' "$s"
		return 0
	fi
	ssid_via_uci "$1"
}

# 回退：phyN-apM → radioN 第 M 个（mode=ap 且未禁用的）AP section
ssid_via_uci() { # $1=接口名
	local ifn="$1" phy radio apidx secids sec seen dev mode dis ssid
	case "$ifn" in
		phy[0-9]-ap[0-9] | phy[0-9]-ap[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	phy="${ifn%%-*}"
	radio="radio${phy#phy}"
	apidx="${ifn##*-ap}"
	seen=0
	secids=$(uci show wireless 2>/dev/null |
		awk -F'[.=]' '/^wireless\..+=wifi-iface$/ {print $2}')
	for sec in $secids; do
		dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
		[ "$dev" = "$radio" ] || continue
		mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
		[ "$mode" = 'ap' ] || continue
		dis=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
		[ "$dis" = '1' ] && continue
		seen=$((seen + 1))
		if [ "$seen" = "$apidx" ]; then
			ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
			[ -n "$ssid" ] && {
				printf '%s' "$ssid"
				return 0
			}
			return 1
		fi
	done
	return 1
}

# radio 是否未启用——以 openwrt 官方判定为准，uci 优先、运行时兜底：
# ① uci wireless.<radio>.disabled 为 1/on/true → 未启用
#    （这是用户在 LuCI 里关无线时写下的值，比运行时状态权威；
#     旧实现只在 ubus 读不到时才看它，于是"已经在 LuCI 里关掉的 wifi
#     在卡片上仍然显示已启用"）
# ② 运行时 ubus network.wireless status 里 radio 的 up 为假 → 也算未启用
#    （无线总开关关闭、定时关闭这类没写进配置的运行时禁用）
wifi_radio_off() { # $1=radio 名 → rc 0=未启用
	local dis up
	dis=$(uci -q get "wireless.$1.disabled" 2>/dev/null)
	case "$dis" in 1 | on | true | yes) return 0 ;; esac
	# ② 运行时没起来也算未启用（无线总开关关闭、定时关闭等）
	#    CPD_WS 是 z_status 预先取好的 network.wireless status，避免每个接口各调一次 ubus
	if [ -n "$CPD_WS" ]; then
		up=$(printf '%s' "$CPD_WS" | jsonfilter -q -e "@.$1.up" 2>/dev/null)
		case "$up" in 0 | false) return 0 ;; esac
	elif command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		up=$(ubus call network.wireless status 2>/dev/null | jsonfilter -q -e "@.$1.up" 2>/dev/null)
		case "$up" in 0 | false) return 0 ;; esac
	fi
	return 1
}

# 该 section 是它 radio 内第几个启用的 AP section（1-based；找不到回 0）
ap_section_index() { # $1=section id $2=device
	local want="$1" dev="$2" secids sec d m dis n=0
	secids=$(uci show wireless 2>/dev/null |
		awk -F'[.=]' '/^wireless\..+=wifi-iface$/ {print $2}')
	for sec in $secids; do
		d=$(uci -q get "wireless.$sec.device" 2>/dev/null)
		[ "$d" = "$dev" ] || continue
		m=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
		[ "$m" = 'ap' ] || continue
		dis=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
		[ "$dis" = '1' ] && continue
		n=$((n + 1))
		[ "$sec" = "$want" ] && {
			printf '%s' "$n"
			return 0
		}
	done
	printf '0'
}

# radio 的 AP 运行时接口里，SSID 匹配优先，序号兜底
ap_runtime_if() { # $1=radio $2=ssid $3=序号
	local radio="$1" want="$2" idx="$3" ifn ssid
	ifn=$(iw dev 2>/dev/null | awk -v radio="$radio" '
		/^phy#[0-9]+$/ { phy = "radio" substr($0, 5) }
		/^[ \t]*Interface [^ \t]+$/ { ifn = $2 }
		/^[ \t]*type [ \t]*AP[ \t]*$/ {
			if (ifn != "" && phy == radio) print ifn
			ifn = ""
		}')
	# SSID 匹配优先
	for i in $ifn; do
		ssid=$(iw dev "$i" info 2>/dev/null | awk '/^[ \t]*ssid / {print $2; exit}')
		[ "$ssid" = "$want" ] && {
			printf '%s' "$i"
			return 0
		}
	done
	# 序号兜底
	[ "$idx" -gt 0 ] 2>/dev/null && {
		printf '%s' "$ifn" | sed -n "${idx}p"
	}
	return 0
}

# ============================================================
# 参数扫描：confirm_enable（《整包集成与打包.md》§11.1）
# 在各页解析业务参数之前扫一遍 argv 摘出它；摘掉后的参数按位置传递
# ============================================================

CONFIRM_ENABLE=0
EN_BY_APPLY=0
strip_confirm() { # $@=原始业务参数 → 设置 CONFIRM_ENABLE / ARGS（换行分隔）
	local a
	CONFIRM_ENABLE=0
	ARGS=""
	for a in "$@"; do
		case "$a" in
			confirm_enable=1)
				CONFIRM_ENABLE=1
				;;
			*)
				if [ -z "$ARGS" ]; then
					ARGS="$a"
				else
					ARGS="$ARGS
$a"
				fi
				;;
		esac
	done
}

# 通用：写 opennds 的页面在 enabled=0 且未确认时不写任何东西
guard_enable() { # 返回 0=可继续；返回 1=已输出 need_confirm 应答
	local en
	en=$(nds_enabled)
	if [ "$en" = '0' ] && [ "$CONFIRM_ENABLE" != '1' ]; then
		printf '{"ok":0,"error":"need_confirm","enabled":0}\n'
		return 1
	fi
	return 0
}

# ============================================================
# 页面：overview（《OpenNDS概览.md》§7）
# ============================================================

# 读三份名单，归一为小写合法 MAC 集合：BL_MACS / TR_MACS / PM_MACS 与原始 PM_LIST
ov_load_lists() { # 读三份名单（小写集合）：BL_MACS / TR_MACS / PM_MACS，原始条目 PM_LIST
	local v
	PM_LIST=$(list_of 'opennds.@opennds[0].preemptivemac')

	BL_MACS=""
	for v in $(list_of 'opennds.@opennds[0].blockedmac'); do
		mac_valid "$v" || continue # 空值等脏数据过滤掉
		BL_MACS="$BL_MACS $(mac_lower "$v")"
	done
	BL_MACS=" $BL_MACS "

	# 一个客户端只能属于一个名单：黑名单优先。
	# openNDS 官方机制里 BlockedMAC 的报文在防火墙层直接丢弃，比 trusted 更靠前，
	# 所以 MAC 一旦在黑名单里，就不再算可信任 / 免认证 —— 页面显示与运行时一致。
	# 配置里已经写重复的（旧版本或手改留下），由启动/应用后的 sys_dedup_lists 清掉。
	TR_MACS=""
	for v in $(list_of 'opennds.@opennds[0].trustedmac'); do
		mac_valid "$v" || continue
		mac_in_bl "$(mac_lower "$v")" && continue
		TR_MACS="$TR_MACS $(mac_lower "$v")"
	done
	TR_MACS=" $TR_MACS "

	PM_MACS=""
	for v in $PM_LIST; do
		case "$v" in
			mac=*)
				v="${v#mac=}"
				v="${v%%;*}"
				mac_valid "$v" || continue
				v=$(mac_lower "$v")
				mac_in_bl "$v" && continue
				PM_MACS="$PM_MACS $v"
				;;
		esac
	done
	PM_MACS=" $PM_MACS "
}

# 黑名单 / 信任 / 免认证三份名单互斥（黑名单 > 可信任 > 免认证）：
# 启动与应用后各跑一次，把配置里真实存在的重复条目删掉（只动重复项，其余不碰）。
# 这一步保证用户设备上历史遗留的"同时出现在两个名单里"会被自动修正。
sys_dedup_lists() {
	local osc v lm e changed=0
	uci -q show 'opennds.@opennds[0]' >/dev/null 2>&1 || return 0
	osc='@opennds[0]'

	local bl=' '
	for v in $(list_of 'opennds.@opennds[0].blockedmac'); do
		mac_valid "$v" && bl="$bl$(mac_lower "$v") "
	done

	# ① 黑名单里有的，从 trustedmac 摘掉
	for v in $(list_of 'opennds.@opennds[0].trustedmac'); do
		mac_valid "$v" || continue
		lm=$(mac_lower "$v")
		case "$bl" in
			*" $lm "*) uci del_list "opennds.$osc.trustedmac=$v" 2>/dev/null && changed=1 ;;
		esac
	done

	# ② 黑名单里有的，从 preemptivemac 摘掉（并清掉预认证队列，免得下一轮又自动登录）
	local pm
	pm=$(list_of 'opennds.@opennds[0].preemptivemac')
	for e in $pm; do
		lm=$(printf '%s' "$e" | sed -n 's/^mac=//p' | cut -d';' -f1)
		mac_valid "$lm" || continue
		lm=$(mac_lower "$lm")
		case "$bl" in
			*" $lm "*) uci del_list "opennds.$osc.preemptivemac=$e" 2>/dev/null || continue
				remove_preauth_queue "$lm"
				changed=1
				;;
		esac
	done

	# ③ 可信任与免认证同时存在的：保留可信任（权限更大），摘免认证
	local tr=' ' v2
	for v2 in $(list_of "opennds.$osc.trustedmac"); do
		mac_valid "$v2" && tr="$tr$(mac_lower "$v2") "
	done
	pm=$(list_of "opennds.$osc.preemptivemac")
	for e in $pm; do
		lm=$(printf '%s' "$e" | sed -n 's/^mac=//p' | cut -d';' -f1)
		mac_valid "$lm" || continue
		lm=$(mac_lower "$lm")
		case "$tr" in
			*" $lm "*) uci del_list "opennds.$osc.preemptivemac=$e" 2>/dev/null || continue
				remove_preauth_queue "$lm"
				changed=1
				;;
		esac
	done

	[ "$changed" = '1' ] || return 0
	if uci commit opennds 2>/dev/null; then
		log '已清理重复名单条目：同一 MAC 只保留一个身份（黑名单 > 可信任 > 免认证）'
	fi
	return 0
}

mac_in_bl() {
	case "$BL_MACS" in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# openNDS 官方 MAC 黑名单语义：blockedmac 只在 macmechanism='block' 时生效。
# 名单有内容而用户没设过 mechanism 时补成 'block'；用户已设的值一律不碰
# （'allow' 是白名单模式，属于用户自己的选择，前端会另行提示名单不生效）。
# $1=opennds section 名（不含配置前缀）
ensure_block_mechanism() { # $1=section
	local mm
	mm=$(uci -q get "opennds.$1.macmechanism" 2>/dev/null)
	case "$mm" in
		'' | *[!A-Za-z0-9_-]*) uci set "opennds.$1.macmechanism"='block' || out_err '写入配置失败' ;;
	esac
	return 0
}
mac_in_tr() {
	case "$TR_MACS" in
		*" $1 "*) return 0 ;;
	esac
	return 1
}
mac_in_pm() {
	case "$PM_MACS" in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# 单客户端 limits 对象（7 键）；$1=该 mac 的 preemptivemac 条目（可为空）
ov_limits_json() {
	local e="$1" p k v
	local st=0 ur=0 dr=0 uq=0 dq=0
	if [ -n "$e" ]; then
		local oldifs="$IFS"
		IFS=';'
		set -- $e
		IFS="$oldifs"
		for p in "$@"; do
			case "$p" in
				*=*)
					k="${p%%=*}"
					v="${p#*=}"
					;;
				*) continue ;;
			esac
			case "$k" in
				sessiontimeout) st="$v" ;;
				uploadrate) ur="$v" ;;
				downloadrate) dr="$v" ;;
				uploadquota) uq="$v" ;;
				downloadquota) dq="$v" ;;
			esac
		done
	fi
	int_valid "$st" || st=0
	int_valid "$ur" || ur=0
	int_valid "$dr" || dr=0
	int_valid "$uq" || uq=0
	int_valid "$dq" || dq=0
	local fup_u fup_d
	fup_u="$CPD_FUP_U"
	fup_d="$CPD_FUP_D"
	if [ -z "$fup_u$fup_d" ]; then
		fup_u=$(uci_val 'opennds.@opennds[0].fup_upload_throttle_rate' '0')
		fup_d=$(uci_val 'opennds.@opennds[0].fup_download_throttle_rate' '0')
	fi
	int_valid "$fup_u" || fup_u=0
	int_valid "$fup_d" || fup_d=0

	# >0 才算"单独设置"；条目不存在或值为 0 → enabled:false
	lim_en() {
		[ "$1" -gt 0 ] 2>/dev/null && printf 'true' || printf 'false'
	}

	printf '{"maxSession":{"enabled":%s,"value":"%s"},' "$(lim_en "$st")" "$st"
	printf '"uploadRate":{"enabled":%s,"value":"%s"},' "$(lim_en "$ur")" "$ur"
	printf '"downloadRate":{"enabled":%s,"value":"%s"},' "$(lim_en "$dr")" "$dr"
	printf '"uploadQuota":{"enabled":%s,"value":"%s"},' "$(lim_en "$uq")" "$uq"
	printf '"downloadQuota":{"enabled":%s,"value":"%s"},' "$(lim_en "$dq")" "$dq"
	printf '"overQuotaUploadRate":{"enabled":%s,"value":"%s"},' "$(lim_en "$fup_u")" "$fup_u"
	printf '"overQuotaDownloadRate":{"enabled":%s,"value":"%s"}}' "$(lim_en "$fup_d")" "$fup_d"
}

# 租约文件：与官方 libopennds.sh 的 dhcp_check() 同源 ——
# openNDS 配置里有 dhcp_leases_file 就用它，否则依次找 dnsmasq 的三个默认位置
dhcp_leases_file() {
	local v f
	v=$(uci_val 'opennds.@opennds[0].dhcp_leases_file' '')
	if [ -n "$v" ]; then
		printf '%s' "$v"
		return 0
	fi
	for f in /tmp/dhcp.leases /var/lib/misc/dnsmasq.leases /var/db/dnsmasq.leases; do
		[ -f "$f" ] && { printf '%s' "$f"; return 0; }
	done
	printf '/tmp/dhcp.leases'
	return 0
}

# 租约一次性读成 "mac<TAB>主机名"（小写 MAC）；下面查表就不再 fork
ov_lease_map() {
	awk 'NF >= 4 { h = $4; if (h == "" || h == "*") next; print tolower($2) "\t" h }' \
		"$(dhcp_leases_file)" 2>/dev/null
}

ov_host_for() { # $1=小写 mac（租约是小写）
	local m="$1" k v h=''
	if [ -n "$CPD_LEASE_MAP" ]; then
		while IFS='	' read -r k v; do
			[ "$k" = "$m" ] && { h="$v"; break; }
		done <<EOF2
$CPD_LEASE_MAP
EOF2
		printf '%s' "$h"
		return 0
	fi
	# 兜底：没有预读表时现查文件（dnsmasq 行：到期时间 MAC IP 主机名 clientid）
	awk -v m="$m" 'tolower($2) == m && $4 != "" && $4 != "*" {print $4; exit}' \
		"$(dhcp_leases_file)" 2>/dev/null
}

# ARP/邻居表兜底取 IP：openNDS 的 trusted 客户端不一定带着 ip 字段回来，
# 只看 ndsctl 会让"可信任客户端在线却没 IP"。同网段设备的邻居表一定有它。
neigh_ip_for() { # $1=小写 mac
	ip -4 neigh show 2>/dev/null |
		awk -v m="$1" 'tolower($4) == "lladdr" && tolower($5) == m {print $1; exit}'
}

# network.wireless status（ubus）→ "section<TAB>ifname" 行。
# 这是 OpenWrt 运行时最权威的映射：uci 里配的是 section，真正跑起来的接口名
# （phyN-apM）只有 netifd 知道。之前只靠 iw 反查，机器上没装 iw 时全部为空，
# 无线接入点卡片就会一直显示 0。
ws_iface_map() {
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" | awk '
	function flush() {
		if (depth == 1 && sec != "") printf "%s\t%s\n", sec, ifn
		sec = ""; ifn = ""
	}
	/"interfaces"[ \t]*:[ \t]*\[/ { in_if = 1; depth = 0; sec = ""; ifn = ""; next }
	!in_if { next }
	/^[ \t]*\{[ \t]*$/ { depth++; next }
	/^[ \t]*\}[ \t]*,?[ \t]*$/ { if (depth > 0) { if (depth == 1) flush(); depth-- } next }
	depth == 1 && /"section"[ \t]*:/ {
		s = $0; sub(/.*"section"[ \t]*:[ \t]*"/, "", s); sub(/".*/, "", s); sec = s; next
	}
	depth == 1 && /"ifname"[ \t]*:/ {
		v = $0; sub(/.*"ifname"[ \t]*:[ \t]*"/, "", v); sub(/".*/, "", v); ifn = v; next
	}
	'
}

# ubus 调用统一加超时：hostapd 不应答时 ubus 会一直等，整个 dashboard
# 请求被拖死，LuCI 20 秒 RPC 超时后前端拿到的就是空数据
ubus_call() {
	local secs=3
	command -v timeout >/dev/null 2>&1 && secs=3 || secs=''
	if [ -n "$secs" ]; then
		timeout "$secs" ubus "$@" 2>/dev/null
	else
		ubus "$@" 2>/dev/null
	fi
}

# hostapd ubus 的关联终端表：mac<TAB>ifname。
# openNDS 的 clientif 来自 get_client_interface.sh：机器上没装 iw 时退回
# ip -4 neigh 的设备列（br-lan），永远对不上 phyN-apM —— AP 卡片计数和
# 客户端 SSID 都不能靠 clientif，得按 MAC 反查关联表。
# hostapd 的 ubus 对象拿不到时（固件没带 hostapd ubus 支持）退回
# iw dev <接口> station dump；再拿不到就为空，AP 计数由 ov_aps 兜底。
ws_sta_map() { # $1=AP_META（每行 iface<TAB>ssid<TAB>section）
	local ifn
	[ -n "$1" ] || return 0
	command -v ubus >/dev/null 2>&1 || return 0
	for ifn in $(printf '%s\n' "$1" | awk -F'\t' '$1 != "-" && $1 != "" {print $1}'); do
		local got
		got=$(ubus_call call "hostapd.$ifn" get_clients |
			awk -v i="$ifn" '
			{
				s = $0
				m = "[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:" \
					"[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]"
				if (match(s, "\"" m "\"")) {
					k = substr(s, RSTART + 1, RLENGTH - 2)
					# 只要键值是 { 的（clients 对象的键），不要 "address":"<mac>" 这类值
					rest = substr(s, RSTART + RLENGTH)
					sub(/^[ \t]*/, "", rest)
					if (rest ~ /^[ \t]*:[ \t]*\{/) print tolower(k) "\t" i
				}
			}')
		if [ -n "$got" ]; then
			printf '%s\n' "$got"
		elif command -v iw >/dev/null 2>&1; then
			# Station xx:xx:… (on phy2-ap0)
			iw dev "$ifn" station dump 2>/dev/null |
				awk -v i="$ifn" '/^[ \t]*Station[ \t]/ {print tolower($2) "\t" i}'
		fi
	done
}

# 当前启用的 AP 列表：AP_META 每行 iface<TAB>ssid<TAB>section
ov_ap_meta() {
	local secids sec mode dis dev ssid ifn idx
	AP_META=''
	secids=$(uci show wireless 2>/dev/null |
		awk -F'[.=]' '/^wireless\..+=wifi-iface$/ {print $2}')
	for sec in $secids; do
		mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
		[ "$mode" = 'ap' ] || continue
		dis=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
		[ "$dis" = '1' ] && continue
		dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
		if [ -n "$dev" ]; then
			wifi_radio_off "$dev" && continue
		fi
		ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
		ifn=$(printf '%s\n' "$AP_MAP" | awk -F'\t' -v s="$sec" '$1 == s {print $2; exit}')
		if [ -z "$ifn" ]; then
			idx=$(ap_section_index "$sec" "$dev")
			ifn=$(ap_runtime_if "$dev" "$ssid" "$idx")
		fi
		# 空字段同样用 - 占位：read 会吞掉连续的 tab
		[ -z "$ifn" ] && ifn='-'
		[ -z "$ssid" ] && ssid='-'
		AP_META="$AP_META$ifn	$ssid	$sec
"
	done
}

# 运行时接口名 → SSID（客户端列表「接入点」一列显示 SSID，不显示 phyN-apM）
iface_ssid() { # $1=接口名
	local i s r
	[ -n "$1" ] || return 0
	while IFS='	' read -r i s r; do
		[ "$i" = "$1" ] && [ "$s" != '-' ] && [ -n "$s" ] && { printf '%s' "$s"; return 0; }
	done <<EOF2
$AP_META
EOF2
}

# 客户端 → SSID：优先按 MAC 查关联表（clientif 在没装 iw 的机器上是
# br-lan 之类的网桥名，查不到 AP），查不到再退回 clientif 直配
client_ssid() { # $1=mac（小写） $2=clientif
	local cif="$2" sm
	sm=$(printf '%s\n' "$STA_MAP" | awk -F'\t' -v m="$1" '$1 == m && NF >= 2 {print $2; exit}')
	[ -n "$sm" ] && cif="$sm"
	iface_ssid "$cif"
}

# 客户端行；$1=state $2=ip $3=iface $4=mac $5=dl_kb $6=ul_kb $7=ss $8=se $9=online(0/1)
ov_client_row() {
	local state="$1" ip="$2" cif="$3" lm="$4" dkb="$5" ukb="$6" ss="$7" se="$8"
	local onl="${9:-1}"
	local host ssidv apsec up down auth pre trst blk joined expires lim authorized
	host=$(ov_host_for "$lm")
	dkb="${dkb:-0}"
	ukb="${ukb:-0}"
	case "$dkb" in '' | null | *[!0-9]*) dkb=0 ;; esac
	case "$ukb" in '' | null | *[!0-9]*) ukb=0 ;; esac
	up=$((ukb * 1024))
	down=$((dkb * 1024))
	# openNDS 对 trusted 客户端不一定填 ip；用邻居表补，别让"在线却没 IP"
	[ -z "$ip" ] && ip=$(neigh_ip_for "$lm")
	ssidv=$(client_ssid "$lm" "$cif")
	apsec=$(printf '%s\n' "$STA_SEC" | awk -F'\t' -v m="$lm" '$1 == m && NF >= 2 {print $2; exit}')

	auth=false
	pre=false
	trst=false
	blk=false
	case "$state" in
		Authenticated | AuthBlocked) auth=true ;;
	esac
	mac_in_pm "$lm" && pre=true
	mac_in_tr "$lm" && trst=true
	mac_in_bl "$lm" && blk=true
	# trusted 是独立状态，不算 authenticated
	[ "$trst" = 'true' ] && auth=false

	# authorized = 有访问权限（已认证 / 可信任 / 免认证已登录），黑名单一律不算
	authorized=false
	if [ "$blk" != 'true' ]; then
		if [ "$auth" = 'true' ] || [ "$trst" = 'true' ]; then
			authorized=true
		fi
	fi
	[ "$blk" = 'true' ] && authorized=false

	joined=$(fmt_time "$ss")
	expires=$(fmt_time "$se")
	lim=$(ov_limits_json "$(entry_for_mac "$PM_LIST" "$lm")")

	printf '{"host":"%s","ip":"%s","mac":"%s","iface":"%s","ssid":"%s","apsec":"%s","expires":"%s","joined":"%s","timeout":%s,"trafficUp":%s,"trafficDown":%s,"authenticated":%s,"preauth":%s,"trusted":%s,"blocked":%s,"online":%s,"authorized":%s,"limits":%s}' \
		"$(json_escape "$host")" "$(json_escape "$ip")" "$(json_escape "$lm")" \
		"$(json_escape "$cif")" "$(json_escape "$ssidv")" "$(json_escape "$apsec")" \
		"$(json_escape "$expires")" "$(json_escape "$joined")" \
		"${CPD_AUTHIDLE:-120}" \
		"$up" "$down" "$auth" "$pre" "$trst" "$blk" \
		"$( [ "$onl" = '1' ] && printf 'true' || printf 'false' )" \
		"$authorized" "$lim"
}

# 一次构建仪表盘全部数据：CPD_IN / ROWS_JSON / COUNTS_* / APS_JSON
# 之前 status 与 clients 是两个请求、各解析一次 ndsctl、各跑一遍 uci，
# 页面切进来要等两次串行往返；合并成一次后首屏明显更快。
ov_build() {
	local running enabled engaged busy scope='' conf_err=''
	local sm_mac sm_ifn sm_sec
	if [ -f "${OPENNDS_CONF:-/etc/config/opennds}" ]; then
		conf_err=$(uci show opennds 2>&1 >/dev/null)
	fi
	enabled=$(nds_enabled)
	engaged=$(nds_engaged)
	busy=$(busy_probe)
	scope=$(uci_val 'zone_detect.main.session_scope' 'default')
	running=0
	nds_running && running=1
	CPD_RUNNING="$running"
	CPD_ENABLED="$enabled"
	CPD_ENGAGED="$engaged"
	CPD_BUSY="$busy"
	CPD_SCOPE="$scope"
	CPD_CONFERR="$conf_err"

	ov_load_lists
	# 预读：租约表 / 空闲超时 / FUP 速率（每个客户端再查就太慢了）
	CPD_LEASE_MAP=$(ov_lease_map)
	CPD_AUTHIDLE=$(uci_val 'opennds.@opennds[0].authidletimeout' '120')
	CPD_FUP_U=$(uci_val 'opennds.@opennds[0].fup_upload_throttle_rate' '0')
	CPD_FUP_D=$(uci_val 'opennds.@opennds[0].fup_download_throttle_rate' '0')
	CPD_WS=''
	if command -v ubus >/dev/null 2>&1; then
		CPD_WS=$(ubus_call call network.wireless status)
	fi
	AP_MAP=$(ws_iface_map "$CPD_WS")
	ov_ap_meta
	STA_MAP=$(ws_sta_map "$AP_META")
	# MAC → 所属 AP 的 uci 段名。同一个 SSID 常常同时开在 2.4G 和 5G 上，
	# 那是两个段、两张卡片；卡片数量按段统计，列表也必须按段筛选，
	# 否则会出现「卡片显示 2 个、点开列表 5 条」的错位。
	STA_SEC=''
	if [ -n "$STA_MAP" ]; then
		while IFS='	' read -r sm_mac sm_ifn; do
			[ -n "$sm_mac" ] || continue
			sm_sec=$(printf '%s\n' "$AP_META" |
				awk -F'\t' -v x="$sm_ifn" '$1 == x && NF >= 3 {print $3; exit}')
			[ -n "$sm_sec" ] || continue
			STA_SEC="$STA_SEC$sm_mac	$sm_sec
"
		done <<EOF5
$STA_MAP
EOF5
	fi

	CPD_PARSED=''
	CPD_IN=''
	ONLINE_LOWER=''
	if [ "$running" = '1' ]; then
		CPD_PARSED=$(parse_clients)
		# 空值一律写成 -：POSIX read 把 IFS 里的 tab 当空白，连续两个 tab
		# 会被并成一个，空字段直接消失，后面所有字段整体左移（trusted 客户端
		# 的 ip 就是空串，会把 clientif 读成 ip、把流量读成接口名）。
		CPD_IN=$(printf '%s\n' "$CPD_PARSED" | awk -F'\t' '
			function S(v) { return (v == "") ? "-" : v }
			$1 == "S" {
				cif = $5; sub(/ .*/, "", cif)
				print S($2) "\t" S($3) "\t" S($4) "\t" S(cif) "\t" S($9) "\t" S($10) "\t" S($6) "\t" S($7)
			}')
		ONLINE_LOWER=$(printf '%s\n' "$CPD_IN" | awk -F'\t' 'NF {print tolower($1)}' | sort -u)
	fi

	ov_rows
	ov_counts
	ov_aps
}

ov_rows() {
	local mac state ip cif dkb ukb ss se lm rows='' sep='' n=0
	if [ "$CPD_RUNNING" = '1' ]; then
		while IFS='	' read -r mac state ip cif dkb ukb ss se; do
			[ -n "$mac" ] || continue
			# 还原占位符（见 ov_build 里的 S()）
			[ "$ip" = '-' ] && ip=''
			[ "$cif" = '-' ] && cif=''
			[ "$ss" = '-' ] && ss=''
			[ "$se" = '-' ] && se=''
			lm=$(mac_lower "$mac")
			rows="$rows$sep$(ov_client_row "$state" "$ip" "$cif" "$lm" "$dkb" "$ukb" "$ss" "$se" 1)"
			sep=','
			n=$((n + 1))
		done <<EOF2
$CPD_IN
EOF2
	fi

	# 名单补行：trusted / preemptivemac / blockedmac 里不在线的 MAC
	local supp
	supp=$(printf '%s\n' $TR_MACS $PM_MACS $BL_MACS | sort -u | grep -v '^$')
	for lm in $supp; do
		printf '%s\n' "$ONLINE_LOWER" | grep -qx "$lm" && continue
		rows="$rows$sep$(ov_client_row '' '' '' "$lm" 0 0 '' '' 0)"
		sep=','
		n=$((n + 1))
	done
	ROWS_JSON="$rows"
	N_ROWS="$n"
}

# 统计口径：在线 = 有访问权限的在线客户端（已认证 / 免认证已登录 / 可信任），
# 未认证单独算一类。计数与列表用同一组标记（online / authorized），
# 不会出现"卡片 2 个、点开只有 1 个"的对不上。
ov_counts() {
	local lm st cif
	N_ONLINE=0
	N_AUTH=0
	N_PRE=0
	N_TR=0
	N_UN=0
	while IFS='	' read -r lm st cif; do
		[ -n "$lm" ] || continue
		mac_in_bl "$lm" && continue # 黑名单从在线里剔除
		case "$st" in
			Trusted)
				N_TR=$((N_TR + 1))
				N_ONLINE=$((N_ONLINE + 1))
				continue
				;;
			Authenticated | AuthBlocked) ;;
			*)
				N_UN=$((N_UN + 1)) # Preauthenticated：还没通过认证，不算在线
				continue
				;;
		esac
		if mac_in_pm "$lm"; then
			N_PRE=$((N_PRE + 1))
		else
			N_AUTH=$((N_AUTH + 1))
		fi
		N_ONLINE=$((N_ONLINE + 1))
	done <<EOF2
$CPD_IN
EOF2

	# 可信任以配置为准（在线的照常算，离线的不漏）
	local m2 tr_cfg=0
	for m2 in $TR_MACS; do
		[ -n "$m2" ] && tr_cfg=$((tr_cfg + 1))
	done
	[ "$tr_cfg" -gt "$N_TR" ] && N_TR="$tr_cfg"

	N_BL=0
	for m2 in $BL_MACS; do
		[ -n "$m2" ] && N_BL=$((N_BL + 1))
	done
}

ov_aps() {
	local ifn ssid sec cnt lm sm sep=''
	# 关联表整体拿不到（hostapd ubus / iw 都失败）时，退回按 openNDS
	# 的 clientif 计数——装了 iw 的机器上 clientif 就是运行时接口名
	local sta_any=0
	printf '%s\n' "$STA_MAP" | grep -q . && sta_any=1
	while IFS='	' read -r ifn ssid sec; do
		[ "$ifn" = '-' ] && ifn=''
		[ "$ssid" = '-' ] && ssid=''
		[ -n "$ssid$sec" ] || continue
		cnt=0
		if [ -n "$ifn" ]; then
			if [ "$sta_any" = '1' ]; then
				# 按 hostapd 关联终端计数：clientif（get_client_interface.sh）
				# 没装 iw 时是 br-lan，对不上 phyN-apM，按它数永远是 0
				while IFS='	' read -r lm sm; do
					[ -n "$lm" ] || continue
					[ "$sm" = "$ifn" ] || continue
					mac_in_bl "$lm" && continue # 黑名单客户端不计入
					cnt=$((cnt + 1))
				done <<EOF2
$STA_MAP
EOF2
			elif [ "$CPD_RUNNING" = '1' ]; then
				while IFS='	' read -r lm st ip cif dkb ukb ss se; do
					[ -n "$lm" ] || continue
					[ "$cif" = "$ifn" ] || continue
					mac_in_bl "$lm" && continue
					cnt=$((cnt + 1))
				done <<EOF3
$CPD_IN
EOF3
			fi
		fi
		APS_JSON="$APS_JSON$sep{\"iface\":\"$(json_escape "$ifn")\",\"ssid\":\"$(json_escape "$ssid")\",\"section\":\"$(json_escape "$sec")\",\"count\":$cnt}"
		sep=','
	done <<EOF2
$AP_META
EOF2
}

ov_status_fields() { # 输出 status 的 JSON 片段（不含外层花括号）
	local mif mip=''
	mif=$(managed_iface)
	[ -n "$mif" ] && mip=$(iface_ip "$mif")
	printf '"running":%s,"enabled":%s,"engaged":%s,"busy":%s,"fupEnabled":%s,"session_scope":"%s","confErr":"%s","counts":{"online":%s,"authenticated":%s,"preauth":%s,"trusted":%s,"unauthenticated":%s,"blacklist":%s,"maxclients":%s},"managed":{"iface":"%s","ip":"%s"},"aps":%s' \
		"$CPD_RUNNING" "$CPD_ENABLED" "$CPD_ENGAGED" "$CPD_BUSY" "$(fup_enabled_val)" \
		"$(json_escape "$CPD_SCOPE")" "$(json_escape "$CPD_CONFERR")" \
		"$N_ONLINE" "$N_AUTH" "$N_PRE" "$N_TR" "$N_UN" "$N_BL" \
		"$(uci_val 'opennds.@opennds[0].maxclients' '250')" \
		"$(json_escape "$mif")" "$(json_escape "$mip")" \
		"[${APS_JSON}]"
}

ov_status() {
	ov_build
	printf '{"ok":1,%s}\n' "$(ov_status_fields)"
}

ov_clients() {
	ov_build
	printf '{"ok":1,"running":%s,"enabled":%s,"clients":[%s],"count":%s}\n' \
		"$CPD_RUNNING" "$CPD_ENABLED" "$ROWS_JSON" "$N_ROWS"
}

# 概览页首屏只发这一个请求：状态 + 客户端列表一次给全
ov_dashboard() {
	ov_build
	printf '{"ok":1,%s,"clients":[%s],"count":%s}\n' \
		"$(ov_status_fields)" "$ROWS_JSON" "$N_ROWS"
}

ov_run_state() {
	local running enabled
	enabled=$(nds_enabled)
	running=0
	nds_running && running=1
	printf '{"ok":1,"running":%s,"enabled":%s}\n' "$running" "$enabled"
}

ov_set_run() { # $1=0|1
	local want="$1"
	case "$want" in
		0 | 1) ;;
		*) out_err 'set_run 参数必须是 0 或 1' ;;
	esac
	acquire_lock
	uci set 'opennds.@opennds[0].enabled'="$want"
	if [ "$want" = '1' ]; then
		# 用户点「启动」才补：登录模式 3 且脚本路径为空（缺失），不覆盖用户自己设的值
		lo=$(uci_val 'opennds.@opennds[0].login_option_enabled' '')
		tp=$(uci_val 'opennds.@opennds[0].themespec_path' '')
		if [ "$lo" = '3' ] && [ -z "$tp" ]; then
			uci set 'opennds.@opennds[0].themespec_path'='/usr/lib/opennds/theme_zone_detect.sh'
		fi
	fi
	uci commit opennds
	if [ "$want" = '1' ]; then
		/etc/init.d/opennds start 9>&- >/dev/null 2>&1
	else
		/etc/init.d/opennds stop 9>&- >/dev/null 2>&1
	fi
	# 返回执行后的真实状态。init.d start/stop 都是 procd 异步动作、立即返回，
	# openNDS 真正可服务（ndsctl 能应答）要几秒。启动分支必须等就绪再回：
	# 之前只查一次就回，用户每次点「启动」都会先看到
	# 「操作未完全生效，请查看 openNDS 日志」的红色横幅，过一会轮询才变绿。
	local running=0 i=0
	if [ "$want" = '1' ]; then
		# 启动等就绪：总预算约 13 秒（6 次 × 单次限时 2 秒 + 间隔），
		# 正常几秒内就绪立刻返回
		while [ "$i" -lt 6 ]; do
			if nds_running && NDSCTL_TIMEOUT=2 ndsctl_run status >/dev/null 2>&1; then
				running=1
				break
			fi
			sleep 0.5 2>/dev/null || sleep 1
			i=$((i + 1))
		done
		# 限时到了但进程确实在跑：如实回「运行中」，
		# 统计/客户端列表等就绪后由页面轮询补齐
		nds_running && running=1
	else
		# 停止等进程退出（最多约 5 秒），退了就是真的停了
		while [ "$i" -lt 10 ]; do
			nds_running || { running=0; break; }
			running=1
			sleep 0.5 2>/dev/null || sleep 1
			i=$((i + 1))
		done
	fi
	printf '{"ok":1,"running":%s,"enabled":%s}\n' "$running" "$(nds_enabled)"
}

ov_restart() {
	acquire_lock
	/etc/init.d/opennds restart 9>&- >/dev/null 2>&1
	# 返回 0 只代表脚本跑完；就绪与否由前端轮询 run_state 判定（最多 20 秒）
	printf '{"ok":1}\n'
}

# 客户端行操作（免认证 / 信任 / 拉黑 / 断开…）一律只写 uci 增量：
# 不 commit、不重启 nds、不踢人 —— 真正生效等 openwrt 自带的「保存并应用」。
ov_client_action() { # $1=action $2=mac
	local action="$1" mac="$2"
	case "$action" in
		preauth | unpreauth | deauth | trust | untrust | block | unblock) ;;
		*) out_err "未知操作：$action" ;;
	esac
	mac_valid "$mac" || out_err 'MAC 格式不正确'
	local lm e
	lm=$(mac_lower "$mac")

	# preauth / trust 入口先查黑名单，命中不写任何配置
	if [ "$action" = 'preauth' ] || [ "$action" = 'trust' ]; then
		ov_load_lists
		mac_in_bl "$lm" && out_err '该客户端在黑名单中，请先解除拉黑'
	fi

	# 断开 / 拉黑是即时动作：二次确认后立刻生效，不受 openwrt「保存并应用」约束
	case "$action" in
		deauth)
			acquire_lock
			# 先踢下线，再撤掉它的免认证条目并落盘（否则重连又自动登录）
			ndsctl_mac deauth "$lm"
			ov_load_lists
			e=$(entry_for_mac "$PM_LIST" "$lm")
			if [ -n "$e" ]; then
				uci del_list 'opennds.@opennds[0].preemptivemac'="$e" 2>/dev/null
				uci commit opennds || out_err '写入配置失败'
				remove_preauth_queue "$lm"
			fi
			printf '{"ok":1,"immediate":1}\n'
			return 0
			;;
	block)
		acquire_lock
		# 黑名单 MAC 写 /etc/config/opennds 的 blockedmac（openNDS 官方 MAC 黑名单）
		local osc
		osc=$(sys_ensure_sec opennds '@opennds[0]') ||
			out_err '写入配置失败：找不到 opennds 配置节，且无法新建'
		ov_load_lists
		# ① 黑名单追加并立刻落盘；macmechanism 未设置时补成官方 'block' 语义
		mac_in_bl "$lm" || { uci add_list "opennds.$osc.blockedmac"="$lm" || out_err '写入配置失败'; }
		ensure_block_mechanism "$osc"
		# ② 摘两份名单并立刻落盘
		if uci -q show 'opennds.@opennds[0]' >/dev/null 2>&1; then
			e=$(entry_for_mac "$PM_LIST" "$lm")
			[ -n "$e" ] && uci del_list 'opennds.@opennds[0].preemptivemac'="$e" 2>/dev/null
			mac_in_tr "$lm" && uci del_list 'opennds.@opennds[0].trustedmac'="$lm" 2>/dev/null
		fi
		uci commit opennds || out_err '写入配置失败'
		# ③ 撤信任 + 清预认证队列 + 踢下线
		ndsctl_mac untrust "$lm"
		remove_preauth_queue "$lm"
		ndsctl_mac deauth "$lm"
		# ④ 重启并等就绪（fw 规则要按新名单重新加载）
		local ready=1
		service_restart || ready=0
		printf '{"ok":1,"immediate":1,"restarted":%s,"ready":%s}\n' "$SR_RESTARTED" "$ready"
		return 0
		;;
	esac

	acquire_lock

	local osc ond bsc
	osc=$(sys_ensure_sec opennds '@opennds[0]') ||
		out_err '暂存配置失败：找不到 opennds 配置节，且无法新建（请检查 /etc/config 是否可写）'
	ond="opennds.$osc"

	case "$action" in
		preauth)
			ov_load_lists
			# 已在名单内：不覆盖已有参数（§11.2 第 5 条）
			mac_in_pm "$lm" && {
				printf '{"ok":1,"staged":1}\n'
				return 0
			}
			# 6 参数写全（缺字段会继承上一条客户端的值）；MAC 一律小写
			uci_w add_list "$ond.preemptivemac=mac=$lm;sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0" ||
				sys_stage_fail
			# 没有 DHCP 租约 → 预认证拿不到 IP，应用后也不会生效
			if ! grep -qw "$lm" /tmp/dhcp.leases 2>/dev/null; then
				printf '{"ok":1,"staged":1,"warnings":["该客户端没有 DHCP 租约，预认证不会生效"]}\n'
			else
				printf '{"ok":1,"staged":1}\n'
			fi
			;;
		unpreauth)
			ov_load_lists
			e=$(entry_for_mac "$PM_LIST" "$lm")
			if [ -n "$e" ]; then
				uci_w del_list "$ond.preemptivemac"="$e" || sys_stage_fail
			fi
			printf '{"ok":1,"staged":1}\n'
			;;
		trust)
			ov_load_lists
			e=$(entry_for_mac "$PM_LIST" "$lm")
			mac_in_tr "$lm" || { uci_w add_list "$ond.trustedmac"="$lm" || sys_stage_fail; }
			# 两份名单必须互斥：顺手摘掉 preemptivemac 条目
			[ -n "$e" ] && { uci_w del_list "$ond.preemptivemac"="$e" || sys_stage_fail; }
			printf '{"ok":1,"staged":1}\n'
			;;
		untrust)
			ov_load_lists
			mac_in_tr "$lm" && { uci_w del_list "$ond.trustedmac"="$lm" || sys_stage_fail; }
			printf '{"ok":1,"staged":1}\n'
			;;
		unblock)
			ov_load_lists
			if mac_in_bl "$lm"; then
				uci_w del_list 'opennds.@opennds[0].blockedmac'="$lm" || sys_stage_fail
			fi
			printf '{"ok":1,"staged":1}\n'
			;;
	esac
}

# $1=stage|apply —— stage 只写 uci 增量（等 openwrt「保存并应用」），apply 才 commit + 重启
ov_client_edit() { # $1=stage|apply $2=mac $3…=k=v（5 项）
	local mode="$1"
	shift
	case "$mode" in
		stage | apply) ;;
		*) out_err '模式必须是 stage 或 apply' ;;
	esac
	local mac="$1"
	shift
	mac_valid "$mac" || out_err 'MAC 格式不正确'
	local lm
	lm=$(mac_lower "$mac")

	local st='' ur='' dr='' uq='' dq='' a k v
	for a in "$@"; do
		case "$a" in
			*=*) k="${a%%=*}"; v="${a#*=}" ;;
			*) out_err "参数格式必须是 k=v：$a" ;;
		esac
		int_valid "$v" || out_err "$k 必须是非负整数"
		case "$k" in
			sessiontimeout) st="$v" ;;
			uploadrate) ur="$v" ;;
			downloadrate) dr="$v" ;;
			uploadquota) uq="$v" ;;
			downloadquota) dq="$v" ;;
			*) out_err "未知参数：$k" ;;
		esac
	done
	[ -z "$st$ur$dr$uq$dq" ] && out_err '缺少限制参数'
	st="${st:-0}"; ur="${ur:-0}"; dr="${dr:-0}"; uq="${uq:-0}"; dq="${dq:-0}"

	acquire_lock

	# 先确保 opennds 配置节存在（缺失时自愈新建，失败要把 uci 原话带回去）
	local secname sec
	secname=$(sys_ensure_sec opennds '@opennds[0]') ||
		out_err '暂存配置失败：找不到 opennds 配置节，且无法新建（请检查 /etc/config 是否可写）'
	sec="opennds.$secname"

	# 已有条目里的 custom= 字段要原样保留（别在重排字段时抹掉）
	local old custom='' tail
	old=$(entry_for_mac "$(list_of 'opennds.@opennds[0].preemptivemac')" "$lm")
	if [ -n "$old" ]; then
		case "$old" in
			*';custom='*)
				tail="${old##*;custom=}"
				custom=";custom=$tail"
				;;
		esac
	fi

	local new
	new="mac=$lm;sessiontimeout=$st;uploadrate=$ur;downloadrate=$dr;uploadquota=$uq;downloadquota=$dq$custom"
	if [ -n "$old" ]; then
		uci_w del_list "$sec.preemptivemac"="$old" || sys_stage_fail
	fi
	uci_w add_list "$sec.preemptivemac"="$new" || sys_stage_fail

	# 编辑框下的「确定」只写增量：不 commit、不重启，
	# 配置真正落盘与 nds 重启一律等 openwrt 自带的「保存并应用」。
	if [ "$mode" = 'stage' ]; then
		printf '{"ok":1,"staged":1}\n'
		return 0
	fi

	uci commit opennds || out_err '写入配置失败'

	# 改已有客户端的限额参数必须重启（在线会话的参数只在启动时读入）
	local ready=1
	service_restart || ready=0
	# 无 DHCP 租约的客户端写进 preemptivemac 也不会被取用（§4）
	local warn_json=''
	if ! grep -qw "$lm" /tmp/dhcp.leases 2>/dev/null; then
		warn_json=',"warnings":["该客户端没有 DHCP 租约，预认证不会生效"]'
	fi
	printf '{"ok":1,"restarted":'"$SR_RESTARTED"',"ready":%s%s}\n' "$ready" "$warn_json"
}

# openwrt「保存并应用」：把概览页暂存的增量（客户端限额 / 免认证 / 信任 / 黑名单）
# 真正落盘，重启 nds 让在线会话按新配置重建。
ov_apply() {
	acquire_lock
	uci commit opennds || out_err '写入配置失败'
	local ready=1
	service_restart || ready=0
	# 重启后让 openNDS 按新的 preemptivemac 重建预认证队列（否则要等下次接入才生效）
	[ "$SR_RESTARTED" = '1' ] && kick_preemptive
	printf '{"ok":1,"restarted":%s,"ready":%s}\n' "$SR_RESTARTED" "$ready"
}

# ============================================================
# 门户库通用工具（《区域识别.md》§3.3/§4/§5，多页复用）
# ============================================================

CPD_ROOT="${CPD_ROOT:-/usr/lib/opennds/cpd}"
ZONE_MARKERS="${ZONE_MARKERS:-/usr/lib/opennds/zone_markers}"
ZONE_UP="${ZONE_UP:-/tmp/zone_up}"

name_bytes() { # 字节数（长度一律按字节计）
	printf '%s' "$1" | wc -c | tr -d ' '
}

# 门户文件/文件夹名：只挡真正致命的字符（/ \ | 前导. 控制字符 空名），
# 空格、中文、括号、方括号等常见字符全部放行
# $1=名称 $2=最大字节数
name_ok() {
	local n="$1"
	[ -n "$n" ] || return 1
	case "$n" in
		'.' | '..' | .* | */* | *'\'* | *'|'*) return 1 ;;
	esac
	printf '%s' "$n" | grep -q '[[:cntrl:]]' && return 1
	[ "$(name_bytes "$n")" -le "$2" ] 2>/dev/null || return 1
	return 0
}

# 区域名（SSID / 接口名）当目录名用：只挡真正致命的字符（§2.5），
# 空格、中文、括号等全部放行
zone_name_ok() {
	local z="$1"
	[ -n "$z" ] || return 1
	case "$z" in
		'.' | '..' | */* | *'\'* | *'|'*) return 1 ;;
	esac
	printf '%s' "$z" | grep -q '[[:cntrl:]]' && return 1
	return 0
}

zdir_for() { # $1=type $2=zone
	printf '%s/%s/%s' "$CPD_ROOT" "$1" "$2"
}

# 读 uci list：逐条输出（值按 ' 引号切分，SSID 含空格也安全）
cache_pairs() { # $1=键名（zone_detect.main.wireless）
	uci show "$1" 2>/dev/null |
		sed -n 's/^[^=]*=//p' |
		awk -F"'" '{
			for (i = 2; i <= NF; i += 2) if ($i != "") print $i
		}'
}

# ============================================================
# 门户条目：保留上传时的原名，不改名、不做文件名映射
# 「某个区域用哪个门户」只记在 uci（zone_detect.main.wireless / wired），
# 「用类型默认门户」记在 zone_markers；分发脚本按这两处直接找文件。
# ============================================================

# 列目录里的门户条目 → "name<TAB>kind" 行
# 保留用户上传时的原名（*.sh 文件，或含 theme.sh 的文件夹）；default 为兜底项不列
z_portal_scan() { # $1=目录
	local d="$1" f b
	[ -d "$d" ] || return 0
	for f in "$d"/*; do
		[ -e "$f" ] || continue
		b="${f##*/}"
		case "$b" in
			.* | default) continue ;;
		esac
		if [ -f "$f" ]; then
			case "$b" in
				*.sh) printf '%s\tfile\n' "$b" ;;
			esac
		elif [ -d "$f" ] && [ -f "$f/theme.sh" ]; then
			printf '%s\tdir\n' "$b"
		fi
	done
	return 0
}

# ============================================================
# zone_markers：默认门户标记（§2.4）
# 行格式 wireless|<SSID>|<接口名>|<管理接口> / wired|<接口名>|-|<管理接口>
# 匹配只用前两段；写入用「先删同 type|zone 旧行、再追加」
# ============================================================

marker_del() { # $1=type $2=zone
	[ -f "$ZONE_MARKERS" ] || return 0
	awk -F'|' -v t="$1" -v z="$2" '!($1 == t && $2 == z)' \
		"$ZONE_MARKERS" >"$ZONE_MARKERS.tmp" 2>/dev/null &&
		mv "$ZONE_MARKERS.tmp" "$ZONE_MARKERS"
	return 0
}

marker_add() { # $1=type $2=zone $3=诊断接口名 $4=管理接口
	marker_del "$1" "$2"
	printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$ZONE_MARKERS" 2>/dev/null
	return 0
}

marker_diag_if() { # $1=type $2=zone → 第一个匹配 SSID 的 AP 运行时接口名或 '-'
	local secids sec ssid dev idx rif
	if [ "$1" = 'wireless' ]; then
		secids=$(uci show wireless 2>/dev/null |
			awk -F'[.=]' '/^wireless\..+=wifi-iface$/ {print $2}')
		for sec in $secids; do
			ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
			[ "$ssid" = "$2" ] || continue
			dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
			idx=$(ap_section_index "$sec" "$dev")
			rif=$(ap_runtime_if "$dev" "$ssid" "$idx")
			[ -n "$rif" ] && {
				printf '%s' "$rif"
				return 0
			}
		done
	fi
	printf '-'
}

# 判断目录里是否已有同名门户（名字含不含 .sh 都算命中）；rc=0 存在
z_portal_exists() { # $1=目录 $2=名字
	local d="$1" n="$2" b
	case "$n" in
		'' | */* | .*) return 1 ;;
	esac
	[ -f "$d/$n" ] && return 0
	b="${n%.sh}"
	[ -f "$d/$b.sh" ] && return 0
	[ -f "$d/$b/theme.sh" ] && return 0
	return 1
}

# ============================================================
# 页面：zone（《区域识别.md》§4）
# ============================================================

z_saved_of() { # $1=list(wireless|wired) $2=区域名 → 已保存的门户名或空
	local pair ss store
	while IFS= read -r pair; do
		[ -n "$pair" ] || continue
		case "$pair" in
			*'|'*) ;;
			*) continue ;;
		esac
		ss="${pair%%|*}"
		store="${pair#*|}"
		case "$store" in
			*'|'*) continue ;;
		esac
		[ "$ss" = "$2" ] && {
			printf '%s' "$store"
			return 0
		}
	done <<EOF2
$(cache_pairs "zone_detect.main.$1")
EOF2
	return 1
}

# 同 z_saved_of，但区分「缓存里没有该区域」（输出 null）与「保存为默认」（输出 ""）
z_saved_json() { # $1=list(wireless|wired) $2=区域名 → 门户名 JSON（含空串）或 null
	local v
	v=$(z_saved_of "$1" "$2")
	if [ $? -eq 0 ]; then
		printf '"%s"' "$(json_escape "$v")"
	else
		printf 'null'
	fi
}

z_is_current_ssid() { # $1=ssid → 是否存在 mode=ap 的无线 section
	local secids sec ssid
	secids=$(uci show wireless 2>/dev/null |
		awk -F'[.=]' '/^wireless\..+=wifi-iface$/ {print $2}')
	for sec in $secids; do
		[ "$(uci -q get "wireless.$sec.mode" 2>/dev/null)" = 'ap' ] || continue
		ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
		[ "$ssid" = "$1" ] && return 0
	done
	return 1
}

z_unmatched_scan() { # → "type<TAB>name" 行
	local out="" type d name
	for type in wireless wired; do
		[ -d "$CPD_ROOT/$type" ] || continue
		for d in "$CPD_ROOT/$type"/*; do
			[ -d "$d" ] || continue # glob 不命中时字面量不是目录
			name="${d##*/}"
			case "$name" in
				.*) continue ;;
			esac
			if [ "$type" = 'wireless' ]; then
				z_is_current_ssid "$name" && continue
			else
				[ "$name" = "$Z_MGMT" ] && continue
			fi
			out="$out$type	$name
"
		done
	done
	printf '%s' "$out"
}

z_status() {
	local lo engaged enabled busy scope mif mip wsv wcur sv cur ws=''
	lo=$(uci_get 'opennds.@opennds[0].login_option_enabled')
	engaged=$(nds_engaged)
	enabled=$(nds_enabled)
	busy=$(busy_probe)
	scope=$(uci_val 'zone_detect.main.scope' '')
	# 无线运行时视图只取一次，下面逐个 section 判断用（比每个接口各调一次 ubus 省）
	CPD_WS=''
	if command -v ubus >/dev/null 2>&1; then
		CPD_WS=$(ubus_call call network.wireless status)
	fi
	ws="$CPD_WS"
	mif=$(managed_iface)
	[ -n "$mif" ] && {
		mip=$(iface_ip "$mif")
		wsv=$(z_saved_json wired "$mif")
		# 门户保持原名，uci 里记的那个名字就是生效门户
		wcur=$(z_saved_of wired "$mif" 2>/dev/null || true)
	}
	[ -n "$wsv" ] || wsv=null

	# 无线卡片：全部 mode=ap section（禁用的也要，可预配置）
	local secids sec dev mode dis ssid disf dup cards='' sep='' n=0 allss rad dis_radio
	secids=$(uci show wireless 2>/dev/null |
		awk -F'[.=]' '/^wireless\..+=wifi-iface$/ {print $2}')
	allss=''
	for sec in $secids; do
		ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
		[ -n "$ssid" ] && allss="$allss$ssid
"
	done
	for sec in $secids; do
		mode=$(uci -q get "wireless.$sec.mode" 2>/dev/null)
		[ "$mode" = 'ap' ] || continue
		ssid=$(uci -q get "wireless.$sec.ssid" 2>/dev/null)
		dev=$(uci -q get "wireless.$sec.device" 2>/dev/null)
		dis=$(uci -q get "wireless.$sec.disabled" 2>/dev/null)
		# 启用判定取三路信号的并集（任一为「关」就按未启用显示）：
		# ① 接口自身 disabled —— 不能只认 '1'，on/true/yes 同样是关
		# ② 所属 radio 被关（wifi_radio_off：uci disabled 优先，运行时 up 兜底）
		# ③ ubus 运行时视图里该 section 的 config.disabled=true
		#    （有的固件/操作路径只改运行时视图而不落 uci，漏了这条就会
		#     出现"已经关掉的 Wi-Fi 卡片仍显示已启用"）
		disf=0
		case "$dis" in 1 | on | true | yes) disf=1 ;; esac
		dis_radio=0
		if [ -n "$dev" ] && wifi_radio_off "$dev"; then
			dis_radio=1
			disf=1
		fi
		if [ "$disf" = '0' ] && [ -n "$ws" ] && [ -n "$dev" ]; then
			case "$(printf '%s' "$ws" |
				jsonfilter -e "@.$dev.interfaces[@.section=\"$sec\"].config.disabled" 2>/dev/null)" in
				true | 1) disf=1 ;;
			esac
		fi
		# ④ 运行时兜底（配置上全启用、现实里没在跑的场景）：
		#    radio 已 up 却找不到这个 section 的真实接口 → 没在工作，按未启用显示；
		#    radio 的 up=false 时 interfaces 列表为空，这里同样命中。
		#    uci 与 ubus 的 config 都没写 disabled、但接口没建立（radio 被关、
		#    DFS 信道没起 beacon、netifd 没拉起）时，漏了这条就会显示"已启用"。
		#    只认 up 值明确的 radio：键缺失（ubus 视图异常）时不动，避免误标。
		if [ "$disf" = '0' ] && [ -n "$ws" ] && [ -n "$dev" ]; then
			up=$(printf '%s' "$ws" | jsonfilter -q -e "@.$dev.up" 2>/dev/null)
			case "$up" in
				0 | false | 1 | true)
					ifn=$(printf '%s' "$ws" |
						jsonfilter -q -e "@.$dev.interfaces[@.section=\"$sec\"].ifname" 2>/dev/null | head -n1)
					[ -n "$ifn" ] || disf=1
					;;
			esac
		fi
		# 运行时接口名（iw dev / /sys/class/net 的 phyX-apX，openNDS 官方识别用的就是它）
		rtif=''
		if [ "$disf" = '0' ]; then
			idx=$(ap_section_index "$sec" "$dev")
			rtif=$(ap_runtime_if "$dev" "$ssid" "$idx")
		fi
		dup=0
		if [ -n "$ssid" ]; then
			dup=$(printf '%s\n' "$allss" | grep -Fx "$ssid" | wc -l | tr -d ' ')
			[ "$dup" -ge 2 ] 2>/dev/null && dup=1 || dup=0
		fi
		sv=$(z_saved_json wireless "$ssid")
		cur=$(z_saved_of wireless "$ssid" 2>/dev/null || true)
		cards="$cards$sep{\"ssid\":\"$(json_escape "$ssid")\",\"section\":\"$(json_escape "$sec")\",\"device\":\"$(json_escape "$dev")\",\"disabled\":$disf,\"radioDisabled\":$dis_radio,\"runtime\":\"$(json_escape "$rtif")\",\"dup\":$dup,\"saved\":$sv,\"current\":\"$(json_escape "$cur")\"}"
		sep=','
		n=$((n + 1))
	done

	Z_MGMT="$mif"
	local un
	un=$(z_unmatched_scan | grep -c .)
	un="${un:-0}"

	printf '{"ok":1,"enabled":%s,"busy":%s,"engaged":%s,"loginOptionEnabled":"%s","scope":"%s","wired":{"iface":"%s","ip":"%s","saved":%s,"current":"%s"},"wireless":[%s],"unmatched":%s}\n' \
		"$enabled" "$busy" "$engaged" "$(json_escape "$lo")" \
		"$(json_escape "$scope")" \
		"$(json_escape "$mif")" "$(json_escape "$mip")" \
		"$wsv" "$(json_escape "$wcur")" \
		"$cards" "$un"
}

z_uploaded() { # $1=type $2=zone → 该区域门户目录里的全部门户（原名就是唯一标识）
	local type="$1" zone="$2"
	case "$type" in
		wireless | wired) ;;
		*) out_err 'type 必须是 wireless 或 wired' ;;
	esac
	zone_name_ok "$zone" ||
		out_err '该区域名含非法路径字符，无法建立门户目录，请改用默认门户'
	local zdir
	zdir=$(zdir_for "$type" "$zone")
	[ -d "$zdir" ] || {
		printf '{"ok":1,"items":[],"count":0}\n'
		return 0
	}
	local name kind items='' sep='' n=0
	while IFS='	' read -r name kind; do
		[ -n "$name" ] || continue
		items="$items$sep{\"name\":\"$(json_escape "$name")\",\"kind\":\"$kind\"}"
		sep=','
		n=$((n + 1))
	done <<EOF2
$(z_portal_scan "$zdir")
EOF2
	printf '{"ok":1,"items":[%s],"count":%s}\n' "$items" "$n"
}

z_upload_begin() { # $1=id
	local id="$1"
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	rm -rf "$ZONE_UP/$id" 2>/dev/null
	mkdir -p "$ZONE_UP/$id" 2>/dev/null || out_err '无法创建上传临时目录'
	printf '{"ok":1}\n'
}

z_upload_mkdir() { # $1=type $2=zone $3=id $4=文件夹原名 [$5=相对子路径（建嵌套目录用）]
	local type="$1" zone="$2" id="$3" name="$4" sub="${5:-}"
	case "$type" in
		wireless | wired) ;;
		*) out_err 'type 必须是 wireless 或 wired' ;;
	esac
	zone_name_ok "$zone" ||
		out_err '该区域名含非法路径字符，无法建立门户目录，请改用默认门户'
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	[ "$(name_bytes "$name")" -le 31 ] 2>/dev/null ||
		out_err '文件名过长（最多 31 个字符）'
	name_ok "$name" 31 || out_err '文件名含非法字符，无法上传'
	# 子路径逐段校验（名称规则同 name_ok），拒绝绝对路径 / .. / 空段以外的花招
	if [ -n "$sub" ]; then
		case "$sub" in
			/* | *//*) out_err '子路径非法' ;;
		esac
		local seg oldifs="$IFS"
		IFS='/'
		for seg in $sub; do
			[ -n "$seg" ] || continue
			name_ok "$seg" 31 || out_err '子路径含非法名称'
		done
		IFS="$oldifs"
	fi
	[ -d "$ZONE_UP/$id" ] || out_err '上传会话不存在或已过期，请重新上传'
	acquire_lock
	mkdir -p "$ZONE_UP/$id/$name${sub:+/$sub}" 2>/dev/null || out_err '无法创建上传临时文件夹'
	mkdir -p "$(zdir_for "$type" "$zone")" 2>/dev/null
	printf '{"ok":1}\n'
}

z_upload_store() { # $1=type $2=zone $3=id $4=kind $5=原名（原名即落盘名，不改名）
	local type="$1" zone="$2" id="$3" kind="$4" name="$5"
	case "$type" in
		wireless | wired) ;;
		*) out_err 'type 必须是 wireless 或 wired' ;;
	esac
	zone_name_ok "$zone" ||
		out_err '该区域名含非法路径字符，无法建立门户目录，请改用默认门户'
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	case "$kind" in
		file | dir) ;;
		*) out_err 'kind 必须是 file 或 dir' ;;
	esac
	[ "$(name_bytes "$name")" -le 31 ] 2>/dev/null ||
		out_err '文件名过长（最多 31 个字符）'
	name_ok "$name" 31 || out_err '文件名含非法字符，无法上传'
	local tmp="$ZONE_UP/$id/$name"
	if [ "$kind" = 'file' ]; then
		case "$name" in
			*.sh) ;;
			*) out_err '只接受 .sh 门户脚本，或包含 theme.sh 的文件夹' ;;
		esac
		[ -f "$tmp" ] || out_err '上传内容不存在，请重新上传'
		file_is_text "$tmp" || out_err '只支持文本脚本，二进制文件无法上传'
	else
		[ -d "$tmp" ] || out_err '上传内容不存在，请重新上传'
		[ -f "$tmp/theme.sh" ] || out_err '只接受 .sh 门户脚本，或包含 theme.sh 的文件夹'
	fi
	acquire_lock
	local zdir
	zdir=$(zdir_for "$type" "$zone")
	mkdir -p "$zdir" 2>/dev/null || out_err '无法创建门户目录'
	# 同名视为「上传新版本」，直接覆盖：不改名、不建映射
	if [ "$kind" = 'file' ]; then
		cp "$tmp" "$zdir/$name.tmp" 2>/dev/null || out_err '写入门户文件失败'
		chmod 755 "$zdir/$name.tmp" 2>/dev/null
		mv "$zdir/$name.tmp" "$zdir/$name" 2>/dev/null || {
			rm -f "$zdir/$name.tmp" 2>/dev/null
			out_err '替换门户文件失败'
		}
	else
		rm -rf "$zdir/$name" 2>/dev/null
		mv "$tmp" "$zdir/$name" 2>/dev/null || out_err '门户文件夹入库失败'
	fi
	case "$ZONE_UP/$id" in
		"$ZONE_UP"/*) rm -rf "$ZONE_UP/$id" 2>/dev/null ;;
	esac
	printf '{"ok":1,"name":"%s"}\n' "$(json_escape "$name")"
}

z_upload_delete() { # $1=type $2=zone $3=门户名（原名）
	local type="$1" zone="$2" store="$3"
	case "$type" in
		wireless | wired) ;;
		*) out_err 'type 必须是 wireless 或 wired' ;;
	esac
	zone_name_ok "$zone" || out_err '该区域名含非法路径字符'
	[ "$(name_bytes "$store")" -le 31 ] 2>/dev/null &&
		name_ok "$store" 31 || out_err '门户名非法'
	acquire_lock
	local zdir cur
	zdir=$(zdir_for "$type" "$zone")
	cur=$(z_saved_of "$type" "$zone" 2>/dev/null || true)
	# 删掉的正好是这个区域正在用的脚本 → 该区域退回「默认」，
	# 而不是拒绝删除（页面上没有第二个下拉可选，拒绝就永远删不掉）
	if [ -n "$cur" ] && [ "$cur" = "$store" ]; then
		local real p ss st pairs
		LAST_UCI_ERR=''
		real=$(sys_ensure_sec zone_detect main) || real='main'
		pairs=$(cache_pairs "zone_detect.main.$type")
		uci_w -q delete "zone_detect.$real.$type" || :
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			case "$p" in
				*'|'*) ;;
				*) continue ;;
			esac
			ss="${p%%|*}"
			st="${p#*|}"
			[ "$ss" = "$zone" ] && st=''
			uci_w add_list "zone_detect.$real.$type"="$ss|$st" || sys_stage_fail
		done <<EOF4
$pairs
EOF4
		uci_w commit zone_detect || sys_stage_fail
	fi
	# 文件已被别处删掉时按成功处理（§3.4）
	[ -e "$zdir/$store" ] && rm -rf "$zdir/$store" 2>/dev/null
	printf '{"ok":1,"unset":%s}\n' "$([ "$cur" = "$store" ] && printf 1 || printf 0)"
}

z_save_cache() { # $1=global|wireless|wired $2…=对（SSID|门户名）
	local list="$1"
	shift
	case "$list" in
		global)
			# 默认模式面板的保存：只写 scope（§3.1）
			uci set 'zone_detect.main.scope'=global
			uci commit zone_detect
			printf '{"ok":1}\n'
			;;
		wireless | wired)
			local pair ss store nseg skips='' ssep='' good=''
			for pair in "$@"; do
				nseg=$(printf '%s' "$pair" | awk -F'|' '{print NF}')
				ss="${pair%%|*}"
				store="${pair#*|}"
				if [ "$nseg" -ne 2 ] || [ -z "$ss" ]; then
					skips="$skips$ssep$pair"
					ssep='、'
					continue
				fi
				# 含非法字符的区域剔除，其余照常保存（§2.5）
				if ! zone_name_ok "$ss"; then
					skips="$skips$ssep区域「$ss」含非法字符，未写入配置"
					ssep='、'
					continue
				fi
				good="$good
$pair"
			done
			# 只重建本次要写的那个 list，另一个原样保留（§4）
			uci delete "zone_detect.main.$list" 2>/dev/null
			# 对参数整体一条一条进（SSID 含空格，不能按空白切分）
			while IFS= read -r pair; do
				[ -n "$pair" ] || continue
				uci add_list "zone_detect.main.$list"="$pair"
			done <<EOF3
$good
EOF3
			uci set 'zone_detect.main.scope'=zone
			uci commit zone_detect
			if [ -n "$skips" ]; then
				printf '{"ok":1,"warnings":["%s"]}\n' "$(json_escape "$skips")"
			else
				printf '{"ok":1}\n'
			fi
			;;
		*) out_err 'list 必须是 global、wireless 或 wired' ;;
	esac
}

z_apply() { # $1=panel(global|wireless|wired)，confirm_enable 已由分发器摘出
	local panel="$1"
	case "$panel" in
		global | wireless | wired) ;;
		*) out_err 'panel 必须是 global、wireless 或 wired' ;;
	esac
	guard_enable || return 0
	acquire_lock

	if [ "$panel" = 'global' ]; then
		uci set 'opennds.@opennds[0].login_option_enabled'=1
		uci set 'zone_detect.main.scope'=global
		if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
			uci set 'opennds.@opennds[0].enabled'=1
			EN_BY_APPLY=1
		fi
		uci commit opennds
		uci commit zone_detect
		local ready=1
		service_restart || ready=0
		printf '{"ok":1,"ready":%s,"restarted":'"$SR_RESTARTED"',"enabled_by_apply":%s}\n' "$ready" "$EN_BY_APPLY"
		return 0
	fi

	# ---- wireless / wired：只认缓存里已保存的选择（§3.5）----
	local pairs
	pairs=$(cache_pairs "zone_detect.main.$panel")
	if [ -z "$pairs" ]; then
		if [ "$panel" = 'wireless' ]; then
			out_err '请先保存无线区域配置，再点击应用'
		else
			out_err '请先保存有线区域配置，再点击应用'
		fi
	fi

	local mgmt
	mgmt=$(managed_iface)
	[ -n "$mgmt" ] || mgmt='-'

	# ---- 第一遍：先整体校验，有问题就一条都不动 ----
	local pair ss store ZP_LINES='' ZP_SS=''
	while IFS= read -r pair; do
		[ -n "$pair" ] || continue
		case "$pair" in
			*'|'*) ;;
			*) out_err '已保存的配置解析失败，请重新保存' ;;
		esac
		ss="${pair%%|*}"
		store="${pair#*|}"
		case "$store" in
			*'|'*) out_err '已保存的配置解析失败，请重新保存' ;;
		esac
		[ -n "$ss" ] || out_err '已保存的配置解析失败，请重新保存'
		zone_name_ok "$ss" ||
			out_err '该区域名含非法路径字符，无法建立门户目录，请改用默认门户'
		# 同一 SSID 只认第一条（缓存按 SSID 去重写入，防御性）
		printf '%s\n' "$ZP_SS" | grep -Fxq "$ss" && continue
		ZP_SS="$ZP_SS$ss
"
		if [ -n "$store" ]; then
			name_ok "$store" 31 || out_err '已保存的配置解析失败，请重新保存'
			# 门户文件原地不动，选它只是记进 markers/配置；文件没了就拦下
			if ! z_portal_exists "$(zdir_for "$panel" "$ss")" "$store"; then
				if [ "$panel" = 'wireless' ]; then
					out_err '已保存的配置引用了已删除的门户，请重新保存后再应用'
				else
					out_err '已保存的有线区域配置引用了已删除的门户，请重新保存后再应用'
				fi
			fi
		fi
		ZP_LINES="$ZP_LINES$ss	$store
"
	done <<EOF2
$pairs
EOF2

	# ---- 第二遍：逐区域落「默认门户」标记（门户文件无需搬动改名）----
	local W='' wsep=''
	while IFS='	' read -r ss store; do
		[ -n "$ss" ] || continue
		if [ -z "$store" ]; then
			marker_add "$panel" "$ss" "$(marker_diag_if "$panel" "$ss")" "$mgmt"
		else
			marker_del "$panel" "$ss"
		fi
	done <<EOF2
$ZP_LINES
EOF2

	# ---- 写 openNDS 配置：区域面板固定写 3 + themespec_path（§3.5 第 5 步）----
	uci set 'opennds.@opennds[0].login_option_enabled'=3
	uci set 'opennds.@opennds[0].themespec_path'='/usr/lib/opennds/theme_zone_detect.sh'
	if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
		uci set 'opennds.@opennds[0].enabled'=1
		EN_BY_APPLY=1
	fi
	uci commit opennds
	local ready=1
	service_restart || ready=0
	local wjson='[]'
	[ -n "$W" ] && wjson="[\"$(json_escape "$W")\"]"
	printf '{"ok":1,"ready":%s,"restarted":'"$SR_RESTARTED"',"warnings":%s,"enabled_by_apply":%s}\n' "$ready" "$wjson" "$EN_BY_APPLY"
}

z_unmatched_list() {
	Z_MGMT=$(managed_iface)
	local lines out='' sep='' n=0 type name
	lines=$(z_unmatched_scan)
	while IFS='	' read -r type name; do
		[ -n "$type" ] || continue
		out="$out$sep{\"type\":\"$type\",\"name\":\"$(json_escape "$name")\"}"
		sep=','
		n=$((n + 1))
	done <<EOF2
$lines
EOF2
	printf '{"ok":1,"items":[%s],"count":%s}\n' "$out" "$n"
}

z_unmatched_delete() { # $1=type $2=名称
	local type="$1" name="$2"
	case "$type" in
		wireless | wired) ;;
		*) out_err 'type 必须是 wireless 或 wired' ;;
	esac
	zone_name_ok "$name" || out_err '该名称含非法路径字符'
	acquire_lock
	# 目录已被别处删掉时按成功处理
	[ -d "$CPD_ROOT/$type/$name" ] && rm -rf "$CPD_ROOT/$type/$name" 2>/dev/null
	printf '{"ok":1}\n'
}

# ============================================================
# 页面：session（《客户端会话管理.md》§3/§5）
# ============================================================

# 从快照串 k=v;k=v 里取一个键的值
snap_field() { # $1=快照串 $2=键名
	local want="$2" p k v
	local oldifs="$IFS"
	IFS=';'
	set -- $1
	IFS="$oldifs"
	for p in "$@"; do
		case "$p" in
			*=*)
				k="${p%%=*}"
				v="${p#*=}"
				[ "$k" = "$want" ] && {
					printf '%s' "$v"
					return 0
				}
				;;
		esac
	done
	return 1
}

# 校验五项（$1=scope $2..$5=四个超时值，空=沿用默认）
se_validate() {
	local scope="$1" st="$2" ait="$3" pit="$4" ci="$5"
	case "$scope" in
		default | override) ;;
		*) out_err '配置范围必须是 default 或 override' ;;
	esac
	case "$st" in
		'') ;;
		*) int_valid "$st" || out_err '会话超时必须是非负整数（0=永不超时）' ;;
	esac
	case "$ait" in
		'') ;;
		*) int_valid "$ait" || out_err '空闲超时必须是非负整数' ;;
	esac
	case "$pit" in
		'') ;;
		*) int_valid "$pit" || out_err '未认证超时必须是非负整数' ;;
	esac
	case "$ci" in
		'') ;;
		*) { int_valid "$ci" && [ "$ci" -ge 1 ]; } 2>/dev/null ||
			out_err '检查间隔必须是不小于 1 的整数' ;;
	esac
}

se_get() {
	local snap scope st ait pit ci sst sait spit sci pending=0 enabled
	snap=$(uci_get 'zone_detect.main.session_snapshot')
	scope=$(uci_val 'zone_detect.main.session_scope' 'default')
	enabled=$(nds_enabled)
	st=$(uci_get 'opennds.@opennds[0].sessiontimeout')
	ait=$(uci_get 'opennds.@opennds[0].authidletimeout')
	pit=$(uci_get 'opennds.@opennds[0].preauthidletimeout')
	ci=$(uci_get 'opennds.@opennds[0].checkinterval')
	local saved_json='{}'
	if [ -n "$snap" ]; then
		sst=$(snap_field "$snap" sessiontimeout)
		sait=$(snap_field "$snap" authidletimeout)
		spit=$(snap_field "$snap" preauthidletimeout)
		sci=$(snap_field "$snap" checkinterval)
		sscope=$(snap_field "$snap" scope)
		# pending：快照五项与当前 uci 实际值不完全相同（§4）
		# 空快照值 = 不写键/保持原样，对 uci 无要求，跳过比较
		if { [ -n "$sst" ] && [ "$sst" != "$st" ]; } ||
			{ [ -n "$sait" ] && [ "$sait" != "$ait" ]; } ||
			{ [ -n "$spit" ] && [ "$spit" != "$pit" ]; } ||
			{ [ -n "$sci" ] && [ "$sci" != "$ci" ]; } ||
			{ [ -n "$sscope" ] && [ "$sscope" != "$scope" ]; }; then
			pending=1
		fi
		saved_json="{\"sessiontimeout\":\"$(json_escape "$sst")\",\"authidletimeout\":\"$(json_escape "$sait")\",\"preauthidletimeout\":\"$(json_escape "$spit")\",\"checkinterval\":\"$(json_escape "$sci")\",\"scope\":\"$(json_escape "$sscope")\"}"
	fi
	printf '{"ok":1,"values":{"sessiontimeout":"%s","authidletimeout":"%s","preauthidletimeout":"%s","checkinterval":"%s"},"scope":"%s","pending":%s,"saved":%s,"enabled":%s}\n' \
		"$(json_escape "$st")" "$(json_escape "$ait")" \
		"$(json_escape "$pit")" "$(json_escape "$ci")" \
		"$(json_escape "$scope")" "$pending" "$saved_json" "$enabled"
}

se_save() { # $1=scope $2..$5=四个值（空=沿用默认）
	se_validate "$@"
	local scope="$1" st="$2" ait="$3" pit="$4" ci="$5"
	# 只写 session_snapshot 这一个键（不写 session_scope，§3）
	uci set 'zone_detect.main.session_snapshot'="sessiontimeout=$st;authidletimeout=$ait;preauthidletimeout=$pit;checkinterval=$ci;scope=$scope"
	uci commit zone_detect
	printf '{"ok":1}\n'
}

# 覆盖模式：把条目改成完整 6 参数、sessiontimeout=0；
# 其它参数原样保留、custom= 原样尾随（§3）
pm_override_entry() { # $1=条目 → 新条目
	local e="$1" p k v mac='' ur=0 dr=0 uq=0 dq=0 custom=''
	local oldifs="$IFS"
	IFS=';'
	set -- $e
	IFS="$oldifs"
	for p in "$@"; do
		case "$p" in
			*=*)
				k="${p%%=*}"
				v="${p#*=}"
				;;
			*) continue ;;
		esac
		case "$k" in
			mac) mac="$v" ;;
			uploadrate) [ -n "$v" ] && ur="$v" ;;
			downloadrate) [ -n "$v" ] && dr="$v" ;;
			uploadquota) [ -n "$v" ] && uq="$v" ;;
			downloadquota) [ -n "$v" ] && dq="$v" ;;
			custom) custom="$p" ;;  # 整段原样保留在末尾
		esac
	done
	[ -n "$mac" ] || return 1
	printf 'mac=%s;sessiontimeout=0;uploadrate=%s;downloadrate=%s;uploadquota=%s;downloadquota=%s' \
		"$mac" "$ur" "$dr" "$uq" "$dq"
	[ -n "$custom" ] && printf ';%s' "$custom"
	printf '\n'
}

se_apply() {
	guard_enable || return 0
	local snap scope st ait pit ci
	snap=$(uci_get 'zone_detect.main.session_snapshot')
	[ -n "$snap" ] || out_err '存在未保存的修改，请先保存后再应用'
	scope=$(snap_field "$snap" scope)
	st=$(snap_field "$snap" sessiontimeout)
	ait=$(snap_field "$snap" authidletimeout)
	pit=$(snap_field "$snap" preauthidletimeout)
	ci=$(snap_field "$snap" checkinterval)
	se_validate "$scope" "$st" "$ait" "$pit" "$ci"
	acquire_lock
	# 空值 = 不写这个键，保持 uci 原样（绝不能写空串，§2）
	case "$st" in
		'') ;;
		*) uci set 'opennds.@opennds[0].sessiontimeout'="$st" ;;
	esac
	case "$ait" in
		'') ;;
		*) uci set 'opennds.@opennds[0].authidletimeout'="$ait" ;;
	esac
	case "$pit" in
		'') ;;
		*) uci set 'opennds.@opennds[0].preauthidletimeout'="$pit" ;;
	esac
	case "$ci" in
		'') ;;
		*) uci set 'opennds.@opennds[0].checkinterval'="$ci" ;;
	esac
	# 覆盖模式：清各条目的 sessiontimeout（改 0 不是删参数，§3）
	if [ "$scope" = 'override' ]; then
		local e new tmpf orig cnt
		orig=$(list_of 'opennds.@opennds[0].preemptivemac')
		tmpf=$(mktemp /tmp/nds-pm-XXXXXX 2>/dev/null) || tmpf="/tmp/nds-pm.$$"
		: >"$tmpf"
		for e in $orig; do
			if new=$(pm_override_entry "$e"); then
				printf '%s\n' "$new" >>"$tmpf"
			else
				printf '%s\n' "$e" >>"$tmpf" # 无 mac= 的畸形条目原样保留
			fi
		done
		# 安全阀：原名单非空而重建结果为空 = 读取异常，宁可不改也不能清空配置
		cnt=$(grep -c . "$tmpf" 2>/dev/null)
		[ -n "$orig" ] && [ "${cnt:-0}" -eq 0 ] && {
			rm -f "$tmpf"
			out_err '读取授权客户端列表失败，已取消写入（不会清空现有配置）'
		}
		# 整份重建名单：list 必须走 delete + add_list（uci set 会把多词值写成 option）
		uci -q delete 'opennds.@opennds[0].preemptivemac' 2>/dev/null
		while IFS= read -r e; do
			[ -n "$e" ] || continue
			uci add_list 'opennds.@opennds[0].preemptivemac'="$e"
		done <<EOF3
$(cat "$tmpf")
EOF3
		rm -f "$tmpf"
	fi
	uci set 'zone_detect.main.session_scope'="$scope"
	if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
		uci set 'opennds.@opennds[0].enabled'=1
		EN_BY_APPLY=1
	fi
	uci commit opennds
	uci commit zone_detect
	if service_restart; then
		printf '{"ok":1,"ready":1,"restarted":'"$SR_RESTARTED"',"enabled_by_apply":%s}\n' "$EN_BY_APPLY"
	else
		# 不回滚（§4）
		printf '{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}\n'
	fi
}

# ============================================================
# 页面：exempt（《客户端豁免管理.md》§5）
# ============================================================

# 大小写无关地找 preemptivemac 条目（exempt 专用；概览页 entry_for_mac 只配小写入库）
ex_entry_for_mac() { # $1=list 值 $2=小写 mac
	local e m
	for e in $1; do
		case "$e" in
			mac=*)
				m="${e#mac=}"
				m="${m%%;*}"
				[ "$(mac_lower "$m")" = "$2" ] && {
					printf '%s' "$e"
					return 0
				}
				;;
		esac
	done
	return 1
}

# 逗号分隔 MAC 串 → 存入指定变量（换行分隔小写 MAC）。
# 直接调用（不经命令替换），非法 MAC 的 out_err 才能真正退出脚本；
# MAC 定长，子串去重安全
ex_parse_macs() { # $1=串 $2=输出变量名
	# 先把输出变量名存进局部变量：下面的 set -- $1 会覆盖位置参数
	local var="$2" t lm out=''
	local oldifs="$IFS"
	IFS=','
	set -- $1
	IFS="$oldifs"
	for t in "$@"; do
		[ -n "$t" ] || continue
		mac_valid "$t" || out_err "非法MAC: $t"
		lm=$(mac_lower "$t")
		case "$out" in
			*"$lm"*) ;;
			*) out="$out$lm
" ;;
		esac
	done
	eval "$var=\$out"
}

# 接口 → 网络区域（共用反查逻辑：iw 直读 → uci 序号映射；非无线 → 管理接口）
ex_zone_for() { # $1=运行时接口名（可空）
	local ifn="$1" s mif
	[ -n "$ifn" ] || ifn=$(managed_iface)
	[ -n "$ifn" ] || return 1
	if iw dev "$ifn" info >/dev/null 2>&1; then
		s=$(ssid_for_if "$ifn") && {
			printf '%s' "$s"
			return 0
		}
		return 1
	fi
	mif=$(managed_iface)
	[ "$ifn" = "$mif" ] && printf '%s' "$ifn"
	return 0
}

# 豁免页公共数据：名单/开关一次取齐 + 租约表预读（每个客户端再 fork
# 一遍 uci/awk 就是豁免页"切进来要等 2~3 秒"的元凶）
ex_common() {
	local t p b
	EX_ENABLED=$(nds_enabled)
	EX_PE=$(uci_val 'opennds.@opennds[0].allow_preemptive_authentication' '1')
	CPD_LEASE_MAP=$(ov_lease_map)
	local tjson='' sep=''
	for t in $(list_of 'opennds.@opennds[0].trustedmac'); do
		[ -n "$t" ] || continue
		tjson="$tjson$sep\"$(json_escape "$t")\""
		sep=','
	done
	local pjson=''
	sep=''
	for p in $(list_of 'opennds.@opennds[0].preemptivemac'); do
		[ -n "$p" ] || continue
		pjson="$pjson$sep\"$(json_escape "$p")\""
		sep=','
	done
	# 黑名单一起返回：前端在应用前做"一个客户端只属于一个名单"的校验
	local bjson='' bsep=''
	for b in $(list_of 'opennds.@opennds[0].blockedmac'); do
		mac_valid "$b" || continue
		bjson="$bjson$bsep\"$(json_escape "$(mac_lower "$b")")\""
		bsep=','
	done
	EX_TJSON=$tjson
	EX_PJSON=$pjson
	EX_BJSON=$bjson
	EX_TLIST=$(list_of 'opennds.@opennds[0].trustedmac')
	EX_PENTRIES=$(list_of 'opennds.@opennds[0].preemptivemac')
}

# 在线/离线客户端信息表（"clients":{...} 的内容，不含外层键）
ex_clients() {
	local running=0 srow
	nds_running && running=1
	local out='' sep='' seen='|'
	if [ "$running" = '1' ]; then
		local mac lm ip cif zone host
		srow=$(parse_clients)
		while IFS='	' read -r tag mac st ip cif rest; do
			[ "$tag" = 'S' ] || continue
			[ -n "$mac" ] || continue
			lm=$(mac_lower "$mac")
			cif="${cif%% *}"
			zone=$(ex_zone_for "$cif")
			host=$(ov_host_for "$lm")
			# trusted 客户端 ndsctl 不一定给 ip：邻居表兜底，
			# 否则"可信任列表里在线设备不显示 IP"
			[ -z "$ip" ] && ip=$(neigh_ip_for "$lm")
			out="$out$sep\"$(json_escape "$mac")\":{\"host\":\"$(json_escape "$host")\",\"ip\":\"$(json_escape "$ip")\",\"zone\":\"$(json_escape "$zone")\",\"online\":1}"
			sep=','
			seen="$seen$lm|"
		done <<EOF2
$srow
EOF2
	fi
	# 名单里配了但不在线的：ip -4 neigh 兜底补 IP（zone 未知）；
	# 主机名照官方 dhcp_check 从 DHCP 租约查 —— 租约与 openNDS 是否在跑无关
	local lm
	for lm in $EX_TLIST $(printf '%s\n' $EX_PENTRIES | sed -n 's/^mac=//p' | cut -d';' -f1); do
		lm=$(mac_lower "$lm") 2>/dev/null || continue
		case "$seen" in
			*"|$lm|"*) continue ;;
		esac
		local nip hosto
		nip=$(ip -4 neigh show 2>/dev/null |
			awk -v m="$lm" 'tolower($4) == "lladdr" && tolower($5) == m {print $1; exit}')
		hosto=$(ov_host_for "$lm")
		out="$out$sep\"$(json_escape "$lm")\":{\"host\":\"$(json_escape "$hosto")\",\"ip\":\"$(json_escape "$nip")\",\"zone\":\"\",\"online\":0}"
		sep=','
		seen="$seen$lm|"
	done
	EX_CLIENTS=$out
}

ex_status() {
	ex_common
	ex_clients
	printf '{"ok":1,"enabled":%s,"trusted":[%s],"preempt":[%s],"preempt_enabled":%s,"blocked":[%s],"clients":{%s}}\n' \
		"$EX_ENABLED" "$EX_TJSON" "$EX_PJSON" "$EX_PE" "$EX_BJSON" "$EX_CLIENTS"
}

ex_save() { # 命名参数：trusted_add= trusted_remove= preempt_add= preempt_remove=
	# preempt_clear=0|1 preempt_enabled=0|1 [confirm_enable=1]
	# MAC 串只含冒号逗号、不含空格，按 k=v 前缀解析不会误切
	local a ta='' tr='' pa='' pr='' pc='' pe=''
	for a in "$@"; do
		case "$a" in
			confirm_enable=1) CONFIRM_ENABLE=1 ;;
			trusted_add=*) ta="${a#trusted_add=}" ;;
			trusted_remove=*) tr="${a#trusted_remove=}" ;;
			preempt_add=*) pa="${a#preempt_add=}" ;;
			preempt_remove=*) pr="${a#preempt_remove=}" ;;
			preempt_clear=*) pc="${a#preempt_clear=}" ;;
			preempt_enabled=*) pe="${a#preempt_enabled=}" ;;
		esac
	done
	local t_add t_rem p_add p_rem
	ex_parse_macs "$ta" T_ADD
	ex_parse_macs "$tr" T_REM
	ex_parse_macs "$pa" P_ADD
	ex_parse_macs "$pr" P_REM
	t_add=$T_ADD
	t_rem=$T_REM
	p_add=$P_ADD
	p_rem=$P_REM
	case "$pc" in
		'' | 0 | 1) ;;
		*) out_err 'preempt_clear 必须是 0 或 1' ;;
	esac
	case "$pe" in
		'' | 0 | 1) ;;
		*) out_err 'preempt_enabled 必须是 0 或 1' ;;
	esac

	# ---- ② 按本次增删算出应用后的两个名单，取交集（决策 #12）----
	local tlist pentries e m dup_json='' dsep=''
	tlist=$(list_of 'opennds.@opennds[0].trustedmac')
	pentries=$(list_of 'opennds.@opennds[0].preemptivemac')
	local tn pn lm
	tn=" $tlist "
	for lm in $t_rem; do
		tn="$tn "
		tn=$(printf '%s ' "$tn" | sed "s/ $lm / /g")
		tn=" $tn"
	done
	for lm in $t_add; do
		case "$tn" in
			*" $lm "*) ;;
			*) tn="$tn$lm " ;;
		esac
	done
	pn=" "
	for e in $pentries; do
		case "$e" in
			mac=*)
				m="${e#mac=}"
				m="${m%%;*}"
				pn="$pn$(mac_lower "$m") "
				;;
		esac
	done
	if [ "$pc" = '1' ]; then
		pn=" "
	else
		for lm in $p_rem; do
			pn=$(printf '%s' "$pn" | sed "s/ $lm / /g")
			pn=" $pn"
		done
		for lm in $p_add; do
			case "$pn" in
				*" $lm "*) ;;
				*) pn="$pn$lm " ;;
			esac
		done
	fi
	for lm in $tn; do
		[ -n "$lm" ] || continue
		case "$pn" in
			*" $lm "*)
				dup_json="$dup_json$dsep\"$lm\""
				dsep=','
				;;
		esac
	done
	[ -n "$dup_json" ] &&
		printf '{"ok":0,"error":"duplicate","duplicates":[%s]}\n' "$dup_json" &&
		return 0

	# ---- ②′ 黑名单检查：本次要 added 的 MAC（决策 #10）----
	local bl outbl='' bsep=''
	for lm in $t_add $p_add; do
		case " $(list_of 'opennds.@opennds[0].blockedmac') " in
			*" $lm "*)
				outbl="$outbl$bsep\"$lm\""
				bsep=','
				;;
		esac
	done
	[ -n "$outbl" ] &&
		printf '{"ok":0,"error":"blacklisted","macs":[%s]}\n' "$outbl" &&
		return 0

	# ---- 是否需要重启（开关值变化），需要则先过停用守卫 ----
	local cur_pe restarted=0
	cur_pe=$(uci_val 'opennds.@opennds[0].allow_preemptive_authentication' '1')
	if [ -n "$pe" ] && [ "$pe" != "$cur_pe" ]; then
		guard_enable || return 0
	fi
	acquire_lock

	# ---- ③ 写 uci：只动本次提到的 MAC（读-改-写）----
	local n_added=0 n_removed=0 t
	# trusted 名单
	for t in $t_rem; do
		for v in $tlist; do
			[ "$(mac_lower "$v")" = "$t" ] && uci del_list 'opennds.@opennds[0].trustedmac'="$v"
		done
		n_removed=$((n_removed + 1))
	done
	for t in $t_add; do
		case " $tlist " in
			*" $t "* | *" $(mac_upper "$t") "*) ;;
			*)
				uci add_list 'opennds.@opennds[0].trustedmac'="$t"
				n_added=$((n_added + 1))
				;;
		esac
	done
	# preempt 名单
	if [ "$pc" = '1' ]; then
		for e in $pentries; do
			case "$e" in
				mac=*)
					m="${e#mac=}"
					m="${m%%;*}"
					remove_preauth_queue "$m"
					ndsctl_mac deauth "$(mac_lower "$m")"
					;;
			esac
			uci del_list 'opennds.@opennds[0].preemptivemac'="$e"
			n_removed=$((n_removed + 1))
		done
	else
		for lm in $p_rem; do
			e=$(ex_entry_for_mac "$pentries" "$lm")
			if [ -n "$e" ]; then
				uci del_list 'opennds.@opennds[0].preemptivemac'="$e"
				n_removed=$((n_removed + 1))
			fi
			# 删队列文件 + deauth（sessiontimeout=0 = 跟随全局，不 deauth 就一直在线）
			remove_preauth_queue "$lm"
			ndsctl_mac deauth "$lm"
		done
		for lm in $p_add; do
			e=$(ex_entry_for_mac "$pentries" "$lm")
			if [ -z "$e" ]; then
				uci add_list 'opennds.@opennds[0].preemptivemac=mac='"$lm"';sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0'
				n_added=$((n_added + 1))
			fi
		done
	fi
	# 开关（不变则不写）
	if [ -n "$pe" ] && [ "$pe" != "$cur_pe" ]; then
		uci set 'opennds.@opennds[0].allow_preemptive_authentication'="$pe"
		if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
			uci set 'opennds.@opennds[0].enabled'=1
			EN_BY_APPLY=1
		fi
	fi
	uci commit opennds

	# ---- 运行时同步（逐个执行、失败只记日志）----
	for t in $t_add; do
		ndsctl_mac trust "$t"
	done
	for t in $t_rem; do
		ndsctl_mac untrust "$t"
		ndsctl_mac deauth "$t"
	done
	# preempt 名单有变化：commit 后主动投递一次（10.x 主进程不解析名单）
	case "$p_add$p_rem$pc" in
		'') ;;
		*) kick_preemptive ;;
	esac

	if [ -n "$pe" ] && [ "$pe" != "$cur_pe" ]; then
		service_restart && restarted=$SR_RESTARTED
	fi
	printf '{"ok":1,"restarted":%s,"added":%s,"removed":%s,"enabled_by_apply":%s}\n' \
		"$restarted" "$n_added" "$n_removed" "$EN_BY_APPLY"
}

# 文件是否为文本（无 NUL 字节即视为文本；前 8KB 现查）
file_is_text() { # $1=文件路径
	head -c 8192 "$1" 2>/dev/null | od -An -tu1 2>/dev/null |
		awk '{ for (i = 1; i <= NF; i++) if ($i == 0) exit 1 }'
}

# ndsctl 调用（小写失败转大写重试一次），返回真实成败供计数
ndsctl_mac_rc() { # $1=子命令 $2=小写 mac
	ndsctl "$1" "$2" >/dev/null 2>&1 && return 0
	ndsctl "$1" "$(mac_upper "$2")" >/dev/null 2>&1
}

# ============================================================
# 页面：blacklist（《客户端黑名单.md》）
# 名单 = /etc/config/opennds 的 blockedmac（由本插件的分发脚本执行拦截：
# openNDS 9.4.0 起已废弃 macmechanism/blockedmaclist，主进程不再自己读它，
# 客户端被拒绝认证、只看得到门户，靠 theme_zone_detect.sh 的黑名单分支实现）。
# 门户库 = /usr/lib/opennds/cpd/blacklist/，兜底 = cpd/default/blacklist/default.sh
# ============================================================

BL_PORTAL_DIR="$CPD_ROOT/blacklist"

# 门户库扫描：.sh 文件与含 theme.sh 的文件夹；跳过 default.sh 与 default/
bl_portals_scan() {
	local d="$BL_PORTAL_DIR" f b
	[ -d "$d" ] || return 0
	for f in "$d"/*; do
		[ -e "$f" ] || continue
		b="${f##*/}"
		case "$b" in
			default.sh | default) continue ;;
		esac
		if [ -f "$f" ] && [ "${b%.sh}" != "$b" ]; then
			printf '%s\tfile\n' "$b"
		elif [ -d "$f" ] && [ -f "$f/theme.sh" ]; then
			printf '%s\tdir\n' "$b"
		fi
	done
	return 0
}

bl_portal_sel() { # 当前选中的黑名单门户（空 = 兜底 default.sh）
	uci_val 'zone_detect.main.portal_blacklist' ''
}

bl_status() {
	local enabled m macj='' sep='' mm portal pj='' sep2='' name kind
	ensure_opennds_conf >/dev/null 2>&1 || true
	enabled=$(nds_enabled)
	for m in $(list_of 'opennds.@opennds[0].blockedmac'); do
		[ -n "$m" ] || continue # 空值等脏数据过滤掉
		macj="$macj$sep\"$(json_escape "$m")\""
		sep=','
	done
	mm=$(uci -q get 'opennds.@opennds[0].macmechanism' 2>/dev/null)
	portal=$(bl_portal_sel)
	while IFS='	' read -r name kind; do
		[ -n "$name" ] || continue
		pj="$pj$sep2{\"name\":\"$(json_escape "$name")\",\"kind\":\"$kind\"}"
		sep2=','
	done <<EOF2
$(bl_portals_scan)
EOF2
	printf '{"ok":1,"enabled":%s,"macs":[%s],"mechanism":"%s","portal":"%s","portals":[%s],"dir":"%s"}\n' \
		"$enabled" "$macj" "$(json_escape "$mm")" "$(json_escape "$portal")" "$pj" \
		"$(json_escape "$BL_PORTAL_DIR")"
}

# 删除已上传门户；正在使用的拒绝删（前后端同一口径，见《客户端黑名单.md》决策 #8）
bl_portal_delete() { # 命名参数：name=<门户名>
	local a name='' p sel
	for a in "$@"; do
		case "$a" in name=*) name="${a#name=}" ;; esac
	done
	[ -n "$name" ] || out_err '缺少门户名'
	name_ok "$name" 40 || out_err '门户名含非法字符'
	case "$name" in
		default.sh | default) out_err '内置默认门户不能删除' ;;
	esac
	sel=$(bl_portal_sel)
	[ "$sel" = "$name" ] && out_err '该门户正在使用中，请先在「门户选择」里换一个再删除'
	p="$BL_PORTAL_DIR/$name"
	if [ -f "$p" ]; then
		acquire_lock
		rm -f "$p" 2>/dev/null || out_err '删除门户失败'
	elif [ -d "$p" ]; then
		acquire_lock
		rm -rf "$p" 2>/dev/null || out_err '删除门户失败'
	else
		out_err '门户不存在'
	fi
	printf '{"ok":1}\n'
}

bl_upload_begin() { # $1=id
	local id="$1"
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	rm -rf "$ZONE_UP/$id" 2>/dev/null
	mkdir -p "$ZONE_UP/$id" 2>/dev/null || out_err '无法创建上传临时目录'
	printf '{"ok":1}\n'
}

bl_upload_store() { # $1=id $2=原名（原名即落盘名）
	local id="$1" name="$2" tmp
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	[ -n "$name" ] || out_err '缺少文件名'
	[ "$(name_bytes "$name")" -le 20 ] 2>/dev/null || out_err '文件名过长（最多 20 个字符）'
	name_ok "$name" 20 || out_err '文件名含非法字符，无法上传'
	case "$name" in
		default.sh) out_err '不能上传名为 default.sh 的脚本，兜底门户请用内置 default.sh' ;;
		*.sh) ;;
		*) out_err '只接受 .sh 门户脚本' ;;
	esac
	tmp="$ZONE_UP/$id/$name"
	[ -f "$tmp" ] || out_err '上传内容不存在，请重新上传'
	file_is_text "$tmp" || out_err '只支持文本脚本，二进制文件无法上传'
	acquire_lock
	mkdir -p "$BL_PORTAL_DIR" 2>/dev/null || out_err '无法创建门户目录'
	cp "$tmp" "$BL_PORTAL_DIR/$name.tmp" 2>/dev/null || out_err '写入门户文件失败'
	chmod 755 "$BL_PORTAL_DIR/$name.tmp" 2>/dev/null
	mv "$BL_PORTAL_DIR/$name.tmp" "$BL_PORTAL_DIR/$name" 2>/dev/null || {
		rm -f "$BL_PORTAL_DIR/$name.tmp" 2>/dev/null
		out_err '替换门户文件失败'
	}
	case "$ZONE_UP/$id" in
		"$ZONE_UP"/*) rm -rf "$ZONE_UP/$id" 2>/dev/null ;;
	esac
	printf '{"ok":1,"name":"%s"}\n' "$(json_escape "$name")"
}

# ============================================================
# 页面：router（《路由器访问.md》§5-§6）
# ============================================================

OPENNDS_CONF="${OPENNDS_CONF:-/etc/config/opennds}"
RT_BAK_DIR="${RT_BAK_DIR:-/tmp/zone-router}"

# 去首尾空格与 Tab
rt_trim() {
	local s="$1"
	while :; do
		case "$s" in
			' '*) s="${s# }" ;;
			'	'*) s="${s#	}" ;;
			*) break ;;
		esac
	done
	while :; do
		case "$s" in
			*' ') s="${s% }" ;;
			*'	') s="${s%	}" ;;
			*) break ;;
		esac
	done
	printf '%s' "$s"
}

# 数字串去前导零后按十进制返回（ash 的 $((0443)) 会按八进制算，必须先去）
rt_num_val() { # $1=数字串 → stdout 值；非纯数字 rc=1
	local s="$1"
	case "$s" in
		'' | *[!0-9]*) return 1 ;;
	esac
	while [ "${s#0}" != "$s" ]; do s="${s#0}"; done
	[ -n "$s" ] || s=0
	printf '%s' "$s"
}

rt_is_num() { # 纯数字
	case "$1" in
		'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

rt_is_proto() { # $1 → tcp/udp（大小写不敏感）
	case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
		tcp | udp) return 0 ;;
	esac
	return 1
}

rt_is_ipish() { # 只含数字与点（可能是个 IP）
	case "$1" in
		'' | *[!0-9.]*) return 1 ;;
	esac
	return 0
}

rt_ip_ok() { # $1 → 点分四段、每段 0..255
	local oldifs="$IFS" s v
	IFS='.'
	set -- $1
	IFS="$oldifs"
	[ "$#" -eq 4 ] || return 1
	for s in "$@"; do
		v=$(rt_num_val "$s") || return 1
		[ "$v" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}

# 输入文本 → RT_RULES（换行分隔）/ RT_ERRS（JSON，尾逗号）/ RT_N
# SEEN 做精确去重（不做子串/模糊去重，§5.4）
rt_parse_text() { # $1=多行文本
	RT_RULES=''
	RT_ERRS=''
	RT_N=0
	SEEN=' '
	local line ln=0 n t1 t2 t3 p low
	while IFS= read -r line || [ -n "$line" ]; do
		ln=$((ln + 1))
		line=$(printf '%s' "$line" | tr -d '\r')
		line=$(rt_trim "$line")
		[ -n "$line" ] || continue
		local oldifs="$IFS"
		set -- $line
		IFS="$oldifs"
		n=$#
		t1="${1:-}"
		t2="${2:-}"
		t3="${3:-}"
		case "$n" in
			1)
				if rt_is_num "$t1"; then
					rt_add_port_rule "$ln" tcp "$t1"
					rt_add_port_rule "$ln" udp "$t1"
				elif rt_is_ipish "$t1"; then
					rt_add_ip_rule "$ln" "$t1"
				else
					low=$(printf '%s' "$t1" | tr 'A-Z' 'a-z')
					case "$low" in
						*'-'*) rt_err "$ln" '不支持端口范围，请写单个端口' ;;
						tcp | udp) rt_err "$ln" '`tcp` / `udp` 后必须跟端口号' ;;
						*tcp* | *udp* | *all* | *both*) rt_err "$ln" '协议只能是 tcp 或 udp；两个协议都要请直接写端口号' ;;
						*) rt_err "$ln" '格式不正确，支持 `端口`、`协议 端口`、`IP`' ;;
					esac
				fi
				;;
			2)
				if rt_is_proto "$t1"; then
					if rt_is_num "$t2"; then
						p=$(printf '%s' "$t1" | tr 'A-Z' 'a-z')
						rt_add_port_rule "$ln" "$p" "$t2"
					elif rt_is_ipish "$t2" && [ -n "$(printf '%s' "$t2" | tr -d '.')" ]; then
						rt_err "$ln" '`tcp` / `udp` 后必须跟端口号'
					else
						rt_err "$ln" '端口必须是数字'
					fi
				elif rt_is_num "$t1"; then
					if rt_is_ipish "$t2"; then
						rt_err "$ln" '暂不支持同时限定端口和来源 IP：要限定设备请只写 IP，要限定端口请只写端口'
					else
						rt_err "$ln" '格式不正确，支持 `端口`、`协议 端口`、`IP`'
					fi
				elif rt_is_ipish "$t1"; then
					rt_err "$ln" '格式不正确，支持 `端口`、`协议 端口`、`IP`'
				else
					low=$(printf '%s' "$t1" | tr 'A-Z' 'a-z')
					case "$low" in
						*'-'*) rt_err "$ln" '不支持端口范围，请写单个端口' ;;
						*tcp* | *udp* | *all* | *both*) rt_err "$ln" '协议只能是 tcp 或 udp；两个协议都要请直接写端口号' ;;
						*) rt_err "$ln" '格式不正确，支持 `端口`、`协议 端口`、`IP`' ;;
					esac
				fi
				;;
			3)
				if rt_is_proto "$t1" && rt_is_num "$t2" && rt_is_ipish "$t3"; then
					rt_err "$ln" '暂不支持同时限定端口和来源 IP：要限定设备请只写 IP，要限定端口请只写端口'
				else
					rt_err "$ln" '格式不正确，支持 `端口`、`协议 端口`、`IP`'
				fi
				;;
			*)
				rt_err "$ln" '格式不正确，支持 `端口`、`协议 端口`、`IP`'
				;;
		esac
	done <<EOF2
$1
EOF2
	return 0
}

rt_err() { # $1=行号 $2=消息
	RT_ERRS="$RT_ERRS{\"line\":$1,\"msg\":\"$(json_escape "$2")\"},"
}

# 端口规则：范围 → 前缀拦截 → essentials 静默丢弃 → 精确去重 → 展开
rt_add_port_rule() { # $1=行号 $2=proto(小写) $3=端口串
	local p rule
	p=$(rt_num_val "$3") || {
		rt_err "$1" '端口必须是数字'
		return 0
	}
	if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
		rt_err "$1" '端口必须在 1-65535 之间'
		return 0
	fi
	# openNDS 的去重是 grep 子串匹配：端口号是内置端口（22/443/53/67）前缀的条目
	# 会在 ndsRTR 链里被吞掉，只能在这里提前拒绝（§5.4）
	case "$2:$p" in
		tcp:2 | tcp:4 | tcp:44 | udp:5 | udp:6)
			rt_err "$1" "端口 $p 是内置放行端口（443/22/53/67）的前缀，openNDS 去重时会把它当成重复条目丢掉，请改用其它端口"
			return 0
			;;
	esac
	rule="allow $2 port $p"
	case "$SEEN" in
		*"|$rule|"*) return 0 ;; # 展开结果之间重复，保留首次
	esac
	SEEN="$SEEN|$rule|"
	case "$RT_ESSENTIALS" in
		*"|$rule|"*) return 0 ;; # 内置 essentials：静默丢弃
	esac
	RT_RULES="$RT_RULES$rule
"
	RT_N=$((RT_N + 1))
	return 0
}

rt_add_ip_rule() { # $1=行号 $2=IP
	rt_ip_ok "$2" || {
		rt_err "$1" 'IP 地址格式不正确'
		return 0
	}
	local rule="allow all from $2"
	case "$SEEN" in
		*"|$rule|"*) return 0 ;;
	esac
	SEEN="$SEEN|$rule|"
	RT_RULES="$RT_RULES$rule
"
	RT_N=$((RT_N + 1))
	return 0
}

RT_ESSENTIALS='|allow udp port 53|allow udp port 67|allow tcp port 22|allow tcp port 443|'

rt_b64decode() { # $1 → stdout；无可用解码器 rc=2
	if command -v base64 >/dev/null 2>&1; then
		printf '%s' "$1" | base64 -d 2>/dev/null
		return $?
	fi
	if command -v openssl >/dev/null 2>&1; then
		printf '%s' "$1" | openssl base64 -d -A 2>/dev/null
		return $?
	fi
	# 兜底：纯 awk 按字节解码（busybox 必带 awk），不依赖 base64/openssl
	command -v awk >/dev/null 2>&1 || return 2
	printf '%s' "$1" | LC_ALL=C awk '
		BEGIN {
			c = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
			for (i = 1; i <= length(c); i++) v[substr(c, i, 1)] = i - 1
		}
		{
			s = $0
			for (i = 1; i <= length(s); i++) {
				ch = substr(s, i, 1)
				if (ch == "=" || ch == "\r") continue
				if (!(ch in v)) { bad = 1; continue }
				buf = buf * 64 + v[ch]
				bits += 6
				while (bits >= 8) {
					bits -= 8
					p = 2 ^ bits
					printf "%c", int(buf / p)
					buf = buf % p
				}
			}
		}
		END { if (bad) exit 1 }
	'
}

rt_get_arg() { # $@ 里找 $1=... 的值（k=v 独立参数）
	local a
	for a in "$@"; do
		case "$a" in
			"$1="*)
				printf '%s' "${a#*=}"
				return 0
				;;
		esac
	done
	return 1
}

rt_has_udp() { # $1=items $2=port → 是否存在未折叠的 udp 同端口条目
	printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == "U" && $3 == p { f = 1 } END { exit !f }'
}

usedp_has() { # $1=usedp $2=port
	case "$1" in
		*" $2 "*) return 0 ;;
	esac
	return 1
}

# uci list（换行分隔）→ 简写文本（§5.5 反解析 + 折叠）
rt_reverse() { # $1=list 值
	local items='' i=0 v rest p t o out='' usedp=' '
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		v=$(rt_trim "$v")
		[ -n "$v" ] || continue
		# 内置 essentials 由 openNDS 无条件放行，界面不展示（§5.5 第 1 条）
		case "$RT_ESSENTIALS" in
			*"|$v|"*) continue ;;
		esac
		i=$((i + 1))
		case "$v" in
			'allow tcp port '*)
				rest="${v#allow tcp port }"
				if rt_is_num "$rest"; then
					items="$items$i	T	$rest	$v
"
				else
					items="$items$i	RAW	-	$v
"
				fi
				;;
			'allow udp port '*)
				rest="${v#allow udp port }"
				if rt_is_num "$rest"; then
					items="$items$i	U	$rest	$v
"
				else
					items="$items$i	RAW	-	$v
"
				fi
				;;
			'allow all from '*)
				rest="${v#allow all from }"
				if rt_ip_ok "$rest"; then
					items="$items$i	IP	$rest	$v
"
				else
					items="$items$i	RAW	-	$v
"
				fi
				;;
			*)
				items="$items$i	RAW	-	$v
"
				;;
		esac
	done <<EOF2
$1
EOF2
	# 折叠：同端口都无 IP 的 tcp+udp 两条 → 裸端口，占先出现那条的位置
	while IFS='	' read -r i t p o; do
		[ -n "$i" ] || continue
		case "$t" in
			T)
				if rt_has_udp "$items" "$p" && ! usedp_has "$usedp" "$p"; then
					out="${out}$p
"
					usedp="$usedp$p "
				else
					out="${out}tcp $p
"
				fi
				;;
			U)
				case "$usedp" in
					*" $p "*) ;;
					*) out="${out}udp $p
" ;;
				esac
				;;
			IP)
				out="${out}$p
"
				;;
			RAW)
				out="${out}$o
"
				;;
		esac
	done <<EOF2
$items
EOF2
	printf '%s' "$out"
	return 0
}

rt_status() {
	local pt text='' fw4=1 list
	command -v fw4 >/dev/null 2>&1 || fw4=0
	nds_conf_ok || out_err '未找到 openNDS 配置'
	pt=$(uci_val 'opennds.@opennds[0].users_to_router_passthrough' '0')
	[ "$pt" = '1' ] || pt=0
	list=$(cache_pairs 'opennds.@opennds[0].users_to_router')
	[ -n "$list" ] && text=$(rt_reverse "$list")
	printf '{"ok":1,"enabled":%s,"passthrough":%s,"text":"%s","fw4":%s}\n' \
		"$(nds_enabled)" "$pt" "$(json_escape_nl "$text")" "$fw4"
}

rt_validate() { # $@ 含 text_b64=...
	local tb tb_seen=0 a
	for a in "$@"; do
		case "$a" in
			text_b64=*)
				tb="${a#text_b64=}"
				tb_seen=1
				;;
		esac
	done
	[ "$tb_seen" = '1' ] || out_err '缺少 text_b64 参数'
	[ "${#tb}" -le 131072 ] || out_err '内容过长'
	local text
	local rc
	text=$(rt_b64decode "$tb"); rc=$?
	[ "$rc" = '2' ] && out_err '系统缺少解码工具（awk / base64）'
	[ "$rc" != '0' ] && out_err '内容不是有效的 base64'
	[ "$(name_bytes "$text")" -le 65536 ] || out_err '内容过长'
	rt_parse_text "$text"
	if [ -n "$RT_ERRS" ]; then
		printf '{"ok":0,"errors":[%s]}\n' "${RT_ERRS%,}"
		return 0
	fi
	local r rj='' sep=''
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		rj="$rj$sep\"$(json_escape "$r")\""
		sep=','
	done <<EOF2
$RT_RULES
EOF2
	printf '{"ok":1,"rules":[%s],"count":%s}\n' "$rj" "$RT_N"
}

rt_apply() { # $@ 含 text_b64=... passthrough=0|1 [confirm_enable=1]
	local a tb='' pt='' tb_seen=0
	for a in "$@"; do
		case "$a" in
			text_b64=*)
				tb="${a#text_b64=}"
				tb_seen=1
				;;
			passthrough=*) pt="${a#passthrough=}" ;;
			confirm_enable=1) CONFIRM_ENABLE=1 ;;
		esac
	done
	[ "$tb_seen" = '1' ] || out_err '缺少 text_b64 参数'
	case "$pt" in
		0 | 1) ;;
		*) out_err 'passthrough 必须是 0 或 1' ;;
	esac
	[ "${#tb}" -le 131072 ] || out_err '内容过长'
	local text
	local rc
	text=$(rt_b64decode "$tb"); rc=$?
	[ "$rc" = '2' ] && out_err '系统缺少解码工具（awk / base64）'
	[ "$rc" != '0' ] && out_err '内容不是有效的 base64'
	[ "$(name_bytes "$text")" -le 65536 ] || out_err '内容过长'
	rt_parse_text "$text"
	if [ -n "$RT_ERRS" ]; then
		printf '{"ok":0,"errors":[%s]}\n' "${RT_ERRS%,}"
		return 0
	fi
	guard_enable || return 0
	acquire_lock
	nds_conf_ok || out_err '未找到 openNDS 配置'
	mkdir -p "$RT_BAK_DIR" 2>/dev/null
	cp "$OPENNDS_CONF" "$RT_BAK_DIR/opennds.bak" 2>/dev/null ||
		out_err '无法备份 openNDS 配置'
	local fail=0 r
	uci -q delete 'opennds.@opennds[0].users_to_router' 2>/dev/null
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		uci add_list 'opennds.@opennds[0].users_to_router'="$r" || { fail=1; fail_at 'users_to_router 写入'; }
	done <<EOF2
$RT_RULES
EOF2
	uci set 'opennds.@opennds[0].users_to_router_passthrough'="$pt" || { fail=1; fail_at 'users_to_router_passthrough 写入'; }
	if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
		uci set 'opennds.@opennds[0].enabled'=1
		EN_BY_APPLY=1
	fi
	uci commit opennds || { fail=1; fail_at 'opennds commit'; }
	uci commit zone_detect 2>/dev/null || true
	if [ "$fail" = '1' ]; then
		# revert 丢掉 /tmp/.uci 增量 → 文件放回原位 → 不再 commit（§6.2 第 3 步）
		uci revert opennds 2>/dev/null
		cp "$RT_BAK_DIR/opennds.bak" "$OPENNDS_CONF" 2>/dev/null
		out_err "写入配置失败（$FAIL_STEP），已回滚"
	fi
	local wjson='[]'
	if [ "$pt" = '1' ] && [ "$RT_N" -gt 0 ]; then
		wjson='["已关闭接管，端口规则当前不生效"]'
	fi
	if service_restart; then
		printf '{"ok":1,"restarted":'"$SR_RESTARTED"',"rules":%s,"warnings":%s,"enabled_by_apply":%s}\n' "$RT_N" "$wjson" "$EN_BY_APPLY"
	else
		printf '{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}\n'
	fi
}

# ============================================================
# 页面：walledgarden（《WalledGarden.md》§5-§6）
# 三条红线：不生成 allow to X / allow port N to X；
# 协议位白名单校验后小写化，绝不原样透传
# ============================================================

wg_err() { # $1=行号 $2=消息
	WG_ERRS="$WG_ERRS{\"line\":$1,\"msg\":\"$(json_escape "$2")\"},"
}

wg_dom_ok() { # $1=已小写域名
	[ -n "$1" ] || return 1
	[ "$(name_bytes "$1")" -le 253 ] || return 1
	case "$1" in
		*[!a-z0-9.-]* | .* | *. | *..*) return 1 ;;
	esac
	printf '%s' "$1" | awk 'BEGIN{RS=".";ok=1}{
		if (length($0) < 1 || length($0) > 63) ok=0
		if ($0 ~ /^-/ || $0 ~ /-$/) ok=0
		if ($0 ~ /[^a-z0-9-]/) ok=0
	}END{exit !ok}' || return 1
	return 0
}

wg_target_norm() { # $1=行号 $2=target → WG_TGT（域名小写）；失败 rc=1
	case "$2" in
		*[!0-9.]*)
			# 带 / 且斜杠前是 IP 样式（1.2.3.4/24 这类 CIDR）→ 按 IP 报错更直观
			case "$2" in
				*/*)
					case "${2%%/*}" in
						*[!0-9.]* | '') ;;
						*)
							wg_err "$1" 'IP 地址格式不正确'
							return 1
							;;
					esac
					;;
			esac
			WG_TGT=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
			wg_dom_ok "$WG_TGT" && return 0
			wg_err "$1" '域名格式不正确'
			return 1
			;;
		*)
			rt_ip_ok "$2" && {
				WG_TGT="$2"
				return 0
			}
			wg_err "$1" 'IP 地址格式不正确'
			return 1
			;;
	esac
}

wg_emit() { # $1=proto $2=port $3=target（跨行精确去重，保留首次）
	local rule="allow $1 port $2 to $3"
	case "$WG_SEEN" in
		*"|$rule|"*) return 0 ;;
	esac
	WG_SEEN="$WG_SEEN|$rule|"
	WG_RULES="$WG_RULES$rule
"
	WG_N=$((WG_N + 1))
	return 0
}

wg_portlist_parse() { # $1=行号 $2=portlist 字段 → WG_PORTS_LINE（空格分隔端口，去前导零、行内去重）；失败 rc=1
	local rest p seen=' ' out=''
	case "$2" in
		*[!0-9,]*)
			case "$2" in
				*,*) wg_err "$1" '端口列表格式不正确，用逗号分隔，如 `80,443`' ;;
				*) wg_err "$1" '端口必须是数字' ;;
			esac
			return 1
			;;
	esac
	case "$2" in
		*,,* | ,* | *,)
			wg_err "$1" '端口列表格式不正确，用逗号分隔，如 `80,443`'
			return 1
			;;
	esac
	rest="$2"
	while [ -n "$rest" ]; do
		p="${rest%%,*}"
		case "$rest" in
			*,*) rest="${rest#*,}" ;;
			*) rest='' ;;
		esac
		p=$(rt_num_val "$p") || {
			wg_err "$1" '端口必须是数字'
			return 1
		}
		if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
			wg_err "$1" '端口必须在 1-65535 之间'
			return 1
		fi
		case "$seen" in
			*" $p "*) continue ;; # 行内重复端口（80,080）只展开一次（§5.4）
		esac
		seen="$seen $p "
		out="$out $p"
	done
	WG_PORTS_LINE="${out# }"
	return 0
}

# 手动区文本 → WG_RULES（展开后的 uci 条目，换行分隔）/ WG_ERRS / WG_N / WG_P80
wg_parse_text() { # $1=手动区文本
	local line ln=0 f1 f2 f3 oldifs p
	while IFS= read -r line || [ -n "$line" ]; do
		ln=$((ln + 1))
		line=$(printf '%s' "$line" | tr -d '\r')
		line=$(rt_trim "$line")
		[ -n "$line" ] || continue
		oldifs="$IFS"
		set -- $line
		IFS="$oldifs"
		f1="${1:-}"
		f2="${2:-}"
		f3="${3:-}"
		case $# in
			1)
				case "$f1" in
					*[!0-9]*)
						wg_err "$ln" '必须指定端口：openNDS 里只写目标会变成全端口全协议放行，请写成 `端口 域名或IP`'
						;;
					*) wg_err "$ln" '缺少域名或IP' ;;
				esac
				;;
			2)
				case "$f1" in
					*[!0-9,]*)
						f1=$(printf '%s' "$f1" | tr 'A-Z' 'a-z')
						case "$f1" in
							tcp | udp)
								case "$f2" in
									# `tcp 443`（端口在、目标缺）→ 缺少域名或IP（§5.3）
									*[!0-9]*) wg_err "$ln" '`tcp` / `udp` 后必须跟端口号' ;;
									*) wg_err "$ln" '缺少域名或IP' ;;
								esac
								;;
							*) wg_err "$ln" '协议只能是 tcp 或 udp；两个协议都要请直接写 `端口 域名或IP`' ;;
						esac
						;;
					*)
						wg_portlist_parse "$ln" "$f1" || continue
						wg_target_norm "$ln" "$f2" || continue
						for p in $WG_PORTS_LINE; do
							[ "$p" = '80' ] && WG_P80=1
							wg_emit tcp "$p" "$WG_TGT"
							wg_emit udp "$p" "$WG_TGT"
						done
						;;
				esac
				;;
			3)
				case "$f1" in
					*[!0-9]*)
						f1=$(printf '%s' "$f1" | tr 'A-Z' 'a-z')
						case "$f1" in
							tcp | udp)
								wg_portlist_parse "$ln" "$f2" || continue
								wg_target_norm "$ln" "$f3" || continue
								for p in $WG_PORTS_LINE; do
									[ "$p" = '80' ] && WG_P80=1
									wg_emit "$f1" "$p" "$WG_TGT"
								done
								;;
							*) wg_err "$ln" '协议只能是 tcp 或 udp；两个协议都要请直接写 `端口 域名或IP`' ;;
						esac
						;;
					*) wg_err "$ln" '多个端口之间用逗号分隔，如 `80,443`' ;;
				esac
				;;
			*)
				wg_err "$ln" '格式不正确，支持 `端口 域名或IP`、`协议 端口 域名或IP`'
				;;
		esac
	done <<EOF2
$1
EOF2
	return 0
}

# 自动区域名文本 → WG_FQDNS（换行分隔，小写去重）；错误进 WG_ERRS（行号按域名文本）
wg_parse_domains() { # $1=域名文本
	local line ln=0 d
	while IFS= read -r line || [ -n "$line" ]; do
		ln=$((ln + 1))
		line=$(printf '%s' "$line" | tr -d '\r')
		line=$(rt_trim "$line")
		[ -n "$line" ] || continue
		case "$line" in
			*:*)
				wg_err "$ln" '自动区只接受域名；IP 请填到手动区'
				continue
				;;
		esac
		d=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
		case "$d" in
			*[!0-9.]*)
				wg_dom_ok "$d" || {
					wg_err "$ln" '域名格式不正确'
					continue
				}
				;;
			*)
				wg_err "$ln" '自动区只接受域名；IP 请填到手动区'
				continue
				;;
		esac
		case "$WG_FSEEN" in
			*"|$d|"*) continue ;;
		esac
		WG_FSEEN="$WG_FSEEN|$d|"
		WG_FQDNS="$WG_FQDNS$d
"
	done <<EOF2
$1
EOF2
	return 0
}

wg_parse_ports() { # $1=ports 明文（数字，逗号/空格分隔）→ WG_PORTS 空格分隔；失败 rc=1
	local s="$1" p rest seen=' ' out=''
	case "$s" in
		*[!0-9,\ ]*)
			wg_err 0 '端口格式不正确，多个用逗号分隔（如 80,443）'
			return 1
			;;
	esac
	case "$s" in
		*,,* | ,* | *,)
			wg_err 0 '端口格式不正确，多个用逗号分隔（如 80,443）'
			return 1
			;;
	esac
	rest=$(printf '%s' "$s" | tr ',\t' '  ')
	for p in $rest; do
		p=$(rt_num_val "$p") || {
			wg_err 0 '端口必须是数字'
			return 1
		}
		if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
			wg_err 0 '端口必须在 1-65535 之间'
			return 1
		fi
		case "$seen" in
			*" $p "*) continue ;;
		esac
		seen="$seen $p "
		out="$out $p"
	done
	WG_PORTS="${out# }"
	return 0
}

# dnsmasq 能力探测（照 libopennds.sh:1393-1430 的判法，§6.4）
wg_detect_mode() {
	if dnsmasq --version 2>/dev/null | grep -q ' nftset '; then
		printf 'nftset'
	elif dnsmasq --version 2>/dev/null | grep -q ' ipset ' &&
		command -v ipset >/dev/null 2>&1; then
		printf 'ipset'
	else
		printf 'none'
	fi
	return 0
}

# preauthenticated_users（换行分隔）→ 简写文本（§5.5 反解析）
# 一对 tcp+udp 同端口同目标 → 合并 `N T`；allow port N to T → 纠正成两行；
# allow to T 与其它任何写法 → 原样输出（决策 #9）
wg_reverse() { # $1=uci list 值
	local v rest p t out='' pend='' pendp='' pendt=''
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		v=$(rt_trim "$v")
		[ -n "$v" ] || continue
		case "$v" in
			'allow tcp port '*)
				rest="${v#allow tcp port }"
				case "$rest" in
					*' to '*)
						p="${rest%% to *}"
						t="${rest#* to }"
						if [ -n "$pend" ]; then
							out="${out}tcp $pendp $pendt
"
							pend=''
						fi
						if rt_is_num "$p" && [ -n "$t" ]; then
							pend=1
							pendp="$p"
							pendt="$t"
						else
							out="${out}$v
"
						fi
						;;
					*) out="${out}$v
" ;;
				esac
				;;
			'allow udp port '*)
				rest="${v#allow udp port }"
				case "$rest" in
					*' to '*)
						p="${rest%% to *}"
						t="${rest#* to }"
						if [ -n "$pend" ] && [ "$pendp" = "$p" ] && [ "$pendt" = "$t" ]; then
							out="${out}$p $t
"
							pend=''
						else
							if [ -n "$pend" ]; then
								out="${out}tcp $pendp $pendt
"
								pend=''
							fi
							out="${out}udp $p $t
"
						fi
						;;
					*) out="${out}$v
" ;;
				esac
				;;
			'allow port '*)
				rest="${v#allow port }"
				case "$rest" in
					*' to '*)
						p="${rest%% to *}"
						t="${rest#* to }"
						if [ -n "$pend" ]; then
							out="${out}tcp $pendp $pendt
"
							pend=''
						fi
						if rt_is_num "$p" && [ -n "$t" ]; then
							# 历史遗留：实际跑的是整站全端口放行，纠正成两条正确规则（§5.5 第 3 条）
							out="${out}tcp $p $t
udp $p $t
"
						else
							out="${out}$v
"
						fi
						;;
					*) out="${out}$v
" ;;
				esac
				;;
			*)
				if [ -n "$pend" ]; then
					out="${out}tcp $pendp $pendt
"
					pend=''
				fi
				out="${out}$v
"
				;;
		esac
	done <<EOF2
$1
EOF2
	if [ -n "$pend" ]; then
		out="${out}tcp $pendp $pendt
"
	fi
	printf '%s' "$out"
	return 0
}

wg_status() {
	nds_conf_ok || out_err '未找到 openNDS 配置'
	local text='' domains='' ports='' list
	list=$(cache_pairs 'opennds.@opennds[0].preauthenticated_users')
	[ -n "$list" ] && text=$(wg_reverse "$list")
	list=$(cache_pairs 'opennds.@opennds[0].walledgarden_fqdn_list')
	[ -n "$list" ] && domains="$list"
	list=$(cache_pairs 'opennds.@opennds[0].walledgarden_port_list')
	[ -n "$list" ] && ports=$(printf '%s\n' "$list" | awk 'NR>1{printf ","} {printf "%s",$0}')
	printf '{"ok":1,"enabled":%s,"manual":"%s","domains":"%s","ports":"%s","wg_mode":"%s"}\n' \
		"$(nds_enabled)" \
		"$(json_escape_nl "$text")" \
		"$(json_escape_nl "$domains")" \
		"$(json_escape "$ports")" \
		"$(wg_detect_mode)"
}

# base64 参数解码：$1=参数名，其余为 k=v 独立参数 → stdout 文本
# 缺参 / 无工具 / 解码失败 / 超 64KB → out_err（退出）
wg_get_b64() { # $1=参数名 $@=k=v
	local key="$1"
	shift
	local a v='' seen=0 rc=0 text
	for a in "$@"; do
		case "$a" in
			"$key="*)
				v="${a#*=}"
				seen=1
				;;
		esac
	done
	[ "$seen" = '1' ] || out_err "缺少 $key 参数"
	[ "${#v}" -le 131072 ] || out_err '内容过长'
	text=$(rt_b64decode "$v") || rc=$?
	[ "$rc" = '2' ] && out_err '系统缺少解码工具（awk / base64）'
	[ "$rc" != '0' ] && out_err '内容不是有效的 base64'
	[ "$(name_bytes "$text")" -le 65536 ] || out_err '内容过长'
	printf '%s' "$text"
	return 0
}

wg_reset() {
	WG_RULES=''
	WG_ERRS=''
	WG_N=0
	WG_P80=0
	WG_SEEN='|'
	WG_FQDNS=''
	WG_FSEEN='|'
	WG_PORTS=''
	WG_PORTS_LINE=''
	WG_TGT=''
}

wg_json_list() { # $1=换行分隔值 → stdout JSON 数组
	local v sep='' j=''
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		j="$j$sep\"$(json_escape "$v")\""
		sep=','
	done <<EOF2
$1
EOF2
	printf '[%s]' "$j"
	return 0
}

wg_validate() { # $@: manual_b64 domains_b64 ports
	local text dtext ports_s
	text=$(wg_get_b64 manual_b64 "$@") || return 0
	dtext=$(wg_get_b64 domains_b64 "$@") || return 0
	ports_s=$(rt_get_arg ports "$@") || out_err '缺少 ports 参数'
	wg_reset
	wg_parse_text "$text"
	wg_parse_domains "$dtext"
	wg_parse_ports "$ports_s"
	if [ -n "$WG_ERRS" ]; then
		printf '{"ok":0,"errors":[%s]}\n' "${WG_ERRS%,}"
		return 0
	fi
	local r pj='' psep='' p
	for p in $WG_PORTS; do
		pj="$pj$psep\"$p\""
		psep=','
	done
	local p80=0
	[ "$WG_P80" = '1' ] && p80=1
	printf '{"ok":1,"manual_rules":%s,"fqdns":%s,"ports":[%s],"port80":%s}\n' \
		"$(wg_json_list "$WG_RULES")" \
		"$(wg_json_list "$WG_FQDNS")" \
		"$pj" "$p80"
}

wg_apply() { # $@: manual_b64 domains_b64 ports [confirm_enable=1]
	local a
	for a in "$@"; do
		case "$a" in
			confirm_enable=1) CONFIRM_ENABLE=1 ;;
		esac
	done
	local text dtext ports_s
	text=$(wg_get_b64 manual_b64 "$@") || return 0
	dtext=$(wg_get_b64 domains_b64 "$@") || return 0
	ports_s=$(rt_get_arg ports "$@") || out_err '缺少 ports 参数'
	wg_reset
	wg_parse_text "$text"
	wg_parse_domains "$dtext"
	wg_parse_ports "$ports_s"
	if [ -n "$WG_ERRS" ]; then
		printf '{"ok":0,"errors":[%s]}\n' "${WG_ERRS%,}"
		return 0
	fi
	guard_enable || return 0
	acquire_lock
	nds_conf_ok || out_err '未找到 openNDS 配置'
	mkdir -p "$RT_BAK_DIR" 2>/dev/null
	cp "$OPENNDS_CONF" "$RT_BAK_DIR/opennds.bak" 2>/dev/null ||
		out_err '无法备份 openNDS 配置'
	local fail=0 r
	uci -q delete 'opennds.@opennds[0].preauthenticated_users' 2>/dev/null
	uci -q delete 'opennds.@opennds[0].walledgarden_fqdn_list' 2>/dev/null
	uci -q delete 'opennds.@opennds[0].walledgarden_port_list' 2>/dev/null
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		uci add_list 'opennds.@opennds[0].preauthenticated_users'="$r" || { fail=1; fail_at 'preauthenticated_users 写入'; }
	done <<EOF2
$WG_RULES
EOF2
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		uci add_list 'opennds.@opennds[0].walledgarden_fqdn_list'="$r" || { fail=1; fail_at 'walledgarden_fqdn_list 写入'; }
	done <<EOF2
$WG_FQDNS
EOF2
	for r in $WG_PORTS; do
		uci add_list 'opennds.@opennds[0].walledgarden_port_list'="$r" || { fail=1; fail_at 'walledgarden_port_list 写入'; }
	done
	if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
		uci set 'opennds.@opennds[0].enabled'=1
		EN_BY_APPLY=1
	fi
	uci commit opennds || { fail=1; fail_at 'opennds commit'; }
	if [ "$fail" = '1' ]; then
		uci revert opennds 2>/dev/null
		cp "$RT_BAK_DIR/opennds.bak" "$OPENNDS_CONF" 2>/dev/null
		out_err "写入配置失败（$FAIL_STEP），已回滚"
	fi
	# warnings 恒为数组（§6）；两条固定文案
	local wjson='[' sep=''
	if [ "$WG_P80" = '1' ]; then
		wjson="$wjson\"警告：放行 80 端口可能击穿客户端系统的强制门户检测（CPD），上游不建议\""
		sep=','
	fi
	if [ -z "$WG_FQDNS" ] && [ -n "$WG_PORTS" ]; then
		wjson="$wjson$sep\"域名列表为空，端口设置不会生效\""
	fi
	wjson="$wjson]"
	if service_restart; then
		printf '{"ok":1,"restarted":'"$SR_RESTARTED"',"warnings":%s,"enabled_by_apply":%s}\n' "$wjson" "$EN_BY_APPLY"
	else
		printf '{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}\n'
	fi
}

# ============================================================
# 页面：access（《访问限制.md》§5-§6）
# 三条红线：不把"端口在前"原文写进 uci（裸 counter drop 全断网）、
# 不生成 block port N to X（无协议端口被清空）、协议位白名单后小写化
# 复用 walledgarden 的 WG_ERRS / WG_SEEN / wg_dom_ok / wg_get_b64 /
# wg_detect_mode / wg_json_list / wg_reset（本页另用独立前缀变量）
# ============================================================

ac_emit() { # $1=proto(空=无协议位) $2=port(空=无端口位) $3=target
	local rule
	if [ -n "$1" ]; then
		rule="block $1 port $2 to $3"
	else
		rule="block to $3"
	fi
	case "$WG_SEEN" in
		*"|$rule|"*) return 0 ;;
	esac
	WG_SEEN="$WG_SEEN|$rule|"
	WG_RULES="$WG_RULES$rule
"
	WG_N=$((WG_N + 1))
	return 0
}

ac_portlist_parse() { # $1=行号 $2=portlist → WG_PORTS_LINE；失败 rc=1
	local rest p seen=' ' out=''
	case "$2" in
		*-*)
			wg_err "$1" '不支持端口范围，请逐个端口写'
			return 1
			;;
	esac
	case "$2" in
		*[!0-9,]*)
			case "$2" in
				*,*) wg_err "$1" '端口列表格式不正确，用英文逗号分隔，如 `80,443`' ;;
				*) wg_err "$1" '端口必须是 1-65535 的整数' ;;
			esac
			return 1
			;;
	esac
	case "$2" in
		*,,* | ,* | *,)
			wg_err "$1" '端口列表格式不正确，用英文逗号分隔，如 `80,443`'
			return 1
			;;
	esac
	rest="$2"
	while [ -n "$rest" ]; do
		p="${rest%%,*}"
		case "$rest" in
			*,*) rest="${rest#*,}" ;;
			*) rest='' ;;
		esac
		p=$(rt_num_val "$p") || {
			wg_err "$1" '端口必须是 1-65535 的整数'
			return 1
		}
		if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
			wg_err "$1" '端口必须是 1-65535 的整数'
			return 1
		fi
		case "$seen" in
			*" $p "*) continue ;;
		esac
		seen="$seen $p "
		out="$out $p"
	done
	WG_PORTS_LINE="${out# }"
	return 0
}

ac_mask_ok() { # $1=CIDR 掩码 → 0..32
	local m
	m=$(rt_num_val "$1") || return 1
	[ "$m" -le 32 ] 2>/dev/null || return 1
	return 0
}

# 域名 | IPv4 | IPv4 CIDR → WG_TGT（域名小写）；失败 rc=1
ac_target_norm() { # $1=行号 $2=target
	case "$2" in
		*/*)
			case "${2%%/*}" in
				'' | *[!0-9.]*)
					wg_err "$1" 'IP 地址格式不正确'
					return 1
					;;
			esac
			if rt_ip_ok "${2%%/*}" && ac_mask_ok "${2#*/}"; then
				WG_TGT="$2"
				return 0
			fi
			wg_err "$1" 'IP 地址格式不正确'
			return 1
			;;
		*:*)
			wg_err "$1" 'IP 地址格式不正确'
			return 1
			;;
		*[!0-9.]*)
			WG_TGT=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
			wg_dom_ok "$WG_TGT" && return 0
			wg_err "$1" '域名格式不正确'
			return 1
			;;
		*)
			rt_ip_ok "$2" && {
				WG_TGT="$2"
				return 0
			}
			wg_err "$1" 'IP 地址格式不正确'
			return 1
			;;
	esac
}

# 手动阻止文本 → WG_RULES（展开后的 block 条目）/ WG_ERRS / WG_N
ac_parse_text() { # $1=文本
	local line ln=0 f1 f2 f3 oldifs p f1low
	while IFS= read -r line || [ -n "$line" ]; do
		ln=$((ln + 1))
		line=$(printf '%s' "$line" | tr -d '\r')
		line=$(rt_trim "$line")
		[ -n "$line" ] || continue
		oldifs="$IFS"
		set -- $line
		IFS="$oldifs"
		f1="${1:-}"
		f2="${2:-}"
		f3="${3:-}"
		case $# in
			1)
				case "$f1" in
					# 含连字符（8000-8100）是端口段，不是目标（§5.4）
					*-*)
						wg_err "$ln" '不支持端口范围，请逐个端口写'
						;;
					*[!0-9]*)
						ac_target_norm "$ln" "$f1" && ac_emit '' '' "$WG_TGT"
						;;
					*) wg_err "$ln" '缺少域名或 IP' ;;
				esac
				;;
			2)
				case "$f1" in
					*[!0-9,]*)
						f1low=$(printf '%s' "$f1" | tr 'A-Z' 'a-z')
						case "$f1low" in
							tcp | udp | tcp/udp)
								case "$f2" in
									# `tcp 443`（端口在、目标缺）→ 缺少域名或 IP（§5.4）
									*[!0-9]*)
										wg_err "$ln" '`tcp`/`udp` 后必须跟端口号；想拦所有协议直接写域名或 IP'
										;;
									*) wg_err "$ln" '缺少域名或 IP' ;;
								esac
								;;
							*.*) wg_err "$ln" '格式不正确，支持 `域名或IP`、`端口 域名或IP`、`协议 端口 域名或IP`' ;;
							*) wg_err "$ln" '协议只能是 tcp、udp 或 tcp/udp' ;;
						esac
						;;
					*)
						ac_portlist_parse "$ln" "$f1" || continue
						ac_target_norm "$ln" "$f2" || continue
						for p in $WG_PORTS_LINE; do
							ac_emit tcp "$p" "$WG_TGT"
							ac_emit udp "$p" "$WG_TGT"
						done
						;;
				esac
				;;
			3)
				case "$f1" in
					*[!0-9]*)
						f1low=$(printf '%s' "$f1" | tr 'A-Z' 'a-z')
						case "$f1low" in
							tcp | udp)
								ac_portlist_parse "$ln" "$f2" || continue
								ac_target_norm "$ln" "$f3" || continue
								for p in $WG_PORTS_LINE; do
									ac_emit "$f1low" "$p" "$WG_TGT"
								done
								;;
							tcp/udp)
								ac_portlist_parse "$ln" "$f2" || continue
								ac_target_norm "$ln" "$f3" || continue
								for p in $WG_PORTS_LINE; do
									ac_emit tcp "$p" "$WG_TGT"
									ac_emit udp "$p" "$WG_TGT"
								done
								;;
							*.*) wg_err "$ln" '格式不正确，支持 `域名或IP`、`端口 域名或IP`、`协议 端口 域名或IP`' ;;
							*) wg_err "$ln" '协议只能是 tcp、udp 或 tcp/udp' ;;
						esac
						;;
					*) wg_err "$ln" '多个端口之间用英文逗号分隔，如 `80,443`' ;;
				esac
				;;
			*)
				wg_err "$ln" '格式不正确，支持 `域名或IP`、`端口 域名或IP`、`协议 端口 域名或IP`'
				;;
		esac
	done <<EOF2
$1
EOF2
	return 0
}

# 自动阻止域名文本 → WG_FQDNS（换行分隔，小写去重）
ac_parse_domains() { # $1=文本
	local line ln=0 d
	while IFS= read -r line || [ -n "$line" ]; do
		ln=$((ln + 1))
		line=$(printf '%s' "$line" | tr -d '\r')
		line=$(rt_trim "$line")
		[ -n "$line" ] || continue
		case "$line" in
			*[!0-9]*) ;;
			*)
				# 纯数字 = 端口行（443），端口只能填端口框（§5.3）
				wg_err "$ln" '只能填域名，一行一个'
				continue
				;;
		esac
		case "$line" in
			*' '* | *"	"*)
				wg_err "$ln" '只能填域名，一行一个'
				continue
				;;
		esac
		case "$line" in
			*[!0-9./]*) ;; # 含其它字符 → 域名候选
			*)
				wg_err "$ln" '自动阻止只接受域名；IP 请填到手动阻止'
				continue
				;;
		esac
		case "$line" in
			*:*)
				wg_err "$ln" '自动阻止只接受域名；IP 请填到手动阻止'
				continue
				;;
		esac
		d=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
		wg_dom_ok "$d" || {
			wg_err "$ln" '域名格式不正确'
			continue
		}
		case "$WG_FSEEN" in
			*"|$d|"*) continue ;;
		esac
		WG_FSEEN="$WG_FSEEN|$d|"
		WG_FQDNS="$WG_FQDNS$d
"
	done <<EOF2
$1
EOF2
	return 0
}

# 端口框（明文，逗号/空格分隔）→ WG_PORTS；失败 rc=1（决策 #8，错误算独立提示）
ac_parse_ports() { # $1=ports
	local s="$1" p rest seen=' ' out=''
	case "$s" in
		*，* | *；*)
			wg_err 0 '端口必须使用英文逗号分隔'
			return 1
			;;
	esac
	case "$s" in
		*-*)
			wg_err 0 '不支持端口范围，请逐个端口写'
			return 1
			;;
	esac
	case "$s" in
		*[!0-9,\ ]*)
			wg_err 0 '端口必须是 1-65535 的整数'
			return 1
			;;
	esac
	case "$s" in
		*,,* | ,* | *,)
			wg_err 0 '端口列表格式不正确，用英文逗号分隔，如 `80,443`'
			return 1
			;;
	esac
	rest=$(printf '%s' "$s" | tr ',\t' '  ')
	for p in $rest; do
		p=$(rt_num_val "$p") || {
			wg_err 0 '端口必须是 1-65535 的整数'
			return 1
		}
		if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
			wg_err 0 '端口必须是 1-65535 的整数'
			return 1
		fi
		case "$seen" in
			*" $p "*) continue ;;
		esac
		seen="$seen $p "
		out="$out $p"
	done
	WG_PORTS="${out# }"
	return 0
}

# authenticated_users 的 block 条目（换行分隔）→ 简写文本（§5.6 反解析）
# 非 block 条目不显示、不动（决策 #13）
ac_reverse() { # $1=全部条目
	local v rest p t out='' pend='' pendp='' pendt=''
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		v=$(rt_trim "$v")
		[ -n "$v" ] || continue
		case "$v" in
			block*) ;;
			*) continue ;; # allow / passthrough 等不认领
		esac
		case "$v" in
			'block tcp port '*)
				rest="${v#block tcp port }"
				case "$rest" in
					*' to '*)
						p="${rest%% to *}"
						t="${rest#* to }"
						if [ -n "$pend" ]; then
							out="${out}tcp $pendp $pendt
"
							pend=''
						fi
						if rt_is_num "$p" && [ -n "$t" ]; then
							pend=1
							pendp="$p"
							pendt="$t"
						else
							out="${out}$v
"
						fi
						;;
					*) out="${out}$v
" ;;
				esac
				;;
			'block udp port '*)
				rest="${v#block udp port }"
				case "$rest" in
					*' to '*)
						p="${rest%% to *}"
						t="${rest#* to }"
						if [ -n "$pend" ] && [ "$pendp" = "$p" ] && [ "$pendt" = "$t" ]; then
							out="${out}$p $t
"
							pend=''
						else
							if [ -n "$pend" ]; then
								out="${out}tcp $pendp $pendt
"
								pend=''
							fi
							out="${out}udp $p $t
"
						fi
						;;
					*) out="${out}$v
" ;;
				esac
				;;
			'block port '*)
				rest="${v#block port }"
				case "$rest" in
					*' to '*)
						p="${rest%% to *}"
						t="${rest#* to }"
						if [ -n "$pend" ]; then
							out="${out}tcp $pendp $pendt
"
							pend=''
						fi
						if rt_is_num "$p" && [ -n "$t" ]; then
							# 历史遗留：实际拦的是 T 的所有端口，纠正成两条（§5.6 第 4 条）
							out="${out}tcp $p $t
udp $p $t
"
						else
							out="${out}$v
"
						fi
						;;
					*) out="${out}$v
" ;;
				esac
				;;
			'block to '*)
				if [ -n "$pend" ]; then
					out="${out}tcp $pendp $pendt
"
					pend=''
				fi
				out="${out}${v#block to }
"
				;;
			'block all to '*)
				if [ -n "$pend" ]; then
					out="${out}tcp $pendp $pendt
"
					pend=''
				fi
				out="${out}${v#block all to }
"
				;;
			*)
				if [ -n "$pend" ]; then
					out="${out}tcp $pendp $pendt
"
					pend=''
				fi
				out="${out}$v
"
				;;
		esac
	done <<EOF2
$1
EOF2
	if [ -n "$pend" ]; then
		out="${out}tcp $pendp $pendt
"
	fi
	printf '%s' "$out"
	return 0
}

ac_status() {
	nds_conf_ok || out_err '未找到 openNDS 配置'
	local text='' auto='' ports='' list blocks
	list=$(cache_pairs 'opennds.@opennds[0].authenticated_users')
	blocks=''
	[ -n "$list" ] && blocks=$(printf '%s\n' "$list" | awk '/^block/')
	[ -n "$blocks" ] && text=$(ac_reverse "$blocks")
	list=$(cache_pairs 'opennds.@opennds[0].blocklist_fqdn_list')
	[ -n "$list" ] && auto="$list"
	list=$(cache_pairs 'opennds.@opennds[0].blocklist_port_list')
	[ -n "$list" ] && ports=$(printf '%s\n' "$list" | awk 'NR>1{printf ","} {printf "%s",$0}')
	printf '{"ok":1,"enabled":%s,"manual":"%s","auto":"%s","ports":"%s","bl_mode":"%s"}\n' \
		"$(nds_enabled)" \
		"$(json_escape_nl "$text")" \
		"$(json_escape_nl "$auto")" \
		"$(json_escape "$ports")" \
		"$(wg_detect_mode)"
}

ac_common() { # $@: manual_b64 auto_b64 ports → 校验全部通过 rc=0；有错已输出应答 rc=1
	local text atext ports_s
	text=$(wg_get_b64 manual_b64 "$@") || return 1
	atext=$(wg_get_b64 auto_b64 "$@") || return 1
	ports_s=$(rt_get_arg ports "$@") || out_err '缺少 ports 参数'
	wg_reset
	ac_parse_text "$text"
	ac_parse_domains "$atext"
	ac_parse_ports "$ports_s"
	if [ -n "$WG_ERRS" ]; then
		printf '{"ok":0,"errors":[%s]}\n' "${WG_ERRS%,}"
		return 1
	fi
	# 只填端口不写域名 → 无法保存（决策 #7，前后端同一口径）
	if [ -z "$WG_FQDNS" ] && [ -n "$WG_PORTS" ]; then
		printf '{"ok":0,"error":"port_only"}\n'
		return 1
	fi
	return 0
}

ac_validate() { # $@: manual_b64 auto_b64 ports
	ac_common "$@" || return 0
	local r pj='' psep='' p po=0
	for p in $WG_PORTS; do
		pj="$pj$psep\"$p\""
		psep=','
	done
	# 最终 authenticated_users 全量（block 在前 + 原有非 block 条目），
	# 与 ac_apply 的写入结果一致，供前端 uci 暂存使用
	local fjson='' fsep='' existing
	existing=$(cache_pairs 'opennds.@opennds[0].authenticated_users')
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		fjson="$fjson$fsep\"$(json_escape "$r")\""
		fsep=','
	done <<EOF2
$WG_RULES
EOF2
	if [ -n "$existing" ]; then
		while IFS= read -r r; do
			[ -n "$r" ] || continue
			case "$r" in
				block*) continue ;;
			esac
			fjson="$fjson$fsep\"$(json_escape "$r")\""
		done <<EOF2
$existing
EOF2
	fi
	printf '{"ok":1,"manual_rules":%s,"fqdns":%s,"ports":[%s],"port_only":%s,"final_list":[%s]}\n' \
		"$(wg_json_list "$WG_RULES")" \
		"$(wg_json_list "$WG_FQDNS")" \
		"$pj" "$po" "$fjson"
}

ac_apply() { # $@: manual_b64 auto_b64 ports [confirm_enable=1]
	local a
	for a in "$@"; do
		case "$a" in
			confirm_enable=1) CONFIRM_ENABLE=1 ;;
		esac
	done
	ac_common "$@" || return 0
	guard_enable || return 0
	acquire_lock
	nds_conf_ok || out_err '未找到 openNDS 配置'
	mkdir -p "$RT_BAK_DIR" 2>/dev/null
	cp "$OPENNDS_CONF" "$RT_BAK_DIR/opennds.bak" 2>/dev/null ||
		out_err '无法备份 openNDS 配置'
	local fail=0 r existing
	# 重建前先把原有条目完整读出来（§5.7：非 block 条目原样保留、不许换位置）
	existing=$(cache_pairs 'opennds.@opennds[0].authenticated_users')
	uci -q delete 'opennds.@opennds[0].authenticated_users' 2>/dev/null
	# 1) 新 block 条目在前（决策 #14：链内顺序 = list 顺序，先写的在上）
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		uci add_list 'opennds.@opennds[0].authenticated_users'="$r" || { fail=1; fail_at 'authenticated_users(block) 写入'; }
	done <<EOF2
$WG_RULES
EOF2
	# 2) 非 block 条目（allow/passthrough）按原顺序跟在后面
	if [ -n "$existing" ]; then
		while IFS= read -r r; do
			[ -n "$r" ] || continue
			case "$r" in
				block*) continue ;;
			esac
			uci add_list 'opennds.@opennds[0].authenticated_users'="$r" || { fail=1; fail_at 'authenticated_users(allow) 写入'; }
		done <<EOF2
$existing
EOF2
	fi
	uci -q delete 'opennds.@opennds[0].blocklist_fqdn_list' 2>/dev/null
	uci -q delete 'opennds.@opennds[0].blocklist_port_list' 2>/dev/null
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		uci add_list 'opennds.@opennds[0].blocklist_fqdn_list'="$r" || { fail=1; fail_at 'blocklist_fqdn_list 写入'; }
	done <<EOF2
$WG_FQDNS
EOF2
	for r in $WG_PORTS; do
		uci add_list 'opennds.@opennds[0].blocklist_port_list'="$r" || { fail=1; fail_at 'blocklist_port_list 写入'; }
	done
	if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
		uci set 'opennds.@opennds[0].enabled'=1
		EN_BY_APPLY=1
	fi
	uci commit opennds || { fail=1; fail_at 'opennds commit'; }
	if [ "$fail" = '1' ]; then
		uci revert opennds 2>/dev/null
		cp "$RT_BAK_DIR/opennds.bak" "$OPENNDS_CONF" 2>/dev/null
		out_err "写入配置失败（$FAIL_STEP），已回滚"
	fi
	if service_restart; then
		printf '{"ok":1,"restarted":'"$SR_RESTARTED"',"warnings":[],"enabled_by_apply":%s}\n' "$EN_BY_APPLY"
	else
		printf '{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}\n'
	fi
}

# ============================================================
# 页面：settings（《OpenNDS设置.md》§6）
# 只碰三个键：fup_upload_throttle_rate / fup_download_throttle_rate /
# gatewayinterface，外加 cpd/default/<tab>/default.sh 门户文件
# ============================================================

ST_TABS='|wireless|wired|'

st_tab_ok() { # $1=tab（白名单防目录穿越）
	case "$ST_TABS" in
		*"|$1|"*) return 0 ;;
	esac
	return 1
}

st_iface_exists() { # $1=接口名 → 在 ip -4 -o addr show 里
	ip -4 -o addr show 2>/dev/null | awk -v n="$1" '$2 == n { f = 1 } END { exit !f }'
}

# 公平使用策略开关：zone_detect 里存过就以它为准；没存过按 openNDS 现有速率推断
fup_enabled_val() {
	local v u d
	v=$(uci_val 'zone_detect.main.fup_enabled' '')
	case "$v" in
		1) printf '1'; return 0 ;;
		0) printf '0'; return 0 ;;
	esac
	u=$(uci_val 'opennds.@opennds[0].fup_upload_throttle_rate' '0')
	d=$(uci_val 'opennds.@opennds[0].fup_download_throttle_rate' '0')
	int_valid "$u" || u=0
	int_valid "$d" || d=0
	if [ "$u" = '0' ] && [ "$d" = '0' ]; then printf '0'; else printf '1'; fi
}

st_fup_split() { # $1=原始值 → stdout "动作|数值"（0/未设/空/脏值 → reject|0）
	local v
	case "$1" in
		'' | 0) printf 'reject|0' ;;
		*)
			v=$(rt_num_val "$1") || {
				printf 'reject|0'
				return 0
			}
			if [ "$v" -ge 1 ]; then
				printf 'limit|%s' "$v"
			else
				printf 'reject|0'
			fi
			;;
	esac
	return 0
}

# 列某类型的可选门户（不含内置 default.sh）→ "name<TAB>kind" 行
st_portal_items() { # $1=tab
	local d="$CPD_ROOT/default/$1" f b
	[ -d "$d" ] || return 0
	for f in "$d"/*; do
		[ -e "$f" ] || continue
		b="${f##*/}"
		case "$b" in
			.* | default.sh | default) continue ;;
		esac
		if [ -f "$f" ]; then
			case "$b" in
				*.sh) printf '%s\tfile\n' "$b" ;;
			esac
		elif [ -d "$f" ] && [ -f "$f/theme.sh" ]; then
			printf '%s\tdir\n' "$b"
		fi
	done
	return 0
}

st_status() {
	nds_conf_ok || out_err '未找到 openNDS 配置'
	local up dw upa upr dwa dwr ifc dev pj='' sep='' t b ij='' isep='' n ipaddr
	up=$(st_fup_split "$(uci_val 'opennds.@opennds[0].fup_upload_throttle_rate' '0')")
	dw=$(st_fup_split "$(uci_val 'opennds.@opennds[0].fup_download_throttle_rate' '0')")
	upa="${up%%|*}"
	upr="${up#*|}"
	dwa="${dw%%|*}"
	dwr="${dw#*|}"
	# 每个类型：当前选中的门户（空=内置 default.sh）+ 可选项（上传时保留的原名）
	local sel items isep2 pn pk
	for t in wireless wired; do
		sel=$(uci_val "zone_detect.main.portal_$t" '')
		[ "$sel" = 'default' ] && sel=''
		[ -n "$sel" ] && ! z_portal_exists "$CPD_ROOT/default/$t" "$sel" && sel=''
		items=''
		isep2=''
		while IFS='	' read -r pn pk; do
			[ -n "$pn" ] || continue
			items="$items$isep2\"$(json_escape "$pn")\""
			isep2=','
		done <<EOF3
$(st_portal_items "$t")
EOF3
		pj="$pj$sep\"$t\":{\"sel\":\"$(json_escape "$sel")\",\"builtin\":$(
			[ -f "$CPD_ROOT/default/$t/default.sh" ] && printf 'true' || printf 'false'
		),\"items\":[$items]}"
		sep=','
	done
	# 接口列表：只列有 IPv4 的，排除 lo/虚拟隧道/wan 侧设备，同名只取第一条
	local wanskip=' ' i=0 zname nets nd dv w
	while :; do
		zname=$(uci -q get "firewall.@zone[$i].name" 2>/dev/null) || break
		case "$zname" in
			wan | wan6 | wwan)
				nets=$(uci -q get "firewall.@zone[$i].network" 2>/dev/null)
				for nd in $nets; do
					wanskip="$wanskip$nd "
					dv=$(uci -q get "network.$nd.device" 2>/dev/null)
					for w in $dv; do wanskip="$wanskip$w "; done
					dv=$(uci -q get "network.$nd.ifname" 2>/dev/null)
					for w in $dv; do wanskip="$wanskip$w "; done
				done
				;;
		esac
		i=$((i + 1))
	done
	local ifl ordered='' n ipaddr
	ifl=$(ip -4 -o addr show 2>/dev/null | awk -v wl="$wanskip" '
		function skip(n) {
			return n == "lo" || n ~ /^docker/ || n ~ /^veth/ ||
			       n ~ /^ppp/ || n ~ /^tun/ || n ~ /^tap/ || n ~ /^wg/ ||
			       n ~ /^wan/ || n ~ /^wwan/ || index(wl, " " n " ") > 0
		}
		{
			split($4, a, "/")
			if ($2 != "" && !($2 in s) && !skip($2)) { s[$2] = 1; print $2 "\t" a[1] }
		}')
	ifc=$(uci_val 'opennds.@opennds[0].gatewayinterface' 'br-lan')
	[ -n "$ifc" ] || ifc='br-lan'
	dev="$ifc"
	# 配置值对不上接口列表 → 试着用 network.<值>.device 换设备名（只为高亮，不反写）
	if ! st_iface_exists "$ifc"; then
		local rd
		rd=$(uci -q get "network.$ifc.device" 2>/dev/null)
		if [ -n "$rd" ] && st_iface_exists "$rd"; then
			dev="$rd"
		fi
	fi
	# 正在使用的设备永远排第一，其余按系统顺序
	while IFS='	' read -r n ipaddr; do
		[ -n "$n" ] || continue
		if [ "$n" = "$dev" ]; then
			ordered="$n	$ipaddr
$ordered"
		else
			ordered="$ordered$n	$ipaddr
"
		fi
	done <<EOF2
$ifl
EOF2
	while IFS='	' read -r n ipaddr; do
		[ -n "$n" ] || continue
		ij="$ij$isep{\"name\":\"$(json_escape "$n")\",\"ip\":\"$(json_escape "$ipaddr")\"}"
		isep=','
	done <<EOF2
$ordered
EOF2
	local fup_en
	fup_en=$(fup_enabled_val)
	printf '{"ok":1,"enabled":%s,"portals":{%s},"fupEnabled":%s,"fup":{"upAction":"%s","upRate":%s,"downAction":"%s","downRate":%s},"iface":"%s","device":"%s","ifaces":[%s]}\n' \
		"$(nds_enabled)" "$pj" "$fup_en" "$upa" "$upr" "$dwa" "$dwr" \
		"$(json_escape "$ifc")" "$(json_escape "$dev")" "$ij"
}

st_upload_mkdir() { # $1=tab $2=id $3=文件夹原名 [$4=相对子路径（建嵌套目录用）]
	st_tab_ok "$1" || out_err '目标类型非法'
	local tab="$1" id="$2" name="$3" sub="${4:-}"
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	[ "$(name_bytes "$name")" -le 31 ] 2>/dev/null ||
		out_err '文件名过长（最多 31 个字符）'
	name_ok "$name" 31 || out_err '文件名含非法字符，无法上传'
	# 子路径逐段校验（名称规则同 name_ok）
	if [ -n "$sub" ]; then
		case "$sub" in
			/* | *//*) out_err '子路径非法' ;;
		esac
		local seg oldifs="$IFS"
		IFS='/'
		for seg in $sub; do
			[ -n "$seg" ] || continue
			name_ok "$seg" 31 || out_err '子路径含非法名称'
		done
		IFS="$oldifs"
	fi
	[ -d "$ZONE_UP/$id" ] || out_err '上传会话不存在或已过期，请重新上传'
	acquire_lock
	mkdir -p "$ZONE_UP/$id/$name${sub:+/$sub}" 2>/dev/null || out_err '无法创建上传临时文件夹'
	mkdir -p "$CPD_ROOT/default/$tab" 2>/dev/null || out_err '无法创建目标目录'
	printf '{"ok":1}\n'
}

# 互斥覆盖：default/<tab>/ 下要么一个单文件要么一个文件夹，
# 上传新的就把旧的（除内置 default.sh 外）全部删掉
st_clean_portal_dir() { # $1=目录 $2=保留名
	local dir="$1" keep="$2" f b
	for f in "$dir"/*; do
		[ -e "$f" ] || continue
		b="${f##*/}"
		case "$b" in
			default.sh) continue ;;
			"$keep" | "$keep.tmp") continue ;;
		esac
		rm -rf "$f" 2>/dev/null
	done
	return 0
}

st_upload_default() { # $1=tab $2=id $3=kind(file|dir) $4=文件名（保留上传时的原名落盘）
	st_tab_ok "$1" || out_err '目标类型非法'
	local tab="$1" id="$2" kind="$3" name="$4"
	case "$id" in
		'' | *[!A-Za-z0-9]*) out_err '上传 id 非法' ;;
	esac
	case "$kind" in
		file | dir) ;;
		*) out_err 'kind 必须是 file 或 dir' ;;
	esac
	[ "$(name_bytes "$name")" -le 31 ] 2>/dev/null ||
		out_err '文件名过长（最多 31 个字符）'
	name_ok "$name" 31 || out_err '文件名含非法字符，无法上传'
	local tmp="$ZONE_UP/$id/$name"
	if [ "$kind" = 'file' ]; then
		case "$name" in
			*.sh) ;;
			*) out_err '只接受 .sh 门户脚本，或包含 theme.sh 的文件夹' ;;
		esac
		[ -f "$tmp" ] || out_err '上传会话不存在或已过期，请重新上传'
		local sz
		sz=$(wc -c <"$tmp" 2>/dev/null | tr -d ' ')
		[ -n "$sz" ] && [ "$sz" -gt 0 ] || out_err '文件内容为空'
		[ "$sz" -le 524288 ] || out_err '文件过大（上限 512KB）'
		file_is_text "$tmp" || out_err '只支持文本脚本，二进制文件无法上传'
	else
		[ -d "$tmp" ] || out_err '上传会话不存在或已过期，请重新上传'
		[ -f "$tmp/theme.sh" ] || out_err '只接受 .sh 门户脚本，或包含 theme.sh 的文件夹'
	fi
	acquire_lock
	local dir="$CPD_ROOT/default/$tab"
	mkdir -p "$dir" 2>/dev/null || out_err '无法创建目标目录'
	if [ "$kind" = 'file' ]; then
		# 原子覆盖：先落同盘 .tmp 再 mv（避免 source 时读到半截文件）
		cp "$tmp" "$dir/$name.tmp" 2>/dev/null || out_err '写入门户文件失败'
		chmod 755 "$dir/$name.tmp" 2>/dev/null || {
			rm -f "$dir/$name.tmp" 2>/dev/null
			out_err '无法设置执行权限'
		}
		# 互斥覆盖：先清掉其它门户，再落位
		st_clean_portal_dir "$dir" "$name"
		mv "$dir/$name.tmp" "$dir/$name" 2>/dev/null || {
			rm -f "$dir/$name.tmp" 2>/dev/null
			out_err '替换门户文件失败'
		}
	else
		st_clean_portal_dir "$dir" "$name"
		rm -rf "$dir/$name" 2>/dev/null
		mv "$tmp" "$dir/$name" 2>/dev/null || out_err '门户文件夹入库失败'
		[ -d "$dir/$name" ] || out_err '门户文件夹入库失败（目标不是文件夹）'
		[ -f "$dir/$name/theme.sh" ] || out_err '门户文件夹里没有 theme.sh'
		# 让 SFTP / 其它账号也能进目录、读文件（a+rX：目录补 x，普通文件只加读）
		chmod 755 "$dir/$name" 2>/dev/null
		chmod -R a+rX "$dir/$name" 2>/dev/null
		chmod 755 "$dir/$name/theme.sh" 2>/dev/null
	fi
	# 清临时目录（id 已白名单校验，路径限定在 ZONE_UP 下）
	case "$ZONE_UP/$id" in
		"$ZONE_UP"/*) rm -rf "$ZONE_UP/$id" 2>/dev/null ;;
	esac
	printf '{"ok":1,"name":"%s","kind":"%s","path":"%s"}\n' \
		"$(json_escape "$name")" "$kind" \
		"$(json_escape "$dir/$name")"
}

st_portal_save() { # $1=tab $2=门户名（default/空 = 内置 default.sh）
	st_tab_ok "$1" || out_err '目标类型非法'
	acquire_lock
	local real
	real=$(sys_ensure_sec zone_detect main) ||
		out_err '写入配置失败：缺少 zone_detect 配置节'
	LAST_UCI_ERR=''
	case "$2" in
		'' | default)
			uci_w -q delete "zone_detect.$real.portal_$1" || :
			;;
		*)
			name_ok "$2" 31 || out_err '门户名非法'
			z_portal_exists "$CPD_ROOT/default/$1" "$2" || out_err '门户不存在'
			uci_w set "zone_detect.$real.portal_$1"="$2" || sys_stage_fail
			;;
	esac
	uci_w commit zone_detect || sys_stage_fail
	printf '{"ok":1}\n'
}

st_clean_default() { # $1=tab $2=门户名（保留原名的那个文件/文件夹）
	st_tab_ok "$1" || out_err '目标类型非法'
	local tab="$1" name="$2"
	name_ok "$name" 31 || out_err '门户名非法'
	case "$name" in
		default.sh) out_err '内置默认门户不能清理' ;;
	esac
	acquire_lock
	local dir="$CPD_ROOT/default/$tab" sel removed=0 existed=0
	if [ -e "$dir/$name" ]; then
		existed=1
		rm -rf "$dir/$name" 2>/dev/null
		[ -e "$dir/$name" ] || removed=1
		[ "$removed" = '1' ] || out_err '清理失败：门户目录不可写'
	fi
	# 清掉正在使用的那一个时，把选择改回内置 default.sh（失败不阻断文件清理）
	sel=$(uci_val "zone_detect.main.portal_$tab" '')
	if [ "$sel" = "$name" ]; then
		uci -q delete "zone_detect.main.portal_$tab" 2>/dev/null
		uci commit zone_detect 2>/dev/null
	fi
	printf '{"ok":1,"removed":%s}\n' "$removed"
}

st_rate_val() { # $1=动作 $2=速率 $3=结果变量名（直接调用，out_err 退出才有效）
	if [ "$1" = 'reject' ]; then
		eval "$3=0"
		return 0
	fi
	[ -n "$2" ] || out_err '请填写速率'
	local v
	v=$(rt_num_val "$2") || out_err '速率必须是大于 0 的整数'
	[ "$v" -ge 1 ] || out_err '速率必须是大于 0 的整数'
	[ "$v" -le 10000000 ] || out_err '速率过大，请检查单位是否为 Kb/s'
	eval "$3=\$v"
	return 0
}

st_apply() { # $@: up_action= up_rate= down_action= down_rate= iface= [fup_enabled=0|1] [confirm_enable=1]
	local a upa='' upr='' dwa='' dwr='' ifc='' uv=0 dv=0 fen=1
	for a in "$@"; do
		case "$a" in
			up_action=*) upa="${a#*=}" ;;
			up_rate=*) upr="${a#*=}" ;;
			down_action=*) dwa="${a#*=}" ;;
			down_rate=*) dwr="${a#*=}" ;;
			iface=*) ifc="${a#*=}" ;;
			fup_enabled=*) fen="${a#*=}" ;;
			confirm_enable=1) CONFIRM_ENABLE=1 ;;
		esac
	done
	case "$fen" in
		0 | 1) ;;
		*) out_err '公平使用策略开关值非法' ;;
	esac
	case "$upa" in
		limit | reject) ;;
		*) out_err '上传动作非法' ;;
	esac
	case "$dwa" in
		limit | reject) ;;
		*) out_err '下载动作非法' ;;
	esac
	[ -n "$ifc" ] || out_err '缺少网络接口'
	case "$ifc" in
		*[!A-Za-z0-9._-]* | .* | *..*) out_err '网络接口名非法' ;;
	esac
	st_iface_exists "$ifc" || out_err '网络接口不存在或没有 IPv4 地址'
	if [ "$fen" = '1' ]; then
		st_rate_val "$upa" "$upr" uv
		st_rate_val "$dwa" "$dwr" dv
	else
		# 开关关闭：清空速率，openNDS 侧即不启用配额限速
		uv=0
		dv=0
	fi
	guard_enable || return 0
	acquire_lock
	nds_conf_ok || out_err '未找到 openNDS 配置'
	mkdir -p "$RT_BAK_DIR" 2>/dev/null
	cp "$OPENNDS_CONF" "$RT_BAK_DIR/opennds.bak" 2>/dev/null ||
		out_err '无法备份 openNDS 配置'
	local fail=0
	uci set 'opennds.@opennds[0].fup_upload_throttle_rate'="$uv" || { fail=1; fail_at 'fup_upload_throttle_rate 写入'; }
	uci set 'opennds.@opennds[0].fup_download_throttle_rate'="$dv" || { fail=1; fail_at 'fup_download_throttle_rate 写入'; }
	uci set 'opennds.@opennds[0].gatewayinterface'="$ifc" || { fail=1; fail_at 'gatewayinterface 写入'; }
	uci set 'zone_detect.main.fup_enabled'="$fen" || { fail=1; fail_at 'fup_enabled 写入'; }
	if [ "$(nds_enabled)" = '0' ] && [ "$CONFIRM_ENABLE" = '1' ]; then
		uci set 'opennds.@opennds[0].enabled'=1
		EN_BY_APPLY=1
	fi
	uci commit opennds || { fail=1; fail_at 'opennds commit'; }
	uci commit zone_detect 2>/dev/null || true
	if [ "$fail" = '1' ]; then
		uci revert opennds 2>/dev/null
		cp "$RT_BAK_DIR/opennds.bak" "$OPENNDS_CONF" 2>/dev/null
		out_err "写入配置失败（$FAIL_STEP），已回滚"
	fi
	if service_restart; then
		printf '{"ok":1,"restarted":'"$SR_RESTARTED"',"enabled_by_apply":%s}\n' "$EN_BY_APPLY"
	else
		printf '{"ok":0,"error":"配置已写入，但 openNDS 未能启动，请检查日志"}\n'
	fi
}

# ============================================================
# 页面：sys（LuCI 框架保存/复位按钮的 uci 暂存通道）
# uci_stage 只写 /tmp/.uci 增量、不 commit —— openwrt 顶部的
# 「未保存的配置: N」指示器与复位按钮都以这份增量为数据源。
# ============================================================

SYS_CONFS='opennds|zone_detect'

sys_conf_ok() {
	case "$1" in
		opennds | zone_detect) return 0 ;;
	esac
	return 1
}

sys_sid_ok() { # section：匿名 @type[0] 与命名 section 都放行
	printf '%s' "$1" | grep -Eq '^[][A-Za-z0-9_@.-]+$'
}

sys_opt_ok() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]+$'
}

# uci 写操作的统一入口：/tmp/.uci 增量文件是全局锁，
# 多个进程同时写会拿到「Resource temporarily unavailable」，
# 这里对锁冲突重试，其它错误立刻上报并把 uci 原文留给前端。
LAST_UCI_ERR=''
uci_w() {
	local i=0 out rc
	while :; do
		out=$(uci "$@" 2>&1)
		rc=$?
		[ "$rc" -eq 0 ] && return 0
		LAST_UCI_ERR="$out"
		case "$out" in
			*'temporarily unavailable'* | *'Try again'* | *'locked'* | *'Locked'*) ;;
			*) return "$rc" ;;
		esac
		i=$((i + 1))
		[ "$i" -ge 4 ] && return "$rc"
		sleep 1
	done
}

sys_stage_fail() {
	if [ -n "$LAST_UCI_ERR" ]; then
		out_err "暂存配置失败：$LAST_UCI_ERR"
	fi
	out_err '暂存配置失败'
}

# 新建 section 时用的类型名（与出厂模板一致）
sys_sec_type() {
	printf '%s' "$1"
}

# 该配置里第一个 <type> 类型 section 的名字（匿名 section 会输出 @type[n]）
sys_find_sec() {
	uci show "$1" 2>/dev/null |
		awk -F'[.=]' -v t="$2" 'NF == 3 && $3 == t { print $2; exit }'
}

# 把页面传来的 section 引用落成「一定可写」的 section 名：
# 引用能解析就直接用；解析不到就先按出厂模板把 section 建出来
# （只在用户点保存/保存并应用时发生，安装时零写入）。
sys_ensure_sec() { # $1=config $2=sid → stdout 输出可写 section 名
	local conf="$1" sid="$2" typ name
	case "$sid" in
		@*)
			# 先直接探测 @type[n]：uci 能解析就说明这一节确实存在。
			# （只靠 uci show 的类型行去找，万一行缺失就会误建第二个同名节，
			#   而 openNDS 只认 @opennds[0]，写进去等于丢失）
			if uci -q show "$conf.$sid" >/dev/null 2>&1; then
				printf '%s' "$sid"
				return 0
			fi
			typ=$(printf '%s' "$sid" | sed -e 's/^@//' -e 's/\[.*$//')
			name=$(sys_find_sec "$conf" "$typ")
			if [ -n "$name" ]; then
				printf '%s' "$name"
				return 0
			fi
			uci_w set "$conf.cpd=$typ" || return 1
			printf 'cpd'
			;;
		*)
			if uci -q show "$conf.$sid" >/dev/null 2>&1; then
				printf '%s' "$sid"
				return 0
			fi
			uci_w set "$conf.$sid=$(sys_sec_type "$conf")" || return 1
			printf '%s' "$sid"
			;;
	esac
	return 0
}

# 直接数 /tmp/.uci 里的增量条目（ubus 那边读不到时，用来兜底显示「未保存的配置: N」）
sys_changes_count() {
	local n=0 f c
	for f in /tmp/.uci/*; do
		[ -f "$f" ] || continue
		c=$(grep -c '=' "$f" 2>/dev/null || echo 0)
		n=$((n + c))
	done
	printf '{"ok":1,"count":%s}\n' "$n"
}

sys_uci_stage() { # $1=config $2=section $3=option $4=opt|list [值…]
	local conf="$1" sid="$2" opt="$3" typ="$4" real
	shift 4
	sys_conf_ok "$conf" || out_err '配置名非法'
	sys_sid_ok "$sid" || out_err 'section 名非法'
	sys_opt_ok "$opt" || out_err 'option 名非法'
	case "$typ" in
		opt | list) ;;
		*) out_err '类型必须是 opt 或 list' ;;
	esac

	real=$(sys_ensure_sec "$conf" "$sid") ||
		out_err '暂存配置失败：找不到配置节，且无法新建（请检查 /etc/config 是否可写）'
	sid="$real"

	LAST_UCI_ERR=''
	case "$typ" in
		opt)
			if [ $# -eq 0 ]; then
				uci_w -q delete "$conf.$sid.$opt" || sys_stage_fail
			else
				uci_w set "$conf.$sid.$opt"="$1" || sys_stage_fail
			fi
			;;
		list)
			uci_w -q delete "$conf.$sid.$opt" || :
			local v
			for v in "$@"; do
				uci_w add_list "$conf.$sid.$opt"="$v" || sys_stage_fail
			done
			;;
	esac
	printf '{"ok":1}\n'
}

sys_uci_revert() { # $1=config → 丢弃该配置的未提交增量（复位按钮用）
	sys_conf_ok "$1" || out_err '配置名非法'
	uci revert "$1" 2>/dev/null
	printf '{"ok":1}\n'
}

# 写通道自检：在临时配置上跑 set / get / delete，把每一步的真实结果交回前端。
# 目的只有一个——暂存失败时能直接看到 uci 报的是什么，而不是一句笼统的失败。
sys_selftest() {
	local f="${CPD_PROBE_CONF:-/etc/config/cpd_probe}" rc seterr='' readv='' rcerr=''
	rm -f "$f" 2>/dev/null
	if ! printf "config main 'main'\n" >"$f" 2>/dev/null; then
		printf '{"ok":0,"step":"create","error":"%s"}\n' \
			"$(json_escape '/etc/config 不可写，无法创建临时配置')"
		return 0
	fi
	seterr=$(uci set cpd_probe.main.probe='1' 2>&1)
	rc=$?
	readv=$(uci -q get cpd_probe.main.probe 2>/dev/null)
	rcerr=$(uci -q delete cpd_probe.main.probe 2>&1)
	rm -f "$f" 2>/dev/null
	uci revert cpd_probe 2>/dev/null
	printf '{"ok":1,"set":%s,"setErr":"%s","read":"%s","delErr":"%s"}\n' \
		"$([ "$rc" -eq 0 ] && printf 1 || printf 0)" \
		"$(json_escape "$seterr")" "$(json_escape "$readv")" "$(json_escape "$rcerr")"
}

# 原生「保存并应用」commit 之后调用：只做运行时同步，一个字节的配置都不写
# （配置已经由 openwrt 自己的 uci apply 提交完毕）。
# ① 黑名单 MAC：摘信任、清预认证队列、踢下线
# ② 区域识别模式：把已提交的区域配置部署成门户目录与标记文件
# ③ 重启 openNDS，让新配置真正加载（它的 init 没有 procd reload trigger，
#    reload_config 不会动它）
sys_post_apply() {
	local m lm scope deployed=0 zr
	# 应用后先清掉名单里的重复条目（同一 MAC 只能有一个身份）：
	# 用户设备上历史遗留的"既在可信任又在黑名单"会在这里被修正
	sys_dedup_lists
	for m in $(list_of 'opennds.@opennds[0].blockedmac'); do
		[ -n "$m" ] || continue
		lm=$(mac_lower "$m")
		ndsctl_mac untrust "$lm"
		remove_preauth_queue "$lm"
		ndsctl_mac deauth "$lm"
	done

	scope=$(uci -q get 'zone_detect.main.scope' 2>/dev/null)
	if [ "$scope" = 'zone' ]; then
		# 用子 shell 跑：z_apply 校验失败会 out_err 直接 exit，
		# 不隔离的话会把 post_apply 一起带停、连 JSON 都吐不出来。
		# 判据必须看 z_apply 回的 JSON，不能看退出码 —— out_err 是 exit 0，
		# 光看退出码会把"什么都没做"当成部署成功。
		if [ -n "$(uci -q get 'zone_detect.main.wireless' 2>/dev/null)" ]; then
			zr=$( (z_apply wireless) 2>/dev/null )
			case "$zr" in
				*'"ok":1'*) deployed=1 ;;
				*need_confirm*) log 'post_apply：openNDS 处于停用状态，跳过无线区域部署' ;;
				*) log "post_apply：无线区域部署失败：$zr" ;;
			esac
		fi
		if [ -n "$(uci -q get 'zone_detect.main.wired' 2>/dev/null)" ]; then
			zr=$( (z_apply wired) 2>/dev/null )
			case "$zr" in
				*'"ok":1'*) deployed=1 ;;
				*need_confirm*) log 'post_apply：openNDS 处于停用状态，跳有线区域部署' ;;
				*) log "post_apply：有线区域部署失败：$zr" ;;
			esac
		fi
	fi

	kick_preemptive
	# z_apply 内部已经重启过，别再来一次
	[ "$deployed" = '1' ] && {
		printf '{"ok":1,"restarted":1,"zone":1}\n'
		return 0
	}
	if service_restart; then
		printf '{"ok":1,"restarted":%s,"zone":0}\n' "$SR_RESTARTED"
	else
		printf '{"ok":0,"error":"配置已提交，但 openNDS 未能启动，请检查日志"}\n'
	fi
}

# 设备原配置里的可信任客户端（随包提供，只读）与当前配置对比，返回缺的那几个。
# 本函数绝不写任何配置：用户点「恢复」只是把它们并进页面名单，仍要自己保存。

# ============================================================
# 旧版自建黑名单配置一次性迁移
# 旧版本把黑名单 MAC 存在插件自建的 /etc/config/zone_blacklist 里。
# 现在黑名单改用 openNDS 官方机制（/etc/config/opennds 的 blockedmac +
# macmechanism='block'）。检测到旧文件就把里面的 MAC 迁入官方名单，
# 然后删除旧文件——openNDS 只有一个配置文件，插件不再多建。
# ============================================================
ZONE_BLACKLIST_CONF="${ZONE_BLACKLIST_CONF:-/etc/config/zone_blacklist}"

# 确保 /etc/config/opennds 存在且有一个 opennds 类型节。
# 官方 opennds 包自带这个文件（opennds.conf 模板，节名就是 `config opennds`），
# 极简安装可能没有它 —— 前端 uci 暂存第一步 uci/load 读的就是这个文件，
# 缺了会报「RPC call to uci/get failed with ubus code 4: 未找到资源」。
# 缺文件/缺节时补一个空节并 commit（rpcd 的 uci/get 只认已提交内容）。
# 输出可写 section 名（'@opennds[0]' 或新建的 'cpd'），失败返回非 0。
ensure_opennds_conf() {
	local sid='@opennds[0]'
	if [ ! -f "$OPENNDS_CONF" ]; then
		touch "$OPENNDS_CONF" 2>/dev/null || return 1
	fi
	if uci -q show "opennds.$sid" >/dev/null 2>&1; then
		printf '%s' "$sid"
		return 0
	fi
	if ! uci_w set 'opennds.cpd=opennds'; then
		return 1
	fi
	uci commit opennds 2>/dev/null
	log "已补建缺失的 openNDS 配置节（$OPENNDS_CONF）"
	printf 'cpd'
	return 0
}

bl_migrate_legacy() {
	[ -f "$ZONE_BLACKLIST_CONF" ] || return 0
	local m any=0 osc cur
	osc=$(ensure_opennds_conf) || return 0
	cur=" $(list_of "opennds.$osc.blockedmac") "
	for m in $(list_of 'zone_blacklist.main.mac'); do
		mac_valid "$m" || continue
		m=$(mac_lower "$m")
		case "$cur" in
			*" $m "*) ;;
			*) uci add_list "opennds.$osc.blockedmac"="$m" 2>/dev/null && any=1 ;;
		esac
	done
	if [ "$any" = '1' ]; then
		ensure_block_mechanism "$osc"
		uci commit opennds 2>/dev/null
	fi
	rm -f "$ZONE_BLACKLIST_CONF" 2>/dev/null
	log '已迁移旧黑名单配置 /etc/config/zone_blacklist → opennds blockedmac，旧文件已删除'
	return 0
}

# ============================================================
# 主分发
# ============================================================

bl_migrate_legacy

case "$PAGE" in
	overview)
		SUB="${2:-}"
		[ $# -ge 2 ] || out_err 'overview：缺少子命令'
		shift 2
		strip_confirm "$@"
		# 摘掉 confirm_enable 后按位置还原参数
		set -- $ARGS
		case "$SUB" in
			status) ov_status ;;
			dashboard) ov_dashboard ;;
			run_state) ov_run_state ;;
			set_run) ov_set_run "$1" ;;
			restart) ov_restart ;;
			clients) ov_clients ;;
			client_detail) ov_client_detail "$1" ;;
			client_action) ov_client_action "$1" "$2" ;;
			client_edit) ov_client_edit apply "$@" ;;
			client_edit_stage) ov_client_edit stage "$@" ;;
			apply) ov_apply ;;
			*) out_err "overview：未知子命令 $SUB" ;;
		esac
		;;
	zone)
		[ $# -ge 2 ] || out_err 'zone：缺少子命令'
		SUB="$2"
		shift 2
		# save_cache 的对参数与上传的 zone 名可能含空格，
		# 除 apply 外都按位置直传，不走 strip_confirm 的空白重排
		case "$SUB" in
			status) z_status ;;
			uploaded) z_uploaded "$1" "$2" ;;
			upload_begin) z_upload_begin "$1" ;;
			upload_mkdir) z_upload_mkdir "$1" "$2" "$3" "$4" "$5" ;;
			upload_store) z_upload_store "$1" "$2" "$3" "$4" "$5" ;;
			upload_delete) z_upload_delete "$1" "$2" "$3" ;;
			save_cache) z_save_cache "$@" ;;
			apply)
				strip_confirm "$@"
				set -- $ARGS
				z_apply "$1"
				;;
			unmatched_list) z_unmatched_list ;;
			unmatched_delete) z_unmatched_delete "$1" "$2" ;;
			*) out_err "zone：未知子命令 $SUB" ;;
		esac
		;;
	session)
		[ $# -ge 2 ] || out_err 'session：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			get) se_get ;;
			save) se_save "$@" ;;
			apply)
				strip_confirm "$@"
				se_apply
				;;
			*) out_err "session：未知子命令 $SUB" ;;
		esac
		;;
	exempt)
		[ $# -ge 2 ] || out_err 'exempt：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			status) ex_status ;;
			save) ex_save "$@" ;;
			*) out_err "exempt：未知子命令 $SUB" ;;
		esac
		;;
	blacklist)
		[ $# -ge 2 ] || out_err 'blacklist：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			status) bl_status ;;
			portal_delete) bl_portal_delete "$@" ;;
			upload_begin) bl_upload_begin "$1" ;;
			upload_store) bl_upload_store "$1" "$2" ;;
			*) out_err "blacklist：未知子命令 $SUB" ;;
		esac
		;;
	router)
		[ $# -ge 2 ] || out_err 'router：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			status) rt_status ;;
			validate) rt_validate "$@" ;;
			apply) rt_apply "$@" ;;
			*) out_err "router：未知子命令 $SUB" ;;
		esac
		;;
	walledgarden)
		[ $# -ge 2 ] || out_err 'walledgarden：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			status) wg_status ;;
			validate) wg_validate "$@" ;;
			apply) wg_apply "$@" ;;
			*) out_err "walledgarden：未知子命令 $SUB" ;;
		esac
		;;
	access)
		[ $# -ge 2 ] || out_err 'access：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			status) ac_status ;;
			validate) ac_validate "$@" ;;
			apply) ac_apply "$@" ;;
			*) out_err "access：未知子命令 $SUB" ;;
		esac
		;;
	settings)
		[ $# -ge 2 ] || out_err 'settings：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			status) st_status ;;
			upload_begin) z_upload_begin "$1" ;;
			upload_mkdir) st_upload_mkdir "$1" "$2" "$3" "$4" ;;
			upload_default) st_upload_default "$1" "$2" "$3" "$4" ;;
			portal_save) st_portal_save "$1" "$2" ;;
			clean_default) st_clean_default "$1" "$2" ;;
			apply) st_apply "$@" ;;
			*) out_err "settings：未知子命令 $SUB" ;;
		esac
		;;
	sys)
		[ $# -ge 2 ] || out_err 'sys：缺少子命令'
		SUB="$2"
		shift 2
		case "$SUB" in
			uci_stage) [ $# -ge 3 ] || out_err 'uci_stage 需要 config section option 参数'; sys_uci_stage "$@" ;;
			uci_revert) [ $# -ge 1 ] || out_err 'uci_revert 需要 config 参数'; sys_uci_revert "$1" ;;
			changes_count) sys_changes_count ;;
			selftest) sys_selftest ;;
			post_apply) sys_post_apply ;;
			*) out_err "sys：未知子命令 $SUB" ;;
		esac
		;;
	'')
		out_err '缺少页面名'
		;;
	*)
		out_err "未知页面：$PAGE"
		;;
esac
