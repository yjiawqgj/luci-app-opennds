/*
 * Walled Garden · openNDS CPD（LuCI view）
 * 照《WalledGarden.md》：手动区（必须带端口）+ 自动区（dnsmasq nftset）；
 * 编辑器「完成」只改前端状态，「保存」= 内存快照，「应用」= 后端校验+写三键+重启。
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
			manual: '',
			domains: '',
			ports: '',
			wgMode: 'nftset',
			manualEditing: false,
			autoEditing: false,
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' });
		var manualPanel, autoPanel, portsInput;

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('Walled Garden'), 'openNDS · 域名白名单',
				_('为未认证客户端放行指定域名或地址。手动模式要求每个域名仅对应一个 IP；自动模式支持多 IP 域名（如 CDN）。')));

			/* 手动区 */
			var sec1 = CPD.section(_('手动'), 'Manual');
			sec1.appendChild(E('p', { 'class': 'cpd-note' },
				_('可以添加域名，但是添加的域名必须只有一个 IP，否则规则将不会被应用。')));
			manualPanel = E('div', {});
			sec1.appendChild(manualPanel);
			renderManual();
			body.appendChild(sec1);

			/* 自动区 */
			var sec2 = CPD.section(_('自动'), 'Auto');
			sec2.appendChild(E('p', { 'class': 'cpd-note' }, [
				_('自动配置需要系统已安装dnsmasq-full，且为支持nftset的dnsmasq。'),
				E('br'),
				_('域名与端口为全匹配模式，即一个域名可以匹配多个端口，多个端口也可以匹配一个域名，不区分TCP/UDP协议。')
			]));
			if (state.wgMode === 'none') {
				sec2.appendChild(E('div', { 'class': 'cpd-warnbar' },
					_('自动模式不可用：需安装 dnsmasq-full（支持 nftset）。安装后本区配置才会生效。')));
			} else if (state.wgMode === 'ipset') {
				sec2.appendChild(E('div', { 'class': 'cpd-warnbar' },
					_('当前走旧式 ipset 回退，建议升级 dnsmasq-full')));
			}
			autoPanel = E('div', {});
			sec2.appendChild(autoPanel);
			renderAuto();
			body.appendChild(sec2);

			/* 底部操作 */
		}

		/* ---------- 手动区 ---------- */
		function renderManual() {
			manualPanel.innerHTML = '';
			manualPanel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', {
					'class': 'cbi-button',
					'aria-expanded': state.manualEditing ? 'true' : 'false',
					'click': function () { startEdit('manual'); }
				}, _('编辑'))
			]));
			if (state.manualEditing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'spellcheck': 'false',
					'placeholder': '663 example.com\ntcp/udp 663 example.com'
				});
				ta.value = state.manual;
				ta.addEventListener('input', function () { state.manual = ta.value; });
				manualPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': function () { cancelEdit('manual'); } }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { finishEdit('manual', ta); }
						}, _('完成'))
					])
				]));
				window.setTimeout(function () { ta.focus(); }, 0);
			} else if (state.manual.trim()) {
				manualPanel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('规则列表')),
					E('div', { 'class': 'cpd-note', 'style': 'margin-top:5px' },
						_('每条配置必须包含 IP/域名 端口，不能只写域名或者IP。')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' }, state.manual))
				]));
			}
		}

		/* ---------- 自动区 ---------- */
		function renderAuto() {
			autoPanel.innerHTML = '';
			autoPanel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', {
					'class': 'cbi-button',
					'aria-expanded': state.autoEditing ? 'true' : 'false',
					'click': function () { startEdit('auto'); }
				}, _('编辑'))
			]));
			if (state.autoEditing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'spellcheck': 'false',
					'placeholder': 'example.com'
				});
				ta.value = state.domains;
				ta.addEventListener('input', function () { state.domains = ta.value; });
				autoPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					E('label', {}, _('域名列表')),
					E('div', { 'class': 'cpd-note', 'style': 'margin-bottom:5px' }, _('一行一个域名')),
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': function () { cancelEdit('auto'); } }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { finishEdit('auto', ta); }
						}, _('完成'))
					])
				]));
				window.setTimeout(function () { ta.focus(); }, 0);
			} else if (state.domains.trim()) {
				autoPanel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('域名列表')),
					E('div', { 'class': 'cpd-note', 'style': 'margin-top:5px' }, _('一行一个域名')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' }, state.domains))
				]));
			}
			/* 端口框：编辑态与展示态都显示 */
			portsInput = E('input', { 'class': 'cpd-input', 'type': 'text', 'placeholder': '80,443' });
			portsInput.value = state.ports;
			portsInput.addEventListener('input', function () { state.ports = portsInput.value; });
			autoPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
				E('label', {}, _('端口')),
				E('div', { 'class': 'cpd-note', 'style': 'margin-bottom:5px' },
					_('填写允许访问的端口，多个可用逗号分隔（如 80,443）；留空表示不限制端口。')),
				portsInput
			]));
		}

		/* ---------- 编辑 ---------- */
		function startEdit(which) {
			var editing = (which === 'manual') ? state.manualEditing : state.autoEditing;
			if (editing) {
				var ta = (which === 'manual' ? manualPanel : autoPanel).querySelector('.cpd-ta');
				if (ta) ta.focus();
				return;
			}
			if (which === 'manual') { state.manualEditing = true; renderManual(); }
			else { state.autoEditing = true; renderAuto(); }
		}

		function cancelEdit(which) {
			if (which === 'manual') { state.manualEditing = false; renderManual(); }
			else { state.autoEditing = false; renderAuto(); }
			CPD.toast(_('已取消编辑，未保存本次修改'));
		}

		function finishEdit(which, ta) {
			var value = (ta ? ta.value : '').replace(/\r\n/g, '\n').split('\n')
				.map(function (l) { return l.trim(); })
				.filter(function (l) { return l; }).join('\n');
			if (which === 'manual') {
				state.manual = value;
				state.manualEditing = false;
				renderManual();
				CPD.toast(_('规则列表已更新'), 'ok');
			} else {
				state.domains = value;
				state.autoEditing = false;
				renderAuto();
				CPD.toast(_('域名列表已更新'), 'ok');
			}
		}

		function editingBusy() {
			return state.manualEditing || state.autoEditing;
		}

		function currentText() {
			return state.manual;
		}
		function currentAuto() {
			return state.domains;
		}
		function currentPorts() {
			return state.ports;
		}

		/* ---------- 保存 / 应用 ---------- */
		function stageWg() {
			/* 先过后端校验，把展开后的最终规则落成 uci 暂存 */
			return CPD.api('walledgarden', 'validate', [
				'manual_b64=' + CPD.b64encode(currentText()),
				'domains_b64=' + CPD.b64encode(currentAuto()),
				'ports=' + currentPorts()
			]).then(function (j) {
				if (j.error === 'busy') throw { error: 'busy' };
				if (!j.ok && j.errors) { CPD.showErrors(j.errors); throw { silent: true }; }
				if (!j.ok) throw { error: j.error || _('校验失败') };
				return Promise.all([
					CPD.stageUci('opennds', '@opennds[0]', 'preauthenticated_users', 'list',
						j.manual_rules || []),
					CPD.stageUci('opennds', '@opennds[0]', 'walledgarden_fqdn_list', 'list',
						j.fqdns || []),
					CPD.stageUci('opennds', '@opennds[0]', 'walledgarden_port_list', 'list',
						j.ports || [])
				]);
			});
		}

		function handleSave() {
			if (editingBusy()) {
				CPD.toast(_('请先完成或取消列表编辑'), 'warn');
				return;
			}
			stageWg().then(function () {
				state.snapshot = {
					manual: currentText(),
					domains: currentAuto(),
					ports: currentPorts()
				};
				CPD.toast(_('配置已保存（尚未生效，请点击应用）'), 'ok');
			}, function (e) {
				if (e && e.silent) return;
				CPD.toast(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		function handleApply() {
			if (editingBusy()) {
				CPD.toast(_('请先完成或取消列表编辑'), 'warn');
				return;
			}
			/* 保存并应用：先落 uci 暂存，再由后端写入并重启 */
			stageWg().then(function () {
				return CPD.apiConfirmable('walledgarden', 'apply', [
					'manual_b64=' + CPD.b64encode(currentText()),
					'domains_b64=' + CPD.b64encode(currentAuto()),
					'ports=' + currentPorts()
				]);
			}).then(function (j) {
				if (j && j.error === 'busy') { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (j.ok) {
					CPD.toast(_('配置已应用'), 'ok');
					CPD.showWarnings(j.warnings);
					CPD.notifyChanges();
					refresh();
				} else if (j.errors) {
					CPD.showErrors(j.errors);
				} else {
					CPD.toast(j.error || _('应用失败'), 'err');
				}
			}).catch(function (e) {
				if (e && e.silent) return;
				CPD.toast(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		function refresh() {
			CPD.api('walledgarden', 'status').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				state.manual = j.manual || '';
				state.domains = j.domains || '';
				state.ports = j.ports || '';
				state.wgMode = j.wg_mode || 'none';
				state.manualEditing = false;
				state.autoEditing = false;
				state.snapshot = { manual: state.manual, domains: state.domains, ports: state.ports };
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
			return CPD.revertStaged(['opennds']).then(function () {
				refresh();
			}, function (e) {
				CPD.toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
