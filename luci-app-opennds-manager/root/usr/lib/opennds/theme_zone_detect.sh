#!/bin/sh
# Network Zone Detection - ThemeSpec dispatcher for openNDS (login mode 3)
# Installed at: /usr/lib/opennds/theme_zone_detect.sh
# CPD-VERSION: r10 (2026-11-28) —— 在路由器上执行
#   grep CPD-VERSION /usr/lib/opennds/theme_zone_detect.sh
# 可核对装的是不是本版本（排查"脚本没更新"用）。
#
# openNDS configuration (/etc/config/opennds):
#     option login_option_enabled '3'
#     option themespec_path '/usr/lib/opennds/theme_zone_detect.sh'
#
# Execution model (IMPORTANT - this is why the dispatch is not in the body):
#   libopennds.sh sources this script LONG BEFORE it parses the FAS query
#   string, so at source time $clientmac is EMPTY. clientmac/clientip are
#   only filled in later by get_arguments(); header() and
#   generate_splash_sequence() are called by libopennds AFTER that.
#   Therefore ALL per-client decisions (blacklist match, zone detection,
#   portal resolution) run inside those wrapper functions, never here.
#
# How it works:
#   openNDS (libopennds.sh) sources this script and then calls, in order:
#     header()               - we dispatch (pick portal, source it) here
#     check_authenticated()  - libopennds built-in
#     generate_splash_sequence() - resolves to the PORTAL's implementation
#   after sourcing, so the portal's own header/footer/page functions are
#   used. This dispatcher therefore:
#
#   0. If the client MAC is in the plugin blacklist (opennds blockedmac), it is
#      served /usr/lib/opennds/cpd/blacklist/<selected portal>; when that is
#      empty it falls to the Settings-page default blacklist portal
#      (cpd/default/blacklist/<portal_blacklist>, else default.sh), so it never
#      gets the zone portal's authenticate button and stays offline.
#   0b. When zone_detect.main.scope is "global" (zone detection disabled on the
#       zone page), every non-blacklisted client is served the global portal:
#       cpd/global/<portal_global>, else cpd/global/default.sh.
#   1. Uses get_client_interface.sh to find the local interface the client
#      is connected to (by client MAC).
#   2. If the interface is a local wireless interface (found in "iw dev"),
#      the zone is wireless: the configured SSID of that interface is looked
#      up in /etc/config/wireless (uci) and the portal is searched in
#          /usr/lib/opennds/cpd/wireless/<SSID>/
#   3. Otherwise the zone is wired: the portal is searched in
#          /usr/lib/opennds/cpd/wired/<interface, e.g. br-lan>/
#   4. Portal resolution inside the zone directory (files keep the name they
#      were uploaded with - LuCI never renames them):
#        a) If LuCI marked this zone as "use the type default"
#           (/usr/lib/opennds/zone_markers contains "type|zone|"):
#              the type default portal (see 4b)
#        b) Otherwise the portal LuCI recorded for this zone in
#           /etc/config/zone_detect:
#              zone_detect.main.wireless = 'SSID|portal.sh'
#              zone_detect.main.wired    = 'br-lan|portal.sh'
#           resolved as <zone>/<portal.sh> or <zone>/<portal>/default.sh
#           (older folder uploads used theme.sh and are still accepted)
#        c) <zone>/default/default.sh  (per-zone fallback)
#        d) type default portal: cpd/default/<type>/<selected>.sh
#           (zone_detect.main.portal_<type>), else
#           cpd/default/<type>/default.sh
#   5. 找不到任何门户时**不回落内置主题**：出示一个没有任何按钮的提示页
#      （客户端保持未认证）。门户页只来自本插件管理的目录，绝不混入
#      openNDS 自带主题（2026-11-20 用户定稿）。
#
# Warning - shebang "sh" is for compatibility with busybox ash (eg on OpenWrt)

