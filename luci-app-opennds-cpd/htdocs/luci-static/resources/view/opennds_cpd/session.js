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

		function matchesSaved() {
			if (!state.saved) return false;
			var s = state.saved;
			var f = formValues();
			return (s.sessiontimeout || '') === f[0] &&
				(s.authidletimeout || '') === f[1] &&
				(s.preauthidletimeout || '') === f[2] &&
				(s.checkinterval || '') === f[3] &&
				(s.scope || 'default') === formScope();
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
					scopeSel = E('select', { 'class': 'cpd-input', 'style': 'max-width:320px;min-width:190px' }, [
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
		function handleSave() {
			var args = [formScope(),
				'st=' + formValues()[0], 'ait=' + formValues()[1],
				'pit=' + formValues()[2], 'ci=' + formValues()[3]];
			/* 后端 save 的参数是位置式：scope st ait pit ci（空=沿用默认） */
			args = [formScope(), formValues()[0], formValues()[1], formValues()[2], formValues()[3]];
			CPD.api('session', 'save', args).then(function (j) {
				if (j.error === 'busy') { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (!j.ok) { CPD.toast(j.error || _('保存失败'), 'err'); return; }
				state.saved = {
					sessiontimeout: formValues()[0],
					authidletimeout: formValues()[1],
					preauthidletimeout: formValues()[2],
					checkinterval: formValues()[3],
					scope: formScope()
				};
				CPD.toast(_('配置已保存'), 'ok');
				refresh();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('保存失败'), 'err');
			});
		}

		function handleApply() {
			if (!state.saved || !matchesSaved()) {
				CPD.toast(_('存在未保存的修改，请先保存后再应用。'), 'warn');
				return;
			}
			CPD.apiConfirmable('session', 'apply').then(function (j) {
				if (j.error === 'busy') { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (j.ok) {
					CPD.toast(_('配置应用完成'), 'ok');
					CPD.showWarnings(j.warnings);
					refresh(true);
				} else {
					CPD.toast(j.error || _('应用失败'), 'err');
				}
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('应用失败'), 'err');
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
			refresh();
			return Promise.resolve();
		};

		return body;
	}
});
