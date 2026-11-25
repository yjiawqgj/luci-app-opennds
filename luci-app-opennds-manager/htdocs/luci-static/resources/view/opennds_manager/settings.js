/*
 * openNDS 设置 · openNDS CPD（LuCI view）
 * 以《OpenNDS设置.html》为 UI 事实源：一级 tab 基础设置 / 高级设置。
 *   基础：客户端全局配置（会话时长/未认证超时/空闲超时/重新认证间隔/最大客户端/
 *         上传下载速率/上传下载流量配额/检查间隔）+ 默认门户上传；
 *   高级：流量卸载（flow_offloading_enable）+ 公平使用策略 + 网络接口。
 *
 * 键名取 11.2.0 conf.c 真实写法（演示 HTML 里的 preauth / idletimeout /
 * flow_offload / authinterval 都是模拟值，不能照抄）：
 *   sessiontimeout / preauthidletimeout / authidletimeout / reauth_interval /
 *   maxclients / uploadrate / downloadrate / uploadquota / downloadquota /
 *   checkinterval / flow_offloading_enable。
 *
 * 流量配额字段的解锁只看 fupCommitted（后端读磁盘已落盘的公平策略状态），
 * 不看本页 stage 的 fupEnabled —— 防止高级页点了开关没保存就把配额放开。
 * 保存 = 写 /tmp/.uci 暂存（原生「未保存的配置」接管），应用 = 原生 commit。
 */
'use strict';
'require view';
'require ui';
'require fs';
'require dom';

var CPD = null;
var TAB_NAMES = {
	wireless: _('无线区域'), wired: _('有线区域'),
	blacklist: _('黑名单'), global: _('全局门户')
};

/* 客户端全局配置：id / 显示名 / 说明 / uci 键 / 最小值 / 单位 / 默认 */
var CLIENT_FIELDS = [
	{ id: 'sessionTimeout', key: 'sessiontimeout', label: _('会话时长'),
		desc: _('客户端通过认证后默认允许联网时长，超时将取消认证。'), min: 1, unit: _('分钟'), def: '120' },
	{ id: 'preauthTimeout', key: 'preauthidletimeout', label: _('未认证超时'),
		desc: _('用户连接网络后在指定时间内没有进行验证或者没有通过认证将会被禁止。'), min: 1, unit: _('分钟'), def: '30' },
	{ id: 'idleTimeout', key: 'authidletimeout', label: _('空闲超时'),
		desc: _('用户通过认证后，断开时长超过指定时间后将会被取消认证。'), min: 1, unit: _('分钟'), def: '5' },
	{ id: 'reauthInterval', key: 'reauth_interval', label: _('重新认证间隔'),
		desc: _('客户端被取消认证后在指定时间内将不会进行验证。0 或留空表示可立即重新认证。'),
		min: 0, unit: _('秒'), def: '0' },
	{ id: 'maxClients', key: 'maxclients', label: _('最大客户端数量'),
		desc: _('最多允许有多少客户端可以被认证，数量不要超过 DHCP 允许最大客户端数量。'), min: 1, unit: _('人'), def: '250' },
	{ id: 'checkInterval', key: 'checkinterval', label: _('检查间隔'),
		desc: _('检查客户端超时、流量配额等检测间隔。'), min: 1, unit: _('秒'), def: '15' }
];
/* 速率 / 配额两栏：同一 field 内两行，0 = 不限制 */
var RATE_FIELDS = [
	{ id: 'cfgUpRate', key: 'uploadrate', label: _('上传速率'), unit: 'kb/s', min: 0, def: '0' },
	{ id: 'cfgDownRate', key: 'downloadrate', label: _('下载速率'), unit: 'kb/s', min: 0, def: '0' }
];
var QUOTA_FIELDS = [
	{ id: 'cfgUpQuota', key: 'uploadquota', label: _('上传量'), unit: 'KB', min: 0, def: '0' },
	{ id: 'cfgDownQuota', key: 'downloadquota', label: _('下载量'), unit: 'KB', min: 0, def: '0' }
];
var ALL_NUM_FIELDS = CLIENT_FIELDS.concat(RATE_FIELDS, QUOTA_FIELDS);