CPD_ROOT="/usr/lib/opennds/cpd"
ZONE_ROOT_WIRELESS="$CPD_ROOT/wireless"
ZONE_ROOT_WIRED="$CPD_ROOT/wired"
ZONE_ROOT_GLOBAL="$CPD_ROOT/global"
DEFAULT_ROOT="$CPD_ROOT/default"
MARKERS="/usr/lib/opennds/zone_markers"
ZONE_DETECT_CONFIG="/etc/config/zone_detect"

zone_debug() {
	# 分发决策日志：用 notice 级别，logread 默认就能看到
	# （排查"客户端收到的是什么门户"用：logread | grep zone_detect）
	echo -n "zone_detect - [$1]" | logger -p daemon.notice -t "opennds[$ndspid]" 2>/dev/null
}

# Uppercase a MAC address without forks where possible (tr is cheap enough here).
mac_upper() {
	echo "$1" | tr 'a-z' 'A-Z'
}

# ---- 有效期内漏恢复的客户端，重连时静默放行（不弹门户） ----
# 场景：关 NDS 时客户端离线（如手机切到别的 WiFi），开机那一次恢复没赶上；
#       等它重新连回来时，openNDS 会把它当新设备弹门户。这里在门户脚本阶段
#       认出这类客户端，用官方 ndsctl auth 按剩余时长静默放行。
# 判据（三者同时满足才放行，避免误放）：
#   1. 账本 authlog 里该 MAC 仍在有效期内（未到期）
#   2. binauthlog 末条是该 MAC 的 shutdown_deauth / preemptive_auth
#      —— 即"因关机下线/曾恢复"，而非主动登出、超时、空闲踢、ndsctl 解绑
#   3. 当前请求确实是未认证客户端（能走到门户脚本就说明未认证）
# 命中后 ndsctl auth "$mac,$剩余分钟"，显式时长保住原到期时间。
# 本函数在 libopennds.sh source 后的 header 阶段运行，clientmac 已就绪，
# 处在同一 shell，可直接用 libopennds 的 do_ndsctl（无死锁）。
cpd_auto_restore() {
	# clientmac 由 libopennds 的 get_arguments 解码后填充，进入门户阶段时应已就绪
	[ -z "$clientmac" ] && return 0

	# 黑名单客户端绝不自动放行：必须先排除，否则会绕过黑名单门户直接上网
	for _blm in $(uci -q get 'opennds.@opennds[0].blockedmac' 2>/dev/null); do
		[ -z "$_blm" ] && continue
		[ "$(mac_upper "$_blm")" = "$(mac_upper "$clientmac")" ] && return 0
	done

	local cdir authlog bl now kb lm exp left mins lastm
	cdir=$(zone_logdir)
	authlog="$cdir/authlog.log"
	bl="$cdir/binauthlog.log"
	[ -f "$authlog" ] || return 0
	now=$(date +%s)

	# ① 账本 authlog 每行是 base64(mac)=session_end，逐行解码 MAC 找未到期的那条
	exp=""
	while IFS='=' read -r kb ev; do
		case "$kb" in ''|*[!A-Za-z0-9+/]*) continue;; esac
		case "$ev" in ''|*[!0-9]*) continue;; esac
		lm=$(ndsctl b64decode "${kb}==" 2>/dev/null | tr 'A-Z' 'a-z')
		[ "$lm" = "$(printf '%s' "$clientmac" | tr 'A-Z' 'a-z')" ] || continue
		[ "$ev" -gt "$now" ] || continue
		exp="$ev"
	done <"$authlog"
	[ -n "$exp" ] || return 0

	# ② binauthlog 里该 MAC 的最后一条必须是"关机下线/恢复记录"
	#    主动登出(client_deauth)、超时(timeout_deauth)、空闲(idle_deauth)、
	#    ndsctl 解绑(ndsctl_deauth) 一律不放行。
	lastm=''
	[ -f "$bl" ] && lastm=$(grep -iF "$clientmac" "$bl" 2>/dev/null | tail -1 |
		awk -F'method=' '{print $2}' | awk -F', ' '{printf "%s", $1}' | tr -d '"')
	case "$lastm" in
		shutdown_deauth|preemptive_auth) ;;
		*) return 0;;
	esac

	# ③ 剩余分钟（向上取整、至少 1），ndsctl auth 显式时长保住原到期时间
	left=$(( exp - now ))
	mins=$(( (left + 59) / 60 ))
	[ "$mins" -lt 1 ] && mins=1

	do_ndsctl auth "$clientmac" "$mins"
	[ "$ndsstatus" = "authenticated" ] || return 0
	zone_debug "auto-restored $clientmac (${mins} min left), skip portal"
	# 输出一个极简成功页，CPD 检测到已联网会自动关闭浏览器，用户无感
	echo '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>OK</body></html>'
	exit 0
}

