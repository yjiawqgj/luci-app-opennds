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
	local sub="$1" mac="$2"
	ndsctl "$sub" "$mac" >/dev/null 2>&1 || ndsctl "$sub" "$(mac_upper "$mac")" >/dev/null 2>&1
	# 用户口径（2026-11-21）：任何"改变客户端身份"的动作都要先清原状态再应用
	# 新状态。deauth（解除认证/移出名单/拉黑前的踢下线）是身份变更的统一落点，
	# 踢完立刻清掉该 mac 在 openNDS 两份落盘日志里的全部记录。
	# 顺序关键：必须在 ndsctl deauth 之后——deauth 自己会往 binauthlog 写一条
	# deauth 记录，清早了那条又留下。authlog 清掉后，NDS 重启的 auth_restore
	# 也遍历不到该 mac，不会又把它恢复成已认证。
	# deauth 失败（NDS 没运行）也照清：移出操作时 NDS 本来可能就是停的。
	[ "$sub" = 'deauth' ] && purge_client_logs "$mac"
	return 0
}

# 就绪判据：pidof 有值 且 ndsctl status 能成功。
# $1 = 轮数（默认 6；单轮 = ndsctl 限时 2 秒 + 间隔）。
# 轮数可调：rpcd exec 的硬上限是 120 秒（前端 XHR 约 20 秒会报超时），
# 同步路径控制在 20 秒内最好；后台 worker 无此约束，重启后用长预算。
wait_ready_n() {
	local i=0 n="${1:-6}"
	while [ "$i" -lt "$n" ]; do
		if [ -n "$(pidof opennds 2>/dev/null)" ] &&
			NDSCTL_TIMEOUT=2 ndsctl_run status >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.5 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	return 1
}

