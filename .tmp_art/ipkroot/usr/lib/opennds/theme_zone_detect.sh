#!/bin/sh
# Network Zone Detection - ThemeSpec dispatcher for openNDS (login mode 3)
# Installed at: /usr/lib/opennds/theme_zone_detect.sh
#
# openNDS configuration (/etc/config/opennds):
#     option login_option_enabled '3'
#     option themespec_path '/usr/lib/opennds/theme_zone_detect.sh'
#
# How it works:
#   openNDS (libopennds.sh) sources this script and then calls the
#   generate_splash_sequence() function defined by the portal script we
#   source below. This dispatcher therefore:
#
#   0. If the client MAC is in the blacklist (/etc/config/zone_blacklist),
#      it is served the blacklist portal instead of a zone portal.
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
#           resolved as <zone>/<portal.sh> or <zone>/<portal>/theme.sh
#        c) <zone>/default/default.sh  (per-zone fallback)
#        d) type default portal: cpd/default/<type>/<selected>.sh
#           (zone_detect.main.portal_<type>), else
#           cpd/default/<type>/default.sh
#   5. If nothing is found, falls back to the stock
#      theme_click-to-continue-basic.sh so clients always get a portal.
#
# Warning - shebang "sh" is for compatibility with busybox ash (eg on OpenWrt)

CPD_ROOT="/usr/lib/opennds/cpd"
ZONE_ROOT_WIRELESS="$CPD_ROOT/wireless"
ZONE_ROOT_WIRED="$CPD_ROOT/wired"
ZONE_ROOT_BLACKLIST="$CPD_ROOT/blacklist"
DEFAULT_ROOT="$CPD_ROOT/default"
MARKERS="/usr/lib/opennds/zone_markers"
BLACKLIST_CONFIG="/etc/config/zone_blacklist"
ZONE_DETECT_CONFIG="/etc/config/zone_detect"
FALLBACK_THEME="/usr/lib/opennds/theme_click-to-continue-basic.sh"

zone_debug() {
	# debug log helper, visible with "logread | grep zone_detect"
	echo -n "zone_detect - [$1]" | logger -p daemon.debug -t "opennds[$ndspid]" 2>/dev/null
}