# 算 openNDS 落盘日志目录（与 api.sh 的 authlog_dir 同口径）
zone_logdir() {
	# 沙箱覆盖优先（测试用）
	[ -n "${CPD_NDSLOG_DIR:-}" ] && { printf '%s' "$CPD_NDSLOG_DIR"; return 0; }
	# 真机上 libopennds.sh 的 configure_log_location 已算好 $logdir 并 source 进来，
	# 直接用它最稳（与 openNDS 实际写入目录百分百一致），省去重复探测。
	[ -n "${logdir:-}" ] && { printf '%s' "${logdir%/}"; return 0; }
	# 兜底：自行探测（旧版或非 libopennds 调用场景）
	local mp d
	mp=$(uci -q get 'opennds.@opennds[0].log_mountpoint' 2>/dev/null)
	if [ -n "$mp" ]; then printf '%s/ndslog' "$mp"; return 0; fi
	for d in /tmp /run /var; do
		if df 2>/dev/null | awk -v x="$d" '$1 == "tmpfs" && $6 == x {f=1} END {exit !f}'; then
			printf '%s/ndslog' "$d"; return 0
		fi
	done
	printf '/tmp/ndslog'
}

# iw 把非 ASCII 字节转义成 \xNN（中文 SSID 真机上就是
#   ssid \xe4\xba\x92\xe8\x81\x94\xe7\xbd\x91），不还原就和门户目录名对不上。
# printf %b 各 shell 对 \xNN 支持不一致，先换算成 POSIX 的 \0OOO 八进制。
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

# Map a runtime wireless interface name (eg phy2-ap0) to its configured SSID
# by parsing /etc/config/wireless:
#   phyN-apM  ->  radio N, M-th (0 based) enabled "ap" wifi-iface on radio N
ssid_from_if() {
	localif="$1"

	# Primary: ask the driver. This is immune both to the phyN-apM numbering
	# scheme and to gaps in it — the uci fallback below counts the M-th
	# enabled AP on the radio, so disabling an AP in the middle of a radio
	# shifts every later index and resolves the wrong SSID (or none).
	# 注意用 [[:space:]]：`[ \t]` 只在 gawk 下才是制表符，mawk/busybox awk
	# 的方括号里 "\\t" 是字面的反斜杠和 t——iw 的续行全用 tab 缩进，匹配不上。
	live_ssid=$(iw dev "$localif" info 2>/dev/null | awk '/^[[:space:]]*ssid[[:space:]]/{sub(/^[[:space:]]*ssid[[:space:]]+/, ""); print; exit}')
	live_ssid=$(ssid_unescape "$live_ssid")
	if [ ! -z "$live_ssid" ]; then
		echo "$live_ssid"
		return
	fi

	radio=$(echo "$localif" | sed -n "s/^phy\([0-9][0-9]*\)-ap[0-9][0-9]*$/\1/p")
	apidx=$(echo "$localif" | sed -n "s/^phy[0-9][0-9]*-ap\([0-9][0-9]*\)$/\1/p")

	if [ -z "$radio" ]; then
		echo ""
		return
	fi

	if [ "$(uci -q get wireless.radio$radio.disabled)" = "1" ]; then
		echo ""
		return
	fi

	ssid=""
	n=0
	for sec in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.device='radio$radio'$/\1/p"); do
		[ "$(uci -q get wireless.$sec.mode)" = "ap" ] || continue
		[ "$(uci -q get wireless.$sec.disabled)" = "1" ] && continue

		if [ "$n" -eq "$apidx" ]; then
			ssid=$(uci -q get wireless.$sec.ssid)
			break
		fi
		n=$((n+1))
	done

	echo "$ssid"
}

