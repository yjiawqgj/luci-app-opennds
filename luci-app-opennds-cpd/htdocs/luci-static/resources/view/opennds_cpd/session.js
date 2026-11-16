/*
 * 客户端会话管理 · openNDS CPD（LuCI view）
 * 照《客户端会话管理.md》：四个超时区块 + 配置范围（默认/覆盖）；
 * 「保存」写 zone_detect 缓存（session_snapshot），「应用」比对快照后写 openNDS 并重启；
 * pending=1 时表单按快照回填并提示「尚未应用」。
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
			st: '', ait: '', pit: '', ci: '',
			scope: 'default',
			saved: null, /* 最后一次保存的五项（来自 get.saved / 保存成功后的本地值） */
			pending: 0
		};
		var body = E('div', { 'class': 'cpd-page' });
		var inputs = {}, scopeSel, scopeHint;

		var FIELDS = [
			{ key: 'st', title: _('会话超时'), label: _('默认时间1440（分钟）'), ph: '1440', min: 0 },
			{ key: 'ait', title: _('空闲超时'), label: _('默认时间120分钟'), ph: '120', min: 0 },
			{ key: 'pit', title: _('未认证超时'), label: _('超时时间（分钟）'), ph: _('请输入分钟数'), min: 0 },
			{ key: 'ci', title: _('检查间隔'), label: _('默认时间为15（秒）'), ph: '15（秒）', min: 1 }
		];

		function formValues() {
			return [inputs.st.value, inputs.ait.value, inputs.pit.value, inputs.ci.value];
		}

		function formScope() {
			return scopeSel.value;
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('客户端会话管理'), 'openNDS · Sessions',
				_('配置会话超时、空闲超时、未认证超时及检查间隔。')));

			FIELDS.forEach(function (fd) {
				var sec = CPD.section(fd.title);
				var inp = E('input', {
					'class': 'cpd-input', 'type': 'number',
					'style': 'max-width:200px', 'min': String(fd.min), 'step': '1',
					'placeholder': fd.ph
				});
				inp.value = state[fd.key];
				inputs[fd.key] = inp;
				sec.appendChild(E('div', { 'class': 'cpd-field' }, [
					E('label', {}, fd.label),
					inp
				]));
				if (fd.key === 'pit') {
					sec.appendChild(E('p', { 'class': 'cpd-note' },
						_('检查客户端超时和配额状态的间隔（秒）')));
				}
				if (fd.key === 'st') {
					scopeSel = E('select', { 'class': 'cpd-input', 'style': 'max-width:320px;min-width:190px;height:36px;padding:0 8px;line-height:34px' }, [
						E('option', { value: 'default' }, _('默认')),
						E('option', { value: 'override' }, _('覆盖'))
					]);
					scopeSel.value = state.scope;
					scopeSel.addEventListener('change', function () { state.scope = scopeSel.value; });
					scopeHint = E('p', { 'class': 'cpd-note' }, _('覆盖会覆盖单独客户端的配置'));
					sec.appendChild(E('div', { 'class': 'cpd-field' }, [
						E('label', {}, _('配置范围')),
						scopeSel,
						scopeHint
					]));
				}
				body.appendChild(sec);
			});

		}

		/* ---------- 保存 / 应用 ---------- */
		function snapshotString() {
			return 'sessiontimeout=' + formValues()[0] +
				';authidletimeout=' + formValues()[1] +
				';preauthidletimeout=' + formValues()[2] +
				';checkinterval=' + formValues()[3] +
				';scope=' + formScope();
		}

		function stageSnapshot() {
			return CPD.stageUci('zone_detect', 'main', 'session_snapshot', 'opt',
				snapshotString()).then(function () {
				state.saved = {
					sessiontimeout: formValues()[0],
					authidletimeout: formValues()[1],
					preauthidletimeout: formValues()[2],
					checkinterval: formValues()[3],
					scope: formScope()
				};
			});
		}

		function handleSave() {
			return stageSnapshot().then(function () {
				CPD.statusBar(_('配置已保存，点击页面底部的「保存并应用」后生效'));
			}, function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		function handleApply() {
			/* 保存并应用：先把当前表单落成 uci 暂存，再由后端写入 openNDS 并重启 */
			stageSnapshot().then(function () {
				return CPD.apiConfirmable('session', 'apply');
			}).then(function (j) {
				if (j.error === 'busy') { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (j.ok) {
					CPD.toast(_('配置应用完成'), 'ok');
					CPD.showWarnings(j.warnings);
					CPD.notifyChanges();
					refresh(true);
				} else {
					CPD.toast(j.error || _('应用失败'), 'err');
				}
			}).catch(function (e) {
				CPD.toast(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		function refresh() {
			CPD.api('session', 'get').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				var useSnapshot = (j.pending === 1 && j.saved);
				var v = j.values || {};
				if (useSnapshot) {
					var s = j.saved;
					state.st = s.sessiontimeout || '';
					state.ait = s.authidletimeout || '';
					state.pit = s.preauthidletimeout || '';
					state.ci = s.checkinterval || '';
					state.scope = s.scope || 'default';
					CPD.toast(_('上次保存的配置尚未应用，点「应用」后生效'), 'warn');
				} else {
					state.st = v.sessiontimeout || '';
					state.ait = v.authidletimeout || '';
					state.pit = v.preauthidletimeout || '';
					state.ci = v.checkinterval || '';
					state.scope = j.scope || 'default';
				}
				state.pending = j.pending;
				/* 快照引用始终来自后端：pending=1 时它就是"已保存待应用"的那份 */
				state.saved = j.saved || null;
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
			return CPD.revertStaged(['zone_detect']).then(function () {
				refresh();
			}, function (e) {
				CPD.toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
