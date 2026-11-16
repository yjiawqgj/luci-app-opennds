/*
 * 访问限制· openNDS CPD（LuCI view）
 * 照《访问限制.md》：手动阻止（block 规则）+ 自动阻止（域名/端口框）；
 * 编辑器「保存」只做本区格式校验不请求后端；「保存」= 内存快照；
 * 「应用」= 后端校验 + 写三键 + 重启；只填端口不写域名前后端同口径拦截。
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
			blMode: 'nftset',
			manualEditing: false,
			autoEditing: false,
			taManual: null,
			taAuto: null,
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' });
		var manualPanel, autoPanel, portsInput;

		function toast(msg, kind) {
			CPD.toastCenter(msg, kind); /* 本页/黑名单页同款深色胶囊 */
		}

		/* ---------- 校验（编辑器内、不发请求） ---------- */
		function checkManualLine(line) {
			/* 每行必须含域名/IP；端口段不支持（决策 #12，完整校验在应用时由后端做） */
			var tokens = line.split(/\s+/);
			var hasTarget = tokens.some(function (t) { return /[a-z.]/i.test(t); });
			var hasRange = tokens.some(function (t) { return /^[0-9]+-[0-9]+$/.test(t); });
			if (!hasTarget) return _('每行必须有一个域名或者一个IP地址');
			if (hasRange) return _('不支持端口范围，请逐个端口写');
			return null;
		}

		function checkDomainLine(line) {
			if (/\s/.test(line)) return _('只能填域名，一行一个');
			if (/^[0-9]+$/.test(line)) return _('只能填域名，一行一个');
			if (/[*\/:]/.test(line)) return _('只能填域名，一行一个');
			return null;
		}

		function checkPorts(v) {
			/* 返回 null=通过，否则错误消息（决策 #8，不算行错误） */
			if (/[，；]/.test(v)) return _('端口必须使用英文逗号分隔');
			if (/-/.test(v)) return _('不支持端口范围，请逐个端口写');
			if (/[^\d,\s]/.test(v)) return _('端口必须是 1-65535 的整数');
			if (/,,|^\s*,|,\s*$/.test(v)) return _('端口列表格式不正确，用英文逗号分隔，如 80,443');
			var items = v.split(/[,\s]+/).filter(function (x) { return x; });
			for (var i = 0; i < items.length; i++) {
				var p = parseInt(items[i], 10);
				if (!/^\d+$/.test(items[i]) || p < 1 || p > 65535) {
					return _('端口必须是 1-65535 的整数');
				}
			}
			return null;
		}

		function portOnly() {
			return !state.domains.trim() && !!state.ports.trim();
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('访问限制'), 'openNDS',
				_('只针对已认证和预授权客户端生效，可信任客户端不受此限制。')));

			/* 手动阻止 */
			var sec1 = CPD.section(_('手动限制'), 'Manual');
			sec1.appendChild(E('p', { 'class': 'cpd-note' },
				_('填写域名需要确保域名只有一个IP地址，否则添加规则后将不会生效。')));
			sec1.appendChild(E('p', { 'class': 'cpd-note' },
				_('每行必须有一个域名或者一个IP地址，域名或者IP地址可以搭配访问协议，即：tcp/udp；也可以搭配端口号，但不支持端口范围。')));
			manualPanel = E('div', {});
			sec1.appendChild(manualPanel);
			renderManual();
			body.appendChild(sec1);

			/* 自动阻止 */
			var sec2 = CPD.section(_('自动阻止'), 'Auto');
			sec2.appendChild(E('p', { 'class': 'cpd-note' },
				_('域名和端口为全匹配模式：端口对所有域名生效，不能按域名分别设置。')));
			sec2.appendChild(E('p', { 'class': 'cpd-note' },
				_('只写域名不写端口，会阻止这些域名的所有协议、所有端口；填了端口就只拦这些端口，且只能拦 TCP。只写端口不写域名无法保存——拦截列表靠域名解析填充，没有域名这条规则不会生效。')));
			if (state.blMode === 'none') {
				sec2.appendChild(E('div', { 'class': 'cpd-warnbar' },
					_('自动阻止不可用：需安装 dnsmasq-full（支持 nftset）。安装后本区配置才会生效。')));
			} else if (state.blMode === 'ipset') {
				sec2.appendChild(E('div', { 'class': 'cpd-warnbar' },
					_('当前走旧式 ipset 回退，建议升级 dnsmasq-full')));
			}
			autoPanel = E('div', {});
			sec2.appendChild(autoPanel);
			renderAuto();
			body.appendChild(sec2);

		}

		function renderManual() {
			manualPanel.innerHTML = '';
			state.taManual = null;
			manualPanel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', {
					'class': 'cbi-button',
					'aria-expanded': state.manualEditing ? 'true' : 'false',
					'click': function () { startEdit('manual'); }
				}, _('编辑'))
			]));
			if (state.manualEditing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'spellcheck': 'false', 'rows': '6',
					'placeholder': 'tcp/udp 443 example.com\n80 192.168.1.20'
				});
				ta.value = state.manual;
				state.taManual = ta;
				manualPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': function () { cancelEdit('manual'); } }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { saveManual(ta); }
						}, _('确定'))
					])
				]));
				window.setTimeout(function () { ta.focus(); }, 0);
			} else if (state.manual.trim()) {
				manualPanel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('已保存规则')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' }, state.manual))
				]));
			}
		}

		function renderAuto() {
			autoPanel.innerHTML = '';
			state.taAuto = null;
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
					'placeholder': 'example.com\nwww.example.com'
				});
				ta.value = state.domains;
				state.taAuto = ta;
				autoPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					E('label', {}, _('域名')),
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': function () { cancelEdit('auto'); } }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { saveAuto(ta); }
						}, _('确定'))
					])
				]));
				window.setTimeout(function () { ta.focus(); }, 0);
			} else if (state.domains.trim()) {
				autoPanel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('已保存规则')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' }, state.domains))
				]));
			}
			portsInput = E('input', {
				'class': 'cpd-input', 'type': 'text', 'placeholder': '80,443',
				'inputmode': 'numeric'
			});
			portsInput.value = state.ports;
			/* 必须实时回写：之前这个框只显示不回写，用户在框里填的端口永远
			 * 进不了 state.ports，保存后配置里就只有域名没有端口。 */
			portsInput.addEventListener('input', function () {
				state.ports = portsInput.value;
			});
			portsInput.addEventListener('change', function () {
				state.ports = portsInput.value;
			});
			autoPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
				E('label', {}, _('端口')),
				E('div', { 'class': 'cpd-note', 'style': 'margin-bottom:5px' },
					_('多个端口号使用英文逗号分隔，不支持端口范围。')),
				portsInput
			]));
		}

		/* ---------- 编辑 ---------- */
		function startEdit(which) {
			if (which === 'manual') { state.manualEditing = true; renderManual(); }
			else { state.autoEditing = true; renderAuto(); }
		}

		function cancelEdit(which) {
			if (which === 'manual') { state.manualEditing = false; renderManual(); }
			else { state.autoEditing = false; renderAuto(); }
		}

		function saveManual(ta) {
			var text = (ta ? ta.value : state.manual).replace(/\r\n/g, '\n');
			var lines = text.split('\n').map(function (l) { return l.trim(); })
				.filter(function (l) { return l; });
			for (var i = 0; i < lines.length; i++) {
				var err = checkManualLine(lines[i]);
				if (err) {
					toast(_('第 %s 行：').format(i + 1) + err, 'warn');
					return false; /* 不落状态 */
				}
			}
			state.manual = lines.join('\n');
			state.manualEditing = false;
			renderManual();
			return true;
		}

		function saveAuto(ta) {
			var text = (ta ? ta.value : state.domains).replace(/\r\n/g, '\n');
			var lines = text.split('\n').map(function (l) { return l.trim(); })
				.filter(function (l) { return l; });
			for (var i = 0; i < lines.length; i++) {
				var err = checkDomainLine(lines[i]);
				if (err) {
					toast(_('第 %s 行：').format(i + 1) + err, 'warn');
					return false; /* 不落状态 */
				}
			}
			state.domains = lines.join('\n');
			state.autoEditing = false;
			renderAuto();
			return true;
		}

		/* 编辑框开着就直接点底部保存，是很自然的操作：先把编辑框收进来 */
		function syncEditors() {
			if (state.manualEditing && !saveManual(state.taManual)) return false;
			if (state.autoEditing && !saveAuto(state.taAuto)) return false;
			if (portsInput) state.ports = portsInput.value;
			return true;
		}

		/* ---------- 保存 / 应用 ---------- */
		function stageAccess() {
			/* 先过后端校验，把展开后的最终规则落成 uci 暂存 */
			return CPD.api('access', 'validate', [
				'manual_b64=' + CPD.b64encode(state.manual),
				'auto_b64=' + CPD.b64encode(state.domains),
				'ports=' + state.ports
			]).then(function (j) {
				if (j.error === 'busy') throw { error: 'busy' };
				if (j.error === 'port_only') {
					toast(_('只填端口不写域名无法保存：没有域名，拦截列表为空，规则不会生效'), 'warn');
					state.autoEditing = true; /* 展开自动区编辑器 */
					renderAuto();
					throw { silent: true };
				}
				if (!j.ok && j.errors) { CPD.showErrors(j.errors); throw { silent: true }; }
				if (!j.ok) throw { error: j.error || _('校验失败') };
				return Promise.all([
					CPD.stageUci('opennds', '@opennds[0]', 'authenticated_users', 'list',
						j.final_list || []),
					CPD.stageUci('opennds', '@opennds[0]', 'blocklist_fqdn_list', 'list',
						j.fqdns || []),
					CPD.stageUci('opennds', '@opennds[0]', 'blocklist_port_list', 'list',
						j.ports || [])
				]);
			});
		}

		function precheckPorts() {
			var pe = checkPorts(state.ports);
			if (pe) {
				toast(pe, 'warn');
				if (portsInput) portsInput.focus();
				return false;
			}
			return true;
		}

		function handleSave() {
			if (!syncEditors()) return Promise.resolve();
			if (!precheckPorts()) return Promise.resolve();
			return stageAccess().then(function () {
				state.snapshot = { manual: state.manual, domains: state.domains, ports: state.ports };
				/* 不弹横幅：右上角「未保存的配置」就是反馈 */
			}, function (e) {
				if (e && e.silent) return;
				toast(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		function handleApply() {
			if (!syncEditors()) return Promise.resolve();
			if (!precheckPorts()) return Promise.resolve();
			/* 保存并应用：先落 uci 增量，再走 openwrt 原生 commit 流程 */
			return stageAccess().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				if (e && e.silent) return;
				toast(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		function refresh() {
			CPD.api('access', 'status').then(function (j) {
				if (!j.ok) { toast(j.error || _('读取状态失败'), 'err'); return; }
				state.manual = j.manual || '';
				state.domains = j.auto || '';
				state.ports = j.ports || '';
				state.blMode = j.bl_mode || 'none';
				state.manualEditing = false;
				state.autoEditing = false;
				state.snapshot = { manual: state.manual, domains: state.domains, ports: state.ports };
				renderAll();
			}).catch(function (e) {
				toast((e && e.error) || _('读取状态失败'), 'err');
			});
		}

		refresh();
		/* ---------- LuCI 框架底部按钮：保存 / 保存&应用 / 复位 ---------- */
		this.handleSave = function () {
			return handleSave();
		};
		this.handleSaveApply = function () {
			return handleApply();
		};
		this.handleReset = function () {
			return CPD.revertStaged().then(function () {
				refresh();
			}, function (e) {
				toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