var CSS = '\
.cpd-num{font-family:inherit;font-size:13.5px;color:var(--text,#222a31);height:38px;padding:0 11px;\
background:#fff;border:1px solid var(--line,#d7dde3);border-radius:6px;width:130px}\
.cpd-num:focus{outline:none;border-color:#2274a5;box-shadow:0 0 0 2px #e7f1f8}\
.cpd-num:disabled{background:#f7f9fa;color:#9aa6b2;cursor:not-allowed}\
.cpd-ctlrow{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:12px}\
.cpd-ctlrow + .cpd-ctlrow{margin-top:10px}\
.cpd-ctlrow .lab{font-size:12.5px;min-width:64px}\
.cpd-ctlrow .unit{font-size:12.5px;color:var(--muted,#657585)}\
.cpd-field{padding:16px 0;border-bottom:1px solid var(--line-soft,#e9edf0)}\
.cpd-field:first-child{padding-top:12px}\
.cpd-field:last-child{border-bottom:0}\
.cpd-field h4{font-size:14px;font-weight:650;margin:0 0 5px}\
.cpd-modebar{display:flex;border-bottom:1px solid var(--line,#d7dde3);margin:18px 0 4px}\
.cpd-modebtn{font-family:inherit;font-size:14.5px;font-weight:500;color:inherit;background:transparent!important;\
border:0;border-bottom:2px solid transparent;min-height:47px;padding:0 24px;margin-bottom:-1px;cursor:pointer;outline:none!important;box-shadow:none!important}\
.cpd-modebtn.on{font-weight:700;border-bottom-color:#2274a5}\
.cpd-modebtn:hover,.cpd-modebtn:focus{background:transparent!important;outline:none!important;box-shadow:none!important}\
';