# Uppercase a MAC address without forks where possible (tr is cheap enough here).
mac_upper() {
	echo "$1" | tr 'a-z' 'A-Z'
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
	live_ssid=$(iw dev "$localif" info 2>/dev/null | awk '/^[ \t]*ssid[ \t]/{sub(/^[ \t]*ssid[ \t]+/, ""); print; exit}')
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
#   name "foo" / "foo.sh"   -> <dir>/foo.sh -> <dir>/foo/theme.sh -> default
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
	elif [ -f "$pdir/$pbase/theme.sh" ]; then
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

# ---- Blacklist check (highest priority) -----------------------------------

zone_type=""
zone_name=""
clientif=""
portal=""

if [ ! -z "$clientmac" ] && [ -f "$BLACKLIST_CONFIG" ]; then
	cmac=$(mac_upper "$clientmac")
	for bmac in $(uci -q get zone_blacklist.main.mac); do
		if [ "$(mac_upper "$bmac")" = "$cmac" ]; then
			# Blacklisted: ignore zones entirely, serve the blacklist portal.
			bportal=$(uci -q get zone_blacklist.main.portal)
			portal=$(portal_from_name "$ZONE_ROOT_BLACKLIST" "$bportal")
			if [ -z "$portal" ]; then
				portal=$(type_default_portal blacklist)
			fi
			if [ -z "$portal" ]; then
				portal="$FALLBACK_THEME"
			fi
			zone_type="blacklist"
			zone_name="$cmac"
			zone_debug "client $clientmac is blacklisted, portal=$portal"
			break
		fi
	done
fi

# ---- Zone detection -------------------------------------------------------

if [ -z "$zone_type" ]; then
	if [ ! -z "$clientmac" ]; then
		# get_client_interface.sh prints "<interface>" (plus the mesh node
		# MAC in mesh setups - variable is called clientmeshif but holds a
		# MAC, and the usage text still mentions three fields, which is
		# history; at most two fields are printed) and exits 1 with no output
		# when the client is not in "ip neigh"; ignore both.
		client_if_string=$(/usr/lib/opennds/get_client_interface.sh "$clientmac" 2>/dev/null)
		clientif=$(echo "$client_if_string" | awk '{printf $1}')
	fi

	if [ ! -z "$clientif" ]; then
		# Is the client on one of OUR wireless interfaces?
		if iw dev 2>/dev/null | awk -F 'Interface ' 'NF>1{print $2}' | grep -qwx "$clientif"; then
			zssid=$(ssid_from_if "$clientif")

			if [ ! -z "$zssid" ]; then
				zone_type="wireless"
				zone_name="$zssid"
			else
				# Wireless interface but no SSID resolvable (disabled/removed
				# from config or mesh/mgd interfaces) - no zone can be matched.
				# Still record the type so the wireless TYPE-DEFAULT portal can
				# catch the client; leaving zone_type empty would build the
				# path ".../cpd/default//default.sh" and skip the type default.
				zone_type="wireless"
				zone_debug "wireless interface $clientif has no resolvable SSID"
			fi
		else
			# Not a wireless interface -> wired zone (eg br-lan)
			zone_type="wired"
			zone_name="$clientif"
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

# ---- Portal resolution ----------------------------------------------------

# A zone name is used as a directory name. An SSID is arbitrary octets, so it
# may contain "/" or be "." / ".." -- both would escape the portal root.
case "$zone_name" in
	*/*|.|..)
		zone_debug "zone name '$zone_name' is not a safe path component, using type default"
		zone_name=""
		;;
esac

if [ "$zone_type" = "blacklist" ]; then
	: # portal already resolved above
elif [ ! -z "$zone_name" ]; then
	if [ "$zone_type" = "wireless" ]; then
		zonedir="$ZONE_ROOT_WIRELESS/$zone_name"
	else
		zonedir="$ZONE_ROOT_WIRED/$zone_name"
	fi

	zone_debug "client $clientmac zone=$zone_type/$zone_name"

	if [ -f "$MARKERS" ] && awk -F'|' -v t="$zone_type" -v z="$zone_name" \
		'NF >= 2 && $1 == t && $2 == z { found = 1; exit } END { exit !found }' "$MARKERS" 2>/dev/null; then
		# LuCI marked this zone as "use the type default portal"
		portal=$(type_default_portal "$zone_type")
	else
		# Portal picked for this very zone (file keeps its uploaded name)
		zone_portal=$(portal_for_zone "$zone_type" "$zone_name")
		if [ ! -z "$zone_portal" ]; then
			portal=$(portal_from_name "$zonedir" "$zone_portal")
		fi
		# Directory level default used when the zone has no explicit choice
		if [ -z "$portal" ] && [ -f "$zonedir/default/default.sh" ]; then
			portal="$zonedir/default/default.sh"
		fi
	fi

	if [ -z "$portal" ]; then
		portal=$(type_default_portal "$zone_type")
	fi
else
	# No zone name (unknown interface): type default only.
	portal=$(type_default_portal "$zone_type")
fi

if [ ! -f "$portal" ]; then
	portal="$FALLBACK_THEME"
	zone_debug "no zone portal found, falling back to $portal"
fi

# We are sourced by libopennds.sh: never exit(), just return and let openNDS
# report the missing generate_splash_sequence() itself.
if [ -z "$portal" ] || [ ! -f "$portal" ]; then
	zone_debug "no portal at all, giving up"
	return 0
fi

userinfo="zone=$zone_type/$zone_name, portal=$portal"

# Source the portal script. It defines generate_splash_sequence() and sets
# its own quota/portal variables; openNDS (libopennds.sh) will call
# generate_splash_sequence() right after this include returns.
# NOTE: do NOT exit here - we are sourced inside libopennds.sh!
. "$portal"
