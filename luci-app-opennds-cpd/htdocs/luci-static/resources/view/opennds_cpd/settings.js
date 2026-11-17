/*
 * openNDS 设置 · openNDS CPD（LuCI view）
 * 照《OpenNDS设置.md》：默认门户（三 tab 上传/清理 default.sh，即时动作不进快照）+
 * 公平使用策略（限速/取消认证，取消认证写 0）+ 网络接口（前端切换只改状态，
 * gatewayinterface 只在「应用」写盘）；保存 = 内存快照，应用 = 后端写三键 + 重启。
 */
'use strict';
'require view';
'require ui';
'require fs';
'require dom';

var CPD = null;
var TAB_NAMES = { wireless: _('无线区域'), wired: _('有线区域'), blacklist: _('黑名单') };

return view.extend({
	load: function () {
		return L.require('opennds_cpd.common').then(function (m) { CPD = m; });
	},

	render: function () {
		var state = {
			portals: {
				wireless: { sel: '', items: [], builtin: false },
				wired: { sel: '', items: [], builtin: false },
				blacklist: { sel: '', items: [], builtin: false }
			},
			upAction: 'reject', upRate: '',
			downAction: 'reject', downRate: '',
			iface: 'br-lan',
			device: 'br-lan',
			ifaces: [],
			tab: 'wireless',
			fupEnabled: true,
			snapshot: null
		};
		var body = E('div', { 'class': 'cpd-page' });
		var portalBox, fupBox, ifaceBox, switchBtn, switchLabel, fupOffHint;

		/* ---------- 页头 ---------- */
		function renderAll() {
			body.innerHTML = '';
			body.appendChild(CPD.pageHead(
				_('openNDS 设置'), 'Settings',
				_('默认门户、公平使用策略与网络接口设置。')));

			/* 默认门户设置 */
			var sec1 = CPD.section(_('默认门户设置'), 'Default Portal');
			sec1.appendChild(E('p', { 'class': 'cpd-note' },
				_('文件夹与文件为相互覆盖模式，后者总会覆盖前者，如果上传文件夹，则文件夹内必须有一个default.sh的主入口脚本。')));
			portalBox = E('div', {});
			sec1.appendChild(portalBox);
			renderPortalTabs();
			sec1.appendChild(E('div', { 'style': 'margin-top:10px' }, [
				E('input', {
					'type': 'file', 'accept': '.sh', 'id': 'cpd-portal-file', 'style': 'display:none'
				}),
				E('input', {
					'type': 'file', 'webkitdirectory': '', 'id': 'cpd-portal-dir', 'style': 'display:none'
				})
			]));
			body.appendChild(sec1);

			/* 公平使用策略：开关 + 配额区（关闭时整块隐藏） */
			var sec2 = CPD.section(_('公平使用策略'), 'Fair Use Policy');
			sec2.appendChild(E('p', { 'class': 'cpd-warnline' }, _('下载配额检查优于上传配额检查。')));
			switchBtn = E('button', {
				'type': 'button', 'role': 'switch', 'aria-checked': state.fupEnabled ? 'true' : 'false',
				'aria-label': _('公平使用策略开关'),
				'style': 'position:relative;width:46px;height:26px;flex:none;padding:0;border:1px solid #c9d2da;' +
					'border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s',
				'click': function () {
					state.fupEnabled = !state.fupEnabled;
					renderFupSwitch();
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
				_('开启后才能设置上传、下载的配额处理方式与限速；仪表盘页客户端编辑里的流量限制也依赖此开关。'));
			sec2.appendChild(fupOffHint);
			fupBox = E('div', {
				'style': 'display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:18px;max-width:620px'
			});
			sec2.appendChild(fupBox);
			renderFupSwitch();
			body.appendChild(sec2);

			/* 网络接口 */
			var sec3 = CPD.section(_('网络接口'), 'Network Interface');
			sec3.appendChild(E('p', { 'class': 'cpd-warnline' },
				_('更改网络接口，某些自定义规则和客户端将会失效，请先调整好相关配置再更改。')));
			ifaceBox = E('div', { 'style': 'margin-top:10px' });
			sec3.appendChild(ifaceBox);
			renderIfaces();
			body.appendChild(sec3);

		}

		/* ---------- 默认门户 ---------- */
		function portalInfo(tab) {
			return state.portals[tab] || { sel: '', items: [], builtin: false };
		}

		/* 下拉最长 10 个字符，全名放 title 悬停可见 */
		function shortName(n) {
			n = String(n || '');
			return n.length > 10 ? n.slice(0, 10) + '…' : n;
		}

		/* 本页上传的默认门户实际落盘目录（区域各自的门户在 cpd/wireless/<区域>/、cpd/wired/<接口>/，由区域识别页管理） */
		function portalPath(tab) {
			return '/usr/lib/opennds/cpd/default/' + tab + '/';
		}

		function renderPortalTabs() {
			portalBox.innerHTML = '';
			var tabs = ['wireless', 'wired', 'blacklist'];
			/* 与顶部页面切换同风格：无背景色，选中只加粗 + 下划线，不改变文字颜色 */
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
			/* 门户不再做「选择」：该类型下只允许存在一个门户（文件或文件夹），
			 * 后传的覆盖先传的，这里只显示当前生效的那一个 */
			var curName = cur.sel || (cur.items && cur.items.length ? cur.items[0] : '');

			var tools = E('div', {
				'style': 'display:flex;gap:10px;flex-wrap:wrap;margin-top:6px'
			}, [
				E('button', { 'class': 'cbi-button', 'click': pickFile }, _('上传脚本')),
				E('button', { 'class': 'cbi-button', 'click': pickFolder }, _('上传文件夹')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': curName ? null : '',
					'click': askClean
				}, _('清理'))
			]);

			portalBox.appendChild(E('div', {}, [
				tabRow,
				E('div', { 'style': 'padding-top:22px' }, [
					tools
				])
			]));
		}

		/* 名字规则与后端 name_ok 口径一致：ASCII 限 [A-Za-z0-9._- ]，其余须为中文（多字节） */
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
					CPD.toast(_('只接受 .sh 门户脚本，或包含 theme.sh 的文件夹'), 'warn');
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
				/* webkitRelativePath：<文件夹名>/…/文件 */
				var rels = [], folderName = '', hasTheme = false, bad = null;
				files.forEach(function (f) {
					var rp = f.webkitRelativePath || f.name || '';
					var segs = rp.split('/');
					if (!folderName) folderName = segs[0] || '';
					var sub = segs.slice(1).join('/');
					if (!sub) return;
					rels.push({ f: f, sub: sub });
					var base = segs[segs.length - 1];
					if (base === 'theme.sh') hasTheme = true;
					if (/[\x00-\x1f]/.test(sub) || sub.split('/').indexOf('..') >= 0) bad = sub;
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
								if (!j || !j.ok) {
									throw { error: (j && j.error) || _('创建上传目录失败') };
								}
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
			/* 上传即选中：让 openNDS 用这份新门户 */
			CPD.api('settings', 'portal_save', [tab, name]).then(function () {
				refresh();
			}).catch(function () {
				refresh();
			});
		}

		function askClean() {
			var tab = state.tab;
			var info = portalInfo(tab);
			/* 用「当前显示的那个」而不是只看 sel：sel 为空时按钮也能用 */
			var name = info.sel || (info.items && info.items.length ? info.items[0] : '');
			if (!name) {
				CPD.notify(_('该类型当前是内置 default.sh，没有可清理的门户'), 'warn');
				return;
			}
			CPD.confirm(
				_('清理 %s？').format(shortName(name)),
				_('将删除门户目录中的 %s，删除后该类型自动切回默认门户。').format(name),
				_('清理'), true,
				function () {
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
				}
			);
		}

		/* ---------- 公平使用策略 ---------- */
		function quotaColumn(label, isUp) {
			var action = isUp ? state.upAction : state.downAction;
			var rate = isUp ? state.upRate : state.downRate;
			var sel = E('select', { 'class': 'cpd-input', 'style': 'max-width:260px;min-width:170px;height:36px;padding:0 8px;line-height:34px;margin-top:10px' }, [
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
				E('label', { 'class': 'cpd-note', 'style': 'display:block;margin-bottom:10px;font-weight:600;color:var(--text,#222a31)' }, label),
				sel,
				rateLine
			]);
		}

		function renderFup() {
			fupBox.innerHTML = '';
			fupBox.appendChild(quotaColumn(_('上传'), true));
			fupBox.appendChild(quotaColumn(_('下载'), false));
		}

		/* 开关联动：关闭时整块配额区隐藏，只留提示（与演示一致） */
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
				ifaceBox.appendChild(E('p', { 'class': 'cpd-note' },
					_('未找到带 IPv4 地址的网络接口。')));
				return;
			}
			if (state.iface !== state.device && !state.ifaces.some(function (i) { return i.name === state.device; })) {
				ifaceBox.appendChild(E('p', { 'class': 'cpd-note' },
					_('当前配置的接口「%s」不在本机接口列表里，点击下方任一接口即可切换').format(state.iface)));
			}
			/* 卡片按内容自然大小排布（同仪表盘），有几个占多大，不强行撑满整行 */
			var grid = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:12px;margin-top:16px' });
			state.ifaces.forEach(function (it) {
				var active = (it.name === state.device);
				/* 点击事件直接挂在按钮属性上：不依赖 innerHTML 重绘后的二次绑定 */
				var card = E('button', {
					'type': 'button',
					'data-iface': it.name,
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
					E('div', { 'class': 'cpd-note', 'style': 'margin-top:4px' },
						'IP：' + it.ip)
				]);
				grid.appendChild(card);
			});
			ifaceBox.appendChild(grid);
		}

		function clickIface(name) {
			if (name === state.device) {
				CPD.notify(_('当前正在使用 %s').format(name), 'warn');
				return;
			}
			CPD.confirm(
				_('切换网络接口？'),
				_('将 openNDS 接管接口从「%s」切换到「%s」。切换后部分自定义规则和客户端可能失效。')
					.format(state.device, name),
				_('切换'), false,
				function () {
					state.device = name;
					state.iface = name;
					renderIfaces();
					/* 不弹横幅：切完只是本地选择，底部「保存」才写配置 */
				}
			);
		}

		/* ---------- 保存 / 应用 ---------- */
		function checkFup() {
			var pairs = [
				[state.upAction, state.upRate, true],
				[state.downAction, state.downRate, false]
			];
			for (var i = 0; i < pairs.length; i++) {
				var act = pairs[i][0], rate = pairs[i][1];
				if (act === 'reject') continue;
				if (!String(rate).trim()) return _('请填写速率');
				if (!/^\d+$/.test(String(rate).trim())) return _('速率必须是大于 0 的整数');
				var n = parseInt(rate, 10);
				if (n < 1) return _('速率必须是大于 0 的整数');
				if (n > 10000000) return _('速率过大，请检查单位是否为 Kb/s');
			}
			return null;
		}

		/* 暂存到 /tmp/.uci（顶部「未保存的配置」计数由此产生），与应用写入的键保持一致 */
		function stageAll() {
			var fe = state.fupEnabled ? checkFup() : null;
			if (fe) return Promise.reject({ error: fe });
			var uv = state.fupEnabled && state.upAction === 'limit' ? state.upRate.trim() : '0';
			var dv = state.fupEnabled && state.downAction === 'limit' ? state.downRate.trim() : '0';
			return Promise.all([
				CPD.stageUci('opennds', '@opennds[0]', 'fup_upload_throttle_rate', 'opt', uv),
				CPD.stageUci('opennds', '@opennds[0]', 'fup_download_throttle_rate', 'opt', dv),
				CPD.stageUci('opennds', '@opennds[0]', 'gatewayinterface', 'opt', state.device),
				CPD.stageUci('zone_detect', 'main', 'fup_enabled', 'opt', state.fupEnabled ? '1' : '0')
			]).then(function () {
				state.snapshot = {
					upAction: state.upAction, upRate: state.upRate,
					downAction: state.downAction, downRate: state.downRate,
					device: state.device
				};
			});
		}

		function handleSave() {
			return stageAll().then(function () {
				/* 不弹横幅：右上角「未保存的配置」就是反馈 */
			}, function (e) {
				CPD.notify(CPD.errText(e, _('保存失败')), 'err');
			});
		}

		function notSaved() {
			if (!state.snapshot) return true;
			return state.snapshot.upAction !== state.upAction ||
				state.snapshot.upRate !== state.upRate ||
				state.snapshot.downAction !== state.downAction ||
				state.snapshot.downRate !== state.downRate ||
				state.snapshot.device !== state.device;
		}

		function handleApply() {
			var fe = state.fupEnabled ? checkFup() : null;
			if (fe) {
				CPD.toast(fe, 'warn');
				return Promise.resolve();
			}
			/* 保存并应用：先落 uci 增量，再走 openwrt 原生 commit 流程 */
			return stageAll().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		}

		/* 读取设置：门户列表 / 公平使用 / 网络接口 */
		function refresh() {
			CPD.api('settings', 'status').then(function (j) {
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
				state.snapshot = {
					upAction: state.upAction, upRate: state.upRate,
					downAction: state.downAction, downRate: state.downRate,
					device: state.device
				};
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
			/* 原生 revert 会自己发 uci-reverted、清指示器并刷新页面，
			 * 不必再弹一条转瞬即逝的提示 */
			return CPD.revertStaged().then(function () {
				refresh();
			}, function (e) {
				CPD.toast(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
