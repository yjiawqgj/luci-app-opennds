/*
 * openNDS 设置 · openNDS CPD（LuCI view）
 * 照《OpenNDS设置.md》：默认门户（三 tab 上传/清理 default.sh，即时动作不进快照）+
 * 公平使用策略（限速/取消认证，取消认证写 0）+ 网络接口（前端切换只改状态，
 * gatewayinterface 只在「应用」写盘）；保存 = 内存快照，应用 = 后端写三键 + 重启。
 */
'use strict';
'require view';
'require ui';
'require fs';
'require dom';

var CPD = null;
var TAB_NAMES = { wireless: _('无线区域'), wired: _('有线区域'), blacklist: _('黑名单') };

return view.extend({
	load: function () {
		return L.require('opennds_cpd.common').then(function (m) { CPD = m; });
	},

	render: function () {
		var state = {
			portals: {
				wireless: { sel: '', items: [], builtin: false },
				wired: { sel: '', items: [], builtin: false },
				blacklist: { sel: '', items: [], builtin: false }
			},
			upAction: 'reject', upRate: '',
			downAction: 'reject', downRate: '',
			iface: 'br-lan',
			device: 'br-lan',
			ifaces: [],
			tab: 'wireless',
			fupEnabled: true,
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' });
		var portalBox, fupBox, ifaceBox, switchBtn, switchLabel, fupOffHint;

		/* ---------- 页头 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('openNDS 设置'), 'Settings',
				_('默认门户、公平使用策略与网络接口设置。')));

			/* 默认门户设置 */
			var sec1 = CPD.section(_('默认门户设置'), 'Default Portal');
			portalBox = E('div', {});
			sec1.appendChild(portalBox);
			renderPortalTabs();
			sec1.appendChild(E('div', { 'style': 'margin-top:10px' }, [
				E('input', {
					'type': 'file', 'accept': '.sh', 'id': 'cpd-portal-file', 'style': 'display:none'
				}),
				E('p', { 'class': 'cpd-note' },
					_('这里上传的是该类型的默认门户（区域未单独选门户时使用）。文件保留原名，openNDS 直接 source，不能有输出语句。'))
			]));
			body.appendChild(sec1);

			/* 公平使用策略：开关 + 配额区（关闭时整块隐藏） */
			var sec2 = CPD.section(_('公平使用策略'), 'Fair Use Policy');
			sec2.appendChild(E('p', { 'class': 'cpd-warnline' }, _('下载配额检查优于上传配额检查。')));
			switchBtn = E('button', {
				'type': 'button', 'role': 'switch', 'aria-checked': state.fupEnabled ? 'true' : 'false',
				'aria-label': _('公平使用策略开关'),
				'style': 'position:relative;width:46px;height:26px;flex:none;padding:0;border:1px solid #c9d2da;' +
					'border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s',
				'click': function () {
					state.fupEnabled = !state.fupEnabled;
					renderFupSwitch();
				}
			}, E('span', {
				'style': 'position:absolute;top:2px;left:2px;width:20px;height:20px;border-radius:50%;' +
					'background:#fff;box-shadow:0 1px 2px rgba(20,30,40,.22);transition:transform .15s;display:block'
			}));
			switchLabel = E('span', { 'style': 'font-size:13px;font-weight:600' }, '');
			sec2.appendChild(E('div', {
				'style': 'display:flex;align-items:center;gap:12px;margin-top:18px;flex-wrap:wrap'
			}, [switchBtn, switchLabel]));
			fupOffHint = E('p', { 'class': 'cpd-note', 'style': 'margin-top:14px;line-height:1.7;max-width:620px' },
				_('开启后才能设置上传、下载的配额处理方式与限速；仪表盘页客户端编辑里的流量限制也依赖此开关。'));
			sec2.appendChild(fupOffHint);
			fupBox = E('div', {
				'style': 'display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:18px;max-width:620px'
			});
			sec2.appendChild(fupBox);
			renderFupSwitch();
			body.appendChild(sec2);

			/* 网络接口 */
			var sec3 = CPD.section(_('网络接口'), 'Network Interface');
			sec3.appendChild(E('p', { 'class': 'cpd-warnline' },
				_('更改网络接口，某些自定义规则和客户端将会失效，请先调整好相关配置再更改。')));
			ifaceBox = E('div', { 'style': 'margin-top:10px' });
			sec3.appendChild(ifaceBox);
			renderIfaces();
			body.appendChild(sec3);

		}

		/* ---------- 默认门户 ---------- */
		function portalInfo(tab) {
			return state.portals[tab] || { sel: '', items: [], builtin: false };
		}

		/* 下拉最长 10 个字符，全名放 title 悬停可见 */
		function shortName(n) {
			n = String(n || '');
			return n.length > 10 ? n.slice(0, 10) + '…' : n;
		}

		/* 本页上传的默认门户实际落盘目录（区域各自的门户在 cpd/wireless/<区域>/、cpd/wired/<接口>/，由区域识别页管理） */
		function portalPath(tab) {
			return '/usr/lib/opennds/cpd/default/' + tab + '/';
		}

		function renderPortalTabs() {
			portalBox.innerHTML = '';
			var tabs = ['wireless', 'wired', 'blacklist'];
			var tabRow = E('div', { 'role': 'tablist',
				'style': 'display:flex;flex-wrap:wrap;border-bottom:1px solid #e3e9ee;margin-top:16px' });
			tabs.forEach(function (t) {
				var on = state.tab === t;
				tabRow.appendChild(E('button', {
					'role': 'tab', 'type': 'button',
					'style': 'font-family:inherit;font-size:13px;line-height:1.4;padding:9px 14px;border:0;' +
						'background:' + (on ? '#e7f1f8' : 'transparent') + ';cursor:pointer;' +
						'color:' + (on ? '#1a5c85' : '#657585') + ';' +
						'font-weight:' + (on ? '600' : '400') + ';' +
						'border-bottom:2px solid ' + (on ? '#2274a5' : 'transparent') + ';' +
						'margin-bottom:-1px',
					'aria-selected': on ? 'true' : 'false',
					'click': function () { state.tab = t; renderPortalTabs(); }
				}, TAB_NAMES[t]));
			});

			var cur = portalInfo(state.tab);
			var opts = [E('option', { value: '', 'title': 'default.sh' }, _('默认门户'))];
			(cur.items || []).forEach(function (n) {
				opts.push(E('option', { value: n, 'title': n }, shortName(n)));
			});
			var sel = E('select', {
				'class': 'cpd-input',
				'style': 'max-width:420px;min-width:200px;height:34px'
			}, opts);
			sel.value = cur.sel || '';
			sel.addEventListener('change', function () {
				var v = this.value;
				CPD.api('settings', 'portal_save', [state.tab, v || 'default']).then(function (j) {
					if (!j.ok) {
						CPD.toast(j.error || _('切换门户失败'), 'err');
						renderPortalTabs();
						return;
					}
					cur.sel = v;
					CPD.toast(v ? _('当前门户已切换为 %s').format(v)
						: _('当前门户已切换为默认门户'), 'ok');
					renderPortalTabs();
				}).catch(function (e) {
					CPD.toast((e && e.error) || _('切换门户失败'), 'err');
					renderPortalTabs();
				});
			});

			var field = E('div', {
				'style': 'display:flex;align-items:center;gap:10px;flex-wrap:wrap'
			}, [
				E('label', { 'style': 'font-size:13px;font-weight:600' }, _('门户选择')),
				sel,
				E('span', {
					'style': 'font-size:11.5px;color:#7a8794;' +
						'font-family:ui-monospace,Consolas,monospace'
				}, _('门户目录：%s').format(portalPath(state.tab)))
			]);

			var tools = E('div', {
				'style': 'display:flex;gap:10px;flex-wrap:wrap;margin-top:6px'
			}, [
				E('button', { 'class': 'cbi-button', 'click': pickFile }, _('上传')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': cur.sel ? null : '',
					'click': askClean
				}, _('清理'))
			]);

			portalBox.appendChild(E('div', {}, [
				tabRow,
				E('div', { 'style': 'padding-top:22px' }, [
					field,
					tools,
					E('p', { 'class': 'cpd-note', 'style': 'margin-top:12px' },
						_('上传的门户保留原文件名，直接出现在「门户选择」里；同名上传即覆盖为新版本。'))
				])
			]));
		}

		function pickFile() {
			var input = document.getElementById('cpd-portal-file');
			input.value = '';
			input.onchange = function () {
				var f = input.files && input.files[0];
				if (!f) return;
				var name = f.name || '';
				if (!/\.sh$/i.test(name)) {
					CPD.toast(_('只支持上传后缀为 .sh 的脚本'), 'warn');
					return;
				}
				var reader = new FileReader();
				reader.onload = function () {
					uploadDefault(name, String(reader.result));
				};
				reader.readAsText(f);
			};
			input.click();
		}

		function uploadDefault(name, content) {
			var id = 't' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
			var tab = state.tab;
			CPD.api('settings', 'upload_begin', [id]).then(function (j) {
				if (!j.ok) throw { error: j.error || 'upload_begin 失败' };
				return fs.write('/tmp/zone_up/' + id + '/' + name, content);
			}).then(function () {
				return CPD.api('settings', 'upload_default', [tab, id, name]);
			}).then(function (j) {
				if (!j.ok) throw { error: j.error || '上传失败' };
				CPD.toast(_('已上传 %s，并在门户选择中启用').format(name), 'ok');
				var info = portalInfo(tab);
				if (info.items.indexOf(name) < 0) info.items.push(name);
				info.sel = name;
				/* 上传即选中：让 openNDS 用这份新门户 */
				return CPD.api('settings', 'portal_save', [tab, name]);
			}).then(function () {
				renderPortalTabs();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('上传失败'), 'err');
			});
		}

		function askClean() {
			var tab = state.tab;
			var info = portalInfo(tab);
			if (!info.sel) return;
			var name = info.sel;
			CPD.confirm(
				_('清理 %s？').format(shortName(name)),
				_('将删除门户目录中的 %s，删除后该类型自动切回默认门户。').format(name),
				_('清理'), true,
				function () {
					CPD.api('settings', 'clean_default', [tab, name]).then(function (j) {
						if (!j.ok) {
							CPD.toast(j.error || _('清理失败'), 'err');
							return;
						}
						CPD.toast(_('已清理 %s，当前类型已切回默认门户').format(name), 'ok');
						info.items = (info.items || []).filter(function (x) { return x !== name; });
						info.sel = '';
						renderPortalTabs();
					}).catch(function (e) {
						CPD.toast((e && e.error) || _('清理失败'), 'err');
					});
				}
			);
		}

		/* ---------- 公平使用策略 ---------- */
		function quotaColumn(label, isUp) {
			var action = isUp ? state.upAction : state.downAction;
			var rate = isUp ? state.upRate : state.downRate;
			var sel = E('select', { 'class': 'cpd-input', 'style': 'max-width:260px;min-width:170px' }, [
				E('option', { value: 'limit' }, _('限速')),
				E('option', { value: 'reject' }, _('取消认证'))
			]);
			sel.value = action;
			var rateInput = E('input', {
				'class': 'cpd-input', 'type': 'number', 'min': '1', 'step': '1',
				'style': 'max-width:130px',
				'placeholder': isUp ? _('例如 2048') : _('例如 4096')
			});
			rateInput.value = rate;
			var rateLine = E('div', { 'style': 'margin-top:20px;display:flex;align-items:center;gap:8px' }, [
				E('span', { 'class': 'cpd-note' }, _('速率')),
				rateInput,
				E('span', { 'class': 'cpd-note' }, 'Kb/s')
			]);
			function sync() {
				rateLine.style.display = (sel.value === 'reject') ? 'none' : 'flex';
				if (isUp) { state.upAction = sel.value; state.upRate = rateInput.value; }
				else { state.downAction = sel.value; state.downRate = rateInput.value; }
			}
			sel.addEventListener('change', sync);
			rateInput.addEventListener('input', sync);
			rateLine.style.display = (action === 'reject') ? 'none' : 'flex';
			return E('div', {}, [
				E('label', { 'class': 'cpd-note', 'style': 'font-weight:600;color:var(--text,#222a31)' }, label),
				sel,
				rateLine
			]);
		}

		function renderFup() {
			fupBox.innerHTML = '';
			fupBox.appendChild(quotaColumn(_('上传'), true));
			fupBox.appendChild(quotaColumn(_('下载'), false));
		}

		/* 开关联动：关闭时整块配额区隐藏，只留提示（与演示一致） */
		function renderFupSwitch() {
			if (!switchBtn) return;
			var on = !!state.fupEnabled;
			switchBtn.setAttribute('aria-checked', on ? 'true' : 'false');
			switchBtn.style.background = on ? '#2e7d4f' : '#e3e8ec';
			switchBtn.style.borderColor = on ? '#2e7d4f' : '#c9d2da';
			var knob = switchBtn.firstChild;
			if (knob && knob.style) knob.style.transform = on ? 'translateX(20px)' : 'none';
			switchLabel.textContent = on ? _('已开启') : _('已关闭');
			switchLabel.style.color = on ? '#2e7d4f' : '';
			fupBox.style.display = on ? 'grid' : 'none';
			fupOffHint.style.display = on ? 'none' : '';
			if (on) renderFup();
		}

		/* ---------- 网络接口 ---------- */
		function renderIfaces() {
			ifaceBox.innerHTML = '';
			if (!state.ifaces.length) {
				ifaceBox.appendChild(E('p', { 'class': 'cpd-note' },
					_('未找到带 IPv4 地址的网络接口。')));
				return;
			}
			if (state.iface !== state.device && !state.ifaces.some(function (i) { return i.name === state.device; })) {
				ifaceBox.appendChild(E('p', { 'class': 'cpd-note' },
					_('当前配置的接口「%s」不在本机接口列表里，点击下方任一接口即可切换').format(state.iface)));
			}
			var grid = E('div', { 'style': 'display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-top:16px' });
			state.ifaces.forEach(function (it) {
				var active = (it.name === state.device);
				var card = E('button', {
					'type': 'button',
					'style': 'text-align:left;padding:10px 12px;border:1px solid ' +
						(active ? '#2274a5' : '#d7dde3') + ';border-radius:8px;background:' +
						(active ? '#e7f1f8' : '#fff') + ';cursor:pointer;font-family:inherit',
					'aria-pressed': active ? 'true' : 'false',
					'click': function () { clickIface(it.name); }
				}, [
					E('div', { 'style': 'font-family:ui-monospace,Consolas,monospace;font-size:14px' }, [
						it.name,
						active ? E('span', { 'class': 'cpd-badge' }, '● ' + _('正在使用中')) : E([])
					]),
					E('div', { 'class': 'cpd-note', 'style': 'margin-top:4px' },
						_('对应 IP') + '：' + it.ip)
				]);
				grid.appendChild(card);
			});
			ifaceBox.appendChild(grid);
		}

		function clickIface(name) {
			if (name === state.device) {
				CPD.toast(_('当前正在使用 %s').format(name));
				return;
			}
			CPD.confirm(
				_('切换网络接口？'),
				_('将 openNDS 接管接口从「%s」切换到「%s」。切换后部分自定义规则和客户端可能失效。')
					.format(state.device, name),
				_('切换'), false,
				function () {
					state.device = name;
					state.iface = name;
					renderIfaces();
					CPD.toast(_('网络接口已切换为 %s').format(name), 'ok');
				}
			);
		}

		/* ---------- 保存 / 应用 ---------- */
		function checkFup() {
			var pairs = [
				[state.upAction, state.upRate, true],
				[state.downAction, state.downRate, false]
			];
			for (var i = 0; i < pairs.length; i++) {
				var act = pairs[i][0], rate = pairs[i][1];
				if (act === 'reject') continue;
				if (!String(rate).trim()) return _('请填写速率');
				if (!/^\d+$/.test(String(rate).trim())) return _('速率必须是大于 0 的整数');
				var n = parseInt(rate, 10);
				if (n < 1) return _('速率必须是大于 0 的整数');
				if (n > 10000000) return _('速率过大，请检查单位是否为 Kb/s');
			}
			return null;
		}

		function handleSave() {
			state.snapshot = {
				upAction: state.upAction, upRate: state.upRate,
				downAction: state.downAction, downRate: state.downRate,
				device: state.device
			};
			CPD.toast(_('设置已保存（尚未生效，请点击应用）'), 'ok');
		}

		function notSaved() {
			if (!state.snapshot) return true;
			return state.snapshot.upAction !== state.upAction ||
				state.snapshot.upRate !== state.upRate ||
				state.snapshot.downAction !== state.downAction ||
				state.snapshot.downRate !== state.downRate ||
				state.snapshot.device !== state.device;
		}

		function handleApply() {
			var fe = state.fupEnabled ? checkFup() : null;
			if (fe) {
				CPD.toast(fe, 'warn');
				return Promise.resolve();
			}
			return CPD.apiConfirmable('settings', 'apply', [
				'up_action=' + state.upAction,
				'up_rate=' + (state.fupEnabled ? state.upRate.trim() : ''),
				'down_action=' + state.downAction,
				'down_rate=' + (state.fupEnabled ? state.downRate.trim() : ''),
				'iface=' + state.device,
				'fup_enabled=' + (state.fupEnabled ? 1 : 0)
			]).then(function (j) {
				if (j.error === 'busy') { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (j.ok) {
					CPD.toast(_('设置已应用'), 'ok');
					refresh();
				} else {
					CPD.toast(j.error || _('应用失败'), 'err');
				}
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('应用失败'), 'err');
			});
		}

		function refresh() {
			CPD.api('settings', 'status').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				state.portals = j.portals;
				var f = j.fup || {};
				state.upAction = f.upAction || 'reject';
				state.upRate = (f.upAction === 'limit') ? String(f.upRate || '') : '';
				state.downAction = f.downAction || 'reject';
				state.downRate = (f.downAction === 'limit') ? String(f.downRate || '') : '';
				state.iface = j.iface || 'br-lan';
				state.device = j.device || state.iface;
				state.ifaces = j.ifaces || [];
				state.fupEnabled = (j.fupEnabled === 1 || j.fupEnabled === true);
				state.snapshot = {
					upAction: state.upAction, upRate: state.upRate,
					downAction: state.downAction, downRate: state.downRate,
					device: state.device
				};
				renderAll();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('读取状态失败'), 'err');
			});
		}

		refresh();

		/* ---------- LuCI 框架底部按钮：保存 / 保存&应用 / 复位 ---------- */
		this.handleSave = function () {
			handleSave();
			return Promise.resolve();
		};
		this.handleSaveApply = function () {
			return handleApply();
		};
		this.handleReset = function () {
			state.snapshot = null;
			refresh();
			CPD.toast(_('已恢复为当前生效的设置'), 'ok');
			return Promise.resolve();
		};

		return body;
	}
});
