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
		function formValues() {
			return [inputs.st.value, inputs.ait.value, inputs.pit.value, inputs.ci.value]
				.map(function (v) { return String(v == null ? '' : v).trim(); });
		}

		function snapshotString() {
			var v = formValues();
			return 'sessiontimeout=' + v[0] +
				';authidletimeout=' + v[1] +
				';preauthidletimeout=' + v[2] +
				';checkinterval=' + v[3] +
				';scope=' + formScope();
		}

		var FIELD_NAMES = [_('会话超时'), _('空闲超时'), _('未认证超时'), _('检查间隔')];

		/* 与后端 se_validate 口径一致：非负整数；检查间隔 ≥ 1 */
		function validateForm() {
			var v = formValues();
			for (var i = 0; i < v.length; i++) {
				if (v[i] === '') continue;      /* 空 = 不写这个键，保持原值 */
				if (!/^[0-9]+$/.test(v[i])) {
					CPD.notify(_('%s 必须是非负整数（0 表示不限制）').format(FIELD_NAMES[i]), 'warn');
					if (inputs[['st', 'ait', 'pit', 'ci'][i]]) inputs[['st', 'ait', 'pit', 'ci'][i]].focus();
					return false;
				}
				if (i === 3 && Number(v[i]) < 1) {
					CPD.notify(_('检查间隔必须是不小于 1 的整数'), 'warn');
					inputs.ci.focus();
					return false;
				}
			}
			return true;
		}

		/* 覆盖模式：把每条授权客户端的 sessiontimeout 归零，其余字段原样保留
		 * （对齐后端 pm_override_entry；没有 mac= 的畸形条目原样留着） */
		function rebuildPreempt(list) {
			return (list || []).map(function (e) {
				var s = String(e), mac = '', ur = '0', dr = '0', uq = '0', dq = '0', custom = '';
				s.split(';').forEach(function (p) {
					var i = p.indexOf('=');
					if (i < 0) return;
					var k = p.slice(0, i), v = p.slice(i + 1);
					if (k === 'mac') mac = v;
					else if (k === 'uploadrate' && v !== '') ur = v;
					else if (k === 'downloadrate' && v !== '') dr = v;
					else if (k === 'uploadquota' && v !== '') uq = v;
					else if (k === 'downloadquota' && v !== '') dq = v;
					else if (k === 'custom') custom = p;
				});
				if (!mac) return s;
				return 'mac=' + mac + ';sessiontimeout=0;uploadrate=' + ur +
					';downloadrate=' + dr + ';uploadquota=' + uq + ';downloadquota=' + dq +
					(custom ? ';' + custom : '');
			});
		}

		/* 暂存：既写页面自己的缓存（session_snapshot，用于「尚未应用」提示），
		 * 也把真正生效的 opennds 键一起写进本会话的增量 —— 这样右上角
		 * 「未保存的配置」里看到的就是 uci set opennds.@opennds[0].xxx=…，
		 * 点「保存并应用」由 openwrt 自己 commit，不用插件再补一遍。
		 * 注意：增量只存在会话目录里，不 commit 就绝不落盘，断电重启也不会被动生效。 */
		function stageSnapshot() {
			if (!validateForm()) return Promise.reject({ silent: true });
			var v = formValues();
			var scope = formScope();
			var jobs = [
				CPD.stageUci('zone_detect', 'main', 'session_snapshot', 'opt', snapshotString()),
				CPD.stageUci('zone_detect', 'main', 'session_scope', 'opt', scope)
			];
			[['sessiontimeout', v[0]], ['authidletimeout', v[1]],
				['preauthidletimeout', v[2]], ['checkinterval', v[3]]].forEach(function (p) {
				if (p[1] === '') return;        /* 空值不写：绝不把已有键改成空串 */
				jobs.push(CPD.stageUci('opennds', '@opennds[0]', p[0], 'opt', p[1]));
			});
			if (scope === 'override') {
				jobs.push(CPD.api('exempt', 'status').then(function (j) {
					return CPD.stageUci('opennds', '@opennds[0]', 'preemptivemac', 'list',
						rebuildPreempt(j.preempt || []));
				}));
			}
			return Promise.all(jobs).then(function () {
				state.saved = {
					sessiontimeout: v[0], authidletimeout: v[1],
					preauthidletimeout: v[2], checkinterval: v[3],
					scope: scope
				};
			});
		}

		function handleSave() {
			return stageSnapshot().then(function () {
				/* 不弹横幅：右上角「未保存的配置」就是反馈 */
			}, function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		function handleApply() {
			/* 保存并应用：先落 uci 增量，再走 openwrt 原生 commit 流程 */
			return stageSnapshot().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		/* 读取会话参数；后端有"已保存待应用"快照时按快照显示 */
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
				state.saved = j.saved || null;
				renderAll();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('读取状态失败'), 'err');
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
				CPD.toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
