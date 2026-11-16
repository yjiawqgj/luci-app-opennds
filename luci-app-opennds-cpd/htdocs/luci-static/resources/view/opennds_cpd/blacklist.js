/*
 * 客户端黑名单 · openNDS CPD（LuCI view）
 * 照《客户端黑名单.md》：MAC 名单编辑器（save_macs 差量增删）+ 门户选择/上传/删除；
 * toast 用底部居中深色胶囊（本页专用）。
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
			macs: [],      /* 已保存（配置里的）小写 MAC */
			portal: '',    /* 空串 = 默认门户 */
			portals: [],   /* [{name, kind}] */
			editing: false
		};
		var body = E('div', { 'class': 'cpd-page' });
		var macPanel, portalBox, fileInput;

		function toast(msg, kind) {
			CPD.toastCenter(msg, kind);
		}

		function macOk(s) {
			return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(s);
		}

		/* ---------- 渲染 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('客户端黑名单'), 'openNDS',
				_('加入名单的客户端将被永久拒绝认证，无法再打开门户页面。')));

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
				E('div', { 'style': 'margin-top:10px;display:flex;gap:10px' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function () { fileInput = document.getElementById('cpd-bl-file'); pickFile(); }
					}, _('上传')),
					E('button', { 'class': 'cbi-button', 'click': showUploaded }, _('已上传'))
				])
			]));
			body.appendChild(sec2);

			refreshSilently();
		}

		function refreshSilently() {
			/* 上传/删除后局部刷新数据，不整页重绘（保住编辑态与下拉选择） */
			return CPD.api('blacklist', 'status').then(function (j) {
				if (!j.ok) return;
				state.macs = j.macs || [];
				state.portal = j.portal || '';
				state.portals = j.portals || [];
				if (!state.editing) renderMacs();
				renderPortal();
			}).catch(function () {});
		}

		/* ---------- MAC 名单 ---------- */
		function renderMacs() {
			macPanel.innerHTML = '';
			macPanel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', { 'class': 'cbi-button', 'click': startAdd }, _('编辑'))
			]));
			if (state.editing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'rows': '5', 'spellcheck': 'false',
					'placeholder': _('每行一个 MAC，例如 D8:3A:DD:41:6F:22')
				});
				ta.value = state.macs.map(function (m) { return m.toUpperCase(); }).join('\n');
				macPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'cbi-button', 'click': cancelEdit }, _('取消')),
						E('button', { 'class': 'cbi-button', 'click': function () { saveMacs(ta); } }, _('保存')),
						E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function () { saveMacs(ta, true); } }, _('保存并应用'))
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
			if (!lines.length) return { error: _('请先填写客户端 MAC 地址') };
			var seen = {}, out = [];
			for (var i = 0; i < lines.length; i++) {
				if (!macOk(lines[i])) return { error: _('非法MAC: %s').format(lines[i]) };
				var lm = lines[i].toLowerCase();
				if (!seen[lm]) { seen[lm] = 1; out.push(lm); }
			}
			return { list: out };
		}

		function sameList(a, b) {
			if (a.length !== b.length) return false;
			for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
			return true;
		}

		/* 保存 = 写 uci 暂存（顶部「未保存的配置」出现，复位可还原），不生效 */
		function stageMacs(list) {
			return CPD.stageUci('zone_blacklist', 'main', 'mac', 'list', list);
		}

		function saveMacs(ta, andApply) {
			var p = parseMacs(ta);
			if (p.error) { toast(p.error, 'err'); if (ta) ta.focus(); return Promise.resolve(); }
			var unchanged = sameList(p.list, state.macs);
			return (unchanged ? Promise.resolve() : stageMacs(p.list)).then(function () {
				state.macs = p.list;
				state.editing = false;
				renderMacs();
				if (andApply) return applyNow();
				CPD.toast(unchanged ? _('配置未变化') : _('已保存（尚未生效，请点击应用）'), 'ok');
			}, function (e) {
				toast(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		/* 应用 = 提交 zone_blacklist 增量 + 运行时同步 + 重启 */
		function applyNow() {
			return CPD.apiConfirmable('blacklist', 'apply').then(function (j) {
				if (j.error === 'busy') { toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (!j.ok) { toast(j.error || _('应用失败'), 'err'); return; }
				CPD.notifyChanges();
				toast(_('黑名单已应用'), 'ok');
				return refreshSilently();
			}).catch(function (e) {
				toast(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		/* ---------- 门户 ---------- */
		/* 下拉最长 10 个字符，全名放 title 悬停可见 */
		function shortName(n) {
			n = String(n || '');
			return n.length > 10 ? n.slice(0, 10) + '…' : n;
		}

		function renderPortal() {
			portalBox.innerHTML = '';
			var sel = E('select', {
				'class': 'cpd-input',
				'style': 'max-width:320px;min-width:190px;height:36px;padding:0 8px;line-height:34px'
			}, [
				E('option', { value: 'default', 'title': _('默认门户') }, _('默认门户'))
			].concat(state.portals.map(function (p) {
				return E('option', { value: p.name, 'title': p.name }, shortName(p.name));
			})));
			sel.value = state.portal || 'default';
			if (sel.value !== (state.portal || 'default')) sel.value = 'default';
			/* 门户切换也走暂存：点「应用/保存并应用」才写配置 */
			sel.addEventListener('change', function () {
				var v = this.value;
				state.portal = (v === 'default') ? '' : v;
				CPD.stageUci('zone_blacklist', 'main', 'portal', 'opt',
					v === 'default' ? null : v).then(function () {
					toast(v === 'default' ? _('门户已改为默认（尚未生效，请点击应用）')
						: _('门户已改为 %s（尚未生效，请点击应用）').format(v), 'ok');
				}, function (e) {
					toast(CPD.errText(e, _('保存失败')), 'err');
					renderPortal();
				});
			});
			portalBox.appendChild(E('div', { 'class': 'cpd-field' }, [
				E('label', {}, _('门户选择')),
				sel,
				E('span', {
					'style': 'font-size:11.5px;color:#7a8794;' +
						'font-family:ui-monospace,Consolas,monospace'
				}, _('门户目录：/usr/lib/opennds/cpd/blacklist/'))
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
					toast(_('只支持上传后缀为 .sh 的脚本'), 'warn');
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
						toast(_('已上传 %s，点击应用后生效').format(name), 'ok');
						/* 上传即选中（暂存，应用时写入） */
						state.portal = name;
						return CPD.stageUci('zone_blacklist', 'main', 'portal', 'opt', name);
					}).then(function () {
						refreshSilently();
					}).catch(function (e) {
						toast(CPD.errText(e, _('上传失败')), 'err');
					});
				};
				reader.readAsText(f);
			};
			input.click();
		}

		function showUploaded() {
			var list = state.portals.length
				? state.portals.map(function (p) {
					return E('div', { 'style': 'display:flex;align-items:center;justify-content:space-between;gap:8px;padding:6px 0;border-bottom:1px solid #e9edf0' }, [
						E('span', {
							'style': 'font-family:ui-monospace,Consolas,monospace;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap'
						}, p.name + (p.kind === 'dir' ? '/' : '')),
						E('button', {
							'class': 'cbi-button cbi-button-negative',
							'click': function () { askDelete(p); }
						}, _('删除'))
					]);
				})
				: [E('p', { 'class': 'cpd-note' }, _('暂无已上传脚本'))];
			ui.showModal(_('已上传脚本'), E('div', { 'style': 'max-width:460px' }, list));
		}

		function askDelete(p) {
			CPD.confirm(
				_('删除脚本'),
				_('确定删除脚本「%s」？删除后将从已上传列表中移除。').format(p.name),
				_('删除'), true,
				function () {
					CPD.api('blacklist', 'portal_delete', ['name=' + p.name]).then(function (j) {
						if (j.error === 'busy') { toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
						if (!j.ok) { toast(j.error || _('删除失败'), 'err'); return; }
						ui.hideModal();
						toast(_('已删除脚本：%s').format(p.name), 'ok');
						refreshSilently();
					}).catch(function (e) {
						toast((e && e.error) || _('删除失败'), 'err');
					});
				}
			);
		}

		renderAll();
		refreshSilently();

		/* ---------- LuCI 框架底部按钮：保存 = 暂存，保存并应用 = 提交 ---------- */
		this.handleSave = function () {
			if (state.editing) return saveMacs(document.querySelector('.cpd-ta'), false);
			return stageMacs(state.macs).then(function () {
				CPD.toast(_('已保存（尚未生效，请点击应用）'), 'ok');
			}, function (e) {
				toast(CPD.errText(e, _('保存失败')), 'err');
			});
		};
		this.handleSaveApply = function () {
			if (state.editing) return saveMacs(document.querySelector('.cpd-ta'), true);
			return stageMacs(state.macs).then(function () {
				return applyNow();
			}, function (e) {
				toast(CPD.errText(e, _('保存失败')), 'err');
			});
		};
		this.handleReset = function () {
			return CPD.revertStaged(['zone_blacklist']).then(function () {
				state.editing = false;
				return refreshSilently();
			}, function (e) {
				toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