return view.extend({
	load: function () {
		return L.require('opennds_manager.common').then(function (m) { CPD = m; });
	},

	render: function () {
		var state = {
			mode: 'basic',
			portals: {
				wireless: { sel: '', items: [], builtin: false },
				wired: { sel: '', items: [], builtin: false },
				blacklist: { sel: '', items: [], builtin: false },
				global: { sel: '', items: [], builtin: false }
			},
			client: {},
			upAction: 'reject', upRate: '',
			downAction: 'reject', downRate: '',
			iface: 'br-lan',
			device: 'br-lan',
			ifaces: [],
			tab: 'wireless',
			fupEnabled: false,
			fupCommitted: false,
			flowEnabled: false,
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' }, [
			E('style', {}, CSS)
		]);
		var portalBox, fupBox, ifaceBox, switchBtn, switchLabel, fupOffHint;
		var basicPanel, advancedPanel, modeBtns = {};
		var quotaBox, quotaHint, quotaInputs = {};

		/* ---------- 一级 tab ---------- */
		function renderMode() {
			basicPanel.style.display = state.mode === 'basic' ? '' : 'none';
			advancedPanel.style.display = state.mode === 'advanced' ? '' : 'none';
			Object.keys(modeBtns).forEach(function (m) {
				modeBtns[m].className = 'cpd-modebtn' + (state.mode === m ? ' on' : '');
				modeBtns[m].setAttribute('aria-selected', state.mode === m ? 'true' : 'false');
			});
		}

		/* ---------- 页头 + 面板骨架（只建一次） ---------- */
		function buildSkeleton() {
			body.appendChild(CPD.pageHead(
				_('设置'), 'Settings',
				_('客户端全局配置、默认门户与高级策略设置。')));

			var bar = E('div', { 'class': 'cpd-modebar', 'role': 'tablist' });
			['basic', 'advanced'].forEach(function (m) {
				var btn = E('button', {
					'type': 'button', 'class': 'cpd-modebtn', 'role': 'tab',
					'aria-selected': 'false',
					'click': function () { state.mode = m; renderMode(); }
				}, m === 'basic' ? _('基础设置') : _('高级设置'));
				modeBtns[m] = btn;
				bar.appendChild(btn);
			});
			body.appendChild(bar);

			basicPanel = E('div', { 'role': 'tabpanel' });
			advancedPanel = E('div', { 'role': 'tabpanel' });
			body.appendChild(basicPanel);
			body.appendChild(advancedPanel);

			buildBasic();
			buildAdvanced();
			renderMode();
		}

		/* ---------- 基础：客户端全局配置 ---------- */
		function numInput(field) {
			var inp = E('input', {
				'type': 'number', 'class': 'cpd-num',
				'min': String(field.min), 'step': '1', 'inputmode': 'numeric',
				'title': field.min === 0 ? _('填 0 表示不限制') : null,
				'id': 'cpd-f-' + field.id
			});
			inp.value = state.client[field.key] || field.def;
			inp.addEventListener('input', function () {
				state.client[field.key] = inp.value;
			});
			return inp;
		}

		function buildBasic() {
			var sec = CPD.section(_('客户端全局配置'), 'Client Settings');
			CLIENT_FIELDS.forEach(function (f) {
				var row = E('div', { 'class': 'cpd-field' }, [
					E('h4', {}, f.label),
					E('p', { 'class': 'cpd-note' }, f.desc),
					E('div', { 'class': 'cpd-ctlrow' }, [
						E('span', { 'class': 'lab' }, f.label),
						numInput(f),
						E('span', { 'class': 'unit' }, f.unit)
					])
				]);
				sec.appendChild(row);
			});

			/* 速率：上传 / 下载（两行） */
			var rateSec = E('div', { 'class': 'cpd-field' }, [E('h4', {}, _('速率'))]);
			RATE_FIELDS.forEach(function (f) {
				rateSec.appendChild(E('div', { 'class': 'cpd-ctlrow' }, [
					E('span', { 'class': 'lab' }, f.label),
					numInput(f),
					E('span', { 'class': 'unit' }, f.unit)
				]));
			});
			sec.appendChild(rateSec);

			/* 流量配额：默认禁用，红字说明；解锁只看 fupCommitted */
			var qSec = E('div', { 'class': 'cpd-field' }, [E('h4', {}, _('流量配额'))]);
			quotaHint = E('p', { 'class': 'cpd-warnline' },
				_('请先在高级设置里配置“公平使用策略”，开启后才可设置流量配额。'));
			qSec.appendChild(quotaHint);
			quotaBox = E('div', {});
			QUOTA_FIELDS.forEach(function (f) {
				var inp = numInput(f);
				quotaInputs[f.key] = inp;
				quotaBox.appendChild(E('div', { 'class': 'cpd-ctlrow' }, [
					E('span', { 'class': 'lab' }, f.label),
					inp,
					E('span', { 'class': 'unit' }, f.unit)
				]));
			});
			qSec.appendChild(quotaBox);
			sec.appendChild(qSec);
			basicPanel.appendChild(sec);

			/* 默认门户设置 */
			var sec1 = CPD.section(_('默认门户设置'), 'Default Portal');
			sec1.appendChild(E('p', { 'class': 'cpd-note' },
				_('文件夹与文件为相互覆盖模式，后者总会覆盖前者，如果上传文件夹，则文件夹内必须有一个default.sh的主入口脚本。')));
			portalBox = E('div', {});
			sec1.appendChild(portalBox);
			sec1.appendChild(E('div', { 'style': 'margin-top:10px' }, [
				E('input', {
					'type': 'file', 'accept': '.sh', 'id': 'cpd-portal-file', 'style': 'display:none'
				}),
				E('input', {
					'type': 'file', 'webkitdirectory': '', 'id': 'cpd-portal-dir', 'style': 'display:none'
				})
			]));
			basicPanel.appendChild(sec1);
		}

		function renderQuota() {
			var unlocked = !!state.fupCommitted;
			QUOTA_FIELDS.forEach(function (f) {
				var inp = quotaInputs[f.key];
				if (!inp) return;
				if (unlocked) inp.removeAttribute('disabled');
				else inp.setAttribute('disabled', '');
			});
			quotaHint.style.display = unlocked ? 'none' : '';
		}

		/* ---------- 高级 ---------- */
		function buildAdvanced() {
			/* 流量卸载 */
			var fsec = CPD.section(_('流量卸载'), 'Flow Offloading');
			var flowBtn = E('button', {
				'type': 'button', 'role': 'switch', 'aria-checked': 'false',
				'aria-label': _('流量卸载开关'),
				'style': 'position:relative;width:46px;height:26px;flex:none;padding:0;border:1px solid #c9d2da;' +
					'border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s',
				'click': function () {
					state.flowEnabled = !state.flowEnabled;
					renderFlow(flowBtn, flowLabel);
					CPD.stageUci('opennds', '@opennds[0]', 'flow_offloading_enable',
						'opt', state.flowEnabled ? '1' : '0').then(null, function (e) {
							CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
						});
				}
			}, E('span', {
				'style': 'position:absolute;top:2px;left:2px;width:20px;height:20px;border-radius:50%;' +
					'background:#fff;box-shadow:0 1px 2px rgba(20,30,40,.22);transition:transform .15s;display:block'
			}));
			var flowLabel = E('span', { 'style': 'font-size:13px;font-weight:600' }, '');
			fsec.appendChild(E('div', {
				'style': 'display:flex;align-items:center;gap:12px;margin-top:18px;flex-wrap:wrap'
			}, [flowBtn, flowLabel]));
			fsec.appendChild(E('p', { 'class': 'cpd-note', 'style': 'margin-top:14px' },
				_('没有特殊需要请保持开启。')));
			advancedPanel.appendChild(fsec);
			state._flowBtn = flowBtn;
			state._flowLabel = flowLabel;

			/* 公平使用策略 */
			var sec2 = CPD.section(_('公平使用策略'), 'Fair Use Policy');
			sec2.appendChild(E('p', { 'class': 'cpd-warnline' }, _('下载配额检查优于上传配额检查。')));
			switchBtn = E('button', {
				'type': 'button', 'role': 'switch', 'aria-checked': 'false',
				'aria-label': _('公平使用策略开关'),
				'style': 'position:relative;width:46px;height:26px;flex:none;padding:0;border:1px solid #c9d2da;' +
					'border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s',
				'click': function () {
					state.fupEnabled = !state.fupEnabled;
					renderFupSwitch();
					/* 只暂存；配额解锁仍看 fupCommitted，没应用就不放开 */
					CPD.stageUci('zone_detect', 'main', 'fup_enabled',
						'opt', state.fupEnabled ? '1' : '0').then(null, function (e) {
							CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
						});
				}
			}, E('span', {
				'style': 'position:absolute;top:2px;left:2px;width:20px;height:20px;border-radius:50%;' +
					'background:#fff;box-shadow:0 1px 2px rgba(20,30,40,.22);transition:transform .15s;display:block'
			}));
			switchLabel = E('span', { 'style': 'font-size:13px;font-weight:600' }, '');
			sec2.appendChild(E('div', {
				'style': 'display:flex;align-items:center;gap:12px;margin-top:18px;flex-wrap:wrap'
			}, [switchBtn, switchLabel]));
			fupOffHint = E('p', { 'class': 'cpd-note', 'style': 'margin-top:14px;line-height:1.7;max-width:620px' },
				_('开启后才能设置上传、下载的配额处理方式与限速；基础页的流量配额也依赖此开关（需保存并应用）。'));
			sec2.appendChild(fupOffHint);
			fupBox = E('div', {
				'style': 'display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:18px;max-width:620px'
			});
			sec2.appendChild(fupBox);
			advancedPanel.appendChild(sec2);

			/* 网络接口 */
			var sec3 = CPD.section(_('网络接口'), 'Network Interface');
			sec3.appendChild(E('p', { 'class': 'cpd-warnline' },
				_('更改网络接口，某些自定义规则和客户端将会失效，请先调整好相关配置再更改。')));
			ifaceBox = E('div', { 'style': 'margin-top:10px' });
			sec3.appendChild(ifaceBox);
			advancedPanel.appendChild(sec3);
		}

		function renderFlow(btn, label) {
			if (!btn) return;
			var on = !!state.flowEnabled;
			btn.setAttribute('aria-checked', on ? 'true' : 'false');
			btn.style.background = on ? '#2e7d4f' : '#e3e8ec';
			btn.style.borderColor = on ? '#2e7d4f' : '#c9d2da';
			var knob = btn.firstChild;
			if (knob && knob.style) knob.style.transform = on ? 'translateX(20px)' : 'none';
			label.textContent = on ? _('已开启') : _('已关闭');
			label.style.color = on ? '#2e7d4f' : '';
		}

		/* ---------- 默认门户 ---------- */
		function portalInfo(tab) {
			return state.portals[tab] || { sel: '', items: [], builtin: false };
		}
		function portalPath(tab) {
			if (tab === 'global') return '/usr/lib/opennds/cpd/global/';
			return '/usr/lib/opennds/cpd/default/' + tab + '/';
		}
		function renderPortalTabs() {
			portalBox.innerHTML = '';
			var tabs = ['wireless', 'wired', 'blacklist', 'global'];
			var tabRow = E('div', { 'role': 'tablist',
				'style': 'display:flex;flex-wrap:wrap;border-bottom:1px solid #e3e9ee;margin-top:16px' });
			tabs.forEach(function (t) {
				var on = state.tab === t;
				tabRow.appendChild(E('button', {
					'role': 'tab', 'type': 'button',
					'class': 'cpd-tab' + (on ? ' on' : ''),
					'aria-selected': on ? 'true' : 'false',
					'click': function () { state.tab = t; renderPortalTabs(); }
				}, TAB_NAMES[t]));
			});
			var cur = portalInfo(state.tab);
			var curName = cur.sel || (cur.items && cur.items.length ? cur.items[0] : '');
			var uploaded = E('div', {
				'style': 'color:#2e9468;font-size:13px;font-weight:600;text-align:left;margin:12px 0 10px',
				'id': 'cpd-portal-uploaded'
			}, curName ? _('已配置') : '');
			var tools = E('div', {
				'style': 'display:flex;gap:10px;flex-wrap:wrap;margin-top:6px'
			}, [
				E('button', { 'class': 'cbi-button', 'click': pickFile }, _('上传门户')),
				E('button', { 'class': 'cbi-button', 'click': pickFolder }, _('上传门户文件夹')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': curName ? null : '',
					'click': askClean
				}, _('清理'))
			]);
			portalBox.appendChild(E('div', {}, [
				tabRow,
				uploaded,
				E('div', { 'style': 'padding-top:4px' }, [tools])
			]));
		}

		function fileNameOk(n) {
			if (!n || /[/\\|]/.test(n) || /[\x00-\x1f]/.test(n)) return false;
			if (n.charAt(0) === '.') return false;
			if (n !== n.replace(/^\s+|\s+$/g, '')) return false;
			return true;
		}
		function nameBytes(s) {
			return unescape(encodeURIComponent(String(s == null ? '' : s))).length;
		}
		function genId() {
			return 't' + Date.now().toString(36) + Math.floor(Math.random() * 1679616).toString(36) +
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
		function pickFile() {
			var input = document.getElementById('cpd-portal-file');
			input.value = '';
			input.onchange = function () {
				var f = input.files && input.files[0];
				if (!f) return;
				var name = f.name || '';
				if (!/\.sh$/i.test(name)) {
					CPD.toast(_('只接受 .sh 门户脚本，或包含 default.sh 的文件夹'), 'warn');
					return;
				}
				if (nameBytes(name) > 31) {
					CPD.toast(name + '：' + _('文件名过长（最多 31 个字符）'), 'warn');
					return;
				}
				if (!fileNameOk(name)) {
					CPD.toast(name + '：' + _('文件名含非法字符，无法上传'), 'warn');
					return;
				}
				readText(f).then(function (text) {
					return uploadDefault(name, text);
				}, function (e) {
					CPD.toast(CPD.errText(e, _('上传失败')), 'err');
				});
			};
			input.click();
		}
		function pickFolder() {
			var input = document.getElementById('cpd-portal-dir');
			input.value = '';
			input.onchange = function () {
				var files = Array.prototype.slice.call(input.files || []);
				if (!files.length) return;
				var tab = state.tab;
				var rels = [], folderName = '', hasEntry = false, bad = null;
				files.forEach(function (f) {
					var rp = f.webkitRelativePath || f.name || '';
					var segs = rp.split('/');
					if (!folderName) folderName = segs[0] || '';
					var sub = segs.slice(1).join('/');
					if (!sub) return;
					rels.push({ f: f, sub: sub });
					var base = segs[segs.length - 1];
					if (base === 'default.sh') hasEntry = true;
					if (/[\x00-\x1f]/.test(sub) || sub.split('/').indexOf('..') >= 0) bad = sub;
				});
				if (!folderName || bad !== null) {
					CPD.toast((bad || folderName) + '：' + _('文件名含非法字符，无法上传'), 'warn');
					return;
				}
				if (!hasEntry) {
					CPD.toast(_('只接受 .sh 门户脚本，或包含 default.sh 的文件夹'), 'warn');
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
				var chain = CPD.api('settings', 'upload_begin', [id]).then(function (j) {
					if (!j.ok) throw { error: j.error || 'upload_begin 失败' };
					return CPD.api('settings', 'upload_mkdir', [tab, id, folderName]);
				}).then(function (j) {
					if (!j || !j.ok) throw { error: (j && j.error) || _('创建上传目录失败') };
				});
				dirs.forEach(function (d) {
					chain = chain.then(function () {
						return CPD.api('settings', 'upload_mkdir', [tab, id, folderName, d])
							.then(function (j) {
								if (!j || !j.ok) throw { error: (j && j.error) || _('创建上传目录失败') };
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
					return CPD.api('settings', 'upload_default', [tab, id, 'dir', folderName]);
				}).then(function (j) {
					if (!j.ok) throw { error: j.error || '上传失败' };
					CPD.notify(_('已上传门户文件夹 %s（%s），并已在门户选择中启用')
						.format(folderName, j.path || portalPath(tab) + folderName), 'ok');
					uploadActivated(tab, folderName);
				}).catch(function (e) {
					CPD.notify(CPD.errText(e, _('上传失败')), 'err');
				});
			};
			input.click();
		}
		function uploadDefault(name, content) {
			var id = genId();
			var tab = state.tab;
			CPD.api('settings', 'upload_begin', [id]).then(function (j) {
				if (!j.ok) throw { error: j.error || 'upload_begin 失败' };
				return fs.write('/tmp/zone_up/' + id + '/' + name, content);
			}).then(function () {
				return CPD.api('settings', 'upload_default', [tab, id, 'file', name]);
			}).then(function (j) {
				if (!j.ok) throw { error: j.error || '上传失败' };
				CPD.toast(_('已上传 %s，并在门户选择中启用').format(name), 'ok');
				uploadActivated(tab, name);
			}).catch(function (e) {
				CPD.toast(CPD.errText(e, _('上传失败')), 'err');
			});
		}
		function uploadActivated(tab, name) {
			CPD.api('settings', 'portal_save', [tab, name]).then(function () {
				refresh();
			}).catch(function () {
				refresh();
			});
		}
		function askClean() {
			var tab = state.tab;
			var info = portalInfo(tab);
			var name = info.sel || (info.items && info.items.length ? info.items[0] : '');
			if (!name) return;
			CPD.confirm(null, _('确认清理？'), _('清理'), true, function () {
				CPD.api('settings', 'clean_default', [tab, name]).then(function (j) {
					if (!j || !j.ok) {
						CPD.notify((j && j.error) || _('清理失败'), 'err');
						return;
					}
					CPD.notify(j.removed === 1
						? _('已清理 %s，当前类型已切回默认门户').format(name)
						: _('%s 已不存在，列表已刷新').format(name), 'ok');
					refresh();
				}).catch(function (e) {
					CPD.notify(CPD.errText(e, _('清理失败')), 'err');
				});
			});
		}

		/* ---------- 公平使用策略 ---------- */
		function quotaColumn(label, isUp) {
			var action = isUp ? state.upAction : state.downAction;
			var rate = isUp ? state.upRate : state.downRate;
			var sel = E('select', { 'class': 'cpd-input',
				'style': 'max-width:260px;min-width:170px;height:36px;padding:0 8px;line-height:34px;margin-top:10px' }, [
				E('option', { value: 'limit' }, _('限速')),
				E('option', { value: 'reject' }, _('取消认证'))
			]);
			sel.value = action;
			var rateInput = E('input', {
				'class': 'cpd-input', 'type': 'number', 'min': '1', 'step': '1',
				'style': 'max-width:130px',
				'placeholder': isUp ? _('例如 2048') : _('例如 4096')
			});
			rateInput.value = rate;
			var rateLine = E('div', { 'style': 'margin-top:20px;display:flex;align-items:center;gap:8px' }, [
				E('span', { 'class': 'cpd-note' }, _('速率')),
				rateInput,
				E('span', { 'class': 'cpd-note' }, 'Kb/s')
			]);
			function sync() {
				rateLine.style.display = (sel.value === 'reject') ? 'none' : 'flex';
				if (isUp) { state.upAction = sel.value; state.upRate = rateInput.value; }
				else { state.downAction = sel.value; state.downRate = rateInput.value; }
			}
			sel.addEventListener('change', sync);
			rateInput.addEventListener('input', sync);
			rateLine.style.display = (action === 'reject') ? 'none' : 'flex';
			return E('div', {}, [
				E('label', { 'class': 'cpd-note',
					'style': 'display:block;margin-bottom:10px;font-weight:600;color:var(--text,#222a31)' }, label),
				sel,
				rateLine
			]);
		}
		function renderFup() {
			fupBox.innerHTML = '';
			fupBox.appendChild(quotaColumn(_('上传'), true));
			fupBox.appendChild(quotaColumn(_('下载'), false));
		}
		function renderFupSwitch() {
			if (!switchBtn) return;
			var on = !!state.fupEnabled;
			switchBtn.setAttribute('aria-checked', on ? 'true' : 'false');
			switchBtn.style.background = on ? '#2e7d4f' : '#e3e8ec';
			switchBtn.style.borderColor = on ? '#2e7d4f' : '#c9d2da';
			var knob = switchBtn.firstChild;
			if (knob && knob.style) knob.style.transform = on ? 'translateX(20px)' : 'none';
			switchLabel.textContent = on ? _('已开启') : _('已关闭');
			switchLabel.style.color = on ? '#2e7d4f' : '';
			fupBox.style.display = on ? 'grid' : 'none';
			fupOffHint.style.display = on ? 'none' : '';
			if (on) renderFup();
		}

		/* ---------- 网络接口 ---------- */
		function renderIfaces() {
			ifaceBox.innerHTML = '';
			if (!state.ifaces.length) {
				ifaceBox.appendChild(E('p', { 'class': 'cpd-note' }, _('未找到带 IPv4 地址的网络接口。')));
				return;
			}
			if (state.iface !== state.device &&
				!state.ifaces.some(function (i) { return i.name === state.device; })) {
				ifaceBox.appendChild(E('p', { 'class': 'cpd-note' },
					_('当前配置的接口「%s」不在本机接口列表里，点击下方任一接口即可切换').format(state.iface)));
			}
			var grid = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:12px;margin-top:16px' });
			state.ifaces.forEach(function (it) {
				var active = (it.name === state.device);
				var card = E('button', {
					'type': 'button', 'data-iface': it.name,
					'style': 'text-align:left;padding:10px 12px;min-width:150px;border:1px solid ' +
						(active ? '#2274a5' : '#d7dde3') + ';border-radius:8px;background:' +
						(active ? '#e7f1f8' : '#fff') + ';cursor:pointer;font-family:inherit',
					'aria-pressed': active ? 'true' : 'false',
					'click': function (ev) {
						if (ev && ev.preventDefault) ev.preventDefault();
						clickIface(it.name);
					}
				}, [
					E('div', { 'style': 'font-family:ui-monospace,Consolas,monospace;font-size:14px' }, [
						it.name,
						active ? E('span', { 'class': 'cpd-badge' }, '● ' + _('正在使用中')) : E([])
					]),
					E('div', { 'class': 'cpd-note', 'style': 'margin-top:4px' }, 'IP：' + it.ip)
				]);
				grid.appendChild(card);
			});
			ifaceBox.appendChild(grid);
		}
		function clickIface(name) {
			if (name === state.device) return;
			CPD.confirm(null, _('确认切换网络接口？'), _('切换'), true, function () {
				state.device = name;
				state.iface = name;
				renderIfaces();
				CPD.stageUci('opennds', '@opennds[0]', 'gatewayinterface', 'opt', name)
					.then(null, function (e) {
						CPD.notify(CPD.errText(e, _('暂存配置失败')), 'err');
					});
			});
		}

		/* ---------- 校验 / 暂存 / 应用 ---------- */
		function checkClient() {
			for (var i = 0; i < ALL_NUM_FIELDS.length; i++) {
				var f = ALL_NUM_FIELDS[i];
				/* 流量配额未解锁时不校验（禁用态的值不参与保存） */
				if (QUOTA_FIELDS.indexOf(f) >= 0 && !state.fupCommitted) continue;
				var v = String(state.client[f.key] == null ? '' : state.client[f.key]).trim();
				if (v === '') return _('请填写%1（%2）').format(f.label, f.unit);
				if (!/^\d+$/.test(v)) return _('%1必须是%2的整数（%3）')
					.format(f.label, f.min > 0 ? _('大于 0') : _('非负'), f.unit);
				if (parseInt(v, 10) < f.min) return _('%1必须%2（%3）')
					.format(f.label, f.min > 0 ? _('大于 0') : _('非负'), f.unit);
			}
			return null;
		}
		function checkFup() {
			var pairs = [[state.upAction, state.upRate], [state.downAction, state.downRate]];
			for (var i = 0; i < pairs.length; i++) {
				var act = pairs[i][0], rate = String(pairs[i][1] || '').trim();
				if (act !== 'limit') continue;
				if (!rate) return _('请填写速率');
				if (!/^\d+$/.test(rate)) return _('速率必须是大于 0 的整数');
				var n = parseInt(rate, 10);
				if (n < 1) return _('速率必须是大于 0 的整数');
				if (n > 10000000) return _('速率过大，请检查单位是否为 Kb/s');
			}
			return null;
		}

		function stageAll() {
			var ce = checkClient();
			if (ce) return Promise.reject({ error: ce });
			if (state.fupEnabled) {
				var fe = checkFup();
				if (fe) return Promise.reject({ error: fe });
			}
			var uv = state.fupEnabled && state.upAction === 'limit' ? String(state.upRate).trim() : '0';
			var dv = state.fupEnabled && state.downAction === 'limit' ? String(state.downRate).trim() : '0';
			var jobs = [
				CPD.stageUci('opennds', '@opennds[0]', 'gatewayinterface', 'opt', state.device),
				CPD.stageUci('opennds', '@opennds[0]', 'flow_offloading_enable',
					'opt', state.flowEnabled ? '1' : '0'),
				CPD.stageUci('zone_detect', 'main', 'fup_enabled', 'opt', state.fupEnabled ? '1' : '0')
			];
			ALL_NUM_FIELDS.forEach(function (f) {
				/* 流量配额锁定：写 0，不把禁用态的输入带进配置 */
				var v = (QUOTA_FIELDS.indexOf(f) >= 0 && !state.fupCommitted)
					? '0' : String(state.client[f.key] == null ? '' : state.client[f.key]).trim();
				jobs.push(CPD.stageUci('opennds', '@opennds[0]', f.key, 'opt', v || f.def));
			});
			/* 公平策略关闭时清掉限速键 */
			jobs.push(CPD.stageUci('opennds', '@opennds[0]', 'fup_upload_throttle_rate', 'opt', uv));
			jobs.push(CPD.stageUci('opennds', '@opennds[0]', 'fup_download_throttle_rate', 'opt', dv));
			return Promise.all(jobs).then(function () {
				state.snapshot = snapshot();
			});
		}

		function snapshot() {
			var c = {};
			ALL_NUM_FIELDS.forEach(function (f) { c[f.key] = state.client[f.key]; });
			return {
				client: c, device: state.device, flowEnabled: state.flowEnabled,
				upAction: state.upAction, upRate: state.upRate,
				downAction: state.downAction, downRate: state.downRate,
				fupEnabled: state.fupEnabled
			};
		}

		function handleSave() {
			return stageAll().then(function () {
				/* 不弹横幅：右上角「未保存的配置」就是反馈 */
			}, function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		}
		function handleApply() {
			return stageAll().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		/* ---------- 读状态 ---------- */
		function refresh() {
			return CPD.api('settings', 'status').then(function (j) {
				if (!j.ok) { CPD.toast(j.error || _('读取状态失败'), 'err'); return; }
				state.portals = j.portals;
				var f = j.fup || {};
				state.upAction = f.upAction || 'reject';
				state.upRate = (f.upAction === 'limit') ? String(f.upRate || '') : '';
				state.downAction = f.downAction || 'reject';
				state.downRate = (f.downAction === 'limit') ? String(f.downRate || '') : '';
				state.iface = j.iface || 'br-lan';
				state.device = j.device || state.iface;
				state.ifaces = j.ifaces || [];
				state.fupEnabled = (j.fupEnabled === 1 || j.fupEnabled === true);
				/* 配额解锁的唯一依据：后端读磁盘的已提交值 */
				state.fupCommitted = (j.fupCommitted === 1 || j.fupCommitted === true);
				state.flowEnabled = (j.flowEnabled === 1 || j.flowEnabled === true);
				var c = j.client || {};
				ALL_NUM_FIELDS.forEach(function (fd) {
					state.client[fd.key] = (c[fd.key] !== undefined && c[fd.key] !== '')
						? String(c[fd.key]) : fd.def;
				});
				state.snapshot = snapshot();
				if (!basicPanel) buildSkeleton();
				ALL_NUM_FIELDS.forEach(function (fd) {
					var input = document.getElementById('cpd-f-' + fd.id);
					if (input) input.value = state.client[fd.key];
				});
				renderQuota();
				renderFlow(state._flowBtn, state._flowLabel);
				renderPortalTabs();
				renderFupSwitch();
				renderIfaces();
				renderMode();
			}).catch(function (e) {
				CPD.toast((e && e.error) || _('读取状态失败'), 'err');
			});
		}

		buildSkeleton();
		refresh();

		this.handleSave = function () { return handleSave(); };
		this.handleSaveApply = function () { return handleApply(); };
		this.handleReset = function () {
			return CPD.revertStaged().then(function () { refresh(); }, function (e) {
				CPD.toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
