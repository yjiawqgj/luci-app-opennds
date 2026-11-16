/*
 * 网络区域识别 · openNDS CPD（LuCI view）
 * 照《区域识别.md》：区域下拉（全局/区域）+ 默认模式面板 + 无线/有线区域卡片
 * （上传 .sh 文件/文件夹、已上传列表、认证门户下拉、面板级保存/应用）+ 未匹配区块。
 * 「保存」只写 zone_detect 缓存；「应用」才写 openNDS 配置、改名门户并重启。
 */
'use strict';
'require view';
'require ui';
'require dom';
'require fs';

var CPD = null;

var CSS = '\
.zd-scope-row{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-top:14px}\
.zd-scope-label{font-size:12.5px;color:#657585;flex:none;min-width:32px}\
.zd-sel{font-family:inherit;font-size:13.5px;color:#222a31;width:100%;max-width:300px;height:38px;padding:0 34px 0 11px;background:#fff;border:1px solid #d7dde3;border-radius:6px;cursor:pointer}\
.zd-sel:focus{outline:none;border-color:#2274a5;box-shadow:0 0 0 2px #e7f1f8}\
.zd-mode-state{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:12px;font-size:11.5px;color:#9aa6b2}\
.zd-ms-v{color:#222a31}\
.zd-ms-v.on{color:#2e9468}\
.zd-ms-dirty{color:#b57d17}\
.zd-state-line{font-size:11.5px;color:#9aa6b2;margin-top:8px;line-height:1.6;max-width:620px}\
.zd-empty-hint{font-size:12.5px;color:#9aa6b2;margin-top:16px;line-height:1.6}\
.zd-grid3{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px;margin-top:14px}\
.zd-grid1{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px;margin-top:14px}\
.zd-card{font-family:inherit;text-align:left;background:#fff;border:1px solid #d7dde3;border-radius:8px;padding:11px 13px;cursor:pointer;min-width:0;color:#222a31;display:flex;flex-direction:column;justify-content:center;gap:5px;min-height:62px;transition:border-color .12s,background .12s}\
.zd-panel{margin-top:28px;padding-top:20px;border-top:1px solid #e9edf0}\
.zd-card:hover{border-color:#b9c6d1;background:#fafbfc}\
.zd-card.selected{border-color:#2274a5;background:#e7f1f8}\
.zd-card.is-off{background:#fafbfc}\
.zd-sec-desc{font-size:12px;color:#657585;margin-top:5px;line-height:1.6;max-width:760px}\
.zd-sec-desc.mt{margin-top:12px}\
.zd-wc-top{display:flex;align-items:center;justify-content:space-between;gap:8px}\
.zd-wc-ssid{font-size:15px;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}\
.zd-wc-sub{display:block;font-size:12px;color:#9aa6b2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.zd-wc-sub.weak{color:#b3bcc5}\
.zd-wc-ip{display:block;font-size:12px;color:#657585;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.zd-pill{font-size:11px;font-weight:500;line-height:1.5;padding:1px 8px;border-radius:999px;border:1px solid;white-space:nowrap;flex:none}\
.zd-pill.on{color:#2e7d5b;border-color:#bfe0cf;background:#eef8f2}\
.zd-pill.off{color:#7c8894;border-color:#dfe5ea;background:#f4f7f9}\
.zd-tools{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:12px}\
.zd-tool-meta{font-size:11.5px;color:#9aa6b2}\
.zd-row{display:flex;gap:12px;align-items:flex-start;flex-wrap:wrap;margin-top:14px}\
.zd-row-label{width:64px;flex:none;font-size:12.5px;color:#657585;padding-top:9px}\
.zd-row-ctrl{flex:1;min-width:0}\
.zd-save-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:24px;padding-top:16px;border-top:1px solid #e9edf0}\
.zd-save-state{font-size:11.5px;color:#9aa6b2;margin-left:4px}\
.zd-save-state.dirty{color:#b57d17}\
.zd-save-state.ok{color:#2e9468}\
.zd-mask{position:fixed;inset:0;z-index:700;background:rgba(24,34,44,.42);display:none;align-items:center;justify-content:center;padding:20px}\
.zd-mask.on{display:flex}\
.zd-modal{background:#fff;border-radius:10px;box-shadow:0 18px 48px rgba(20,30,40,.22);width:min(480px,100%);max-height:min(78vh,560px);display:flex;flex-direction:column;overflow:hidden}\
.zd-modal-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:13px 18px;border-bottom:1px solid #e9edf0;flex:none}\
.zd-modal-head h3{font-size:14.5px;font-weight:650;margin:0}\
.zd-modal-body{padding:8px 18px 14px;overflow:auto;flex:1 1 auto}\
.zd-modal-foot{display:flex;align-items:center;justify-content:flex-end;gap:10px;padding:12px 18px;border-top:1px solid #e9edf0;background:#fbfcfd;flex:none}\
.zd-modal-foot .zd-tool-meta{margin-right:auto}\
.zd-script-row{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:10px 0;border-bottom:1px solid #e9edf0}\
.zd-script-row:last-child{border-bottom:0}\
.zd-script-name{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:12.5px;color:#222a31;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}\
.zd-mono{font-family:ui-monospace,Consolas,"Courier New",monospace}\
@media (max-width:640px){.zd-grid3{grid-template-columns:1fr}.zd-grid1{max-width:100%}}\
';

function ensureZdStyle() {
	if (document.getElementById('zd-style')) return;
	var st = document.createElement('style');
	st.id = 'zd-style';
	st.textContent = CSS;
	document.head.appendChild(st);
}

function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m];
	});
}