# Resolve a portal name inside a portal directory.
#   name empty / "default"  -> <dir>/default.sh
#   name "foo" / "foo.sh"   -> <dir>/foo.sh -> <dir>/foo/default.sh
#                              -> <dir>/foo/theme.sh (旧上传) -> default
# Only plain names are accepted (no slash, no leading dot).
portal_from_name() {
	pdir="$1"
	pname="$2"

	case "$pname" in
		""|default)
			[ -f "$pdir/default.sh" ] && echo "$pdir/default.sh"
			return
			;;
	esac

	# Reject anything that could escape the directory.
	case "$pname" in
		*/*|.*) return;;
	esac

	pbase=$(echo "$pname" | sed 's/\.sh$//')

	if [ -f "$pdir/$pbase.sh" ]; then
		echo "$pdir/$pbase.sh"
	elif [ -f "$pdir/$pbase/default.sh" ]; then
		# 设置页上传的门户文件夹以 default.sh 为主入口
		echo "$pdir/$pbase/default.sh"
	elif [ -f "$pdir/$pbase/theme.sh" ]; then
		# 区域识别页早期上传的文件夹门户用 theme.sh，继续兼容
		echo "$pdir/$pbase/theme.sh"
	elif [ -f "$pdir/default.sh" ]; then
		echo "$pdir/default.sh"
	fi
}

# Portal chosen for one zone by LuCI, stored as a uci list entry
#   zone_detect.main.wireless = 'SSID|portalname'
#   zone_detect.main.wired    = 'br-lan|portalname'
# The portal file keeps the name it was uploaded with (no renaming), so the
# value is used directly as the portal name. Empty output = no choice yet.
portal_for_zone() {
	pz_type="$1"
	pz_zone="$2"
	[ -f "$ZONE_DETECT_CONFIG" ] || return
	uci -q show "zone_detect.main.$pz_type" 2>/dev/null |
		sed -n 's/^[^=]*=//p' |
		awk -F"'" -v z="$pz_zone" '{
			for (i = 2; i <= NF; i += 2) {
				v = $i
				if (v == "") continue
				if (substr(v, 1, length(z) + 1) == z "|") {
					print substr(v, length(z) + 2)
					exit
				}
			}
		}'
}

# Type default portal: the portal selected on the Settings page for this type
# (zone_detect.main.portal_<type>), else the built-in default.sh.
type_default_portal() {
	td_type="$1"
	td_dir="$DEFAULT_ROOT/$td_type"
	[ -d "$td_dir" ] || return
	td_name=""
	[ -f "$ZONE_DETECT_CONFIG" ] &&
		td_name=$(uci -q get "zone_detect.main.portal_$td_type" 2>/dev/null)
	if [ ! -z "$td_name" ] && [ "$td_name" != "default" ]; then
		td_sel=$(portal_from_name "$td_dir" "$td_name")
		if [ ! -z "$td_sel" ]; then
			echo "$td_sel"
			return
		fi
	fi
	[ -f "$td_dir/default.sh" ] && echo "$td_dir/default.sh"
}

# ---- Portal dispatch (runs at CALL time, clientmac is set) -----------------

# Pick the portal for this client: sets zone_type / zone_name / portal
# (empty portal = no portal configured, serve the no-portal notice page).
cpd_pick_portal() {
	zone_type=""
	zone_name=""
	portal=""

	local pr_scope pr_gname pr_clientif pr_cifstr pr_zssid pr_zonedir
	local pr_zoneportal pr_blportal pr_bmac pr_bname

	# ---- Global mode (zone detection disabled on the zone page) ----
	if [ -f "$ZONE_DETECT_CONFIG" ] &&
		[ "$(uci -q get zone_detect.main.scope 2>/dev/null)" = "global" ]; then
		# 全局模式：不做区域识别，直接出全局门户
		# 设置页「默认门户-全局」选的（cpd/global/<portal_global>）→ 内置 default.sh
		zone_type="global"
		zone_name=""
		pr_gname=$(uci -q get zone_detect.main.portal_global 2>/dev/null)
		if [ ! -z "$pr_gname" ] && [ "$pr_gname" != "default" ]; then
			portal=$(portal_from_name "$ZONE_ROOT_GLOBAL" "$pr_gname")
		fi
		if [ -z "$portal" ] && [ -f "$ZONE_ROOT_GLOBAL/default.sh" ]; then
			portal="$ZONE_ROOT_GLOBAL/default.sh"
		fi
		zone_debug "global mode, portal=$portal"
	else
		# ---- Zone detection ----
		if [ ! -z "$clientmac" ]; then
			# get_client_interface.sh prints "<interface>" (plus the mesh node
			# MAC in mesh setups - variable is called clientmeshif but holds a
			# MAC, and the usage text still mentions three fields, which is
			# history; at most two fields are printed) and exits 1 with no output
			# when the client is not in "ip neigh"; ignore both.
			pr_cifstr=$(/usr/lib/opennds/get_client_interface.sh "$clientmac" 2>/dev/null)
			pr_clientif=$(echo "$pr_cifstr" | awk '{printf $1}')
		fi

		if [ ! -z "$pr_clientif" ]; then
			# Is the client on one of OUR wireless interfaces?
			if iw dev 2>/dev/null | awk -F 'Interface ' 'NF>1{print $2}' | grep -qwx "$pr_clientif"; then
				pr_zssid=$(ssid_from_if "$pr_clientif")

				if [ ! -z "$pr_zssid" ]; then
					zone_type="wireless"
					zone_name="$pr_zssid"
				else
					# Wireless interface but no SSID resolvable (disabled/removed
					# from config or mesh/mgd interfaces) - no zone can be matched.
					# Still record the type so the wireless TYPE-DEFAULT portal can
					# catch the client; leaving zone_type empty would build the
					# path ".../cpd/default//default.sh" and skip the type default.
					zone_type="wireless"
					zone_debug "wireless interface $pr_clientif has no resolvable SSID"
				fi
			else
				# Not a wireless interface -> wired zone (eg br-lan)
				zone_type="wired"
				zone_name="$pr_clientif"
			fi
		else
			# Interface unknown (client not in the ARP/neighbour table yet, or
			# mesh setups). We cannot pick a zone, so go straight to the wired
			# type default portal; that is still better than a stock page.
			zone_type="wired"
			zone_name=""
			zone_debug "client $clientmac interface unknown, using wired type default"
		fi
	fi

	# ---- Blacklist ----
	# openNDS 9.4 起废弃了 macmechanism/allowedmaclist/blockedmaclist，主进程不再
	# 自己拦 MAC。本插件的黑名单存在 opennds 的 blockedmac 列表里，由这里执行：
	# 命中名单的客户端不出示区域门户（区域门户里的"继续"按钮会调 ndsctl auth），
	# 只出示黑名单门户，于是它一直停在上不了网的状态，直到从名单里移除。
	pr_blportal=""
	if [ ! -z "$clientmac" ]; then
		for pr_bmac in $(uci -q get opennds.@opennds[0].blockedmac 2>/dev/null); do
			[ ! -z "$pr_bmac" ] || continue
			if [ "$(mac_upper "$pr_bmac")" = "$(mac_upper "$clientmac")" ]; then
				# ①「客户端黑名单」页选中的门户（cpd/blacklist/）
				pr_bname=$(uci -q get zone_detect.main.portal_blacklist_sel 2>/dev/null)
				if [ ! -z "$pr_bname" ] && [ "$pr_bname" != "default" ]; then
					pr_blportal=$(portal_from_name "$CPD_ROOT/blacklist" "$pr_bname")
				fi
				# ② 兼容上一版构建：旧键 portal_blacklist 曾指向 cpd/blacklist/
				if [ -z "$pr_blportal" ]; then
					pr_bname=$(uci -q get zone_detect.main.portal_blacklist 2>/dev/null)
					if [ ! -z "$pr_bname" ] && [ "$pr_bname" != "default" ]; then
						pr_blportal=$(portal_from_name "$CPD_ROOT/blacklist" "$pr_bname")
					fi
				fi
				# ③ 设置页「默认门户-黑名单」选的默认门户（cpd/default/blacklist/）
				if [ -z "$pr_blportal" ]; then
					pr_blportal=$(type_default_portal blacklist)
				fi
				zone_type="blacklist"
				zone_name=""
				portal="$pr_blportal"
				zone_debug "client $clientmac is blacklisted, portal=$portal"
				break
			fi
		done
	fi

	# ---- Portal resolution (blacklist already resolved above) ----
	if [ "$zone_type" != "blacklist" ]; then

		# A zone name is used as a directory name. An SSID is arbitrary octets, so it
		# may contain "/" or be "." / ".." -- both would escape the portal root.
		case "$zone_name" in
			*/*|.|..)
				zone_debug "zone name '$zone_name' is not a safe path component, using type default"
				zone_name=""
				;;
		esac

		if [ ! -z "$zone_name" ]; then
			if [ "$zone_type" = "wireless" ]; then
				pr_zonedir="$ZONE_ROOT_WIRELESS/$zone_name"
			else
				pr_zonedir="$ZONE_ROOT_WIRED/$zone_name"
			fi

			zone_debug "client $clientmac zone=$zone_type/$zone_name"

			if [ -f "$MARKERS" ] && awk -F'|' -v t="$zone_type" -v z="$zone_name" \
				'NF >= 2 && $1 == t && $2 == z { found = 1; exit } END { exit !found }' "$MARKERS" 2>/dev/null; then
				# LuCI marked this zone as "use the type default portal"
				portal=$(type_default_portal "$zone_type")
			else
				# Portal picked for this very zone (file keeps its uploaded name)
				pr_zoneportal=$(portal_for_zone "$zone_type" "$zone_name")
				if [ ! -z "$pr_zoneportal" ]; then
					portal=$(portal_from_name "$pr_zonedir" "$pr_zoneportal")
				fi
				# Directory level default used when the zone has no explicit choice
				if [ -z "$portal" ] && [ -f "$pr_zonedir/default/default.sh" ]; then
					portal="$pr_zonedir/default/default.sh"
				fi
			fi

			if [ -z "$portal" ]; then
				portal=$(type_default_portal "$zone_type")
			fi
		else
			# No zone name (unknown interface, or global mode where the portal
			# was already picked above): type default only - but never clobber
			# a portal the global branch already resolved (cpd/global/), the
			# type lookup (cpd/default/global/) has no directory for it and
			# would wipe it.
			[ -z "$portal" ] && portal=$(type_default_portal "$zone_type")
		fi

	fi

	# 找不到任何门户：不回落内置主题（2026-11-20 用户定稿）。这里也是排查
	# 黑名单门户的落点：黑名单客户端走到这说明 cpd/default/blacklist/ 没有
	# 门户文件。
	if [ -z "$portal" ] || [ ! -f "$portal" ]; then
		portal=""
		zone_debug "no portal found (zone_type=$zone_type zone_name=$zone_name), serving no portal"
		return 0
	fi

	userinfo="zone=$zone_type/$zone_name, portal=$portal"
	return 0
}

