# luci-app-opennds-cpd

一个 OpenWrt LuCI 插件，为 [openNDS](https://github.com/openNDS/openNDS) 强制门户（Captive Portal）提供图形化管理界面。

插件把 openNDS 现有配置映射成网页操作：网络区域识别、客户端会话、特权客户端、黑名单、路由器访问、Walled Garden、访问限制等。所有界面数据都从 openNDS 原生配置读取，**不修改、不清空 openNDS 的任何配置项**。

## 功能页面

安装后在 LuCI 菜单 **服务 → openNDS** 下：

| 页面 | 说明 |
| --- | --- |
| 概览 | 运行状态与在线/认证客户端统计、启动与停止 |
| 网络区域识别 | 按无线/有线区域分发对应的门户主题 |
| 客户端会话管理 | 查看会话、空闲超时、未认证超时设置 |
| 特权客户端 | 信任客户端与免认证客户端管理 |
| 客户端黑名单 | 拒绝指定客户端认证，可为其配置专用门户 |
| 路由器访问 | 是否由本插件接管路由器访问策略 |
| Walled Garden | 允许未认证客户端访问指定网站（手动/自动列表） |
| 访问限制 | 域名、IP、端口的放行规则 |
| 设置 | 无线/有线区域、黑名单、全局门户配置 |

## 依赖

- `luci-base`
- `rpcd-mod-file`
- `opennds`
- `flock`
- `iw`

适用于 OpenWrt 24.10 及 snapshot（分别产出 `.ipk` 与 `.apk` 包）。

## 编译

本仓库自带 GitHub Actions 工作流 `.github/workflows/build.yml`，推送到 `main` 或 `master` 会自动编译；也可以在 Actions 页面手动点 **Run workflow** 触发。

流程分两段：

1. **离线自检** —— 静态自检（`_selfcheck.py`）+ 后端沙箱用例（`tests/`），任何一项失败都不编译，避免产出"能装但点了没反应"的包。
2. **编译** —— 并行用 24.10 SDK 编 `.ipk`、snapshot SDK 编 `.apk`。

产物在对应 run 的 Artifacts 里下载：

- `luci-app-opennds-cpd_ipk-24.10`
- `luci-app-opennds-cpd_apk-snapshot`

也可以在本地 OpenWrt SDK 里编译：

```sh
cp -r luci-app-opennds-cpd <sdk>/package/
cd <sdk>
./scripts/feeds update -a && ./scripts/feeds install -a
echo 'CONFIG_PACKAGE_luci-app-opennds-cpd=m' >> .config
make defconfig
make package/luci-app-opennds-cpd/compile V=s
```

## 安装

把编出的包传到路由器后安装：

```sh
# opkg 系统（24.10）
opkg install luci-app-opennds-cpd_*.ipk

# apk 系统（snapshot）
apk add --allow-untrusted luci-app-opennds-cpd-*.apk
```

安装脚本只做文件权限和目录准备，不动 openNDS 配置。装完刷新浏览器缓存即可在 **服务 → openNDS** 看到菜单。

## 目录结构

```
luci-app-opennds-cpd/     插件本体（唯一参与打包的目录）
  Makefile                包定义、依赖、安装脚本
  htdocs/.../view/         9 个功能页 JS
  htdocs/.../opennds_cpd/  公共 JS
  root/usr/lib/opennds/    后端 API 与主题分发脚本
  root/etc/config/         区域识别配置
  root/usr/share/          菜单与 rpcd ACL 定义
.github/workflows/         自动编译工作流
tests/                     后端沙箱用例（编译前自检用）
_selfcheck.py              静态自检（编译前自检用）
```

版本号见 `luci-app-opennds-cpd/Makefile` 中的 `PKG_VERSION` / `PKG_RELEASE`。

## 许可

Apache-2.0