wait_ready() { wait_ready_n 6; }

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
#
# 重启必须严格顺序化：stop → 等进程真正退出 → 清链 → start → 等就绪。
# 不能用 /etc/init.d/opennds restart 一把梭：procd 对 stop 的应答是异步的
# （term_timeout 90 秒，官方 service_stopped 只等 10 秒就返回），旧进程可能
# 还没退干净 start 就已经把新实例注册进去了 —— 两个 opennds 互相抢端口/链，
# procd respawn 重试失败后整个服务停在「已停止」，页面上就是「保存并应用后
# NDS 变未运行」的根因。
# 等不到进程退出（极少见）才硬杀：此时实例已被 procd delete，不会触发 respawn。
NDS_INIT="${NDS_INIT:-/etc/init.d/opennds}"
LIBOPENNDS="${LIBOPENNDS:-/usr/lib/opennds/libopennds.sh}"
service_restart() {
	SR_RESTARTED=0
	nds_running || return 0
	SR_RESTARTED=1
	"$NDS_INIT" stop 9>&- >/dev/null 2>&1
	local i=0
	while nds_running && [ "$i" -lt "${CPD_STOP_WAIT:-45}" ]; do
		sleep 1 2>/dev/null || sleep 1
		i=$((i + 1))
	done
	if nds_running; then
		log "openNDS 停止超时（${CPD_STOP_WAIT:-45}s），强制结束进程"
		kill $(pidof opennds) 2>/dev/null
		sleep 1 2>/dev/null || sleep 1
		i=0
		while nds_running && [ "$i" -lt 5 ]; do
			sleep 1 2>/dev/null || sleep 1
			i=$((i + 1))
		done
	fi
	"$LIBOPENNDS" delete_chains 9>&- >/dev/null 2>&1
	"$NDS_INIT" start 9>&- >/dev/null 2>&1
	wait_ready_n "${CPD_READY_WAIT:-24}"
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
/^[[:space:]]*"[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
	line = $0
	sub(/\{[[:space:]]*$/, "", line)
	sub(/[[:space:]]*:[[:space:]]*$/, "", line)
	sub(/^[[:space:]]*"/, "", line)
	sub(/"[[:space:]]*$/, "", line)
	cur = line; in_c = 1
	next
}
in_c && /^[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/ {
	printf "S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
		cur, st[cur], ip[cur], cif[cur], ss[cur], se[cur], la[cur], \
		dlt[cur], ult[cur], davg[cur], uavg[cur], cty[cur], \
		drt[cur], urt[cur], dq[cur], uq[cur], cu[cur]
	in_c = 0; cur = ""
	next
}
in_c {
	s = $0
	sub(/^[[:space:]]+/, "", s)
	sub(/,[[:space:]]*$/, "", s)
	if (match(s, /^"[a-zA-Z_0-9]+"[[:space:]]*:[[:space:]]*".*"$/)) {
		kv = substr(s, RSTART, RLENGTH)
		sub(/^"/, "", kv)
		i = index(kv, "\"")
		k = (i > 0) ? substr(kv, 1, i - 1) : ""
		v = (i > 0) ? substr(kv, i + 1) : ""
		sub(/^[[:space:]]*:[[:space:]]*"/, "", v)
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
/^[[:space:]]*"trusted"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/ { in_t = 1; next }
in_t && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { in_t = 0; next }
in_t {
	s = $0
	sub(/^[[:space:]]+/, "", s)
	sub(/,[[:space:]]*$/, "", s)
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
	s=$(iw dev "$1" info 2>/dev/null | awk '/^[[:space:]]*ssid / {print $2; exit}')
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
# 接口 SSID 直读：iw 优先，没装 iw 用 iwinfo（openwrt 默认自带）
# iw 把非可打印字节转义成 \xNN——中文 SSID 在真机上就是
#   ssid \xe4\xba\x92\xe8\x81\x94\xe7\xbd\x91
# 直接拿去和 uci 里的「互联网」比永远不相等（AP 卡片匹配不到接口、
# 接入点列也就退回了接口名）。这里把 \xNN 解回原始 UTF-8 字节。
# 坑：printf %b 对 \xNN 的支持各 shell 不一致（dash 不认 \x，某些版本还会
# 按宽字符重新编码成 UTF-8 双字节），\0OOO 八进制转义则是 POSIX 都认的，
# 所以先把 \xNN 换算成 \0OOO 再交给 printf %b。
ssid_unescape() { # $1=可能带 \xNN 转义的 SSID
	case "$1" in
		*\\x*) ;;
		*) printf '%s' "$1"; return 0 ;;
	esac
	printf '%b' "$(printf '%s' "$1" | awk '{
		line = $0; out = ""
		while (match(line, /\\x[0-9a-fA-F][0-9a-fA-F]/)) {
			h = tolower(substr(line, RSTART + 2, 2))
			v = 0
			for (i = 1; i <= 2; i++)
				v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
			out = out substr(line, 1, RSTART - 1) \
				sprintf("\\0%d%d%d", int(v / 64), int(v % 64 / 8), v % 8)
			line = substr(line, RSTART + RLENGTH)
		}
		print out line
	}')"
}

iface_raw_ssid() { # $1=接口名
	local s=''
	if command -v iw >/dev/null 2>&1; then
		s=$(iw dev "$1" info 2>/dev/null | awk '/^[[:space:]]*ssid / {print $2; exit}')
		s=$(ssid_unescape "$s")
	fi
	if [ -z "$s" ] && command -v iwinfo >/dev/null 2>&1; then
		# iwinfo 输出：ESSID: "xxx"；unknown 时不带引号 → $2 为空
		s=$(iwinfo "$1" info 2>/dev/null | awk -F'"' '/ESSID:/ {print $2; exit}')
	fi
	printf '%s' "$s"
}

ap_runtime_if() { # $1=radio $2=ssid $3=序号
	local radio="$1" want="$2" idx="$3" ifn ssid i
	ifn=$(iw dev 2>/dev/null | awk -v radio="$radio" '
		/^phy#[0-9]+$/ { phy = "radio" substr($0, 5) }
		/^[[:space:]]*Interface [^[:space:]]+$/ { ifn = $2 }
		/^[[:space:]]*type [[:space:]]*AP[[:space:]]*$/ {
			if (ifn != "" && phy == radio) print ifn
			ifn = ""
		}')
	# 没有 iw 时的兜底：iwinfo 列出全部无线接口，只取 Master（AP）模式的。
	# 官方 get_client_interface.sh 在没 iw 时直接退 br-lan，SSID/接入点就
	# 全对不上了——openwrt 的 iwinfo 一直都在，LuCI 无线页用的就是它。
	if [ -z "$ifn" ] && command -v iwinfo >/dev/null 2>&1; then
		for i in $(iwinfo 2>/dev/null | awk '/^[A-Za-z0-9_.-]+[[:space:]]+ESSID:/ {print $1}'); do
			iwinfo "$i" info 2>/dev/null | grep -q 'Mode: Master' || continue
			ifn="$ifn $i"
		done
	fi
	# SSID 匹配优先
	for i in $ifn; do
		ssid=$(iface_raw_ssid "$i")
		[ -n "$want" ] && [ "$ssid" = "$want" ] && {
			printf '%s' "$i"
			return 0
		}
	done
	# 序号兜底
	[ "$idx" -gt 0 ] 2>/dev/null && {
		printf '%s\n' "$ifn" | tr ' ' '\n' | sed -n "${idx}p"
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
# ARP 邻居表「还连着」的状态判据：只认真正在通信的 REACHABLE / PERMANENT。
# STALE / DELAY / FAILED 是内核标记"设备可能已离开"的残留项——设备关了 WiFi
# 或拔了网线后，ARP 条目还会挂几分钟，其间会被误算成在线有线、接入点显示
# br-lan（真机反馈：卸载重装插件后，没开 WiFi 的设备仍进了有线卡，等缓存
# 到期才消失）。收紧到这两个状态，残留项一律不算在线。
neigh_live() { # $1=ARP 状态字符串 → 0=在线
	case "$1" in
		REACHABLE | PERMANENT) return 0 ;;
		*) return 1 ;;
	esac
}

neigh_ip_for() { # $1=小写 mac
	ip -4 neigh show 2>/dev/null |
		awk -v m="$1" 'tolower($4) == "lladdr" && tolower($5) == m && ($6 == "REACHABLE" || $6 == "PERMANENT") {print $1; exit}'
}

# 邻居表里的设备名（br-lan 等）：有线客户端的「接入点」一列要显示它。
# ndsctl 的 clientif 来自官方 get_client_interface.sh，探不到时是空串
# （真机上见过 clientif=""、ip 有值的行），这时只能从邻居表反查设备。
# 只认活跃状态：STALE 残留不再显示成 br-lan（非有线不显示成有线）。
neigh_dev_for() { # $1=小写 mac
	ip -4 neigh show 2>/dev/null |
		awk -v m="$1" 'tolower($4) == "lladdr" && tolower($5) == m && ($6 == "REACHABLE" || $6 == "PERMANENT") {print $3; exit}'
}

# network.wireless status（ubus）→ "section<TAB>ifname" 行。
# 这是 OpenWrt 运行时最权威的映射：uci 里配的是 section，真正跑起来的接口名
# （phyN-apM）只有 netifd 知道。之前只靠 iw 反查，机器上没装 iw 时全部为空，
# 无线接入点卡片就会一直显示 0。
ws_iface_map() {
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" | awk '
	function flush() {
		if (sec != "") printf "%s\t%s\n", sec, ifn
		sec = ""; ifn = ""
	}
	/"interfaces"[[:space:]]*:[[:space:]]*\[/ { in_if = 1; depth = 0; sec = ""; ifn = ""; next }
	!in_if { next }
	# 空对象 {} 不动层级（真机 radio/interface 的 config 可能是空表）
	/\{[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/ { next }
	# 任何以 { 结尾的行都开对象：netifd 的键序是 section → ifname → config，
	# config 是嵌套对象（mt76 等驱动的 config 里还会带 ifname 键），
	# 只认裸 { 的写法会把 config 内容当成本层字段，键序一变就全错
	/\{[[:space:]]*$/ { depth++; next }
	/\}[[:space:]]*,?[[:space:]]*$/ {
		if (depth == 1) flush()
		if (depth > 0) depth--
		next
	}
	depth == 1 && /"section"[[:space:]]*:/ {
		s = $0; sub(/.*"section"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*/, "", s); sec = s; next
	}
	depth == 1 && /"ifname"[[:space:]]*:/ {
		v = $0; sub(/.*"ifname"[[:space:]]*:[[:space:]]*"/, "", v); sub(/".*/, "", v); ifn = v; next
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

# 单个 AP 的关联终端表：mac<TAB>ifname。查询次序：
# ① hostapd ubus（权威；ubus_call 带 timeout，hostapd 不应答不会卡死）
# ② iw station dump（与官方 get_client_interface.sh 同款）
# ③ iwinfo assoclist（openwrt 默认自带，LuCI 无线页用的就是它；
#    没有 hostapd ubus 对象 / 没装 iw 的固件也能数出关联终端）
# 输出 mac<TAB>iface<TAB>关联秒数（拿不到时长填 -）。
# 第三列是「连上 WiFi 的时刻」的数据源：hostapd/iw 都给连接时长，
# 后端用当前时间减去它倒推出上线时刻；拿不到就留空，前端显示「—」。
# 前两列格式与旧版完全一致，STA_MAP 的下游（ov_conn/client_ssid 等）不受影响。
ws_sta_one() { # $1=运行时接口名
	local ifn="$1" got=''
	if command -v ubus >/dev/null 2>&1; then
		got=$(ubus_call call "hostapd.$ifn" get_clients |
		awk -v i="$ifn" '
		BEGIN { cur = "" }
		{
			s = $0
			m = "[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:" \
				"[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]"
			if (match(s, "\"" m "\"")) {
				k = substr(s, RSTART + 1, RLENGTH - 2)
				# 只要键值是 { 的（clients 对象的键），不要 "address":"<mac>" 这类值
				rest = substr(s, RSTART + RLENGTH)
				sub(/^[[:space:]]*/, "", rest)
				if (rest ~ /^[[:space:]]*:[[:space:]]*\{/) {
					if (cur != "") print cur "\t" i "\t" (sec[cur] == "" ? "-" : sec[cur])
					cur = tolower(k)
				}
			}
			# connected_time 是该客户端已关联的秒数，藏在 client 对象里
			if (cur != "" && match(s, /"connected_time"[[:space:]]*:[[:space:]]*[0-9]+/)) {
				t = substr(s, RSTART, RLENGTH)
				sub(/^[^:]*:/, "", t); gsub(/[[:space:]]/, "", t)
				sec[cur] = t
			}
		}
		END { if (cur != "") print cur "\t" i "\t" (sec[cur] == "" ? "-" : sec[cur]) }')
	fi
	if [ -z "$got" ] && command -v iw >/dev/null 2>&1; then
		got=$(iw dev "$ifn" station dump 2>/dev/null |
			awk -v i="$ifn" '
			/^[[:space:]]*Station[[:space:]]/ {
				if (cur != "") print cur "\t" i "\t" (sec == "" ? "-" : sec)
				cur = tolower($2); sec = ""
			}
			/connected time:/ { sec = $3 }
			END { if (cur != "") print cur "\t" i "\t" (sec == "" ? "-" : sec) }')
	fi
	if [ -z "$got" ] && command -v iwinfo >/dev/null 2>&1; then
		got=$(iwinfo "$ifn" assoclist 2>/dev/null |
			awk -v i="$ifn" '/^[0-9A-Fa-f][0-9A-Fa-f:]{15}[[:space:]]/ {print tolower($1) "\t" i "\t-"}')
	fi
	# 关联时长（详情「上线时间」数据源）：OpenWrt 官方 hostapd ubus get_clients
	# 不带 connected_time，ubus 路径第三列基本都是 -。iw station dump 才有
	# "connected time: N seconds"，单独查一次按 MAC 补进第三列；MAC/iface 仍
	# 以 ubus 为权威，这里只补时长，不改前两列。
	if [ -n "$got" ] && command -v iw >/dev/null 2>&1; then
		local secs tfa tfb
		secs=$(iw dev "$ifn" station dump 2>/dev/null |
			awk '/^[[:space:]]*Station[[:space:]]/ {cur = tolower($2)}
			     /connected time:/ { if (cur != "") print cur "\t" $3 }')
		if [ -n "$secs" ]; then
			# 时长表通过环境变量传给 awk，避免临时文件（ws_sta_map 是并行跑
			# ws_sta_one 的，后台子 shell 里建临时文件不稳）。
			got=$(printf '%s\n' "$got" | SECS="$secs" awk -F'\t' -v OFS='\t' '
				BEGIN { n = split(ENVIRON["SECS"], rows, "\n")
					for (i = 1; i <= n; i++) {
						if (rows[i] == "") continue
						split(rows[i], f, "\t"); s[f[1]] = f[2]
					}
				}
				$3 == "-" && ($1 in s) { $3 = s[$1] }
				{ print }')
		fi
	fi
	[ -n "$got" ] && printf '%s\n' "$got"
}

# hostapd ubus 的关联终端表：mac<TAB>ifname。
# openNDS 的 clientif 来自 get_client_interface.sh：机器上没装 iw 时退回
# ip -4 neigh 的设备列（br-lan），永远对不上 phyN-apM —— AP 卡片计数和
# 客户端 SSID 都不能靠 clientif，得按 MAC 反查关联表。
# hostapd 的 ubus 对象拿不到时（固件没带 hostapd ubus 支持）退回
# iw dev <接口> station dump；再拿不到就为空，AP 计数由 ov_aps 兜底。
# 各 AP 并行查：hostapd 不应答时单次要等 3 秒超时，串行跑 4 个 AP 最坏
# 12 秒——整个 dashboard 被拖慢，卡片十几秒才刷新（真机反馈）。
ws_sta_map() { # $1=AP_META（每行 iface<TAB>ssid<TAB>section）
	local ifn ifaces tmpd=''
	[ -n "$1" ] || return 0
	ifaces=$(printf '%s\n' "$1" | awk -F'\t' '$1 != "-" && $1 != "" {print $1}')
	[ -n "$ifaces" ] || return 0
	tmpd=$(mktemp -d 2>/dev/null) || tmpd=''
	if [ -z "$tmpd" ]; then
		# 拿不到临时目录（极少数只读 /tmp）退回串行
		for ifn in $ifaces; do
			ws_sta_one "$ifn"
		done
		return 0
	fi
	for ifn in $ifaces; do
		ws_sta_one "$ifn" >"$tmpd/$ifn" 2>/dev/null &
	done
	wait
	cat "$tmpd"/* 2>/dev/null
	rm -rf "$tmpd"
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

# 邻居表里有没有这个 MAC——有线设备「还连着」的判据（只认活跃状态）
neigh_has() { # $1=小写 mac
	command -v ip >/dev/null 2>&1 || return 1
	ip -4 neigh show 2>/dev/null |
		awk -v m="$1" 'tolower($4) == "lladdr" && tolower($5) == m && ($6 == "REACHABLE" || $6 == "PERMANENT") {f=1; exit} END {exit !f}'
}

# 管理接口上邻居表里的全部在线设备 MAC（小写，只认 REACHABLE/PERMANENT）：
# 有线在线 = 管理接口的邻居表 − 无线关联表。ARP 表里有它 = 正在跟路由器说话。
# 只认 $1（管理接口）这个 dev：WAN 口的网关 MAC 也在全局邻居表里，不按
# dev 过滤会把运营商网关当成"有线客户端"。不依赖 ndsctl——openNDS 没运行、
# 设备也没碰过门户，邻居表照样看得到它（可信任 / 有线台式机就是这种）。
neigh_mac_list() { # $1=管理接口（可空 = 不过滤 dev，退化场景才用）
	local mif="$1"
	command -v ip >/dev/null 2>&1 || return 0
	ip -4 neigh show 2>/dev/null |
		awk -v d="$mif" 'tolower($4) == "lladdr" && ($6 == "REACHABLE" || $6 == "PERMANENT") && (d == "" || $3 == d) {print tolower($5)}'
}

# 路由器视角的「正在连接」名单（CONN_ON，小写 MAC 清单）与有线子集（WIRED_ON）：
#   无线 = hostapd 关联表（STA_MAP）——权威，openNDS 记不记录、跑不跑都算在线
#   （关联表是 WiFi 驱动层面的，不经过 openNDS）；
#   有线 = 管理接口的邻居表 − 无线关联表。ARP 表里有它 = 正在跟路由器说话，
#     又不在无线关联表里 = 走的有线。不看 openNDS 记录：可信任 / 从没碰过门户的
#     有线设备 ndsctl 里根本没有，按记录找有线卡永远是 0（真机教训）。
#     也不要求 clientif == 管理接口——真机 clientif 经常是空串。
#   关联表整体拿不到（没 hostapd ubus 也没 iw/iwinfo）时退化：openNDS 记录的
#   都算在线、有线按 clientif == 管理接口判——这时没有更准的数据源可用。
# ndsctl 会把客户端留到空闲超时才清，人早走了记录还在——所以"在线"
# 不能以 openNDS 记录为准，否则数字永远偏大。
ov_conn() {
	local lm cif mif sta_any=0
	CONN_ON=''
	WIRED_ON=''
	printf '%s\n' "$STA_MAP" | grep -q . && sta_any=1
	if [ "$sta_any" = '1' ]; then
		# 无线：关联表整体搬进来（NDS 未运行也照常——AP 卡片/有线卡不依赖它）
		while IFS='	' read -r lm cif; do
			[ -n "$lm" ] || continue
			CONN_ON="$CONN_ON$lm
"
		done <<EOFC1
$STA_MAP
EOFC1
		# 有线：管理接口邻居表 − 无线关联表（已在线的 MAC 去重）
		mif=$(managed_iface)
		while IFS='	' read -r lm; do
			[ -n "$lm" ] || continue
			printf '%s\n' "$CONN_ON" | grep -qFx "$lm" && continue
			CONN_ON="$CONN_ON$lm
"
			WIRED_ON="$WIRED_ON$lm
"
		done <<EOFC2
$(neigh_mac_list "$mif")
EOFC2
	else
		# CPD_MACS 已是小写（ov_build 里统一转的）
		[ "$CPD_RUNNING" = '1' ] && CONN_ON="$CPD_MACS"
		# 退化（拿不到关联表）：有线 = clientif 是管理接口的记录
		mif=$(managed_iface)
		[ -n "$mif" ] || return 0
		while IFS='	' read -r lm st ip cif dkb ukb ss se; do
			[ -n "$lm" ] || continue
			case "$cif" in
				"$mif") WIRED_ON="$WIRED_ON$(mac_lower "$lm")
" ;;
			esac
		done <<EOFC3
$CPD_IN
EOFC3
	fi
}

# 客户端行；$1=state $2=ip $3=iface $4=mac $5=dl_kb $6=ul_kb $7=ss $8=se $9=online(0/1)
# $10=wired(0/1)：有线在线（不在无线关联表、邻居表里找得到）
ov_client_row() {
	local state="$1" ip="$2" cif="$3" lm="$4" dkb="$5" ukb="$6" ss="$7" se="$8"
	local onl="${9:-1}" wir="${10:-0}"
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
	# 有线客户端的 clientif 探不到时用邻居表的设备名兜底：
	# 列表「接入点」一列要显示 br-lan（前端再加「（有线）」）
	case "$cif" in
		'' | '-') cif=$(neigh_dev_for "$lm") ;;
	esac
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
	# NDS 停止 / 客户端离线走补行路径时 se 为空，到期时间会被显示成 —。
	# 只要是落盘认证记录里还在有效期的客户端，就用 authlog 记的到期时间兜底。
	if [ -z "$se" ] && auth_cache_get "$lm"; then
		expires=$(auth_expire_fmt "$lm")
	else
		expires=$(fmt_time "$se")
	fi
	lim=$(ov_limits_json "$(entry_for_mac "$PM_LIST" "$lm")")
	# 详情时间：认证时间取落盘最近一次认证时刻（用户口径：只认本次认证），
	# 上线时间由 hostapd 关联时长倒推（只有正在关联的设备才算得出）。
	local auth_t online_t
	auth_t=$(auth_start_fmt "$lm")
	online_t=$(online_since_fmt "$lm")

	printf '{"host":"%s","ip":"%s","mac":"%s","iface":"%s","ssid":"%s","apsec":"%s","expires":"%s","joined":"%s","authTime":"%s","onlineTime":"%s","timeout":%s,"trafficUp":%s,"trafficDown":%s,"authenticated":%s,"preauth":%s,"trusted":%s,"blocked":%s,"online":%s,"authorized":%s,"wired":%s,"limits":%s}' \
		"$(json_escape "$host")" "$(json_escape "$ip")" "$(json_escape "$lm")" \
		"$(json_escape "$cif")" "$(json_escape "$ssidv")" "$(json_escape "$apsec")" \
		"$(json_escape "$expires")" "$(json_escape "$joined")" \
		"$(json_escape "$auth_t")" "$(json_escape "$online_t")" \
		"${CPD_AUTHIDLE:-120}" \
		"$up" "$down" "$auth" "$pre" "$trst" "$blk" \
		"$( [ "$onl" = '1' ] && printf 'true' || printf 'false' )" \
		"$authorized" \
		"$( [ "$wir" = '1' ] && printf 'true' || printf 'false' )" \
		"$lim"
}

# 一次构建仪表盘全部数据：CPD_IN / ROWS_JSON / COUNTS_* / APS_JSON
# 之前 status 与 clients 是两个请求、各解析一次 ndsctl、各跑一遍 uci，
# 页面切进来要等两次串行往返；合并成一次后首屏明显更快。
# 无线侧预读（ov_build / ex_clients 共用）：
#   CPD_WS   network.wireless status 原文
#   AP_MAP   uci section → 运行时接口
#   AP_META  iface<TAB>ssid<TAB>section（当前启用的 AP）
#   STA_MAP  mac<TAB>iface（hostapd 关联表，权威；两列，下游按此解析）
#   STA_CONNSEC  mac<TAB>关联秒数（ws_sta_one 第三列，倒推上线时刻）
#   STA_SEC  mac<TAB>section（同一 SSID 开在 2.4G/5G 是两个段，按段区分）
ov_wireless_prep() {
	local sm_mac sm_ifn sm_sec sm_conn
	CPD_WS=''
	if command -v ubus >/dev/null 2>&1; then
		CPD_WS=$(ubus_call call network.wireless status)
	fi
	AP_MAP=$(ws_iface_map "$CPD_WS")
	ov_ap_meta
	# ws_sta_map 输出三列；拆开：STA_MAP 只要前两列（格式不变），
	# STA_CONNSEC 收第三列（关联时长），供详情「上线时间」倒推用。
	STA_CONNSEC=''
	STA_MAP=''
	while IFS='	' read -r sm_mac sm_ifn sm_conn; do
		[ -n "$sm_mac" ] || continue
		STA_MAP="$STA_MAP$sm_mac	$sm_ifn
"
		case "$sm_conn" in
			'' | - | *[!0-9]*) ;;
			*) STA_CONNSEC="$STA_CONNSEC$sm_mac	$sm_conn
" ;;
		esac
	done <<EOW
$(ws_sta_map "$AP_META")
EOW
	# MAC → 所属 AP 的 uci 段名。同一个 SSID 常常同时开在 2.4G 和 5G 上，	# 那是两个段、两张卡片；卡片数量按段统计，列表也必须按段筛选，
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
}

# ---- 已认证会话：读 openNDS 原生落盘记录 --------------------------------
# openNDS 认证成功时，binauth_log.sh 会把会话写到 <log_mountpoint>/ndslog/authlog.log，
# 每行 "<base64(mac 去等号)>=<session_end 绝对时间戳>"。NDS 启动时 main.c 调
# libopennds.sh "auth_restore" 读它把客户端恢复成已认证——这正是"重启/重连后
# 还能保持认证"的原理。它一直在硬盘上（NDS 停止也不删），所以是判定"是否认证过、
# 是否还在有效期内"的权威源：NDS 关着、刚启动没就绪、首次装插件都靠它。
# 不再自建缓存——自建缓存只在 NDS 运行时才写得到，首次安装/停服时是空的。
#
# AUTH_CACHE 每行：小写mac<TAB>到期时间戳（只留有效期内且未被主动登出的）
# AUTH_START 每行：小写mac<TAB>最近一次认证时刻（binauthlog 里该 mac 最大的 auth
# 记录 session_start）。ndsctl 的 session_start 会在 NDS 恢复认证时被冲成当前
# 时间，所以详情「认证时间」以这个落盘值为准——它不随停服/重启变化。
# authlog.mountpoint 可由 uci opennds.@opennds[0].log_mountpoint 覆盖；
# 未配置时按 openNDS 的探测顺序取第一个 tmpfs（/tmp /run /var），默认 /tmp。
AUTH_CACHE=''
AUTH_START=''

# base64 解码（authlog 的 mac 键去掉了末尾 =）。纯 awk，不依赖 busybox base64 -d。
# 输入是去掉末尾 = 的 base64（authlog 原样）。每 4 个 6-bit 字符还原 3 字节；
# 末组不足 4 个只还原对应的 1~2 字节，不产出填充字节。
B64_DEC_AWK='
BEGIN { B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; P = 64 }
{
	s = $0; out = ""; n = length(s); i = 1
	while (i <= n) {
		c1 = index(B, substr(s, i, 1)) - 1; i++
		if (i > n) break
		c2 = index(B, substr(s, i, 1)) - 1; i++
		out = out sprintf("%c", c1 * 4 + int(c2 / 16))
		if (i > n) break
		c3 = index(B, substr(s, i, 1)) - 1; i++
		out = out sprintf("%c", (c2 * 16) % 256 + int(c3 / 4))
		if (i > n) break
		c4 = index(B, substr(s, i, 1)) - 1; i++
		out = out sprintf("%c", (c3 * 64) % 256 + c4)
	}
	print out
}'

authlog_dir() { # 算出 openNDS 落盘日志目录
	local mp
	# 测试沙箱可覆盖；生产不设这个变量，走 uci / tmpfs 探测
	[ -n "${CPD_NDSLOG_DIR:-}" ] && { printf '%s' "$CPD_NDSLOG_DIR"; return 0; }
	mp=$(uci -q get 'opennds.@opennds[0].log_mountpoint' 2>/dev/null)
	if [ -n "$mp" ]; then
		printf '%s/ndslog' "$mp"
		return 0
	fi
	# 复刻 libopennds.sh configure_log_location 的 tmpfs 探测
	for d in /tmp /run /var; do
		if df 2>/dev/null | awk -v x="$d" '$1 == "tmpfs" && $6 == x {f=1} END {exit !f}'; then
			printf '%s/ndslog' "$d"
			return 0
		fi
	done
	printf '/tmp/ndslog'
}

# 清除某 MAC 在 openNDS 两份落盘日志里的全部记录（用户口径 2026-11-21：
# 任何改变客户端身份的动作都先清原状态、再应用新状态）。
#   authlog.log    ：每行 base64(mac)=到期戳，按解码后的 mac 精确删对应行
#   binauthlog.log ：每行含 clientmac=<mac>，按 mac 精确删对应行
# 只删该 mac 的行，其他客户端日志原样保留。文件缺失时静默返回。
# $1=小写 mac
purge_client_logs() {
	local lm="$1" dir f bl kb exp dec
	dir=$(authlog_dir)
	f="$dir/authlog.log"
	bl="$dir/binauthlog.log"

	# authlog：逐行解码 key，命中目标 mac 的行丢掉，其余原样写回
	if [ -f "$f" ]; then
		while IFS='=' read -r kb exp; do
			dec=$(printf '%s' "$kb" | awk "$B64_DEC_AWK" | tr 'A-Z' 'a-z')
			[ "$dec" = "$lm" ] && continue
			printf '%s=%s\n' "$kb" "$exp"
		done <"$f" >"$f.cpd.new"
		cat "$f.cpd.new" >"$f"
		rm -f "$f.cpd.new"
	fi

	# binauthlog：删掉所有 clientmac 命中目标 mac 的行（大小写都覆盖）
	if [ -f "$bl" ]; then
		awk -v m="$lm" '
			{
				low = tolower($0)
				if (index(low, "clientmac=" m) > 0) next
				print
			}' "$bl" >"$bl.cpd.new"
		cat "$bl.cpd.new" >"$bl"
		rm -f "$bl.cpd.new"
	fi
	return 0
}

auth_cache_load() { # 读原生 authlog + binauthlog（排除主动登出）→ AUTH_CACHE
	AUTH_CACHE=''
	AUTH_START=''
	local dir f now lm exp kb lastm
	now=$(date +%s)
	dir=$(authlog_dir)
	f="$dir/authlog.log"
	[ -f "$f" ] || return 0
	local bl="$dir/binauthlog.log"
	while IFS='=' read -r kb exp; do
		case "$kb" in '' | *[!A-Za-z0-9+/]*) continue ;; esac
		case "$exp" in '' | *[!0-9]*) continue ;; esac
		[ "$exp" -gt "$now" ] || continue
		# openNDS 写的是 base64(mac) 去掉末尾 =，解码器按无 padding 处理
		lm=$(printf '%s' "$kb" | awk "$B64_DEC_AWK" | tr 'A-Z' 'a-z')
		case "$lm" in *:*) ;; *) continue ;; esac
		# auth_restore 同款判据：binauthlog 里该 mac 最后一条若是普通 deauth
		# （用户主动登出/超时/ndsctl 踢下线）则不恢复；shutdown_deauth 是停 NDS
		# 造成的，仍算认证。
		# 关键：真机 binauthlog 写的是无引号 `method=ndsctl_deauth`（见
		# binauth_log.sh 的 loginfo），必须用官方那种 awk -F'method=' 提取；
		# 用 `method="..."` 带引号的 sed 会永远匹配不到，导致 deauth 后落盘
		# 记录没被排除、客户端又被判回「已认证」。
		lastm=''
		[ -f "$bl" ] && lastm=$(grep -F "$lm" "$bl" 2>/dev/null | tail -1 |
			awk -F'method=' '{print $2}' | awk -F', ' '{printf "%s", $1}')
		case "$lastm" in
			*deauth) [ "$lastm" = 'shutdown_deauth' ] || continue ;;
		esac
		AUTH_CACHE="$AUTH_CACHE$lm	$exp
"
	done <"$f"

	# 本次认证时刻：读 binauthlog 里认证成功的记录，取该 mac 最近一次 session_start。
	# 用户口径（2026-11-21）：认证时间只认本次认证——11-21 认证的就显示 11-21，
	# 不再显示历史上最早那次。故取最大值（最近），不是最早。
	# 关键：binauth 传进来的 method 是 client_auth / ndsctl_auth（明文认证流程最终
	# 是 client_auth），不是单纯的 auth；判据必须和 binauth_log.sh 一样取末段
	# （action=${method##*_}），否则会把真正的认证行全过滤掉，认证时间永远显示 —。
	# auth_client 那行不带 session_start，天然被 ss=="" 排除；各 *_deauth 末段是
	# deauth，也不会混进来。每行形如：
	#   Wed Nov 20 10:00:00 2024, method=client_auth, clientmac=aa:bb:..., ..., session_start=1732..., session_end=1732...
	if [ -f "$bl" ]; then
		AUTH_START=$(awk '
		{
			mac = ""; ss = ""; meth = ""
			if (match($0, /clientmac=[^,[:space:]]+/)) {
				mac = substr($0, RSTART + 10, RLENGTH - 10)
				mac = tolower(mac)
			}
			if (match($0, /method=[^,[:space:]]+/))
				meth = substr($0, RSTART + 7, RLENGTH - 7)
			# 取 method 末段：client_auth -> auth；ndsctl_auth -> auth
			n = split(meth, parts, "_")
			act = parts[n]
			if (act != "auth" || mac == "") next
			if (match($0, /session_start=[0-9]+/))
				ss = substr($0, RSTART + 14, RLENGTH - 14)
			if (ss == "" || mac !~ /:/) next
			# 取最近一次（最大时间戳），实现「认证时间只认本次认证」
			if (!(mac in last) || (ss + 0) > (last[mac] + 0)) last[mac] = ss
		}
		END { for (m in last) print m "\t" last[m] }
		' "$bl")
	fi
	return 0
}

auth_cache_get() { # $1=小写 mac → 0=在有效期内认证过
	[ -n "$AUTH_CACHE" ] || return 1
	printf '%s\n' "$AUTH_CACHE" | grep -qF "$1	"
}

# 详情「到期时间」落盘兜底：$1=小写 mac → 打印到期时间戳（无则空串）。
# NDS 停止 / 客户端离线时走补行路径，ndsctl 没有 session_end，se 传空会让
# 到期时间显示 —；authlog.log 里本就记着到期时间，直接取它。
auth_expire_fmt() { # $1=小写 mac
	[ -n "$AUTH_CACHE" ] || return 0
	local e
	e=$(printf '%s\n' "$AUTH_CACHE" | awk -F'\t' -v m="$1" '$1 == m {print $2; exit}')
	fmt_time "$e" || printf ''
}

# 详情「认证时间」：该 mac 落盘的最近一次认证时刻 → 格式化时间；没有则空串
auth_start_fmt() { # $1=小写 mac
	[ -n "$AUTH_START" ] || return 0
	local e
	e=$(printf '%s\n' "$AUTH_START" | awk -F'\t' -v m="$1" '$1 == m {print $2; exit}')
	fmt_time "$e" || printf ''
}

# 详情「上线时间」：当前时间 − 关联时长 → 格式化时间；没有关联时长则空串
# $1=小写 mac。关联时长随时间变化，取当下快照（前端轮询会刷新）。
online_since_fmt() { # $1=小写 mac
	[ -n "$STA_CONNSEC" ] || return 0
	local sec now e
	sec=$(printf '%s\n' "$STA_CONNSEC" | awk -F'\t' -v m="$1" '$1 == m {print $2; exit}')
	case "$sec" in '' | *[!0-9]*) return 0 ;; esac
	now=$(date +%s)
	e=$((now - sec))
	fmt_time "$e" || printf ''
}

ov_build() {
	local running enabled engaged busy scope='' conf_err=''
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
	# 全局最大会话时间（分钟）：详情里客户端没单独设置时显示它。openNDS 默认 1440。
	CPD_DEFSESSION=$(uci_val 'opennds.@opennds[0].sessiontimeout' '1440')
	case "$CPD_DEFSESSION" in '' | *[!0-9]*) CPD_DEFSESSION=1440 ;; esac
	CPD_FUP_U=$(uci_val 'opennds.@opennds[0].fup_upload_throttle_rate' '0')
	CPD_FUP_D=$(uci_val 'opennds.@opennds[0].fup_download_throttle_rate' '0')
	ov_wireless_prep

	CPD_PARSED=''
	CPD_IN=''
	CPD_MACS=''
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
		CPD_MACS=$(printf '%s\n' "$CPD_IN" | awk -F'\t' 'NF {print tolower($1)}' | sort -u)
	fi

	# 认证身份一律读 openNDS 原生落盘记录（NDS 停/刚启动/首次装都在）。
	# ndsctl 的实时 state 只用于流量/IP/会话时间；是否"已认证"以落盘为准。
	auth_cache_load

	ov_conn
	ov_rows
	ov_counts
	ov_aps
}

# 每个客户端行算出唯一的「身份」（前端 tagOf / inFilter 用的是同一组标记）：
#   bl=黑名单  tr=可信任  pre=免认证  auth=已认证  unauth=未认证
# 同时记下行是否在线（onl）与是否有线（wir）。ROW_TBL =
# "mac<TAB>身份<TAB>onl<TAB>wir" 每行一条，ov_counts 只按这张表数数——
# 卡片数字与列表条目永远同源，不会再出现「卡片 3、点开列表 0 条」这种错位。
ov_row_class() { # $1=state $2=小写 mac → 打印 bl|tr|pre|auth|unauth
	local is_auth=0
	case "$1" in
		Authenticated | AuthBlocked) is_auth=1 ;;
	esac
	mac_in_bl "$2" && { printf 'bl'; return 0; }
	mac_in_tr "$2" && { printf 'tr'; return 0; }
	if mac_in_pm "$2" && [ "$is_auth" = '1' ]; then
		printf 'pre'
		return 0
	fi
	[ "$is_auth" = '1' ] && { printf 'auth'; return 0; }
	printf 'unauth'
}

ov_rows() {
	local mac state ip cif dkb ukb ss se lm rows='' sep='' n=0 onl rif wir
	local seen cls cs
	N_ONLINE=0
	ROW_TBL=''
	# 已见 MAC：openNDS 记录的 + 关联表里的 + 邻居表里的（后面补名单行时去重用）
	seen="$CPD_MACS"
	if [ "$CPD_RUNNING" = '1' ]; then
		while IFS='	' read -r mac state ip cif dkb ukb ss se; do
			[ -n "$mac" ] || continue
			# 还原占位符（见 ov_build 里的 S()）
			[ "$ip" = '-' ] && ip=''
			[ "$cif" = '-' ] && cif=''
			[ "$ss" = '-' ] && ss=''
			[ "$se" = '-' ] && se=''
			lm=$(mac_lower "$mac")
			# 认证身份 = ndsctl 实时 state 或 openNDS 原生落盘记录，二者其一
			# 有效即算已认证。NDS 刚启动时 auth_restore 还没把会话恢复进 ndsctl
			# （state 暂为 Preauthenticated），用 authlog 补上，消除"等十秒才
			# 挪到已认证卡"；自定义 binauth 不写 authlog 时仍靠 ndsctl 实时值。
			auth_cache_get "$lm" && state='Authenticated'
			# 在线与否以路由器为准（关联表 / 邻居表）；ndsctl 把客户端留到
			# 空闲超时才清，人早走了记录还在，按记录算在线永远偏大
			onl=0
			wir=0
			printf '%s\n' "$CONN_ON" | grep -qFx "$lm" && onl=1
			printf '%s\n' "$WIRED_ON" | grep -qFx "$lm" && wir=1
			# 无线客户端的接口以关联表为准（clientif 没装 iw 时是 br-lan）
			rif=$(printf '%s\n' "$STA_MAP" | awk -F'\t' -v m="$lm" '$1 == m && NF >= 2 {print $2; exit}')
			[ -n "$rif" ] && cif="$rif"
			rows="$rows$sep$(ov_client_row "$state" "$ip" "$cif" "$lm" "$dkb" "$ukb" "$ss" "$se" "$onl" "$wir")"
			cls=$(ov_row_class "$state" "$lm")
			ROW_TBL="$ROW_TBL$lm	$cls	$onl	$wir
"
			sep=','
			n=$((n + 1))
		done <<EOF2
$CPD_IN
EOF2
	fi

	# 关联表里有、openNDS 还没记录的设备（刚连上 / 没开过浏览器）也要出行：
	# AP 卡片是按 hostapd 关联表数出来的，列表若只认 ndsctl 的记录，就会出现
	# 「卡片 3、点开一条都没有」。这些设备没有会话记录，IP/主机名照常从租约
	# 和邻居表补。**不关门控**：openNDS 没运行时 AP 卡片照样按关联表计数，
	# 点开也要能看到这批设备（2026-11-19 用户反馈）。
	while IFS='	' read -r lm rif; do
		[ -n "$lm" ] || continue
		printf '%s\n' "$seen" | grep -qFx "$lm" && continue
		seen="$seen
$lm"
		# ndsctl 没数据（NDS 停了 / 刚重启）时，用会话缓存恢复身份：
		# 之前认证过且还在有效期内 → 已认证，不进未认证卡
		cs=''
		auth_cache_get "$lm" && cs='Authenticated'
		rows="$rows$sep$(ov_client_row "$cs" '' "$rif" "$lm" 0 0 '' '' 1 0)"
		cls=$(ov_row_class "$cs" "$lm")
		ROW_TBL="$ROW_TBL$lm	$cls	1	0
"
		sep=','
		n=$((n + 1))
	done <<EOF4
$STA_MAP
EOF4

	# 有线在线设备补行：不在无线关联表、但管理接口邻居表里找得到。
	# **不看 openNDS 记录**：可信任 / 从没碰过门户的有线设备 ndsctl 里
	# 根本没有（trusted 客户端不过门户、不会进 ndsctl json），按记录找
	# 有线卡永远是 0。也不依赖 NDS 运行（2026-11-19 用户口径：有线卡
	# 只看路由器，openNDS 停了照样统计）。身份照旧按名单判定。
	while IFS='	' read -r lm; do
		[ -n "$lm" ] || continue
		printf '%s\n' "$seen" | grep -qFx "$lm" && continue
		seen="$seen
$lm"
		cs=''
		auth_cache_get "$lm" && cs='Authenticated'
		rows="$rows$sep$(ov_client_row "$cs" '' "$(neigh_dev_for "$lm")" "$lm" 0 0 '' '' 1 1)"
		cls=$(ov_row_class "$cs" "$lm")
		ROW_TBL="$ROW_TBL$lm	$cls	1	1
"
		sep=','
		n=$((n + 1))
	done <<EOF6
$WIRED_ON
EOF6

	# 名单补行：trusted / preemptivemac / blockedmac 里不在线的 MAC，
	# 外加"认证还在有效期内"的 MAC（读 openNDS 原生 authlog）——已认证卡
	# 按"有效期内就算、不管在线不在线"统计（2026-11-20 用户口径），所以
	# 这些离线的已认证设备也得进列表，点已认证卡才看得到、和卡片同源。
	local supp
	supp=$(printf '%s\n' $TR_MACS $PM_MACS $BL_MACS \
		$(printf '%s\n' "$AUTH_CACHE" | awk -F'\t' 'NF {print $1}') | sort -u | grep -v '^$')
	for lm in $supp; do
		printf '%s\n' "$seen" | grep -qFx "$lm" && continue
		seen="$seen
$lm"
		cs=''
		auth_cache_get "$lm" && cs='Authenticated'
		rows="$rows$sep$(ov_client_row "$cs" '' '' "$lm" 0 0 '' '' 0 0)"
		cls=$(ov_row_class "$cs" "$lm")
		ROW_TBL="$ROW_TBL$lm	$cls	0	0
"
		sep=','
		n=$((n + 1))
	done

	# 在线 = 路由器视角「正在连着」且「有访问权限」（已认证 / 可信任 /
	# 免认证已登录）。未认证与黑名单不算在线——在线卡是身份卡，不是
	# 连接数；刚连上还没过门户的设备归「未认证」卡。与前端 inFilter 的
	# online 分支同一口径（online && authorized && !blocked）。
	while IFS='	' read -r lm cls onl wir; do
		[ -n "$lm" ] || continue
		[ "$onl" = '1' ] || continue
		case "$cls" in
			auth | pre | tr) N_ONLINE=$((N_ONLINE + 1)) ;;
		esac
	done <<EOF9
$ROW_TBL
EOF9
	# NDS 未运行时没有"访问权限"可言：在线/已认证/未认证三张身份卡归零
	# （可信任 / 免认证 / 有线 / 黑名单不受影响，见 ov_counts 与补行循环）。
	[ "$CPD_RUNNING" = '1' ] || N_ONLINE=0

	ROWS_JSON="$rows"
	N_ROWS="$n"
}

# 统计口径：
#   在线     = 正在连着且有访问权限（已认证 / 免认证已登录 / 可信任）；
#              未认证与黑名单不算，有线客户端照算（见 ov_conn）。
#              NDS 未运行时没有"访问权限"可言 → 归零
#   有线     = 正在连着的有线客户端，不分身份（黑名单除外）——与无线接入点
#              卡片按关联表计数同一口径：卡片数的是「连着多少设备」。
#              只看路由器（邻居表−关联表），不受 NDS 运行状态影响
#   已认证   = 认证还在有效期内（openNDS 原生 authlog，不在信任/免认证/黑名单）
#              不管在线不在线，NDS 停着/重装插件也算——不用等连上 WiFi
#   未认证   = 在线但还没通过认证（Preauthenticated / 关联了但没碰过门户）
#   免认证   = 以 preemptivemac 名单为准（离线也在）——读配置文件就能统计，
#              不受 NDS 运行状态影响（2026-11-19 用户口径）
#   可信任   = 以 trustedmac 名单为准（离线的信任设备也在名单里）
#   黑名单   = 以 blockedmac 名单为准
# 全部按 ROW_TBL / 名单数，与客户端列表同源。
ov_counts() {
	local lm cls onl wir m2
	N_AUTH=0
	N_PRE=0
	N_TR=0
	N_UN=0
	N_WIRED=0
	while IFS='	' read -r lm cls onl wir; do
		[ -n "$lm" ] || continue
		case "$cls" in
			# 黑名单行：身份卡都不计，但有线卡照常按连接计数——客户端连上
			# br-lan 就有 IP，卡片不依赖 NDS（2026-11-21 用户口径）
			bl) ;;
			tr) N_TR=$((N_TR + 1)) ;; # 名单为准，离线也在
			pre) ;; # 免认证下面按配置名单数（这里数会漏掉离线与未登录的条目）
			# 已认证 = 认证还在有效期内就算，不管在线不在线（读原生落盘记录）。
			# 客户端关了 WiFi、NDS 停着，只要没过期仍算已认证——不必等它连上 WiFi。
			auth) N_AUTH=$((N_AUTH + 1)) ;;
			*)
				# 在免认证名单里的条目归「免认证」卡（按名单数），不重复进未认证
				[ "$onl" = '1' ] || continue
				mac_in_pm "$lm" && continue
				N_UN=$((N_UN + 1))
				;;
		esac
		# 有线卡：连着的有线设备，不分身份（黑名单客户端连着也计入）
		[ "$onl" = '1' ] && [ "$wir" = '1' ] && N_WIRED=$((N_WIRED + 1))
	done <<EOF2
$ROW_TBL
EOF2

	# 免认证卡 = preemptivemac 名单去重（黑名单除外）。名单是配置文件，
	# NDS 没运行也照读——所以这张卡不要求在线、不要求已登录。
	for m2 in $(printf '%s\n' $PM_MACS | sort -u); do
		[ -n "$m2" ] || continue
		mac_in_bl "$m2" && continue
		N_PRE=$((N_PRE + 1))
	done

	# NDS 未运行：在线/未认证归零（没有"当前访问权限"可言）；已认证不归零——
	# 认证身份看 openNDS 原生落盘记录，只要没过期，停服/重装插件都仍是已认证。
	# 免认证 / 可信任 / 有线 / 黑名单不受影响（名单 / 邻居表为准）。
	if [ "$CPD_RUNNING" != '1' ]; then
		N_UN=0
	fi

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
				# 没装 iw 时是 br-lan，对不上 phyN-apM，按它数永远是 0。
				# 黑名单客户端也计入：客户端连上 WIFI 就在关联表里（有 IP），
				# 卡片按连接计数、不依赖 NDS 运行（2026-11-21 用户口径）。
				while IFS='	' read -r lm sm; do
					[ -n "$lm" ] || continue
					[ "$sm" = "$ifn" ] || continue
					cnt=$((cnt + 1))
				done <<EOF2
$STA_MAP
EOF2
			elif [ "$CPD_RUNNING" = '1' ]; then
				while IFS='	' read -r lm st ip cif dkb ukb ss se; do
					[ -n "$lm" ] || continue
					[ "$cif" = "$ifn" ] || continue
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
	printf '"running":%s,"enabled":%s,"engaged":%s,"busy":%s,"fupEnabled":%s,"defaultSession":%s,"session_scope":"%s","confErr":"%s","counts":{"online":%s,"wired":%s,"authenticated":%s,"preauth":%s,"trusted":%s,"unauthenticated":%s,"blacklist":%s,"maxclients":%s},"managed":{"iface":"%s","ip":"%s"},"aps":%s' \
		"$CPD_RUNNING" "$CPD_ENABLED" "$CPD_ENGAGED" "$CPD_BUSY" "$(fup_enabled_val)" \
		"${CPD_DEFSESSION:-1440}" \
		"$(json_escape "$CPD_SCOPE")" "$(json_escape "$CPD_CONFERR")" \
		"$N_ONLINE" "$N_WIRED" "$N_AUTH" "$N_PRE" "$N_TR" "$N_UN" "$N_BL" \
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
# 把 TAB 分隔的中间表转成 JSON 字符串数组（每行一项，TAB 显示为 " -> "）
lines_to_json() { # $1=多行文本
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" | awk '
		NF {
			s = $0
			gsub(/\t/, " -> ", s)
			gsub(/\\/, "\\\\", s)
			gsub(/"/, "\\\"", s)
			out = out (out == "" ? "" : ",") "\"" s "\""
		}
		END { printf "%s", out }'
}

# 真机自检：把 dashboard 各环节的中间值一次打出来（只读，不抢锁）。
# 远程排障用：SSH 到设备上跑
#   sh /usr/lib/opennds/opennds-cpd-api.sh overview selfcheck
# AP 卡片全 0 / 接入点列不出 SSID 时，看 ap_map / ap_meta / sta_map 哪层为空。
ov_selfcheck() {
	local running enabled t sep='' mtime=''
	enabled=$(nds_enabled)
	running=0
	nds_running && running=1
	ov_build
	# 装的到底是不是刚构建的那版：脚本自身的修改时间（apk 装包时间）。
	# 上一轮「改了没生效」就是装的旧包，先看这个再看别的。
	command -v stat >/dev/null 2>&1 && mtime=$(stat -c '%y' "$0" 2>/dev/null | cut -d. -f1)
	printf '{"ok":1,"build":"%s","running":%s,"enabled":%s,"tools":{' \
		"$(json_escape "$mtime")" "$running" "$enabled"
	for t in ubus jsonfilter iw iwinfo timeout ndsctl uci; do
		printf '%s"%s":%s' "$sep" "$t" "$(command -v "$t" >/dev/null 2>&1 && printf 1 || printf 0)"
		sep=','
	done
	printf '},"path":"%s"' "$(json_escape "$PATH")"
	printf ',"wireless_status_len":%s' "$(printf '%s' "$CPD_WS" | wc -c | tr -d ' ')"
	printf ',"counts":{"online":%s,"wired":%s,"authenticated":%s,"preauth":%s,"trusted":%s,"unauthenticated":%s,"blacklist":%s}' \
		"$N_ONLINE" "$N_WIRED" "$N_AUTH" "$N_PRE" "$N_TR" "$N_UN" "$N_BL"
	printf ',"ap_map":[%s]' "$(lines_to_json "$AP_MAP")"
	printf ',"ap_meta":[%s]' "$(lines_to_json "$AP_META")"
	printf ',"sta_map":[%s]' "$(lines_to_json "$STA_MAP")"
	printf ',"sta_connsec":[%s]' "$(lines_to_json "$STA_CONNSEC")"
	printf ',"clients":[%s]' "$(lines_to_json "$CPD_IN")"
	printf ',"aps":[%s]\n' "$(json_escape "$APS_JSON")"
}

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
	# 文件夹门户：设置页上传的以 default.sh 为主入口，区域页旧上传的
	# 是 theme.sh —— 两种都认，老门户不会因为升级突然失效
	[ -f "$d/$b/default.sh" ] && return 0
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

# 客户端 → 网络区域显示（与概览页「接入点」列同一口径）：
#   ① MAC 反查无线关联表（STA_MAP）→ AP 的 SSID——最准，ndsctl 的 clientif
#      在没装 iw 的机器上是 br-lan，靠它判无线/有线永远是错的
#   ② clientif 本身是无线接口（iw dev <if> info 成功）→ 显示接口名，
#      不能标成有线
#   ③ 其余按有线：管理接口名 +（有线），如 br-lan（有线）；管理接口取不到时
#      退回 clientif 原样
ex_zone_for() { # $1=小写 mac $2=ndsctl clientif
	local s mif
	s=$(client_ssid "$1" "$2")
	[ -n "$s" ] && { printf '%s' "$s"; return 0; }
	if [ -n "$2" ] && iw dev "$2" info >/dev/null 2>&1; then
		printf '%s' "$2"
		return 0
	fi
	mif=$(managed_iface)
	if [ -n "$mif" ]; then
		printf '%s（有线）' "$mif"
	else
		[ -n "$2" ] && printf '%s' "$2"
	fi
	return 0
}

# 名单里配了、但 openNDS 记录里没有的客户端（可信任客户端基本都属于这种：
# openNDS 根本不为它们建会话）。「网络区域」不能只看 ndsctl：
#   ① 无线关联表里有它 → 无线，显示所属 AP 的 SSID
#   ② 邻居表里能找到它 → 有线，显示管理接口，如 br-lan（有线）
#   ③ 都找不到 → 离线，区域留空（返回非 0）
ex_zone_listed() { # $1=小写 mac → stdout 区域名
	local lm="$1" s dev mif ifn
	ifn=$(printf '%s\n' "$STA_MAP" | awk -F'\t' -v m="$lm" '$1 == m && NF >= 2 {print $2; exit}')
	if [ -n "$ifn" ]; then
		s=$(client_ssid "$lm" "$ifn")
		[ -n "$s" ] || s="$ifn"
		printf '%s' "$s"
		return 0
	fi
	mif=$(managed_iface)
	dev=$(neigh_dev_for "$lm")
	# 只认管理接口上的邻居：WAN 侧的网关也在全局邻居表里，
	# 不按 dev 过滤会把运营商网关当成"有线客户端"标出来
	if [ -n "$dev" ] && { [ -z "$mif" ] || [ "$dev" = "$mif" ]; }; then
		printf '%s（有线）' "$dev"
		return 0
	fi
	return 1
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
	# 网络区域要按 MAC 反查无线关联表（与概览页同一口径），先做无线预读
	ov_wireless_prep
	local out='' sep='' seen='|'
	if [ "$running" = '1' ]; then
		local mac lm ip cif zone host
		srow=$(parse_clients)
		while IFS='	' read -r tag mac st ip cif rest; do
			[ "$tag" = 'S' ] || continue
			[ -n "$mac" ] || continue
			lm=$(mac_lower "$mac")
			cif="${cif%% *}"
			zone=$(ex_zone_for "$lm" "$cif")
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
	# 名单里配了但不在线的：ip -4 neigh 兜底补 IP；区域按关联表/邻居表判断
	# （可信任客户端不在 ndsctl 里，靠 openNDS 记录永远显示不出区域）；
	# 主机名照官方 dhcp_check 从 DHCP 租约查 —— 租约与 openNDS 是否在跑无关
	local lm zon onl nip hosto
	for lm in $EX_TLIST $(printf '%s\n' $EX_PENTRIES | sed -n 's/^mac=//p' | cut -d';' -f1); do
		lm=$(mac_lower "$lm") 2>/dev/null || continue
		case "$seen" in
			*"|$lm|"*) continue ;;
		esac
		zon=''
		onl=0
		zon=$(ex_zone_listed "$lm") && onl=1
		nip=$(ip -4 neigh show 2>/dev/null |
			awk -v m="$lm" 'tolower($4) == "lladdr" && tolower($5) == m {print $1; exit}')
		hosto=$(ov_host_for "$lm")
		out="$out$sep\"$(json_escape "$lm")\":{\"host\":\"$(json_escape "$hosto")\",\"ip\":\"$(json_escape "$nip")\",\"zone\":\"$(json_escape "$zon")\",\"online\":$onl}"
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
# 门户库 = /usr/lib/opennds/cpd/blacklist/（页内门户选择键 portal_blacklist_sel）；
# 兜底链 = cpd/default/blacklist/<portal_blacklist>（设置页默认黑名单门户）
#         → cpd/default/blacklist/default.sh
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

bl_portal_sel() { # 黑名单页当前选中的门户（空 = 落到设置页的默认黑名单门户）
	uci_val 'zone_detect.main.portal_blacklist_sel' ''
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

ST_TABS='|wireless|wired|blacklist|global|'

# 门户目录：四个 tab 各管一套默认门户（互为覆盖，一次只有一个生效）。
# 无线/有线/黑名单在 cpd/default/<类型>/；全局门户在 cpd/global/
# （区域识别页「全局」模式用的那个）。
# 「客户端黑名单」页的门户库仍在 cpd/blacklist/，由 bl_* 管理，与此处无关。
st_portal_dir() { # $1=tab
	case "$1" in
		global) printf '%s' "$CPD_ROOT/global" ;;
		*) printf '%s' "$CPD_ROOT/default/$1" ;;
	esac
}

st_tab_ok() { # $1=tab（白名单防目录穿越）
	case "$ST_TABS" in
		*"|$1|"*) return 0 ;;
	esac
	return 1
}

st_iface_exists() { # $1=接口名 → 在 ip -4 -o addr show 里
	ip -4 -o addr show 2>/dev/null | awk -v n="$1" '$2 == n { f = 1 } END { exit !f }'
}

# 公平使用策略开关（优先级从高到低）：
#   ① openNDS 配置里 fup_upload/download_throttle_rate 任一 > 0 → 开
#      （配了限速就是启用了公平使用策略，不管名单里上次存的是什么）
#   ② 都是 0 时看 zone_detect.main.fup_enabled 上次保存的开关状态
#      （非首次安装；首次安装没存过 → 关）
fup_enabled_val() {
	local v u d
	u=$(uci_val 'opennds.@opennds[0].fup_upload_throttle_rate' '0')
	d=$(uci_val 'opennds.@opennds[0].fup_download_throttle_rate' '0')
	int_valid "$u" || u=0
	int_valid "$d" || d=0
	if [ "$u" -gt 0 ] 2>/dev/null || [ "$d" -gt 0 ] 2>/dev/null; then
		printf '1'
		return 0
	fi
	v=$(uci_val 'zone_detect.main.fup_enabled' '')
	case "$v" in
		1) printf '1'; return 0 ;;
		0) printf '0'; return 0 ;;
	esac
	printf '0'
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
	local d f b
	d=$(st_portal_dir "$1")
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
		elif [ -d "$f" ] && { [ -f "$f/default.sh" ] || [ -f "$f/theme.sh" ]; }; then
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
	local sel items isep2 pn pk pdir bdir
	for t in wireless wired blacklist global; do
		sel=$(uci_val "zone_detect.main.portal_$t" '')
		[ "$sel" = 'default' ] && sel=''
		pdir=$(st_portal_dir "$t")
		bdir="$pdir"
		[ -n "$sel" ] && ! z_portal_exists "$pdir" "$sel" && sel=''
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
			[ -f "$bdir/default.sh" ] && printf 'true' || printf 'false'
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
		[ -f "$tmp/default.sh" ] || out_err '只接受 .sh 门户脚本，或包含 default.sh 的文件夹'
	fi
	acquire_lock
	local dir
	dir=$(st_portal_dir "$tab")
	mkdir -p "$dir" 2>/dev/null || out_err '无法创建目标目录'
	if [ "$kind" = 'file' ]; then
		# 原子覆盖：先落同盘 .tmp 再 mv（避免 source 时读到半截文件）
		cp "$tmp" "$dir/$name.tmp" 2>/dev/null || out_err '写入门户文件失败'
		chmod 755 "$dir/$name.tmp" 2>/dev/null || {
			rm -f "$dir/$name.tmp" 2>/dev/null
			out_err '无法设置执行权限'
		}
		# 互斥覆盖：先清掉其它门户，再落位（四个 tab 口径一致）
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
		[ -f "$dir/$name/default.sh" ] || out_err '门户文件夹里没有 default.sh'
		# 让 SFTP / 其它账号也能进目录、读文件（a+rX：目录补 x，普通文件只加读）
		chmod 755 "$dir/$name" 2>/dev/null
		chmod -R a+rX "$dir/$name" 2>/dev/null
		chmod 755 "$dir/$name/default.sh" 2>/dev/null
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
			z_portal_exists "$(st_portal_dir "$1")" "$2" || out_err '门户不存在'
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
	local dir sel removed=0 existed=0
	dir=$(st_portal_dir "$tab")
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

# 保存并应用的后端收尾
#
# 流程：sys post_apply（秒回）→ 派 apply_worker（后台）→ 前端轮询 sys apply_state。
#
# 为什么必须后台化：重启 openNDS = 停旧实例（term_timeout 90 秒，通常几秒，
# 忙时可能十几秒）+ 起新实例 + 等就绪，全程可能超过前端 XHR 的 20 秒
# （超了就是「XHR request timed out」红横幅）。post_apply 现在只做秒级
# 收尾就返回，重活全部移进 worker；worker 与 rpcd 完全脱钩（rpcd 超时
# 只 kill 直接子进程，孤儿不受影响）。状态写 CPD_APPLY_STATE，前端据此
# 决定何时刷新页面。
# ① 黑名单 MAC：摘信任、清预认证队列、踢下线（秒级，留在 post_apply 里）
# ② 区域识别模式：把已提交的区域配置部署成门户目录与标记文件（worker）
# ③ 重启 openNDS，让新配置真正加载（worker；本来停着的不主动拉起）

CPD_APPLY_STATE="${CPD_APPLY_STATE:-/tmp/opennds_cpd_apply.state}"
CPD_APPLY_LOCK="${CPD_APPLY_LOCK:-/var/lock/opennds-cpd-apply.lock}"

apply_state_write() { # $1=JSON 整行覆盖
	printf '%s\n' "$1" >"$CPD_APPLY_STATE" 2>/dev/null
	return 0
}

# worker 专用锁：抢不到（上一次还在跑）不报错、静默退出。
# 短重试几秒：上一轮刚写完终态、锁还没放掉的窗口里派生的 worker
# 不至于白跑一趟（它带着晚到的开关请求）。
worker_lock() {
	command -v flock >/dev/null 2>&1 || return 1
	local ld
	ld=$(dirname "$CPD_APPLY_LOCK")
	mkdir -p "$ld" 2>/dev/null
	[ -d "$ld" ] || return 1
	eval "exec 9>\"\$CPD_APPLY_LOCK\"" 2>/dev/null || return 1
	local try=0
	while ! flock -n 9 2>/dev/null; do
		try=$((try + 1))
		[ "$try" -ge 3 ] && return 1
		sleep 1 2>/dev/null || sleep 1
	done
	return 0
}

# ---- 概览页开关/重启的显式请求 --------------------------------------------
# 开关走 openwrt 原生暂存流程（和其它按钮一致），随那次的 uci 增量一起 commit
# 的还有 zone_detect.main.pending_run（1=启动 / 0=停止）；「重启」按钮同理，
# 带的是 zone_detect.main.pending_restart=1。worker 读到就执行。
# 必须与"本来停着的不主动拉起"并存：普通页面应用不带这些键，worker
# 永远不会替它们改 openNDS 状态；只有概览页自己申请的启停/重启才执行。

pending_run_take() { # 读出并立即清掉 pending_run（先清再执行：中途挂了也不能
	# 留着旧请求，否则下一轮普通应用会误执行）；输出 0|1 或空。
	# 值可以是 0/1，也可以是概览页写的 0-<令牌>/1-<令牌>（令牌保证每次
	# 点开关都产生真实 uci 增量，避免已提交的同值键让应用变成空操作）。
	local pr d
	pr=$(uci -q get 'zone_detect.main.pending_run' 2>/dev/null)
	case "$pr" in
		0) d=0 ;;
		1) d=1 ;;
		0-*) d=0 ;;
		1-*) d=1 ;;
		*) return 0 ;;
	esac
	uci -q delete 'zone_detect.main.pending_run' 2>/dev/null
	uci commit zone_detect 2>/dev/null
	printf '%s' "$d"
	return 0
}

pending_restart_take() { # 读出并立即清掉 pending_restart（先清再执行，防误重放）；
	# 输出 1 或空。概览页「重启」按钮走原生暂存流程，随那次的 uci 增量一起 commit。
	local pr
	pr=$(uci -q get 'zone_detect.main.pending_restart' 2>/dev/null)
	if [ "$pr" = '1' ]; then
		uci -q delete 'zone_detect.main.pending_restart' 2>/dev/null
		uci commit zone_detect 2>/dev/null
		printf '%s' '1'
	fi
	return 0
}

restart_exec() { # 概览页「重启」：跑着的走完整 stop→等退出→start；停着的只拉起
	if nds_running; then
		service_restart
	else
		toggle_exec 1
	fi
}

# 彻底停止 openNDS（用户口径 2026-11-22：点关闭后按钮在开/关之间来回横跳，
# 真机上再手动执行一次 service opennds stop 才显示 inactive、页面才稳定）。
# 根因：opennds 由 procd 托管且带 respawn（官方 init：respawn 360 20 15），
# 主程序 conf.c 读到 enabled!=1 就 exit(0)。点关闭时 enabled=0 已随这批应用
# commit，旧进程自退后 procd 把它当意外退出反复拉起；stop 又只等 pidof 空
# 一次就返回，没确认实例真的关掉，于是进程一会儿有一会儿没，页面 5 秒轮询
# 撞上就"开/关"横跳。
# 修法：stop 后做"稳定确认"——连续 CPD_STOP_STABLE 秒看不到进程才算停透；
# 观察期进程又冒出来（被 respawn/残留）就再补一次 stop（等价于用户真机上
# 补敲的那次 service opennds stop）；多轮仍不退才强杀 + 清链收尾。
stop_fully() {
	local i quiet round=0
	local max_round="${CPD_STOP_ROUNDS:-3}"
	local stable="${CPD_STOP_STABLE:-5}"
	while [ "$round" -lt "$max_round" ]; do
		"$NDS_INIT" stop 9>&- >/dev/null 2>&1
		i=0
		while nds_running && [ "$i" -lt "${CPD_STOP_WAIT:-45}" ]; do
			sleep 1 2>/dev/null || sleep 1
			i=$((i + 1))
		done
		# 等不到退出（残留/卡住）才强杀：此刻实例已被 procd delete，不会 respawn
		if nds_running; then
			log "openNDS stop 后仍在运行，强制结束进程"
			kill $(pidof opennds) 2>/dev/null
			sleep 1 2>/dev/null || sleep 1
		fi
		# 稳定确认：连续 stable 秒无进程 = 停透；期间又出现 = 被拉起，下一轮补 stop
		quiet=0
		while [ "$quiet" -lt "$stable" ]; do
			nds_running && break
			sleep 1 2>/dev/null || sleep 1
			quiet=$((quiet + 1))
		done
		[ "$quiet" -ge "$stable" ] && break
		round=$((round + 1))
	done
	"$LIBOPENNDS" delete_chains 9>&- >/dev/null 2>&1
	return 0
}

toggle_exec() { # $1=0|1（口径与原 ov_set_run 一致，只是搬进了 worker）
	local want="$1" lo tp
	if [ "$want" = '1' ]; then
		# 用户点「启动」才补：登录模式 3 且脚本路径为空（缺失），不覆盖用户自己设的值
		lo=$(uci_val 'opennds.@opennds[0].login_option_enabled' '')
		tp=$(uci_val 'opennds.@opennds[0].themespec_path' '')
		if [ "$lo" = '3' ] && [ -z "$tp" ]; then
			uci set 'opennds.@opennds[0].themespec_path'='/usr/lib/opennds/theme_zone_detect.sh'
			uci commit opennds 2>/dev/null
		fi
		"$NDS_INIT" start 9>&- >/dev/null 2>&1
		wait_ready_n "${CPD_READY_WAIT:-24}"
	else
		stop_fully
	fi
	return 0
}

apply_worker() {
	if ! worker_lock; then
		# 已有 worker 在跑：状态文件归它管。这里绝不能写 busy/done，
		# 否则会把正在跑的那一轮的进度（done:0）覆盖成完成，前端会提前刷新。
		# 晚到的开关请求由正在跑的 worker 在收尾检查里捞起（见下方循环）。
		return 0
	fi
	local was=0 now=0 deployed=0 zr ok=1 err='' scope pr rounds=0
	# was 从状态文件取（post_apply 在应用后第一时间记录的口径）；
	# 文件缺失（手工调试）就按当前状态推
	[ -f "$CPD_APPLY_STATE" ] &&
		was=$(sed -n 's/.*"was_running":\([01]\).*/\1/p' "$CPD_APPLY_STATE" 2>/dev/null)
	[ "$was" = '1' ] || was=0
	log "apply_worker 开始（was_running=$was）"
	apply_state_write '{"ok":1,"done":0,"phase":"working","was_running":'"$was"'}'
	# ① 这次应用带了开关请求 → 它说了算：只启/停，不部署不重启
	#   （口径与原 ov_set_run 一致：启动不部署门户目录，部署由随后的
	#    正常应用流程负责；停止更没有部署可言）
	# ①b 这次应用带了概览页「重启」请求 → 只重启，不部署
	pr=$(pending_run_take)
	if [ -n "$pr" ]; then
		log "apply_worker：概览页开关请求 pending_run=$pr"
		toggle_exec "$pr"
	elif [ -n "$(pending_restart_take)" ]; then
		log 'apply_worker：概览页重启请求 pending_restart=1'
		if ! restart_exec; then
			ok=0
			err='重启失败：openNDS 未能启动，请检查 openNDS 日志'
		fi
	else
		# ② 普通应用：区域识别模式部署 + 重启让配置生效
		# 区域识别模式：把已提交的区域配置部署成门户目录与标记文件。
		# 判据必须看 z_apply 回的 JSON，不能看退出码 —— out_err 是 exit 0，
		# 光看退出码会把"什么都没做"当成部署成功。
		scope=$(uci -q get 'zone_detect.main.scope' 2>/dev/null)
		if [ "$scope" = 'zone' ]; then
			if [ -n "$(uci -q get 'zone_detect.main.wireless' 2>/dev/null)" ]; then
				zr=$( (z_apply wireless) 2>/dev/null )
				case "$zr" in
					*'"ok":1'*) deployed=1 ;;
					*need_confirm*) log 'apply_worker：openNDS 处于停用状态，跳过无线区域部署' ;;
					*) log "apply_worker：无线区域部署失败：$zr" ;;
				esac
			fi
			if [ -n "$(uci -q get 'zone_detect.main.wired' 2>/dev/null)" ]; then
				zr=$( (z_apply wired) 2>/dev/null )
				case "$zr" in
					*'"ok":1'*) deployed=1 ;;
					*need_confirm*) log 'apply_worker：openNDS 处于停用状态，跳有线区域部署' ;;
					*) log "apply_worker：有线区域部署失败：$zr" ;;
				esac
			fi
		fi
		kick_preemptive
		# z_apply 内部已经重启过，别再来一次；本来停着的不主动拉起
		if [ "$deployed" = '0' ] && [ "$was" = '1' ]; then
			if ! service_restart; then
				ok=0
				err='配置已提交，但 openNDS 未能启动，请检查 openNDS 日志'
			fi
		fi
	fi
	# ③ 收尾前再捞一遍晚到的开关/重启请求：worker 干活（重启要十几秒）期间，
	#    用户可能又应用了一次开关或重启操作，它的请求等 worker 完事才执行。
	#    上限 3 轮防失控；没有新请求就立刻出去。
	while [ "$rounds" -lt 3 ]; do
		pr=$(pending_run_take)
		if [ -z "$pr" ]; then
			[ -n "$(pending_restart_take)" ] && pr='restart'
		fi
		[ -z "$pr" ] && break
		if [ "$pr" = 'restart' ]; then
			log 'apply_worker：捞起晚到的重启请求 pending_restart=1'
			if ! restart_exec; then
				ok=0
				err='重启失败：openNDS 未能启动，请检查 openNDS 日志'
			fi
		else
			log "apply_worker：捞起晚到的开关请求 pending_run=$pr"
			toggle_exec "$pr"
		fi
		rounds=$((rounds + 1))
	done
	nds_running && now=1
	apply_state_write '{"ok":'"$ok"',"done":1,"zone":'"$deployed"',"was_running":'"$was"',"running":'"$now"',"error":"'$(json_escape "$err")'"}'
	log "apply_worker 完成（ok=$ok was_running=$was running=$now zone=$deployed）"
	return 0
}

sys_apply_state() {
	if [ -s "$CPD_APPLY_STATE" ]; then
		cat "$CPD_APPLY_STATE"
	else
		printf '{"ok":1,"done":1,"idle":1}\n'
	fi
	return 0
}

sys_post_apply() {
	local m lm was=0 now=0 ts
	nds_running && was=1
	# 应用后先清掉名单里的重复条目（同一 MAC 只能有一个身份）：
	# 用户设备上历史遗留的"既在可信任又在黑名单"会在这里被修正
	sys_dedup_lists
	# 概览页「解除认证」走暂存：待踢的 MAC 记在 zone_detect.main.pending_deauth，
	# openwrt「保存并应用」commit 之后在这里执行（踢下线 + 清预认证队列），然后清掉
	for m in $(list_of 'zone_detect.main.pending_deauth'); do
		[ -n "$m" ] || continue
		lm=$(mac_lower "$m")
		remove_preauth_queue "$lm"
		ndsctl_mac deauth "$lm"
	done
	if [ -n "$(uci -q get 'zone_detect.main.pending_deauth' 2>/dev/null)" ]; then
		uci -q delete 'zone_detect.main.pending_deauth'
		uci commit zone_detect
	fi
	for m in $(list_of 'opennds.@opennds[0].blockedmac'); do
		[ -n "$m" ] || continue
		lm=$(mac_lower "$m")
		ndsctl_mac untrust "$lm"
		remove_preauth_queue "$lm"
		ndsctl_mac deauth "$lm"
	done
	nds_running && now=1
	# worker 已经在跑：不再叠加一轮，前端继续等当前这一轮的结果
	if [ -s "$CPD_APPLY_STATE" ] &&
		grep -q '"done":0' "$CPD_APPLY_STATE" 2>/dev/null; then
		ts=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$CPD_APPLY_STATE" 2>/dev/null)
		case "$ts" in
			'' | *[!0-9]*) ts=0 ;;
		esac
		if [ $(( $(date +%s) - ts )) -lt 150 ]; then
			printf '{"ok":1,"bg":1,"already":1,"was_running":%s,"running":%s}\n' "$was" "$now"
			return 0
		fi
	fi
	ts=$(date +%s)
	apply_state_write '{"ok":1,"done":0,"phase":"starting","was_running":'"$was"',"ts":'"$ts"'}'
	# 派生 worker：双重 fork 成孤儿 + 全部 fd 关闭（stdout 管道不关，
	# rpcd 的应答会一直等到 EOF）。rpcd 超时只 kill 直接子进程，孤儿不受影响。
	SELF_PATH="${0:-/usr/lib/opennds/opennds-cpd-api.sh}"
	# 经 sh 启动：不依赖执行位（SFTP/某些安装方式可能把权限弄丢）
	( sh "$SELF_PATH" apply_worker </dev/null >/dev/null 2>&1 & ) 2>/dev/null
	printf '{"ok":1,"bg":1,"was_running":%s,"running":%s}\n' "$was" "$now"
	return 0
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
			selfcheck) ov_selfcheck ;;
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
			apply_state) sys_apply_state ;;
			*) out_err "sys：未知子命令 $SUB" ;;
		esac
		;;
	apply_worker)
		apply_worker
		;;
	'')
		out_err '缺少页面名'
		;;
	*)
		out_err "未知页面：$PAGE"
		;;
esac
