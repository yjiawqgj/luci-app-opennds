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
			portals: { wireless: false, wired: false, blacklist: false },
			upAction: 'reject', upRate: '',
			downAction: 'reject', downRate: '',
			iface: 'br-lan',
			device: 'br-lan',
			ifaces: [],
			tab: 'wireless',
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' });
		var portalBox, fupBox, ifaceBox;

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
					_('只接受名为 default.sh 的脚本；该文件会被 openNDS 直接 source，不能有输出语句。'))
			]));
			body.appendChild(sec1);

			/* 公平使用策略 */
			var sec2 = CPD.section(_('公平使用策略'), 'Fair Use Policy');
			sec2.appendChild(E('p', { 'class': 'cpd-warnline' }, _('下载配额检查优于上传配额检查。')));
			fupBox = E('div', { 'style': 'display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:10px' });
			sec2.appendChild(fupBox);
			renderFup();
			body.appendChild(sec2);

			/* 网络接口 */
			var sec3 = CPD.section(_('网络接口'), 'Network Interface');
			sec3.appendChild(E('p', { 'class': 'cpd-warnline' },
				_('更改网络接口，某些自定义规则和客户端将会失效，请先调整好相关配置再更改。')));
			ifaceBox = E('div', { 'style': 'margin-top:10px' });
			sec3.appendChild(ifaceBox);
			renderIfaces();
			body.appendChild(sec3);

			body.appendChild(E('div', { 'class': 'cpd-actions-right' }, [
				E('button', { 'class': 'btn', 'click': handleSave }, _('保存')),
				E('button', { 'class': 'cbi-button cbi-button-positive', 'click': handleApply }, _('应用'))
			]));
		}

		/* ---------- 默认门户 ---------- */
		function renderPortalTabs() {
			portalBox.innerHTML = '';
			var tabs = ['wireless', 'wired', 'blacklist'];
			var tabRow = E('div', { 'role': 'tablist', 'style': 'display:flex;gap:6px;flex-wrap:wrap' });
			tabs.forEach(function (t) {
				var b = E('button', {
					'role': 'tab',
					'class': 'btn' + (state.tab === t ? ' cbi-button-positive' : ''),
					'aria-selected': state.tab === t ? 'true' : 'false',
					'click': function () { state.tab = t; renderPortalTabs(); }
				}, TAB_NAMES[t]);
				tabRow.appendChild(b);
			});
			var up = state.portals[state.tab];
			var panel = E('div', { 'role': 'tabpanel', 'style': 'margin-top:10px;display:flex;gap:10px;flex-wrap:wrap' }, [
				E('button', {
					'class': 'btn' + (up ? ' cbi-button-positive' : ''),
					'disabled': up ? '' : null,
					'click': up ? function () {} : pickFile
				}, up ? '✓ ' + _('已上传') : _('上传')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'style': up ? 'background:transparent;color:#c94848;border:1px solid #c94848' : '',
					'disabled': up ? null : '',
					'click': askClean
				}, _('清理'))
			]);
			portalBox.appendChild(E('div', {}, [
				tabRow,
				E('div', { 'aria-label': TAB_NAMES[state.tab] }, panel)
			]));
		}

		function pickFile() {
			var input = document.getElementById('cpd-portal-file');
			input.value = '';
			input.onchange = function () {
				var f = input.files && input.files[0];
				if (!f) return;
				var name = f.name;
				if (!/\.sh$/i.test(name)) {
					CPD.toast(_('只支持上传后缀为 .sh 的脚本'), 'warn');
					return;
				}
				if (name.toLowerCase() !== 'default.sh') {
					CPD.toast(_('请上传名为 default.sh 的脚本'), 'warn');
					return;
				}
				var reader = new FileReader();
				reader.onload = function () {
					uploadDefault(String(reader.result));
				};
				reader.readAsText(f);
			};
			input.click();
		}

		function uploadDefault(content) {
			var id = 't' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
			var tab = state.tab;
			CPD.api('settings', 'upload_begin', [id]).then(function (j) {
				if (!j.ok) throw { error: j.error || 'upload_begin 失败' };
				return fs.write('/tmp/zone_up/' + id + '/default.sh', content);
			}).then(function () {
				return CPD.api('settings', 'upload_default', [tab, id]);
			}).then(function (j) {
				if (!j.ok) throw { error: j.error || '上传失败' };
				CPD.toast(_('已上传 default.sh'), 'ok');
				state.portals[tab] = true;
				renderPortalTabs();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('上传失败'), 'err');
			});
		}

		function askClean() {
			var tab = state.tab;
			CPD.confirm(
				_('清理 default.sh？'),
				_('将删除「%s」指定目录中的 default.sh。删除后上传按钮会恢复为「上传」。').format(TAB_NAMES[tab]),
				_('清理'), true,
				function () {
					CPD.api('settings', 'clean_default', [tab]).then(function (j) {
						if (!j.ok) {
							CPD.toast(j.error || _('清理失败'), 'err');
							return;
						}
						CPD.toast(_('已清理「%s」的 default.sh，可重新上传').format(TAB_NAMES[tab]), 'ok');
						CPD.toast(_('已删除默认门户，标记为"默认"的区域将回退到 openNDS 官方页面'), 'warn');
						state.portals[tab] = false;
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
			var sel = E('select', { 'class': 'cpd-input', 'style': 'max-width:220px' }, [
				E('option', { value: 'limit' }, _('限速')),
				E('option', { value: 'reject' }, _('取消认证'))
			]);
			sel.value = action;
			var rateInput = E('input', {
				'class': 'cpd-input', 'type': 'number', 'min': '1', 'step': '1',
				'style': 'max-width:220px',
				'placeholder': isUp ? _('例如 2048') : _('例如 4096')
			});
			rateInput.value = rate;
			var rateLine = E('div', { 'style': 'margin-top:8px;display:flex;align-items:center;gap:8px' }, [
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
			var grid = E('div', { 'style': 'display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:10px' });
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
			if (notSaved()) {
				CPD.toast(_('当前设置尚未保存，请先保存后再应用。'), 'warn');
				return;
			}
			var fe = checkFup();
			if (fe) {
				CPD.toast(fe, 'warn');
				return;
			}
			CPD.apiConfirmable('settings', 'apply', [
				'up_action=' + state.upAction,
				'up_rate=' + state.upRate.trim(),
				'down_action=' + state.downAction,
				'down_rate=' + state.downRate.trim(),
				'iface=' + state.device
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
		return body;
	}
});
