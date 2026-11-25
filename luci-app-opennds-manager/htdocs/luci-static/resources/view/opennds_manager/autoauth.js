/*
 * 自动认证 · openNDS CPD（LuCI view）
 * 从原「特权客户端」页拆出的预先授权（preemptivemac）板块，布局沿用同一套
 * 五列表格 + 分页 + 差量暂存。后端仍走 exempt status/save（两个名单同源）。
 */
'use strict';
'require view';
'require ui';
'require dom';

var CPD = null;

return view.extend({
	load: function () {
		return L.require('opennds_manager.common').then(function (m) { CPD = m; });
	},

	render: function () {
		var state = {
			preempt: [],      /* 条目原文（mac=…;…） */
			preemptEnabled: 1,
			preempt0: [],
			pe0: 1,
			trusted: [],      /* 可信任名单（小写 MAC）：只用于交集拦截，本页不渲染 */
			info: {},         /* MAC → {host,ip,zone,online} */
			blocked: [],      /* 黑名单 MAC（小写）：一个客户端只能属于一个名单 */
			editing: false,
			open: false,
			perPage: '10',
			page: 1
		};
		var body = E('div', { 'class': 'cpd-page' });

		function macOf(entry) {
			var m = (entry.split(';')[0] || '').replace(/^mac=/i, '');
			return m.toLowerCase();
		}
		function macOk(s) {
			return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(s);
		}
		function listMacs() {
			return state.preempt.map(macOf);
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('自动认证'), 'openNDS · LuCI',
				_('为无法进行强制门户认证的设备自动放行，比如摄像头、传感器等。自动认证的客户端同样受到强制门户的管理。')));
			body.appendChild(renderBlock());
		}

		function renderBlock() {
			var sec = CPD.section(_('自动认证客户端'), 'Auto Authentication');
			sec.appendChild(E('p', { 'class': 'cpd-note' },
				_('可以为无法进行强制门户认证的设备自动放行，比如摄像头、传感器等。但与信任客户端不同，自动认证的客户端同样受到强制门户的管理。')));

			var statusLabel = E('span', {}, state.preemptEnabled ? _('已启用') : _('已关闭'));
			var hint = E('p', { 'class': 'cpd-note', 'style': 'margin-top:6px' },
				_('当前未启用自动预授权：尚未出现在客户端列表里的设备不会被自动放行'));
			hint.style.display = state.preemptEnabled ? 'none' : '';
			var tgl = CPD.switchBtn(!!state.preemptEnabled, _('自动认证开关'), function (on) {
				state.preemptEnabled = on ? 1 : 0;
				statusLabel.textContent = on ? _('已启用') : _('已关闭');
				hint.style.display = on ? 'none' : '';
				CPD.stageUci('opennds', '@opennds[0]', 'allow_preemptive_authentication',
					'opt', String(state.preemptEnabled)).then(null, function (e) {
						tgl.setChecked(!on);
						state.preemptEnabled = on ? 0 : 1;
						statusLabel.textContent = on ? _('已关闭') : _('已启用');
						hint.style.display = on ? '' : 'none';
						CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
					});
			});
			sec.appendChild(E('div', { 'class': 'cpd-switch-row' }, [tgl, statusLabel]));
			sec.appendChild(hint);

			var wrap = E('div', {});
			sec.appendChild(wrap);
			renderListArea(wrap);
			return sec;
		}

		function renderListArea(wrap) {
			var macs = listMacs();
			wrap.innerHTML = '';

			wrap.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('div', { 'class': 'cpd-viewer-label' }, _('MAC 地址列表')),
				E('div', { 'style': 'margin-top:6px' }, [
					E('button', { 'class': 'cbi-button', 'click': function () {
						state.editing = true; renderAll();
					} }, _('编辑'))
				])
			]));
			if (state.editing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'rows': '3', 'spellcheck': 'false'
				});
				ta.value = macs.map(function (m) { return m.toUpperCase(); }).join('\n');
				wrap.appendChild(E('div', { 'class': 'cpd-field' }, [
					E('div', { 'class': 'cpd-note', 'style': 'margin-bottom:5px' },
						_('每行一个 MAC 地址，支持一次输入多个')),
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': function () {
							state.editing = false; renderAll();
						} }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { saveList(ta); }
						}, _('确定'))
					])
				]));
				window.setTimeout(function () {
					ta.focus();
					try { ta.setSelectionRange(ta.value.length, ta.value.length); } catch (e) {}
				}, 0);
			}

			var open = state.open;
			var head = E('div', { 'style': 'margin-top:16px;display:flex;align-items:center;gap:10px;flex-wrap:wrap' }, [
				E('button', {
					'class': 'cbi-button',
					'aria-expanded': open ? 'true' : 'false',
					'click': function () { state.open = !open; renderAll(); }
				}, open ? _('收起列表') : _('展开列表')),
				E('span', { 'class': 'cpd-note' },
					_('自动认证列表') + ' · ' + _('共 %s 条').format(macs.length))
			]);
			wrap.appendChild(head);
			if (!open) return;

			var total = macs.length;
			var pp = (state.perPage === 'all') ? total : parseInt(state.perPage, 10);
			if (!(pp > 0)) pp = total || 1;
			var pages = Math.max(1, Math.ceil(total / pp));
			var cur = Math.min(state.page, pages);
			var slice = macs.slice((cur - 1) * pp, cur * pp);

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
							'click': function () { askRemove(mac, inf.host); }
						}, _('删除')))
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

			var foot = E('div', {
				'style': 'display:flex;align-items:center;justify-content:space-between;gap:10px;' +
					'flex-wrap:wrap;margin-top:10px;font-size:12px;color:#7a8794'
			}, [ E('span', {}, _('共 %s 条 · 第 %s/%s 页').format(total, cur, pages)) ]);
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
				state.page = 1;
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
						'click': function () { state.page = cur - 1; renderAll(); }
					}, '‹ ' + _('上一页')));
				}
				if (cur < pages) {
					pager.appendChild(E('button', {
						'class': 'cbi-button', 'style': 'padding:2px 10px',
						'click': function () { state.page = cur + 1; renderAll(); }
					}, _('下一页') + ' ›'));
				}
				right.appendChild(pager);
			}
			foot.appendChild(right);
			wrap.appendChild(foot);
		}

		function refresh() {
			CPD.api('exempt', 'status').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				state.trusted = (j.trusted || []).map(function (m) { return String(m).toLowerCase(); });
				state.preempt = j.preempt || [];
				state.info = j.clients || {};
				state.blocked = (j.blocked || []).map(function (m) { return String(m).toLowerCase(); });
				state.preemptEnabled = (j.preempt_enabled === 0) ? 0 : 1;
				state.preempt0 = state.preempt.slice();
				state.pe0 = state.preemptEnabled;
				state.editing = false;
				renderAll();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('读取状态失败'), 'err');
			});
		}

		renderAll();
		refresh();

		function saveList(ta) {
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
			var before = state.preempt.map(macOf);
			var removed = before.filter(function (m) { return out.indexOf(m) < 0; });
			var byMac = {};
			state.preempt.forEach(function (e) { byMac[macOf(e)] = e; });
			state.preempt = out.map(function (m) {
				return byMac[m] ||
					('mac=' + m + ';sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0');
			});
			state.editing = false;
			renderAll();
			stageAutoAuth().then(function () {
				return stageDeauthFor(removed);
			}).then(null, function (e) {
				CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
			});
		}

		function stageAutoAuth() {
			return CPD.stageUci('opennds', '@opennds[0]', 'allow_preemptive_authentication',
				'opt', String(state.preemptEnabled))
				.then(function () {
					return CPD.stageListSync('opennds', '@opennds[0]', 'preemptivemac',
						state.preempt0, state.preempt);
				})
				.then(function () {
					state.preempt0 = state.preempt.slice();
				});
		}

		function stageDeauthFor(macs) {
			if (!macs || !macs.length) return Promise.resolve(null);
			return CPD.stageListEdit('zone_detect', 'main', 'pending_deauth', function (arr) {
				var out = arr.slice();
				macs.forEach(function (m) { out.push(CPD.deauthToken(m)); });
				return out;
			});
		}

		function askRemove(mac, host) {
			var who = host && host !== '—' ? host : mac.toUpperCase();
			CPD.confirm(null, _('确认删除客户端？'), _('确认删除'), true, function () {
				state.preempt = state.preempt.filter(function (e) { return macOf(e) !== mac; });
				renderAll();
				stageAutoAuth().then(function () {
					return stageDeauthFor([mac]);
				}).then(null, function (e) {
					CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
				});
			});
		}

		function handleApply() {
			if (state.editing) {
				CPD.notify(_('请先完成或取消 MAC 地址编辑'), 'warn');
				return Promise.resolve();
			}
			var tset = {}, dups = {};
			state.trusted.forEach(function (m) { tset[m] = 1; });
			state.preempt.forEach(function (e) {
				var m = macOf(e);
				if (tset[m]) dups[m] = 1;
			});
			var bset = {};
			state.blocked.forEach(function (m) { bset[m] = 1; });
			var bl = [];
			state.preempt.map(macOf).forEach(function (m) {
				if (bset[m] && bl.indexOf(m) < 0) bl.push(m);
			});
			if (bl.length) {
				var bshown = bl.slice(0, 3).join('、') +
					(bl.length > 3 ? _('等 %s 条').format(bl.length) : '');
				ui.addNotification(null, E('p', {},
					_('%s 在黑名单里，一个客户端只能属于一个列表，请先在「客户端黑名单」页解除拉黑。').format(bshown)), 'error');
				return Promise.resolve();
			}
			var dlist = Object.keys(dups);
			if (dlist.length) {
				var shown = dlist.slice(0, 3).map(function (m) { return '`' + m + '`'; }).join('、') +
					(dlist.length > 3 ? _('等 %s 条').format(dlist.length) : '');
				ui.addNotification(null, E('p', {}, _('%s 同时出现在信任列表和授权列表，一个客户端只能属于一个列表，请删除其中一个后再应用。').format(shown)), 'error');
				return Promise.resolve();
			}
			return stageAutoAuth().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		this.handleSave = function () {
			return stageAutoAuth().then(null, function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		};
		this.handleSaveApply = function () { return handleApply(); };
		this.handleReset = function () {
			return CPD.revertStaged().then(function () {
				refresh();
			}, function (e) {
				CPD.notify(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
