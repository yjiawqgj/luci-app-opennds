/*
 * 客户端黑名单 · openNDS CPD（LuCI view）
 * 名单 = /etc/config/opennds 的 blockedmac。openNDS 9.4 起已废弃
 * macmechanism/blockedmaclist，主进程不再读它，真正的拦截由本插件的分发脚本
 * theme_zone_detect.sh 做：命中名单的客户端不认证、只出示黑名单门户。
 * 门户库 = /usr/lib/opennds/cpd/blacklist/，选中项存 zone_detect.main.portal_blacklist。
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
			portal: '',      /* 空串 = 内置默认门户 */
			portals: [],     /* [{name,kind}] */
			dir: '/usr/lib/opennds/cpd/blacklist/',
			editing: false,
			ta: null         /* 展开中的编辑框，保存时以它为准 */
		};
		var body = E('div', { 'class': 'cpd-page' });
		var macPanel, portalBox, fileInput;

		function macOk(s) {
			return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(s);
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('客户端黑名单'), 'openNDS',
				_('加入名单的客户端将被拒绝认证，只能看到为本页配置的门户页面。')));

			var sec1 = CPD.section(_('客户端黑名单'), 'Blacklist');
			macPanel = E('div', {});
			sec1.appendChild(macPanel);
			renderMacs();
			body.appendChild(sec1);

			var sec2 = CPD.section(_('门户'), 'Portal');
			portalBox = E('div', {});
			sec2.appendChild(portalBox);
			renderPortal();
			sec2.appendChild(E('div', {}, [
				E('input', { 'type': 'file', 'accept': '.sh', 'id': 'cpd-bl-file', 'style': 'display:none' }),
				E('div', { 'style': 'margin-top:10px;display:flex;gap:10px;flex-wrap:wrap' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function () { fileInput = document.getElementById('cpd-bl-file'); pickFile(); }
					}, _('上传')),
					E('button', { 'class': 'cbi-button', 'click': showUploaded }, _('已上传'))
				])
			]));
			body.appendChild(sec2);
		}

		function refreshSilently() {
			return CPD.api('blacklist', 'status').then(function (j) {
				if (!j.ok) return;
				/* 名单里的空值/脏数据不显示 */
				state.macs = (j.macs || []).filter(function (m) { return macOk(m); });
				state.mechanism = j.mechanism || '';
				state.portal = j.portal || '';
				state.portals = j.portals || [];
				if (j.dir) state.dir = j.dir.replace(/\/?$/, '/');
				if (!state.editing) renderMacs();
				renderPortal();
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
		 * 名单进 opennds.blockedmac（拦截由插件的分发脚本执行，openNDS 9.4 起
		 * 已废弃 macmechanism/blockedmaclist，主进程不再读这两个选项）；
		 * 门户选中项进 zone_detect.main.portal_blacklist。 */
		function stageMacs(list) {
			return CPD.stageUci('opennds', '@opennds[0]', 'blockedmac', 'list', list)
				.then(function () {
					return CPD.stageUci('zone_detect', 'main', 'portal_blacklist', 'opt',
						state.portal || null);
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

		/* ---------- 门户 ---------- */
		/* 下拉最长 10 个字符，全名放 title 悬停可见 */
		function shortName(n) {
			n = String(n || '');
			return n.length > 10 ? n.slice(0, 10) + '…' : n;
		}

		function renderPortal() {
			portalBox.innerHTML = '';
			var opts = [E('option', { value: 'default', 'title': _('内置默认门户') }, _('默认门户'))];
			state.portals.forEach(function (p) {
				opts.push(E('option', { value: p.name, 'title': p.name }, shortName(p.name)));
			});
			var sel = E('select', {
				'class': 'cpd-input',
				'style': 'max-width:320px;min-width:190px;height:36px;padding:0 8px;line-height:34px'
			}, opts);
			sel.value = state.portal || 'default';
			if (sel.value !== (state.portal || 'default')) sel.value = 'default';
			/* 门户切换只改本页状态，配置由底部 openwrt「保存 / 保存并应用」写入 */
			sel.addEventListener('change', function () {
				var v = this.value;
				state.portal = (v === 'default') ? '' : v;
			});
			portalBox.appendChild(E('div', { 'class': 'cpd-field' }, [
				E('label', {}, _('门户选择')),
				sel
			]));
		}

		function pickFile() {
			var input = fileInput || document.getElementById('cpd-bl-file');
			input.value = '';
			input.onchange = function () {
				var f = input.files && input.files[0];
				if (!f) return;
				var name = f.name;
				if (!/\.sh$/i.test(name)) {
					CPD.notify(_('只支持上传后缀为 .sh 的脚本'), 'warn');
					return;
				}
				if (name === 'default.sh') {
					CPD.notify(_('不能上传名为 default.sh 的脚本，兜底门户就是它本身'), 'warn');
					return;
				}
				/* 同名挡在门口：本页不做改名映射，覆盖会让用户以为多了一个门户 */
				var dup = state.portals.some(function (p) { return p.name === name; });
				if (dup) {
					CPD.notify(_('已存在同名脚本，请改名后再上传'), 'warn');
					return;
				}
				var reader = new FileReader();
				reader.onload = function () {
					var id = 't' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
					CPD.api('blacklist', 'upload_begin', [id]).then(function (j) {
						if (!j.ok) throw { error: j.error || '上传失败' };
						return fs.write('/tmp/zone_up/' + id + '/' + name, String(reader.result));
					}).then(function () {
						return CPD.api('blacklist', 'upload_store', [id, name]);
					}).then(function (j) {
						if (!j.ok) throw { error: j.error || '上传失败' };
						/* 先刷新门户列表，再把新脚本设为选中（refreshSilently 会
						 * 按配置回填 state.portal，先设会被它覆盖掉） */
						return refreshSilently();
					}).then(function () {
						state.portal = name;
						renderPortal();
						CPD.notify(_('已上传脚本：%s，并在门户选择中启用').format(name), 'ok');
					}).catch(function (e) {
						CPD.notify(CPD.errText(e, _('上传失败')), 'err');
					});
				};
				reader.readAsText(f);
			};
			input.click();
		}

		function showUploaded() {
			var list = state.portals.length
				? state.portals.map(function (p) {
					return E('div', {
						'style': 'display:flex;align-items:center;justify-content:space-between;' +
							'gap:8px;padding:6px 0;border-bottom:1px solid #e9edf0'
					}, [
						E('span', {
							'style': 'font-family:ui-monospace,Consolas,monospace;font-size:13px;' +
								'overflow:hidden;text-overflow:ellipsis;white-space:nowrap'
						}, p.name + (p.kind === 'dir' ? '/' : '')),
						E('button', {
							'class': 'cbi-button cbi-button-negative',
							'click': function () { askDelete(p); }
						}, _('删除'))
					]);
				})
				: [E('p', { 'class': 'cpd-note' }, _('暂无已上传脚本'))];
			CPD.modal(_('已上传脚本'), E('div', { 'style': 'max-width:460px' }, list));
		}

		function askDelete(p) {
			CPD.confirm(
				_('删除脚本'),
				_('确定删除脚本「%s」？删除后将从已上传列表中移除。').format(p.name),
				_('删除'), true,
				function () {
					CPD.api('blacklist', 'portal_delete', ['name=' + p.name]).then(function (j) {
						if (!j.ok) { CPD.notify(j.error || _('删除失败'), 'err'); return; }
						ui.hideModal();
						CPD.notify(_('已删除脚本：%s').format(p.name), 'ok');
						if (state.portal === p.name) state.portal = '';
						return refreshSilently();
					}).catch(function (e) {
						CPD.notify(CPD.errText(e, _('删除失败')), 'err');
					});
				}
			);
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
