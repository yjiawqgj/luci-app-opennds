/*
 * 客户端豁免管理 · openNDS CPD（LuCI view）
 * 照《客户端豁免管理.md》：信任/授权两个名单区块 + 授权开关（staged）+
 * 五列表格（info 补全在线信息）+ 交集拦截 + 差量 save（added/removed）。
 */
'use strict';
'require view';
'require ui';
'require dom';

var CPD = null;

return view.extend({
	load: function () {
		return L.require('opennds_cpd.common').then(function (m) { CPD = m; });
	},

	render: function () {
		var state = {
			trusted: [],      /* 小写 MAC */
			preempt: [],      /* 条目原文（mac=…;…） */
			preemptEnabled: 1,
			trusted0: [],     /* 加载时快照（差量基准） */
			preempt0: [],
			pe0: 1,
			info: {},         /* MAC → {host,ip,zone,online} */
			editing: { trusted: false, preempt: false },
			open: { trusted: false, preempt: false },
			perPage: '10',
			page: { trusted: 1, preempt: 1 }
		};
		var body = E('div', { 'class': 'cpd-page' });

		function macOf(entry) {
			var m = (entry.split(';')[0] || '').replace(/^mac=/i, '');
			return m.toLowerCase();
		}
		function macOk(s) {
			return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(s);
		}

		function listMacs(which) {
			return which === 'trusted'
				? state.trusted.slice()
				: state.preempt.map(macOf);
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('客户端豁免管理'), 'openNDS · LuCI',
				_('为指定客户端提供信任或预先授权：可绕过正常认证，或跳过门户认证但保留流量统计与管理。')));
			body.appendChild(renderBlock('trusted'));
			body.appendChild(renderBlock('preempt'));
		}

		function renderBlock(which) {
			var isPre = which === 'preempt';
			var sec = CPD.section(
				isPre ? _('授权客户端') : _('信任客户端'),
				isPre ? 'Pre-emptive Clients' : 'Trusted Clients');
			sec.appendChild(E('p', { 'class': 'cpd-note' }, isPre
				? _('允许指定客户端跳过门户认证，自动获得预先授权，同时保留 openNDS 对客户端的流量统计、配额、速度和会话时长管理。')
				: _('允许指定客户端绕过 openNDS 的正常认证和客户端流量管理机制，获得无条件访问权限。')));

			if (isPre) {
				var tgl = E('button', {
					'class': 'cbi-button ' + (state.preemptEnabled ? 'cbi-button-positive' : ''),
					'click': function () {
						state.preemptEnabled = state.preemptEnabled ? 0 : 1;
						renderAll();
						CPD.statusBar(state.preemptEnabled
							? _('授权客户端已启用，点击页面底部的「保存并应用」后生效')
							: _('授权客户端已关闭（配置保留），点击「保存并应用」后生效'));
					}
				}, state.preemptEnabled ? _('已启用') : _('已关闭'));
				sec.appendChild(E('div', { 'style': 'margin-top:10px;display:flex;align-items:center;gap:10px' }, [
					tgl,
					E('span', { 'class': 'cpd-note', 'style': 'font-family:monospace' }, 'allow_preemptive_authentication')
				]));
				if (!state.preemptEnabled) {
					sec.appendChild(E('p', { 'class': 'cpd-note', 'style': 'margin-top:6px' },
						_('当前未启用自动预授权：尚未出现在客户端列表里的设备不会被自动放行')));
				}
			}

			var wrap = E('div', {});
			sec.appendChild(wrap);
			renderListArea(wrap, which);
			return sec;
		}

		function renderListArea(wrap, which) {
			var isPre = which === 'preempt';
			var macs = listMacs(which);
			wrap.innerHTML = '';

			/* MAC 地址列表编辑入口 */
			wrap.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('div', { 'class': 'cpd-viewer-label' }, _('MAC 地址列表')),
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'cbi-button', 'click': function () { startEdit(which); } }, _('编辑'))
				])
			]));
			if (state.editing[which]) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'rows': '3', 'spellcheck': 'false',
					'placeholder': 'AA:BB:CC:DD:EE:FF'
				});
				ta.value = macs.map(function (m) { return m.toUpperCase(); }).join('\n');
				wrap.appendChild(E('div', { 'class': 'cpd-field' }, [
					E('div', { 'class': 'cpd-note', 'style': 'margin-bottom:5px' },
						_('每行一个 MAC 地址，支持一次输入多个；格式示例 AA:BB:CC:DD:EE:FF')),
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': function () { cancelEdit(which); } }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { saveList(which, ta); }
						}, _('确定'))
					])
				]));
				window.setTimeout(function () {
					ta.focus();
					try { ta.setSelectionRange(ta.value.length, ta.value.length); } catch (e) {}
				}, 0);
			}

			/* 可折叠表格 */
			var open = state.open[which];
			var head = E('div', { 'style': 'margin-top:16px;display:flex;align-items:center;gap:10px;flex-wrap:wrap' }, [
				E('button', {
					'class': 'cbi-button',
					'aria-expanded': open ? 'true' : 'false',
					'click': function () {
						state.open[which] = !open;
						if (state.open[which]) loadInfo();
						renderAll();
					}
				}, open ? _('收起列表') : _('展开列表')),
				E('span', { 'class': 'cpd-note' },
					(isPre ? _('授权客户端列表') : _('信任客户端列表')) + ' · ' + _('共 %s 条').format(macs.length))
			]);
			wrap.appendChild(head);
			if (!open) return;

			var total = macs.length;
			var pp = (state.perPage === 'all') ? total : parseInt(state.perPage, 10);
			if (!(pp > 0)) pp = total || 1;
			var pages = Math.max(1, Math.ceil(total / pp));
			var cur = Math.min(state.page[which], pages);
			var slice = macs.slice((cur - 1) * pp, cur * pp);

			/* 表头/单元格样式：分隔线在这里显式给，不依赖主题的 .table */
			var TH_S = 'text-align:left;font-size:12px;font-weight:600;color:#5d6b78;' +
				'padding:9px 12px;background:#f4f7f9;border-bottom:1px solid #e3e9ee;white-space:nowrap';
			function tdS(last, extra) {
				return 'padding:11px 12px;border-bottom:' +
					(last ? '0' : '1px solid #e3e9ee') +
					';font-size:12.5px;vertical-align:middle' + (extra ? ';' + extra : '');
			}

			var rows = [E('tr', {}, [
				E('th', { 'style': TH_S }, _('主机名')),
				E('th', { 'style': TH_S }, _('IP 地址')),
				E('th', { 'style': TH_S }, _('MAC 地址')),
				E('th', { 'style': TH_S }, _('网络区域')),
				E('th', { 'style': TH_S }, _('操作'))
			])];
			if (!slice.length) {
				rows.push(E('tr', {}, E('td', {
					'colspan': '5',
					'style': 'text-align:center;color:#8a97a3;padding:26px 12px;font-size:12.5px'
				}, _('暂无客户端记录'))));
			}
			slice.forEach(function (mac, idx) {
				var inf = state.info[mac.toUpperCase()] || state.info[mac] || {};
				var last = (idx === slice.length - 1);
				rows.push(E('tr', {}, [
					E('td', { 'style': tdS(last) }, inf.host || '—'),
					E('td', { 'style': tdS(last) }, inf.ip || '—'),
					E('td', { 'style': tdS(last, 'font-family:ui-monospace,Consolas,monospace') },
						mac.toUpperCase()),
					E('td', { 'style': tdS(last) }, inf.zone || '—'),
					E('td', { 'style': tdS(last, 'text-align:right;white-space:nowrap') },
						E('button', {
							'class': 'cbi-button cbi-button-negative',
							'click': function () { askRemove(which, mac, inf.host); }
						}, isPre ? _('删除') : _('移除')))
				]));
			});
			wrap.appendChild(E('div', {
				'style': 'margin-top:12px;overflow-x:auto;border:1px solid #e3e9ee;border-radius:8px'
			}, E('table', {
				'style': 'width:100%;min-width:640px;border-collapse:collapse;table-layout:fixed'
			}, [
				E('colgroup', {}, [
					E('col', { 'style': 'width:26%' }),
					E('col', { 'style': 'width:22%' }),
					E('col', { 'style': 'width:24%' }),
					E('col', { 'style': 'width:16%' }),
					E('col', { 'style': 'width:12%' })
				]),
				E('tbody', {}, rows)
			])));

			/* 底部条：左边统计，右边「每页」+ 翻页（放这里不会被表格盖住） */
			var foot = E('div', {
				'style': 'display:flex;align-items:center;justify-content:space-between;gap:10px;' +
					'flex-wrap:wrap;margin-top:10px;font-size:12px;color:#7a8794'
			}, [
				E('span', {}, _('共 %s 条 · 第 %s/%s 页').format(total, cur, pages))
			]);
			var ppSel = E('select', {
				'class': 'cpd-input',
				'style': 'height:32px;min-width:88px;padding:0 24px 0 8px;line-height:30px'
			}, [
				E('option', { value: 'all' }, _('全部')),
				E('option', { value: '10' }, '10'),
				E('option', { value: '20' }, '20'),
				E('option', { value: '30' }, '30'),
				E('option', { value: '50' }, '50'),
				E('option', { value: '100' }, '100')
			]);
			ppSel.value = state.perPage;
			ppSel.addEventListener('change', function () {
				state.perPage = ppSel.value;
				state.page[which] = 1;
				renderAll();
			});
			var right = E('div', {
				'style': 'display:flex;align-items:center;gap:10px;flex-wrap:wrap'
			}, [
				E('label', { 'style': 'display:flex;align-items:center;gap:6px' },
					[E('span', {}, _('每页')), ppSel])
			]);
			if (pages > 1) {
				var pager = E('div', { 'style': 'display:flex;align-items:center;gap:6px' });
				if (cur > 1) {
					pager.appendChild(E('button', {
						'class': 'cbi-button', 'style': 'padding:2px 10px',
						'click': function () { state.page[which] = cur - 1; renderAll(); }
					}, '‹ ' + _('上一页')));
				}
				if (cur < pages) {
					pager.appendChild(E('button', {
						'class': 'cbi-button', 'style': 'padding:2px 10px',
						'click': function () { state.page[which] = cur + 1; renderAll(); }
					}, _('下一页') + ' ›'));
				}
				right.appendChild(pager);
			}
			foot.appendChild(right);
			wrap.appendChild(foot);
		}

		function loadInfo() {
			CPD.api('exempt', 'info').then(function (j) {
				if (j.ok) {
					state.info = j.clients || {};
					renderAll();
				}
			}).catch(function () {});
		}

		/* ---------- 编辑 ---------- */
		function startEdit(which) {
			state.editing[which] = true;
			renderAll();
		}

		function cancelEdit(which) {
			state.editing[which] = false;
			renderAll();
		}

		function saveList(which, ta) {
			var lines = (ta ? ta.value : '').replace(/\r\n/g, '\n').split('\n')
				.map(function (l) { return l.trim(); })
				.filter(function (l) { return l; });
			var seen = {}, out = [];
			for (var i = 0; i < lines.length; i++) {
				if (!macOk(lines[i])) {
					CPD.notify(_('非法MAC: %s').format(lines[i]), 'err');
					return;
				}
				var lm = lines[i].toLowerCase();
				if (!seen[lm]) { seen[lm] = 1; out.push(lm); }
			}
			if (which === 'trusted') {
				state.trusted = out;
			} else {
				/* 保留已有条目参数；新 MAC 交给后端补全参数条目 */
				var byMac = {};
				state.preempt.forEach(function (e) { byMac[macOf(e)] = e; });
				state.preempt = out.map(function (m) {
					return byMac[m] ||
						('mac=' + m + ';sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0');
				});
			}
			/* 编辑框下的「确定」只退出编辑态，不写任何配置；
			 * 配置由页面底部的 openwrt「保存 / 保存并应用」写入 */
			state.editing[which] = false;
			renderAll();
			/* 静默退出编辑态：不弹任何横幅 */
		}

		/* 把当前名单与开关落成 uci 暂存（顶部出现「未保存的配置」） */
		function stageExempt() {
			return Promise.all([
				CPD.stageUci('opennds', '@opennds[0]', 'trustedmac', 'list', state.trusted),
				CPD.stageUci('opennds', '@opennds[0]', 'preemptivemac', 'list', state.preempt),
				CPD.stageUci('opennds', '@opennds[0]', 'allow_preemptive_authentication',
					'opt', String(state.preemptEnabled))
			]);
		}

		function askRemove(which, mac, host) {
			var isPre = which === 'preempt';
			var who = host && host !== '—' ? host : mac.toUpperCase();
			CPD.confirm(
				isPre ? _('删除客户端') : _('移除客户端'),
				(isPre ? _('确定要删除客户端「%s」吗？删除后该客户端将不再享受对应豁免。')
					: _('确定要移除客户端「%s」吗？移除后该客户端将不再享受对应豁免。')).format(who),
				isPre ? _('确认删除') : _('确认移除'), true,
				function () {
					if (which === 'trusted') {
						state.trusted = state.trusted.filter(function (m) { return m !== mac; });
					} else {
						state.preempt = state.preempt.filter(function (e) { return macOf(e) !== mac; });
					}
					renderAll();
					/* 静默：删除只改内存，等 openwrt「保存 / 保存并应用」 */
				}
			);
		}

		/* ---------- 应用 ---------- */
		function handleApply() {
			if (state.editing.trusted || state.editing.preempt) {
				CPD.notify(_('请先完成或取消 MAC 地址编辑'), 'warn');
				return Promise.resolve();
			}
			/* 交集拦截（决策 #12）：err 提示不自动消失 */
			var tset = {}, dups = {};
			state.trusted.forEach(function (m) { tset[m] = 1; });
			state.preempt.forEach(function (e) {
				var m = macOf(e);
				if (tset[m]) dups[m] = 1;
			});
			var dlist = Object.keys(dups);
			if (dlist.length) {
				var shown = dlist.slice(0, 3).map(function (m) { return '`' + m + '`'; }).join('、') +
					(dlist.length > 3 ? _('等 %s 条').format(dlist.length) : '');
				ui.addNotification(null, E('p', {}, _('%s 同时出现在信任列表和授权列表，一个客户端只能属于一个列表，请删除其中一个后再应用。').format(shown)), 'error');
				return Promise.resolve();
			}
			var diff = function (a0, a1) {
				var s0 = {}, s1 = {}, add = [], rem = [];
				a0.forEach(function (x) { s0[x] = 1; });
				a1.forEach(function (x) { s1[x] = 1; });
				a1.forEach(function (x) { if (!s0[x]) add.push(x); });
				a0.forEach(function (x) { if (!s1[x]) rem.push(x); });
				return { add: add, rem: rem };
			};
			/* 差量基准是上次后端刷新/应用时的名单（不含本地暂存），
			   这样后端能对差量做运行时同步与黑名单检查 */
			var dt = diff(state.trusted0, state.trusted);
			var dp = diff(state.preempt0.map(macOf), state.preempt.map(macOf));
			var args = [];
			if (dt.add.length) args.push('trusted_add=' + dt.add.join(','));
			if (dt.rem.length) args.push('trusted_remove=' + dt.rem.join(','));
			if (dp.add.length) args.push('preempt_add=' + dp.add.join(','));
			if (dp.rem.length) args.push('preempt_remove=' + dp.rem.join(','));
			if (!state.preempt.length && state.preempt0.length) args.push('preempt_clear=1');
			args.push('preempt_enabled=' + state.preemptEnabled);
			/* 保存并应用：先把当前名单落成 uci 暂存，再交给后端差量执行 */
			return stageExempt().then(function () {
				return CPD.apiConfirmable('exempt', 'save', args);
			}).then(function (j) {
				if (j.error === 'busy') { CPD.notify(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (j.error === 'duplicate' && j.duplicates) {
					ui.addNotification(null, E('p', {},
						_('同时出现在信任列表和授权列表，一个客户端只能属于一个列表，请删除其中一个后再应用。')),
						'error');
					return;
				}
				if (!j.ok) { CPD.notify(j.error || _('应用失败'), 'err'); return; }
				CPD.clearNotice();
				CPD.nativeNotice(_('配置已应用'), 6000);
				CPD.notifyChanges();
				refresh();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		function refresh() {
			CPD.api('exempt', 'status').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				state.trusted = j.trusted || [];
				state.preempt = j.preempt || [];
				state.preemptEnabled = (j.preempt_enabled === 0) ? 0 : 1;
				state.trusted0 = state.trusted.slice();
				state.preempt0 = state.preempt.slice();
				state.pe0 = state.preemptEnabled;
				state.editing = { trusted: false, preempt: false };
				loadInfo();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('读取状态失败'), 'err');
			});
		}

		refresh();
		/* ---------- LuCI 框架底部按钮：保存 / 保存&应用 / 复位 ---------- */
		this.handleSave = function () {
			return stageExempt().then(function () {
				CPD.nativeNotice(_('名单已保存'), 5000);
			}, function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		};
		this.handleSaveApply = function () {
			return handleApply();
		};
		this.handleReset = function () {
			return CPD.revertStaged(['opennds']).then(function () {
				CPD.clearNotice();
				refresh();
			}, function (e) {
				CPD.notify(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