function nameBytes(s) {
	return unescape(encodeURIComponent(String(s == null ? '' : s))).length;
}

/* 与后端 zone_name_ok / name_ok 口径一致的客户端预检 */
function zoneNameOk(n) {
	if (!n || n === '.' || n === '..') return false;
	if (/[\/\\|]/.test(n)) return false;
	if (/[\x00-\x1f]/.test(n)) return false;
	return true;
}

function fileNameOk(n) {
	if (!zoneNameOk(n)) return false;
	if (n.charAt(0) === '.') return false;
	if (n !== n.replace(/^\s+|\s+$/g, '')) return false; /* 首尾空格不允许 */
	return true;
}

function genId() {
	return 'z' + Date.now().toString(36) +
		Math.floor(Math.random() * 1679616).toString(36) +
		Math.floor(Math.random() * 1679616).toString(36);
}

function readText(f) {
	return new Promise(function (resolve, reject) {
		var r = new FileReader();
		r.onload = function () { resolve(String(r.result)); };
		r.onerror = function () { reject({ error: _('读取文件失败') }); };
		r.readAsText(f);
	});
}

return view.extend({
	load: function () {
		return L.require('opennds_cpd.common').then(function (m) { CPD = m; });
	},

	render: function () {
		ensureZdStyle();
		CPD.style();

		var state = {
			scopeSel: 'global',
			loginOptionEnabled: '',
			scope: '',
			engaged: 1, busy: 0,
			wireless: [],           /* 后端卡片（按 section） */
			wired: null,
			zoneDraft: {},          /* ssid → 存储名（''=默认） */
			wiredDraft: null,       /* null=尚未初始化 */
			wiredSaved: null,       /* 已保存（null=未保存过） */
			uploaded: {},           /* 'type|zone' → items */
			active: null,
			wiredActive: false,
			snapshot: null,
			inited: false
		};

		var body = E('div', { 'class': 'cpd-page' });

		/* ---------- 提示条（仅 busy；「尚未接管门户」横幅已按用户要求移除） ---------- */
		var warnbar = E('div', { 'class': 'cpd-warnbar', 'style': 'display:none' }, '');
		function renderWarnbar() {
			if (state.busy) {
				warnbar.textContent = _('等待上一步完成，请稍候重试');
				warnbar.style.display = '';
			} else {
				warnbar.style.display = 'none';
			}
		}

		/* ---------- 数据 ---------- */
		function upKey(type, zone) { return type + '|' + zone; }

		function loadUploaded(type, zone) {
			return CPD.api('zone', 'uploaded', [type, zone]).then(function (j) {
				state.uploaded[upKey(type, zone)] = (j && j.ok) ? (j.items || []) : [];
			}, function () {
				state.uploaded[upKey(type, zone)] = [];
			});
		}

		function loadStatus() {
			return CPD.api('zone', 'status').then(function (j) {
				if (!j || !j.ok) throw { error: (j && j.error) || _('获取状态失败') };
				state.loginOptionEnabled = j.loginOptionEnabled || '';
				state.scope = j.scope || '';
				state.engaged = j.engaged;
				state.busy = j.busy;
				state.wireless = j.wireless || [];
				state.wired = j.wired || null;
				unmatchedCount.textContent =
					_('共 %s 个未匹配文件').format(String(j.unmatched || 0));
				renderWarnbar();
				var jobs = [];
				state.wireless.forEach(function (c) {
					if (zoneNameOk(c.ssid)) jobs.push(loadUploaded('wireless', c.ssid));
				});
				if (state.wired && state.wired.iface && zoneNameOk(state.wired.iface)) {
					jobs.push(loadUploaded('wired', state.wired.iface));
					state.wiredSaved = (state.wired.saved === undefined) ? null : state.wired.saved;
				} else {
					state.wiredSaved = null;
				}
				return Promise.all(jobs);
			}).then(function () {
				initDrafts();
				if (!state.inited) {
					/* 初值：缓存优先，无缓存按实际生效模式（§1） */
					if (state.scope === 'global' || state.scope === 'zone') {
						state.scopeSel = state.scope;
					} else {
						state.scopeSel = (state.loginOptionEnabled === '3') ? 'zone' : 'global';
					}
					state.snapshot = uiSnapshot();
					state.inited = true;
				}
				renderAll();
			}, function (e) {
				CPD.toast((e && e.error) || _('获取状态失败'), 'err');
			});
		}

		function initDrafts() {
			state.wireless.forEach(function (c) {
				if (!(c.ssid in state.zoneDraft)) {
					state.zoneDraft[c.ssid] = (c.saved !== null && c.saved !== undefined) ?
						c.saved : (c.current || '');
				}
			});
			if (state.wired && state.wiredDraft === null) {
				state.wiredDraft = (state.wired.saved !== null && state.wired.saved !== undefined) ?
					state.wired.saved : (state.wired.current || '');
			}
		}

		/* ---------- 快照与脏判断 ---------- */
		function uiSnapshot() {
			var ssids = [];
			state.wireless.forEach(function (c) {
				if (ssids.indexOf(c.ssid) < 0) ssids.push(c.ssid);
			});
			return {
				scope: state.scopeSel,
				wireless: ssids.map(function (s) {
					return s + '|' + (state.zoneDraft[s] || '');
				}),
				wired: ((state.wired && state.wired.iface) || '') + '|' + (state.wiredDraft || '')
			};
		}

		function overallDirty() {
			if (!state.snapshot) return false;
			return JSON.stringify(uiSnapshot()) !== JSON.stringify(state.snapshot);
		}

		function uniqueSsids() {
			var out = [];
			state.wireless.forEach(function (c) {
				if (out.indexOf(c.ssid) < 0) out.push(c.ssid);
			});
			return out;
		}

		function wirelessHasSaved() {
			return state.wireless.some(function (c) {
				return c.saved !== null && c.saved !== undefined;
			});
		}

		/* ---------- 渲染 ---------- */
		var scopeSel = E('select', { 'class': 'zd-sel', 'id': 'zd-scope' }, [
			E('option', { value: 'global' }, _('全局')),
			E('option', { value: 'zone' }, _('区域'))
		]);
		scopeSel.addEventListener('change', function () {
			state.scopeSel = this.value;
			state.active = null;
			state.wiredActive = false;
			renderAll();
		});

		var effV = E('span', { 'class': 'zd-ms-v' }, '');
		var savedV = E('span', { 'class': 'zd-ms-v' }, '');
		var dirtySpan = E('span', { 'class': 'zd-ms-dirty', 'style': 'display:none' },
			_('有未保存的修改'));

		function modeLabel(m) {
			if (m === 'zone') return _('区域模式');
			if (m === 'default') return _('默认模式');
			return _('尚未配置');
		}

		function renderModeState() {
			var eff = (state.loginOptionEnabled === '3') ? 'zone' :
				(state.loginOptionEnabled === '1') ? 'default' : null;
			effV.textContent = modeLabel(eff);
			effV.className = 'zd-ms-v' + (eff ? ' on' : '');
			savedV.textContent = state.scope ? modeLabel(state.scope) : _('无');
			dirtySpan.style.display = overallDirty() ? '' : 'none';
		}

		/* ---------- 默认模式面板 ---------- */
		var defaultNote = E('p', { 'class': 'zd-sec-desc mt' }, '');
		var defaultHint = E('span', { 'class': 'zd-save-state' }, '');

		function renderDefault() {
			var eff = (state.loginOptionEnabled === '3') ? 'zone' :
				(state.loginOptionEnabled === '1') ? 'default' : null;
			if (eff === 'zone') {
				defaultNote.textContent = _('当前仍在使用区域识别。点击应用后，将停止使用区域配置，统一使用 openNDS 默认认证设置。');
			} else if (eff === 'default') {
				defaultNote.textContent = _('当前使用 openNDS 默认认证设置。再次保存或应用会保留该模式。');
			} else {
				defaultNote.textContent = _('选择默认模式将不再使用网络区域识别，统一使用 openNDS 默认认证设置。');
			}
			if (state.scope === 'global') {
				defaultHint.textContent = _('已保存');
				defaultHint.className = 'zd-save-state ok';
			} else if (!state.scope) {
				defaultHint.textContent = _('尚未保存');
				defaultHint.className = 'zd-save-state';
			} else {
				defaultHint.textContent = _('有未保存的修改');
				defaultHint.className = 'zd-save-state dirty';
			}
		}

		/* 全局模式：openNDS 自带的登录方式，不做区域识别 */
		function handleDefaultSave() {
			return Promise.all([
				CPD.stageUci('opennds', '@opennds[0]', 'login_option_enabled', 'opt', '1'),
				CPD.stageUci('zone_detect', 'main', 'scope', 'opt', 'global')
			]).then(function () {
				state.scope = 'global';
				state.snapshot = uiSnapshot();
				renderAll();
			}, function (e) {
				CPD.toast(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		function handleDefaultApply() {
			return handleDefaultSave().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				if (e && e.error) CPD.toast(e.error, 'err');
			});
		}

		/* ---------- 无线区域 ---------- */
		var wifiGrid = E('div', { 'class': 'zd-grid3' });
		var zoneConfig = E('div', { 'class': 'zd-panel' });
		var zoneSaveRow = E('div', { 'class': 'zd-save-row', 'style': 'display:none' });
		var zoneHint = E('span', { 'class': 'zd-save-state' }, '');
		var fileInput = E('input', { 'type': 'file', 'accept': '.sh', 'multiple': '',
			'style': 'display:none' });
		var dirInput = E('input', { 'type': 'file', 'webkitdirectory': '',
			'style': 'display:none' });

		/* 启用的 Wi-Fi 排在前面，未启用的排最后并带灰色「未启用」标记。
		 * 是否启用完全按 openwrt 无线配置判断（接口 disabled 或所属 radio disabled） */
		function renderWifiCards() {
			var list = state.wireless.slice().sort(function (a, b) {
				return (a.disabled ? 1 : 0) - (b.disabled ? 1 : 0);
			});
			var h = list.map(function (c) {
				var sel = (state.active === c.ssid) ? ' selected' : '';
				var off = c.disabled ? ' is-off' : '';
				var pill = c.disabled
					? '<span class="zd-pill off">' + _('未启用') + '</span>'
					: '<span class="zd-pill on">' + _('已启用') + '</span>';
				/* 接口名用 openNDS 官方识别方式：运行时接口名（phy0-ap0 / wlan0），radio 名只作兜底 */
			var iface = c.runtime || c.device || '—';
				var d = state.zoneDraft[c.ssid] || '';
				var sub2 = d ? '<span class="zd-wc-sub">' +
					esc(_('认证脚本：%s').format(shortName(d))) + '</span>' : '';
				return '<button type="button" class="zd-card' + sel + off +
					'" data-ssid="' + esc(c.ssid) + '" aria-pressed="' +
					(state.active === c.ssid ? 'true' : 'false') + '">' +
					'<span class="zd-wc-top"><span class="zd-wc-ssid">' + esc(c.ssid) + '</span>' +
					pill + '</span>' +
					'<span class="zd-wc-sub weak">' + esc(_('无线接口：%s').format(iface)) + '</span>' +
					sub2 +
					'</button>';
			}).join('');
			if (!h) h = '<p class="cpd-note">' + _('本机没有 Wi-Fi 接口') + '</p>';
			wifiGrid.innerHTML = h;
			wifiGrid.querySelectorAll('[data-ssid]').forEach(function (b) {
				b.addEventListener('click', function () {
					var ssid = b.getAttribute('data-ssid');
					if (!ssid) return;
					state.active = ssid;
					renderAll();
				});
			});
		}

		/* 下拉里最长显示 10 个字符，全名放 title（悬停可见） */
		function shortName(n) {
			n = String(n || '');
			return n.length > 10 ? n.slice(0, 10) + '…' : n;
		}

		function selOptions(type, zone, card) {
			var items = state.uploaded[upKey(type, zone)] || [];
			var opts = [E('option', { value: '', 'title': _('默认') }, _('默认'))];
			var hasCur = false;
			items.forEach(function (it) {
				if (it.name === (card && card.current)) hasCur = true;
				opts.push(E('option', { value: it.name, 'title': it.name },
					shortName(it.name)));
			});
			if (card && card.current && !hasCur) {
				opts.push(E('option', { value: card.current, 'title': card.current },
					shortName(card.current)));
			}
			return opts;
		}

		function wirelessHintInfo() {
			/* 模式已存成「默认」而面板在区域模式下 → 必有未保存改动（§3.1） */
			if (state.scope && state.scope !== 'zone') {
				return { text: _('有未保存的修改'), kind: 'dirty' };
			}
			if (wirelessHasSaved()) {
				var same = uniqueSsids().every(function (s) {
					var card = state.wireless.filter(function (c) { return c.ssid === s; })[0];
					var saved = card ? card.saved : null;
					if (saved === null || saved === undefined) return true;
					return (state.zoneDraft[s] || '') === saved;
				});
				if (!same) return { text: _('有未保存的修改'), kind: 'dirty' };
				return { text: _('已保存'), kind: 'ok' };
			}
			var any = uniqueSsids().some(function (s) { return !!state.zoneDraft[s]; });
			if (any) return { text: _('有未保存的修改'), kind: 'dirty' };
			return null; /* 无可提示内容时不占位显示「尚未保存」 */
		}

		function uploadCtx() {
			if (state.active && !zoneNameOk(state.active)) {
				CPD.toast(_('该 SSID 含非法路径字符，无法建立门户目录，请改用默认门户'), 'warn');
				return null;
			}
			if (state.wiredActive && state.wired && state.wired.iface &&
				!zoneNameOk(state.wired.iface)) {
				CPD.toast(_('该 SSID 含非法路径字符，无法建立门户目录，请改用默认门户'), 'warn');
				return null;
			}
			if (state.active) return { type: 'wireless', zone: state.active };
			if (state.wiredActive && state.wired && state.wired.iface) {
				return { type: 'wired', zone: state.wired.iface };
			}
			return null;
		}

		function renderZoneConfig() {
			zoneConfig.innerHTML = '';
			if (!state.active) {
				zoneSaveRow.style.display = 'none';
				return;
			}
			zoneSaveRow.style.display = '';
			var card = state.wireless.filter(function (c) { return c.ssid === state.active; })[0];
			var items = state.uploaded[upKey('wireless', state.active)] || [];
			var authSel = E('select', { 'class': 'zd-sel' }, selOptions('wireless', state.active, card));
			authSel.value = state.zoneDraft[state.active] || '';
			authSel.addEventListener('change', function () {
				state.zoneDraft[state.active] = this.value;
				renderWifiCards();
				renderHints();
			});
			var parts = [];
			if (card && card.disabled) {
				parts.push(_('该 Wi-Fi 当前为禁用状态，所选脚本会在启用后生效。'));
			}
			var d = state.zoneDraft[state.active] || '';
			parts.push(d ?
				_('已选择 %s，仅对当前选中的 Wi-Fi 生效。').format(d) :
				_('尚未选择脚本，选择结果仅对当前选中的 Wi-Fi 生效。'));

			zoneConfig.appendChild(E('div', { 'class': 'zd-tools' }, [
				E('button', { 'type': 'button', 'class': 'cbi-button',
					'click': function () { fileInput.value = ''; fileInput.click(); } },
					_('上传脚本')),
				E('button', { 'type': 'button', 'class': 'cbi-button',
					'click': function () { dirInput.value = ''; dirInput.click(); } },
					_('上传文件夹')),
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': openScriptsModal },
					_('已上传')),
				E('span', { 'class': 'zd-tool-meta' },
					_('共 %s 个脚本').format(String(items.length)))
			]));
			zoneConfig.appendChild(E('div', { 'class': 'zd-row' }, [
				E('div', { 'class': 'zd-row-label' }, _('认证')),
				E('div', { 'class': 'zd-row-ctrl' }, [
					authSel,
					E('p', { 'class': 'zd-state-line' }, parts.join(' '))
				])
			]));
		}

		function wirelessSave(silent) {
			var jobs = [
				CPD.stageUci('zone_detect', 'main', 'scope', 'opt', 'zone'),
				/* 区域模式真正生效的两个 opennds 键也一起暂存：
				 * 右上角「未保存的配置」里就能直接看到它们，
				 * 由 openwrt 原生 commit 落盘（z_apply 之后再写同样的值，属于幂等） */
				CPD.stageUci('opennds', '@opennds[0]', 'login_option_enabled', 'opt', '3'),
				CPD.stageUci('opennds', '@opennds[0]', 'themespec_path', 'opt',
					'/usr/lib/opennds/theme_zone_detect.sh'),
				CPD.stageUci('zone_detect', 'main', 'wireless', 'list',
					uniqueSsids().map(function (s) {
						return s + '|' + (state.zoneDraft[s] || '');
					}))
			];
			return Promise.all(jobs).then(function () {
				state.scope = 'zone';
				state.snapshot = uiSnapshot();
				renderAll();
				/* 不弹横幅：右上角「未保存的配置: N」就是保存的反馈 */
			}, function (e) {
				CPD.toast(CPD.errText(e, _('保存失败')), 'err');
				throw e; /* 保存失败时中止后续应用 */
			});
		}

		/* ---------- 有线区域 ---------- */
		var wiredGrid = E('div', { 'class': 'zd-grid1' });
		var wiredConfig = E('div', { 'class': 'zd-panel' });
		var wiredSaveRow = E('div', { 'class': 'zd-save-row', 'style': 'display:none' });
		var wiredHint = E('span', { 'class': 'zd-save-state' }, '');

		function renderWiredCards() {
			var w = state.wired;
			var h = '';
			if (w && w.iface) {
				/* 卡片只留接口名 + 底部 IP，不再堆说明文字 */
				h = '<button type="button" class="zd-card' + (state.wiredActive ? ' selected' : '') +
					'" data-wired="1" aria-pressed="' + (state.wiredActive ? 'true' : 'false') + '">' +
					'<span class="zd-wc-top"><span class="zd-wc-ssid zd-mono">' + esc(w.iface) + '</span>' +
					'<span class="zd-pill on">' + _('已启用') + '</span></span>' +
					'<span class="zd-wc-ip zd-mono">' + esc(w.ip || '—') + '</span>' +
					'</button>';
			}
			wiredGrid.innerHTML = h;
			wiredGrid.querySelectorAll('[data-wired]').forEach(function (b) {
				b.addEventListener('click', function () {
					state.wiredActive = true;
					renderAll();
				});
			});
		}

		function wiredHintInfo() {
			if (state.wiredSaved === null || state.wiredSaved === undefined) {
				return state.wiredDraft ?
					{ text: _('有未保存的修改'), kind: 'dirty' } :
					null; /* 无可提示内容时不占位显示「尚未保存」 */
			}
			if ((state.wiredDraft || '') !== state.wiredSaved) {
				return { text: _('有未保存的修改'), kind: 'dirty' };
			}
			return { text: _('已保存'), kind: 'ok' };
		}

		function renderWiredConfig() {
			wiredConfig.innerHTML = '';
			if (!state.wiredActive || !state.wired || !state.wired.iface) {
				wiredConfig.appendChild(E('p', { 'class': 'zd-empty-hint' },
					_('点击上方有线区域卡片，为它选择认证脚本。')));
				wiredSaveRow.style.display = 'none';
				return;
			}
			wiredSaveRow.style.display = '';
			var w = state.wired;
			var items = state.uploaded[upKey('wired', w.iface)] || [];
			var authSel = E('select', { 'class': 'zd-sel' }, selOptions('wired', w.iface, w));
			authSel.value = state.wiredDraft || '';
			authSel.addEventListener('change', function () {
				state.wiredDraft = this.value;
				renderHints();
			});
			wiredConfig.appendChild(E('div', { 'class': 'zd-tools' }, [
				E('button', { 'type': 'button', 'class': 'cbi-button',
					'click': function () { fileInput.value = ''; fileInput.click(); } },
					_('上传脚本')),
				E('button', { 'type': 'button', 'class': 'cbi-button',
					'click': function () { dirInput.value = ''; dirInput.click(); } },
					_('上传文件夹')),
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': openScriptsModal },
					_('已上传')),
				E('span', { 'class': 'zd-tool-meta' },
					_('共 %s 个脚本').format(String(items.length)))
			]));
			wiredConfig.appendChild(E('div', { 'class': 'zd-row' }, [
				E('div', { 'class': 'zd-row-label' }, _('认证')),
				E('div', { 'class': 'zd-row-ctrl' }, [
					authSel,
				E('p', { 'class': 'zd-state-line' },
					state.wiredDraft ?
						_('已选择 %s，仅对有线区域生效。').format(state.wiredDraft) :
						_('尚未选择脚本，选择结果仅对有线区域生效。'))
				])
			]));
		}

		function wiredSave(silent) {
			if (!state.wired || !state.wired.iface) return Promise.resolve();
			return CPD.stageUci('zone_detect', 'main', 'scope', 'opt', 'zone').then(function () {
				/* 与无线面板同理：区域模式的两个 opennds 键一起暂存，diff 里看得见 */
				return Promise.all([
					CPD.stageUci('opennds', '@opennds[0]', 'login_option_enabled', 'opt', '3'),
					CPD.stageUci('opennds', '@opennds[0]', 'themespec_path', 'opt',
						'/usr/lib/opennds/theme_zone_detect.sh')
				]);
			}).then(function () {
				return CPD.stageUci('zone_detect', 'main', 'wired', 'list',
					[state.wired.iface + '|' + (state.wiredDraft || '')]);
			}).then(function () {
				state.scope = 'zone';
				state.snapshot = uiSnapshot();
				renderAll();
				/* 不弹横幅：右上角「未保存的配置: N」就是保存的反馈 */
			}, function (e) {
				CPD.toast(CPD.errText(e, _('保存失败')), 'err');
				throw e; /* 保存失败时中止后续应用 */
			});
		}

		/* ---------- 上传 ---------- */
		function toastRejects(rejects) {
			if (rejects.length) CPD.toast(rejects.join(_('；')), 'warn');
		}

		fileInput.addEventListener('change', function () {
			var ctx = uploadCtx();
			var files = Array.prototype.slice.call(fileInput.files || []);
			fileInput.value = '';
			if (!ctx || !files.length) return;
			var okFiles = [], rejects = [];
			files.forEach(function (f) {
				var name = f.name || '';
				if (!name) return;
				if (!/\.sh$/.test(name)) {
					rejects.push(name + '：' + _('只接受 .sh 门户脚本，或包含 theme.sh 的文件夹'));
				} else if (nameBytes(name) > 31) {
					rejects.push(name + '：' + _('文件名过长（最多 31 个字符）'));
				} else if (!fileNameOk(name)) {
					rejects.push(name + '：' + _('文件名含非法字符，无法上传'));
				} else {
					okFiles.push(f);
				}
			});
			if (!okFiles.length) { toastRejects(rejects); return; }
			var id = genId();
			var names = [];
			var chain = CPD.api('zone', 'upload_begin', [id]).then(function (j) {
				if (!j.ok) throw { error: j.error || 'upload_begin 失败' };
			});
			okFiles.forEach(function (f) {
				chain = chain.then(function () {
					return readText(f).then(function (text) {
						return fs.write('/tmp/zone_up/' + id + '/' + f.name, text);
					}).then(function () {
						return CPD.api('zone', 'upload_store',
							[ctx.type, ctx.zone, id, 'file', f.name]);
					}).then(function (j) {
						if (!j.ok) throw { error: j.error || _('上传失败') };
						names.push(f.name);
					});
				}).catch(function (e) {
					rejects.push(f.name + '：' + CPD.errText(e, _('上传失败')));
				});
			});
			chain.then(function () {
				if (names.length) {
					CPD.toast(_('已上传 %s 个脚本：%s')
						.format(String(names.length), names.join(_('、'))), 'ok');
				}
				toastRejects(rejects);
				loadUploaded(ctx.type, ctx.zone).then(renderAll);
			});
		});

		dirInput.addEventListener('change', function () {
			var ctx = uploadCtx();
			var files = Array.prototype.slice.call(dirInput.files || []);
			dirInput.value = '';
			if (!ctx || !files.length) return;
			/* webkitRelativePath：<文件夹名>/…/文件 */
			var rels = [];
			var folderName = '';
			var hasTheme = false;
			var bad = null;
			files.forEach(function (f) {
				var rp = f.webkitRelativePath || f.name || '';
				var segs = rp.split('/');
				if (!folderName) folderName = segs[0] || '';
				var sub = segs.slice(1).join('/');
				if (!sub) return;
				rels.push({ f: f, sub: sub });
				var base = segs[segs.length - 1];
				if (base === 'theme.sh') hasTheme = true;
				if (/[\x00-\x1f]/.test(sub) || sub.split('/').indexOf('..') >= 0) {
					bad = sub;
				}
			});
			if (!folderName || bad !== null) {
				CPD.toast((bad || folderName) + '：' + _('文件名含非法字符，无法上传'), 'warn');
				return;
			}
			if (!hasTheme) {
				CPD.toast(_('只接受 .sh 门户脚本，或包含 theme.sh 的文件夹'), 'warn');
				return;
			}
			if (nameBytes(folderName) > 31) {
				CPD.toast(folderName + '：' + _('文件名过长（最多 31 个字符）'), 'warn');
				return;
			}
			if (!fileNameOk(folderName)) {
				CPD.toast(folderName + '：' + _('文件名含非法字符，无法上传'), 'warn');
				return;
			}
			var id = genId();
			/* 嵌套子目录去重（不含顶层），按深度排序 */
			var dirs = [];
			rels.forEach(function (r) {
				var segs = r.sub.split('/');
				segs.pop();
				for (var i = 1; i <= segs.length; i++) {
					var d = segs.slice(0, i).join('/');
					if (dirs.indexOf(d) < 0) dirs.push(d);
				}
			});
			dirs.sort(function (a, b) {
				return a.split('/').length - b.split('/').length;
			});
			var chain = CPD.api('zone', 'upload_begin', [id]).then(function (j) {
				if (!j.ok) throw { error: j.error || 'upload_begin 失败' };
				return CPD.api('zone', 'upload_mkdir',
					[ctx.type, ctx.zone, id, folderName]).then(function (j2) {
					if (!j2.ok) throw { error: j2.error || 'upload_mkdir 失败' };
				});
			});
			dirs.forEach(function (d) {
				chain = chain.then(function () {
					return CPD.api('zone', 'upload_mkdir',
						[ctx.type, ctx.zone, id, folderName, d]).then(function (j3) {
						if (!j3.ok) throw { error: j3.error || 'upload_mkdir 失败' };
					});
				});
			});
			rels.forEach(function (r) {
				chain = chain.then(function () {
					return readText(r.f).then(function (text) {
						return fs.write('/tmp/zone_up/' + id + '/' + folderName + '/' + r.sub, text);
					});
				});
			});
			chain.then(function () {
				return CPD.api('zone', 'upload_store',
					[ctx.type, ctx.zone, id, 'dir', folderName]);
			}).then(function (j) {
				if (!j.ok) throw { error: j.error || _('上传失败') };
				CPD.toast(_('已上传 %s 个脚本：%s')
					.format(String(rels.length), rels.map(function (r) {
						return r.sub;
					}).join(_('、'))), 'ok');
				loadUploaded(ctx.type, ctx.zone).then(renderAll);
			}).catch(function (e) {
				CPD.toast(CPD.errText(e, _('上传失败')), 'err');
			});
		});

		/* ---------- 已上传脚本弹层 ---------- */
		var scriptsMask = E('div', { 'class': 'zd-mask' }, E('div', {
			'class': 'zd-modal', 'role': 'dialog', 'aria-modal': 'true'
		}, [
			E('div', { 'class': 'zd-modal-head' }, E('h3', {}, _('已上传脚本'))),
			E('div', { 'class': 'zd-modal-body' }, E('div', { 'id': 'zd-script-rows' })),
			E('div', { 'class': 'zd-modal-foot' }, [
				E('span', { 'class': 'zd-tool-meta', 'id': 'zd-script-total' }, ''),
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': closeScriptsModal },
					_('关闭'))
			])
		]));

		function openScriptsModal() {
			var ctx = uploadCtx();
			if (!ctx) return;
			var box = document.getElementById('zd-script-rows');
			var total = document.getElementById('zd-script-total');
			var items = state.uploaded[upKey(ctx.type, ctx.zone)] || [];
			if (!items.length) {
				box.innerHTML = '<p class="zd-empty-hint" style="margin-top:8px">' +
					_('暂无已上传脚本') + '</p>';
			} else {
				box.innerHTML = items.map(function (it) {
					return '<div class="zd-script-row"><span class="zd-script-name">' +
						esc(it.name) + '</span>' +
						'<button type="button" class="cbi-button cbi-button-negative" data-name="' +
						esc(it.name) + '">' +
						_('删除') + '</button></div>';
				}).join('');
				box.querySelectorAll('[data-name]').forEach(function (b) {
					b.addEventListener('click', function () {
						askDelete(ctx, b.getAttribute('data-name'));
					});
				});
			}
			total.textContent = _('共 %s 个脚本').format(String(items.length));
			scriptsMask.classList.add('on');
		}

		function closeScriptsModal() {
			scriptsMask.classList.remove('on');
		}

		scriptsMask.addEventListener('click', function (ev) {
			if (ev.target === scriptsMask) closeScriptsModal();
		});

		function askDelete(ctx, name) {
			CPD.confirm(_('删除脚本'), _('确定删除脚本“%s”吗？删除后，认证下拉框将不再提供该脚本。').format(name),
				_('删除'), true, function () {
					CPD.api('zone', 'upload_delete', [ctx.type, ctx.zone, name]).then(function (j) {
						if (j && j.busy === 1) { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
						if (!j || !j.ok) { CPD.toast((j && j.error) || _('删除失败'), 'err'); return; }
						/* 删除的正是某卡片草稿选中的脚本 → 退回「默认」（§3.4） */
						uniqueSsids().forEach(function (s) {
							if (state.zoneDraft[s] === name) state.zoneDraft[s] = '';
						});
						if (state.wiredDraft === name) state.wiredDraft = '';
						CPD.notify(_('已删除脚本 %s').format(name), 'ok');
						/* 弹窗保持打开并就地刷新列表，让删除结果立刻可见 */
						loadUploaded(ctx.type, ctx.zone).then(function () {
							openScriptsModal();
							loadStatus();
						});
					}, function (e) {
						CPD.toast((e && e.error) || _('删除失败'), 'err');
					});
				});
		}

		/* ---------- 未匹配 ---------- */
		var unmatchedCount = E('span', { 'class': 'zd-tool-meta' }, '');
		var unmatchedMask = E('div', { 'class': 'zd-mask' }, E('div', {
			'class': 'zd-modal', 'role': 'dialog', 'aria-modal': 'true'
		}, [
			E('div', { 'class': 'zd-modal-head' }, E('h3', {}, _('未匹配文件'))),
			E('div', { 'class': 'zd-modal-body' }, E('div', { 'id': 'zd-um-rows' })),
			E('div', { 'class': 'zd-modal-foot' }, [
				E('span', { 'class': 'zd-tool-meta', 'id': 'zd-um-total' }, ''),
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': closeUnmatchedModal },
					_('关闭'))
			])
		]));
		var umItems = [];

		function openUnmatchedModal() {
			CPD.api('zone', 'unmatched_list').then(function (j) {
				umItems = (j && j.ok) ? (j.items || []) : [];
				var box = document.getElementById('zd-um-rows');
				var total = document.getElementById('zd-um-total');
				if (!umItems.length) {
					box.innerHTML = '<p class="zd-empty-hint" style="margin-top:8px">' +
						_('暂无未匹配文件') + '</p>';
				} else {
					box.innerHTML = umItems.map(function (it, i) {
						return '<div class="zd-script-row"><span class="zd-script-name">' +
							esc(it.name) + '</span>' +
							'<button type="button" class="cbi-button cbi-button-negative" data-i="' + i + '">' +
							_('删除') + '</button></div>';
					}).join('');
					box.querySelectorAll('[data-i]').forEach(function (b) {
						b.addEventListener('click', function () {
							var it = umItems[Number(b.getAttribute('data-i'))];
							if (it) askUmDelete(it);
						});
					});
				}
				total.textContent = _('共 %s 个未匹配文件').format(String(umItems.length));
				unmatchedMask.classList.add('on');
			}, function (e) {
				CPD.toast((e && e.error) || _('获取未匹配列表失败'), 'err');
			});
		}

		function closeUnmatchedModal() {
			unmatchedMask.classList.remove('on');
		}

		unmatchedMask.addEventListener('click', function (ev) {
			if (ev.target === unmatchedMask) closeUnmatchedModal();
		});

		function askUmDelete(it) {
			CPD.confirm(_('删除文件'), _('确定删除文件“%s”吗？删除后将不再出现在未匹配列表中。').format(it.name),
				_('删除'), true, function () {
					CPD.api('zone', 'unmatched_delete', [it.type, it.name]).then(function (j) {
						if (j && j.busy === 1) { CPD.toast(_('等待上一步完成，请稍候重试'), 'warn'); return; }
						if (!j || !j.ok) { CPD.toast((j && j.error) || _('删除失败'), 'err'); return; }
						CPD.toast(_('已删除文件 %s').format(it.name), 'ok');
						closeUnmatchedModal();
						loadStatus();
					}, function (e) {
						CPD.toast((e && e.error) || _('删除失败'), 'err');
					});
				});
		}

		document.addEventListener('keydown', function (ev) {
			if (ev.key !== 'Escape') return;
			if (scriptsMask.classList.contains('on')) closeScriptsModal();
			else if (unmatchedMask.classList.contains('on')) closeUnmatchedModal();
		});

		/* ---------- 汇总渲染 ---------- */
		function renderHints() {
			var z = wirelessHintInfo();
			zoneHint.style.display = z ? '' : 'none';
			if (z) {
				zoneHint.textContent = z.text;
				zoneHint.className = 'zd-save-state' + (z.kind ? ' ' + z.kind : '');
			}
			var w = wiredHintInfo();
			wiredHint.style.display = w ? '' : 'none';
			if (w) {
				wiredHint.textContent = w.text;
				wiredHint.className = 'zd-save-state' + (w.kind ? ' ' + w.kind : '');
			}
			renderDefault();
			renderModeState();
		}

		function renderAll() {
			scopeSel.value = state.scopeSel;
			var isZone = (state.scopeSel === 'zone');
			defaultPanel.style.display = isZone ? 'none' : '';
			wirelessPanel.style.display = isZone ? '' : 'none';
			wiredPanel.style.display = isZone ? '' : 'none';
			if (isZone) {
				renderWifiCards();
				renderZoneConfig();
				renderWiredCards();
				renderWiredConfig();
			} else {
				zoneSaveRow.style.display = 'none';
				wiredSaveRow.style.display = 'none';
			}
			renderHints();
		}

		/* ---------- 组装页面 ---------- */
		var defaultPanel = E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [_('默认模式'), E('span', { 'class': 'cpd-en' }, 'Default')]),
			defaultNote,
			E('div', { 'class': 'zd-save-row' }, [defaultHint])
		]);

		zoneSaveRow.appendChild(zoneHint);

		var wirelessPanel = E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [_('无线区域'), E('span', { 'class': 'cpd-en' }, 'Wireless Zones')]),
			E('p', { 'class': 'zd-sec-desc mt' },
				_('以下 Wi-Fi 来自路由器中已创建的无线网络，点击卡片为其配置认证脚本。')),
			wifiGrid,
			fileInput,
			dirInput,
			zoneConfig,
			zoneSaveRow
		]);

		wiredSaveRow.appendChild(wiredHint);

		var wiredPanel = E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [_('有线区域'), E('span', { 'class': 'cpd-en' }, 'Wired Zone')]),
			E('p', { 'class': 'zd-sec-desc mt' },
				_('更改网络接口后，原网络接口配置并不会自动删除，需要到下方未匹配里手动删除；如果未删除，切换回来时将会使用上次配置。')),
			wiredGrid,
			wiredConfig,
			wiredSaveRow
		]);

		var unmatchedPanel = E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [_('未匹配'), E('span', { 'class': 'cpd-en' }, 'Unmatched')]),
			E('p', { 'class': 'zd-sec-desc mt' }, _('以下文件尚未关联到任何区域。')),
			E('div', { 'class': 'zd-tools' }, [
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': openUnmatchedModal }, _('查看')),
				unmatchedCount
			])
		]);

		body.appendChild(CPD.pageHead(
			_('网络区域识别'), 'Network Zone Detection',
			_('选择配置模式，为 Wi-Fi 区域选择认证脚本。')));
		body.appendChild(warnbar);

		body.appendChild(E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [_('区域选择'), E('span', { 'class': 'cpd-en' }, 'Scope')]),
			E('div', { 'class': 'zd-scope-row' }, [
				E('label', { 'class': 'zd-scope-label', 'for': 'zd-scope' }, _('区域')),
				scopeSel
			]),
			E('div', { 'class': 'zd-mode-state' }, [
				E('span', {}, _('当前生效')), effV,
				E('span', { 'aria-hidden': 'true' }, '·'),
				E('span', {}, _('已保存')), savedV,
				dirtySpan
			])
		]));
		body.appendChild(defaultPanel);
		body.appendChild(wirelessPanel);
		body.appendChild(wiredPanel);
		body.appendChild(unmatchedPanel);
		body.appendChild(scriptsMask);
		body.appendChild(unmatchedMask);

		loadStatus();

		/* ---------- LuCI 框架底部按钮：保存 / 保存&应用 / 复位 ---------- */
		this.handleSave = function () {
			if (state.scopeSel !== 'zone') { return handleDefaultSave(); }
			/* 只暂存：右上角出现「未保存的配置」，点开就是原生 diff 弹窗 */
			return Promise.resolve()
				.then(function () { return wirelessSave(true); })
				.then(function () { return wiredSave(true); })
				.catch(function () { /* 失败提示已在内部给出 */ });
		};
		this.handleSaveApply = function () {
			if (state.scopeSel !== 'zone') { return handleDefaultApply(); }
			return Promise.resolve()
				.then(function () { return wirelessSave(true); })
				.then(function () { return wiredSave(true); })
				.then(function () { return CPD.applyStaged(); })
				.catch(function (e) {
					if (e && e.error) CPD.toast(e.error, 'err');
				});
		};
		this.handleReset = function () {
			return CPD.revertStaged().then(function () {
				state.zoneDraft = {};
				state.wiredDraft = null;
				loadStatus();
			}, function (e) {
				CPD.toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
