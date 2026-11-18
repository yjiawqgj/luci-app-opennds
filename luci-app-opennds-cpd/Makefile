include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for openNDS Captive Portal
LUCI_DESCRIPTION:=Manage openNDS captive portal: zones, sessions, exemptions, \
	blacklist, router access and walled garden.
LUCI_DEPENDS:=+luci-base +rpcd-mod-file +opennds +flock +iw
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-opennds-cpd
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/zone_detect
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
# 只做文件权限与目录准备：绝不修改 openNDS 的任何配置项。
# 插件所有界面数据一律从现有 /etc/config/opennds 读取，不写默认值、不清空列表。
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/lib/opennds/opennds-cpd-api.sh
	chmod 755 /usr/lib/opennds/theme_zone_detect.sh
	mkdir -p /usr/lib/opennds/cpd/wireless /usr/lib/opennds/cpd/wired
	mkdir -p /usr/lib/opennds/cpd/default/wireless /usr/lib/opennds/cpd/default/wired
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))