# No-portal notice page body: no authenticate button of any kind, so the
# client simply stays unauthenticated (openNDS serves default_header before
# calling generate_splash_sequence; footer falls back to default_footer).
cpd_no_portal_page() {
	echo "
		<p>
			<big-red>
				$(echo "$gatewayname" | htmlentityencode 2>/dev/null || echo "$gatewayname")
			</big-red>
		</p>
		<hr>
		<p>
			<italic-black>
				此网络暂未提供认证门户，无法完成认证。请联系网络管理员。
			</italic-black>
		</p>
	"
	footer
}

# ---- libopennds entry points -----------------------------------------------
# header() is the first one called per request, and the earliest point where
# clientmac is guaranteed to be parsed - so the dispatch (pick portal and
# source it) happens here. Sourcing the portal overwrites header()/footer()/
# generate_splash_sequence() with the portal's implementations; the instance
# currently running keeps its own body (shell semantics), and the dispatch
# flag below makes the subsequent name lookups resolve to the portal's code
# exactly once, with no recursion.

header() {
	# 先判断是否漏恢复的客户端：是则静默放行并退出，不弹门户
	cpd_auto_restore
	if [ -z "$CPD_DISPATCHED" ]; then
		CPD_DISPATCHED=1
		cpd_pick_portal
		if [ ! -z "$portal" ] && [ -f "$portal" ]; then
			CPD_PORTAL_OK=1
			. "$portal"
			# 门户定义了 header 就转调它的；没定义（少见）落到下面的兜底。
			# 注意：这里按名字调用解析到的是 source 后的最新定义；
			# 若门户没定义 header，会递归回本函数——CPD_DISPATCHED 已置位，
			# 直接落到兜底输出，不会死循环。
			header
			return
		fi
		CPD_PORTAL_OK=0
	fi
	# 兜底 header（无门户，或门户没自定义 header）：与 libopennds
	# default_header 相同的结构，保证门户 footer 的 div 层级能闭合
	echo "<!DOCTYPE html>
		<html>
		<head>
		<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
		<meta http-equiv=\"Pragma\" content=\"no-cache\">
		<meta http-equiv=\"Expires\" content=\"0\">
		<meta charset=\"utf-8\">
		<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
		<link rel=\"shortcut icon\" href=\"/images/splash.jpg\" type=\"image/x-icon\">
		<link rel=\"stylesheet\" type=\"text/css\" href=\"/splash.css\">
		<title>$gatewayname</title>
		</head>
		<body>
		<div class=\"offset\">
		<med-blue>
			$gatewayname <br>
		</med-blue>
		<div class=\"insert\" style=\"max-width:100%;\">
	"
}

footer() {
	# 门户定义了自己的 footer 时，本定义在 source 时被门户覆盖，进不到这里；
	# 能进来说明门户没自定义 footer：用 libopennds 的默认 footer 收尾。
	default_footer
}

generate_splash_sequence() {
	if [ -z "$CPD_DISPATCHED" ]; then
		# header 没先被调（不应发生，但防御一下）：先分发
		CPD_DISPATCHED=1
		cpd_pick_portal
		if [ ! -z "$portal" ] && [ -f "$portal" ]; then
			CPD_PORTAL_OK=1
			. "$portal"
		else
			CPD_PORTAL_OK=0
		fi
	fi
	if [ "$CPD_PORTAL_OK" = "1" ]; then
		if [ -z "$CPD_GS_CALLED" ]; then
			CPD_GS_CALLED=1
			# 门户的 generate_splash_sequence（按名字解析到 source 后的定义；
			# 若门户没定义会解析回本函数，CPD_GS_CALLED 已置位，落到兜底）
			generate_splash_sequence
			return
		fi
	fi
	# 无门户（或门户没有页面函数）：出示无按钮提示页
	cpd_no_portal_page
}
