include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for openNDS Captive Portal
LUCI_DESCRIPTION:=Manage openNDS captive portal: zones, sessions, exemptions, \
	blacklist, router access and walled garden.
LUCI_DEPENDS:=+luci-base +rpcd-mod-file +opennds +flock +iw
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-opennds-cpd
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/zone_blacklist
/etc/config/zone_detect
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/lib/opennds/opennds-cpd-api.sh
	chmod 755 /usr/lib/opennds/theme_zone_detect.sh
	mkdir -p /usr/lib/opennds/cpd/wireless /usr/lib/opennds/cpd/wired /usr/lib/opennds/cpd/blacklist
	mkdir -p /usr/lib/opennds/cpd/default/wireless /usr/lib/opennds/cpd/default/wired /usr/lib/opennds/cpd/default/blacklist
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache
	# 登录模式为 3 时把主题脚本指向本插件的区域识别分发脚本
	if [ "$$$$(uci -q get opennds.@opennds[0].login_option_enabled 2>/dev/null)" = "3" ] && \
	   [ "$$$$(uci -q get opennds.@opennds[0].themespec_path 2>/dev/null)" != "/usr/lib/opennds/theme_zone_detect.sh" ]; then
		uci set opennds.@opennds[0].themespec_path='/usr/lib/opennds/theme_zone_detect.sh'
		uci commit opennds
		[ -z "$$$$(pidof opennds 2>/dev/null)" ] || /etc/init.d/opennds restart >/dev/null 2>&1
	fi
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))

