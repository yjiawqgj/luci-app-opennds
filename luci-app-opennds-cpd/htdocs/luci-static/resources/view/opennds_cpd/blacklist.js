/*
 * 客户端黑名单 · openNDS CPD（LuCI view）
 * 黑名单 = openNDS 官方 MAC 黑名单：/etc/config/opennds 的 blockedmac 列表，
 * 配合 macmechanism='block'。openNDS 官方机制在网络层直接拦截被拉黑的客户端
 * （客户端连门户页面都打不开），因此本页只有 MAC 名单编辑，没有门户选择。
 */
'use strict';
'require view';
'require ui';
'require fs';
'require dom';

var CPD = null;

return view.extend({
	load: function () {
		return L.require('opennds_cpd.common').then(function (m) { CPD = m; });
	},

	render: function () {
		var state = {
			macs: [],        /* 已保存（配置里的）小写 MAC */
			mechanism: '',   /* 当前 macmechanism（allow=白名单模式，黑名单不生效） */
			editing: false,
			ta: null         /* 展开中的编辑框，保存时以它为准 */
		};
		var body = E('div', { 'class': 'cpd-page' });
		var macPanel;

		function macOk(s) {
			return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(s);
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('客户端黑名单'), 'openNDS',
				_('加入名单的客户端将被 openNDS 直接拒绝认证，无法再打开门户页面。')));

			var sec1 = CPD.section(_('客户端黑名单'), 'Blacklist');
			macPanel = E('div', {});
			sec1.appendChild(macPanel);
			renderMacs();
			body.appendChild(sec1);

			refreshSilently();
		}

		function refreshSilently() {
			return CPD.api('blacklist', 'status').then(function (j) {
				if (!j.ok) return;
				/* 名单里的空值/脏数据不显示 */
				state.macs = (j.macs || []).filter(function (m) { return macOk(m); });
				state.mechanism = j.mechanism || '';
				if (!state.editing) renderMacs();
			}).catch(function () {});
		}

		/* ---------- MAC 名单 ---------- */
		function renderMacs() {
			macPanel.innerHTML = '';
			state.ta = null;
			macPanel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', { 'class': 'cbi-button', 'click': startAdd }, _('编辑'))
			]));
			if (state.editing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'rows': '5', 'spellcheck': 'false',
					/* 不放具体 MAC 示例：灰色示例值会被当成"插件预置的一条记录" */
					'placeholder': _('每行一个 MAC 地址，留空表示没有任何记录')
				});
				ta.value = state.macs.map(function (m) { return m.toUpperCase(); }).join('\n');
				state.ta = ta;
				macPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': cancelEdit }, _('取消')),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': function () { saveMacs(ta); }
						}, _('确定'))
					])
				]));
				window.setTimeout(function () {
					ta.focus();
					try { ta.setSelectionRange(0, 0); } catch (e) {}
				}, 0);
			} else if (state.macs.length) {
				macPanel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('黑名单')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' },
							state.macs.map(function (m) { return m.toUpperCase(); }).join('\n')))
				]));
			} else {
				macPanel.appendChild(E('p', { 'class': 'cpd-note', 'style': 'margin-top:10px' },
					_('暂无客户端记录')));
			}
		}

		function startAdd() {
			state.editing = true;
			renderMacs();
		}

		function cancelEdit() {
			state.editing = false;
			renderMacs();
		}

		/* 解析编辑框：返回 {list} 或 {error} */
		function parseMacs(ta) {
			var lines = (ta ? ta.value : '').replace(/\r\n/g, '\n').split('\n')
				.map(function (l) { return l.trim(); })
				.filter(function (l) { return l; });
			var seen = {}, out = [];
			for (var i = 0; i < lines.length; i++) {
				if (!macOk(lines[i])) return { error: _('非法MAC: %s').format(lines[i]) };
				var lm = lines[i].toLowerCase();
				if (!seen[lm]) { seen[lm] = 1; out.push(lm); }
			}
			return { list: out };
		}

		/* 保存 = 写 uci 暂存（顶部「未保存的配置」出现，复位可还原），不生效。
		 * blockedmac 只在 macmechanism='block' 时生效：名单有内容而用户没设过
		 * mechanism 时顺手补上；用户自己设了 'allow'（白名单模式）则提示名单
		 * 不生效，但不替用户改他的配置。 */
		function stageMacs(list) {
			return CPD.stageUci('opennds', '@opennds[0]', 'blockedmac', 'list', list)
				.then(function () {
					if (list.length && state.mechanism !== 'allow') {
						return CPD.stageUci('opennds', '@opennds[0]', 'macmechanism', 'opt', 'block');
					}
				})
				.then(function () {
					if (list.length && state.mechanism === 'allow') {
						CPD.notify(_('openNDS 当前为白名单模式（macmechanism=allow），黑名单名单不会生效'), 'warn');
					}
				});
		}

		/* 保存时以「编辑框此刻的内容」为准。点了「编辑」就直接按底部保存是很
		 * 自然的操作，之前那样会拿着旧的 state.macs 去写，用户看到的修改就
		 * 永远进不了配置。 */
		function currentMacs() {
			if (state.editing && state.ta) {
				var p = parseMacs(state.ta);
				if (p.error) throw { error: p.error };
				state.macs = p.list;
				state.editing = false;
				renderMacs();
				return p.list;
			}
			return state.macs;
		}

		/* 编辑框下的「确定」：只做校验并退出编辑态，不写配置 */
		function saveMacs(ta) {
			var p = parseMacs(ta);
			if (p.error) { CPD.notify(p.error, 'err'); if (ta) ta.focus(); return Promise.resolve(); }
			state.macs = p.list;
			state.editing = false;
			renderMacs();
			return Promise.resolve();
		}

		renderAll();
		refreshSilently();

		/* ---------- LuCI 框架底部按钮：保存 = 暂存，保存并应用 = 提交 ---------- */
		this.handleSave = function () {
			/* 不弹横幅：右上角「未保存的配置: N」就是保存成功的反馈 */
			var list;
			try { list = currentMacs(); }
			catch (e) { CPD.notify(CPD.errText(e, _('保存失败')), 'err'); return Promise.resolve(); }
			return stageMacs(list).catch(function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		};
		this.handleSaveApply = function () {
			var list;
			try { list = currentMacs(); }
			catch (e) { CPD.notify(CPD.errText(e, _('应用失败')), 'err'); return Promise.resolve(); }
			return stageMacs(list).then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		};
		this.handleReset = function () {
			return CPD.revertStaged().then(function () {
				state.editing = false;
				return refreshSilently();
			}, function (e) {
				CPD.notify(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
