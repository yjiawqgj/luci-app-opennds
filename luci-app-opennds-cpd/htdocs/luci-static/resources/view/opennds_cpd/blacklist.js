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
			macs: [],      /* 小写 */
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
						'class': 'btn',
						'click': function () { fileInput = document.getElementById('cpd-bl-file'); pickFile(); }
					}, _('上传')),
					E('button', { 'class': 'btn', 'click': showUploaded }, _('已上传'))
				])
			]));
			body.appendChild(sec2);

			refreshSilently();
		}

		function refreshSilently() {
			/* 上传/删除后局部刷新数据，不整页重绘（保住编辑态与下拉选择） */
			CPD.api('blacklist', 'status').then(function (j) {
				if (!j.ok) return;
				state.macs = j.macs || [];
				state.portal = j.portal || '';
				state.portals = j.portals || [];
				renderMacs();
				renderPortal();
			}).catch(function () {});
		}

		/* ---------- MAC 名单 ---------- */
		function renderMacs() {
			macPanel.innerHTML = '';
			macPanel.appendChild(E('div', { 'style': 'margin-top:12px' }, [
				E('button', { 'class': 'btn', 'click': startAdd }, _('添加'))
			]));
			if (state.editing) {
				var ta = E('textarea', {
					'class': 'cpd-ta', 'rows': '3', 'spellcheck': 'false',
					'placeholder': _('例如 D8:3A:DD:41:6F:22')
				});
				ta.value = state.macs.map(function (m) { return m.toUpperCase(); }).join('\n');
				macPanel.appendChild(E('div', { 'class': 'cpd-field' }, [
					ta,
					E('div', { 'class': 'cpd-actions' }, [
						E('button', { 'class': 'btn', 'click': cancelEdit }, _('取消')),
						E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function () { applyMacs(ta); } }, _('应用'))
					])
				]));
				window.setTimeout(function () {
					ta.focus();
					try { ta.select(); } catch (e) {}
				}, 0);
			} else {
				macPanel.appendChild(E('div', {}, [
					E('div', { 'class': 'cpd-viewer-label' }, _('黑名单')),
					E('div', { 'class': 'cpd-viewer' },
						E('pre', { 'aria-live': 'polite' },
							state.macs.map(function (m) { return m.toUpperCase(); }).join('\n')))
				]));
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

		function applyMacs(ta) {
			var lines = (ta ? ta.value : '').replace(/\r\n/g, '\n').split('\n')
				.map(function (l) { return l.trim(); })
				.filter(function (l) { return l; });
			if (!lines.length) {
				toast(_('请先填写客户端 MAC 地址'), 'warn');
				if (ta) ta.focus();
				return;
			}
			var seen = {}, news = [];
			for (var i = 0; i < lines.length; i++) {
				if (!macOk(lines[i])) {
					toast(_('非法MAC: %s').format(lines[i]), 'err');
					return;
				}
				var lm = lines[i].toLowerCase();
				if (!seen[lm]) { seen[lm] = 1; news.push(lm); }
			}
			var cur = {}, adds = [], rems = [];
			state.macs.forEach(function (m) { cur[m] = 1; });
			news.forEach(function (m) { if (!cur[m]) adds.push(m); });
			state.macs.forEach(function (m) { if (!seen[m]) rems.push(m); });
			var args = [];
			if (adds.length) args.push('add=' + adds.join(','));
			if (rems.length) args.push('remove=' + rems.join(','));
			if (!args.length) {
				state.editing = false;
				renderMacs();
				toast(_('已应用黑名单内容'), 'ok');
				return;
			}
			CPD.api('blacklist', 'save_macs', args).then(function (j) {
				if (j.error === 'busy') { toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
				if (!j.ok) { toast(j.error || _('保存失败'), 'err'); return; }
				state.editing = false;
				toast(_('已应用黑名单内容'), 'ok');
				refreshSilently();
			}).catch(function (e) {
				toast((e && e.error) || _('保存失败'), 'err');
			});
		}

		/* ---------- 门户 ---------- */
		function renderPortal() {
			portalBox.innerHTML = '';
			var sel = E('select', { 'class': 'cpd-input', 'style': 'max-width:320px' }, [
				E('option', { value: 'default' }, _('默认门户'))
			].concat(state.portals.map(function (p) {
				return E('option', { value: p.name }, p.name);
			})));
			sel.value = state.portal || 'default';
			if (sel.value !== (state.portal || 'default')) sel.value = 'default';
			portalBox.appendChild(E('div', { 'class': 'cpd-field' }, [
				E('label', {}, _('门户选择')),
				sel,
				E('div', { 'class': 'cpd-actions', 'style': 'margin-top:8px' }, [
					E('button', {
						'class': 'cbi-button cbi-button-positive',
						'click': function () {
							CPD.api('blacklist', 'save_portal', ['portal=' + sel.value])
								.then(function (j) {
									if (j.error === 'busy') { toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
									if (!j.ok) { toast(j.error || _('应用失败'), 'err'); return; }
									toast(_('门户已应用：%s').format(sel.value === 'default' ? _('默认门户') : sel.value), 'ok');
									state.portal = (sel.value === 'default') ? '' : sel.value;
								}).catch(function (e) {
									toast((e && e.error) || _('应用失败'), 'err');
								});
						}
					}, _('应用'))
				])
			]));
		}

		function pickFile() {
			var input = fileInput || document.getElementById('cpd-bl-file');
			input.value = '';
			input.onchange = function () {
				var f = input.files && input.files[0];
				if (!f) return;
				var name = f.name;
				if (!/\.sh$/i.test(name) || name.toLowerCase() === 'default.sh') {
					toast(_('只支持上传后缀为 .sh 的脚本，且不能命名为 default.sh'), 'warn');
					return;
				}
				if (state.portals.some(function (p) { return p.name === name; })) {
					toast(_('已存在同名脚本，请改名后再上传'), 'warn');
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
						toast(_('已上传脚本：%s').format(name), 'ok');
						refreshSilently();
					}).catch(function (e) {
						toast((e && e.error) || _('上传失败'), 'err');
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
							'style': 'padding:2px 10px',
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

		refreshSilently();
		return body;
	}
});
