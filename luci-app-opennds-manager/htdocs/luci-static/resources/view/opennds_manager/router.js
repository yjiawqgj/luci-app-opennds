/*
 * 路由器访问 · openNDS CPD（LuCI view）
 * 照《路由器访问.md》与演示：接管开关 + 开放端口列表；编辑器「保存」先过
 * 后端 validate（只读），只有底部「应用」才写 uci 并重启 openNDS。
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
			takeoverOff: false,
			fw4: 1,
			editing: false,
			saved: '',
			draft: '',
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' });
		var panel;

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('路由器访问'), 'openNDS · Router Access',
				_('配置 openNDS 对路由器的接管行为，以及对所有客户端开放的端口。')));

			var sec1 = CPD.section(_('接管'), 'Takeover');
			var chk = E('input', { type: 'checkbox', id: 'cpd-takeover-off' });
			chk.checked = state.takeoverOff;
			chk.addEventListener('change', function () {
				state.takeoverOff = chk.checked;
				/* 勾选立即落成 uci 暂存：右上角马上出现「未保存的配置」 */
				CPD.stageUci('opennds', '@opennds[0]', 'users_to_router_passthrough',
					'opt', state.takeoverOff ? '1' : '0').then(null, function (e) {
						CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
					});
			});
			sec1.appendChild(E('div', {}, [
				E('label', { 'style': 'display:inline-flex;align-items:center;gap:9px;padding:8px 0;cursor:pointer' }, [
					chk, E('span', {}, _('关闭接管'))
				]),
				E('p', { 'class': 'cpd-note' }, _('如果你不知道该功能作用，请保持默认。'))
			]));
			body.appendChild(sec1);

			var sec2 = CPD.section(_('开放端口'), 'Open Ports');
			sec2.appendChild(E('p', { 'class': 'cpd-note' }, _('对所有客户端生效。')));
			if (!state.fw4) {
				sec2.appendChild(E('div', { 'class': 'cpd-warnbar' },
					_('当前系统未使用 fw4（nftables），openNDS 不支持 users_to_router 规则，本页配置不会生效。')));
			}
			panel = E('div', {});
			sec2.appendChild(panel);
			renderPanel();
			body.appendChild(sec2);

		}

		function renderPanel() {
			panel.innerHTML = '';
			panel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', {
					'class': 'cbi-button',
					'aria-expanded': state.editing ? 'true' : 'false',
					'click': startAdd
				}, _('编辑'))
			]));

			if (state.editing) {
				var ta = E('textarea', {
					'class': 'cpd-ta',
					'spellcheck': 'false',
					'placeholder': '4433\ntcp/udp 4267\n192.168.1.1\ntcp/udp 3654 192.168.1.1'
				});
				ta.value = state.draft;
				ta.addEventListener('input', function () { state.draft = ta.value; });
				panel.appendChild(E('div', { 'class': 'cpd-field' }, [
					E('label', {}, _('支持IP、协议、端口号。')),
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': cancelEdit }, _('取消')),
						E('button', { 'class': 'cbi-button', 'click': clearDraft }, _('清空')),
						E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function () { saveEdit(ta); } }, _('确定'))
					])
				]));
				window.setTimeout(function () {
					ta.focus();
					try { ta.setSelectionRange(ta.value.length, ta.value.length); } catch (e) {}
				}, 0);
			} else if (state.saved.trim()) {
				panel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('开放端口列表')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' }, state.saved))
				]));
			}
		}

		/* ---------- 编辑 ---------- */
		function startAdd() {
			if (state.editing) {
				var ta = document.querySelector('.cpd-ta');
				if (ta) { ta.focus(); }
				return;
			}
			state.editing = true;
			/* 编辑框必须带出已有内容：这个框是「整块替换」语义，
			 * 空着进来再点确定，等于把原有端口/规则全删掉。 */
			state.draft = state.saved;
			renderPanel();
		}

		function cancelEdit() {
			state.editing = false;
			state.draft = state.saved;
			renderPanel();
			/* 取消编辑不提示，避免噪音 */
		}

		function clearDraft() {
			state.draft = '';
			var ta = document.querySelector('.cpd-ta');
			if (ta) ta.value = '';
		}

		function saveEdit(ta) {
			var text = (ta ? ta.value : state.draft).replace(/\r\n/g, '\n');
			CPD.api('router', 'validate', ['text_b64=' + CPD.b64encode(text)]).then(function (j) {
				if (j.error === 'busy') { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (!j.ok && j.errors) {
					CPD.showErrors(j.errors);
					return; /* 保持编辑态 */
				}
				if (!j.ok) { CPD.toast(j.error || _('校验失败'), 'err'); return; }
				var lines = text.split('\n').map(function (l) { return l.trim(); })
					.filter(function (l) { return l; });
				var value = lines.join('\n');
				state.saved = value;
				state.draft = value;
				state.editing = false;
				renderPanel();
				/* 确定即落成 uci 暂存：右上角马上出现「未保存的配置」，
				 * 点开就是原生 diff，由底部「保存并应用」提交 */
				stageRules(j.rules || []).then(null, function (e2) {
					CPD.notify(CPD.errText(e2, _('暂存配置失败')), 'err');
				});
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('校验失败'), 'err');
			});
		}

		/* ---------- 暂存 / 应用 ---------- */
		/* 编辑框开着就直接按底部按钮，是很自然的操作：这时以编辑框内容为准，
		 * 不再用旧的 state.saved（那样用户刚加的端口会被静默丢弃）。 */
		function currentText() {
			if (state.editing) {
				var ta = document.querySelector('.cpd-ta');
				if (ta) state.draft = ta.value;
				return state.draft;
			}
			return state.saved;
		}

		/* 规则列表 + 接管开关 → uci 暂存（右上角「未保存的配置」由它产生） */
		function stageRules(rules) {
			return Promise.all([
				CPD.stageUci('opennds', '@opennds[0]', 'users_to_router', 'list', rules || []),
				CPD.stageUci('opennds', '@opennds[0]', 'users_to_router_passthrough', 'opt',
					state.takeoverOff ? '1' : '0')
			]);
		}

		function stageRouter() {
			var text = currentText().replace(/\r\n/g, '\n');
			return CPD.api('router', 'validate', ['text_b64=' + CPD.b64encode(text)])
				.then(function (j) {
					/* 后端忙返回 {"ok":0,"busy":1}（没有 error 字段），别落进「校验失败」 */
					if (j && j.busy === 1) throw { error: _('等待上一步完成，请稍候重试') };
					if (!j.ok && j.errors) { CPD.showErrors(j.errors); throw { silent: true }; }
					if (!j.ok) throw { error: j.error || _('校验失败') };
					state.saved = text.split('\n').map(function (l) { return l.trim(); })
						.filter(function (l) { return l; }).join('\n');
					state.draft = state.saved;
					if (state.editing) { state.editing = false; renderPanel(); }
					return stageRules(j.rules || []);
				});
		}

		function handleApply() {
			/* 保存并应用：先落 uci 增量，再走 openwrt 原生 commit 流程 */
			return stageRouter().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				if (e && e.silent) return;
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		function refresh() {
			CPD.api('router', 'status').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				state.takeoverOff = (j.passthrough === 1);
				state.fw4 = j.fw4;
				state.saved = j.text || '';
				state.draft = state.saved;
				state.editing = false;
				renderAll();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('读取状态失败'), 'err');
			});
		}

		refresh();
		/* ---------- LuCI 框架底部按钮：保存 / 保存&应用 / 复位 ---------- */
		this.handleSave = function () {
			/* 不弹横幅：右上角「未保存的配置: N」就是保存成功的反馈 */
			return stageRouter().catch(function (e) {
				if (e && e.silent) return;
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		};
		this.handleSaveApply = function () {
			return handleApply();
		};
		this.handleReset = function () {
			return CPD.revertStaged().then(function () {
				refresh();
			}, function (e) {
				CPD.notify(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	},

});
