/*
 * openNDS 概览（仪表盘） · openNDS CPD（LuCI view）
 * 照《OpenNDS概览.md》：运行状态（开关+重启）、客户端统计（筛选器）、网络接口、
 * 无线接入点、客户端列表（搜索/排序/行内 6 按钮）+ 编辑/详情弹窗。
 * 所有状态变更先二次确认 → 整页锁定遮罩（「正在应用…」+ 倒计时，解锁只看接口返回）；
 * 10 秒自动轮询，锁定/弹窗打开期间暂停。
 */
'use strict';
'require view';
'require ui';
'require dom';

var CPD = null;

var CSS = '\
.ovd-page{max-width:none;width:100%;padding:18px 4px 60px;color:#222a31}\
.ovd-sec{padding:18px 0 6px}\
.ovd-sec h3{font-size:16px;font-weight:650;margin:0 0 4px}\
.ovd-divider{border:0;border-top:1px solid #d7dde3;margin:8px 0 0}\
.ovd-status-line{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:10px 0 2px}\
.ovd-dot{width:10px;height:10px;border-radius:50%;background:#2e9468;box-shadow:0 0 0 3px #e4f4ec;flex:none}\
.ovd-dot.off{background:#c94848;box-shadow:0 0 0 3px #fbe8e8}\
.ovd-status-text{font-size:20px;font-weight:650;color:#2e9468;letter-spacing:.5px}\
.ovd-status-text.off{color:#c94848}\
.ovd-status-text.pending{color:#9aa6b2}\
.ovd-switch{position:relative;width:42px;height:24px;flex:none;padding:0;border:1px solid #c9d2da;border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s}\
.ovd-switch .knob{position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(20,30,40,.22);transition:transform .15s}\
.ovd-switch[aria-checked="true"]{background:#2e9468;border-color:#2e9468}\
.ovd-switch[aria-checked="true"] .knob{transform:translateX(18px)}\
.ovd-stat-grid{display:grid;grid-template-columns:repeat(7,1fr);gap:10px;margin-top:14px}\
.ovd-stat{font-family:inherit;text-align:left;background:#fff;border:1px solid #d7dde3;border-radius:8px;padding:14px 15px;cursor:pointer;min-width:0;color:#222a31}\
.ovd-stat:hover{border-color:#b9c6d1;background:#fafbfc}\
.ovd-stat.selected{border-color:#2274a5;background:#e7f1f8}\
.ovd-stat.selected .ovd-num{color:#1b5f8a}\
.ovd-stat.static{cursor:default;background:#fbfcfd}\
.ovd-stat.static:hover{border-color:#d7dde3;background:#fbfcfd}\
.ovd-stat.static .ovd-num{color:#9aa6b2}\
.ovd-num{display:block;font-size:24px;font-weight:650;line-height:1.2;font-variant-numeric:tabular-nums}\
.ovd-slabel{display:block;font-size:12px;color:#657585;margin-top:5px}\
.ovd-card{background:#fff;border:1px solid #d7dde3;border-radius:8px;padding:13px 14px;min-width:0}\
.ovd-iface-grid{display:flex;flex-wrap:wrap;gap:10px;margin-top:14px}\
.ovd-iface-grid .ovd-card{flex:0 1 300px;max-width:340px}\
.ovd-ap-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,162px));gap:10px;margin-top:14px;align-items:start}\
.ovd-ap{font-family:inherit;font-size:13px;line-height:1.5;text-align:left;color:#222a31;cursor:pointer;display:flex;flex-direction:column;justify-content:space-between;gap:8px;width:100%;padding:12px 13px;min-height:88px;background:#fff;border:1px solid #d7dde3;border-radius:8px;transition:border-color .12s,background .12s}\
.ovd-ap:hover{border-color:#b9c6d1;background:#fafbfc}\
.ovd-ap.selected{border-color:#2274a5;background:#e7f1f8}\
.ovd-ap.selected .ovd-ap-count-num{color:#1b5f8a}\
.ovd-iface-name{font-size:22px;font-weight:700;line-height:1.25;margin-bottom:6px;letter-spacing:.2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.ovd-ap-name{font-size:12.5px;font-weight:650;text-align:left;line-height:1.35;margin:0;color:#222a31;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.ovd-info-row{display:flex;justify-content:space-between;gap:10px;font-size:11.5px;line-height:1.7;color:#657585}\
.ovd-info-row b{color:#222a31;font-weight:600;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\
.ovd-ap-count{display:flex;align-items:baseline;gap:6px;padding:0}\
.ovd-ap-count-num{display:block;font-size:22px;font-weight:650;line-height:1.2;color:#222a31;font-variant-numeric:tabular-nums}\
.ovd-ap-count-label{display:block;font-size:11px;color:#657585;margin-top:0;line-height:1.3;white-space:nowrap}\
.ovd-mono{font-family:ui-monospace,Consolas,"Courier New",monospace}\
.ovd-listhead{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;margin-top:6px}\
.ovd-listhead h3{margin:0}\
.ovd-count{font-size:11.5px;color:#9aa6b2}\
.ovd-search{flex:0 1 300px;min-width:220px;margin-left:auto;align-self:center;height:34px;font-size:13px;padding:0 11px;border:1px solid #d7dde3;border-radius:6px;background:#fff;color:#222a31}\
.ovd-search:focus{outline:none;border-color:#2274a5;box-shadow:0 0 0 2px #e7f1f8}\
.ovd-tablewrap{overflow-x:auto;margin-top:12px;border:1px solid #e9edf0;border-radius:8px;background:#fff}\
.ovd-tbl{width:100%;min-width:1080px;border-collapse:collapse;table-layout:fixed}\
.ovd-tbl thead th{text-align:left;font-size:11.5px;font-weight:600;color:#657585;background:#f7f9fa;padding:9px 10px;border-bottom:1px solid #d7dde3;white-space:nowrap}\
.ovd-tbl tbody td{padding:10px;border-bottom:1px solid #e9edf0;font-size:12.5px;vertical-align:middle}\
.ovd-tbl tbody tr:last-child td{border-bottom:0}\
.ovd-tbl tbody tr:hover td{background:#fafbfc}\
.ovd-sortbtn{font:inherit;color:inherit;background:none;border:0;padding:0;margin:0;display:flex;align-items:center;gap:4px;width:100%;text-align:left;cursor:pointer}\
.ovd-sortbtn:hover{color:#222a31}\
.ovd-arrow{display:inline-block;width:9px;color:#2274a5;font-size:10px;line-height:1;flex:none}\
.ovd-host{display:flex;flex-direction:column;gap:4px;min-width:0}\
.ovd-host-name{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.ovd-tags{display:flex;gap:4px;flex-wrap:wrap}\
.ovd-tag{font-size:10px;font-weight:500;line-height:1.5;padding:0 6px;border-radius:999px;border:1px solid;white-space:nowrap}\
.ovd-tag.t-auth{color:#2e7d5b;border-color:#bfe0cf;background:#eef8f2}\
.ovd-tag.t-unauth{color:#7c8894;border-color:#dfe5ea;background:transparent}\
.ovd-tag.t-pre{color:#8a6116;border-color:#e7d3a6;background:#faf1dc}\
.ovd-tag.t-trusted{color:#1a6b41;border-color:#a9d5bd;background:#dff2e6}\
.ovd-tag.t-black{color:#fff;border-color:#252b31;background:#252b31}\
.ovd-acts{display:flex;flex-wrap:wrap;gap:5px}\
.ovd-rowbtn{font-family:inherit;font-size:11px;color:#222a31;background:#fff;border:1px solid #d7dde3;border-radius:4px;height:26px;padding:0 8px;cursor:pointer;white-space:nowrap}\
.ovd-rowbtn:hover{background:#f4f7f9;border-color:#c4ccd4}\
.ovd-rowbtn:disabled{opacity:.45;cursor:default;background:#f7f9fa}\
.ovd-rowbtn.danger{color:#c94848;border-color:#e8c9c9}\
.ovd-rowbtn.danger:hover{background:#fdf4f4;border-color:#d9a8a8}\
.ovd-empty{text-align:center;color:#9aa6b2;font-size:12.5px;padding:26px 10px}\
.ovd-mask{position:fixed;inset:0;background:rgba(22,30,38,.5);display:none;align-items:center;justify-content:center;padding:18px;z-index:700}\
.ovd-mask.on{display:flex}\
.ovd-dialog{background:#fff;border-radius:10px;width:100%;max-width:660px;max-height:90vh;display:flex;flex-direction:column;box-shadow:0 18px 48px rgba(20,30,40,.24)}\
.ovd-dialog.dtl{max-width:460px}\
.ovd-dhead{padding:15px 20px;border-bottom:1px solid #d7dde3;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}\
.ovd-dhead h3{font-size:16px;font-weight:650;margin:0}\
.ovd-dsub{font-size:11.5px;color:#9aa6b2;font-family:ui-monospace,Consolas,monospace;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\
.ovd-dbody{padding:0 20px 8px;overflow:auto;flex:1}\
.ovd-dfoot{padding:13px 20px;border-top:1px solid #d7dde3;display:flex;justify-content:flex-end;gap:8px;background:#fff;border-radius:0 0 10px 10px}\
.ovd-dsec{padding:14px 0;border-bottom:1px solid #e9edf0}\
.ovd-dsec:last-child{border-bottom:0}\
.ovd-dsec h4{font-size:13px;font-weight:650;margin:0 0 8px}\
.ovd-ed-row{display:flex;gap:12px;align-items:flex-start;padding:6px 0;flex-wrap:wrap}\
.ovd-ed-label{width:104px;flex:none;font-size:12.5px;color:#657585;padding-top:8px}\
.ovd-ed-ctrl{flex:1;min-width:0}\
.ovd-limit-input{display:flex;align-items:center;gap:8px}\
.ovd-limit-input input{max-width:150px;height:34px;padding:0 11px;border:1px solid #d7dde3;border-radius:6px;font-size:13.5px;color:#222a31;background:#fff}\
.ovd-limit-input input:disabled{background:#f4f6f8;color:#9aa6b2}\
.ovd-unit{font-size:12px;color:#657585;white-space:nowrap}\
.ovd-note{font-size:11.5px;color:#9aa6b2;line-height:1.6;margin-top:6px;max-width:470px}\
.ovd-warn{font-size:12px;color:#c94848;line-height:1.65;margin:0 0 8px;max-width:560px}\
.ovd-dtl-sec{padding:11px 0;border-bottom:1px solid #e9edf0}\
.ovd-dtl-sec:last-child{border-bottom:0}\
.ovd-dtl-sec h4{font-size:12px;font-weight:650;color:#657585;margin:0 0 4px}\
.ovd-dtl-row{display:flex;justify-content:space-between;align-items:baseline;gap:18px;padding:3px 0;font-size:12.5px;line-height:1.65}\
.ovd-dtl-k{color:#9aa6b2;flex:none}\
.ovd-dtl-v{text-align:right;color:#222a31;min-width:0;overflow-wrap:anywhere}\
.ovd-dtl-v.mono{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:12px}\
.ovd-lock-sub{font-size:12.5px;color:#657585;margin-top:6px}\
@media (max-width:900px){.ovd-stat-grid{grid-template-columns:repeat(4,1fr)}}\
@media (max-width:560px){.ovd-stat-grid{grid-template-columns:repeat(2,1fr)}.ovd-ap-grid{grid-template-columns:1fr}}\
';

function ensureOvdStyle() {
	if (document.getElementById('ovd-style')) return;
	var st = document.createElement('style');
	st.id = 'ovd-style';
	st.textContent = CSS;
	document.head.appendChild(st);
}

function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m];
	});
}

var TITLES = {
	online: _('在线客户端'),
	auth: _('已认证客户端'),
	unauth: _('未认证客户端'),
	preauth: _('免认证客户端'),
	trusted: _('可信任客户端'),
	blacklist: _('黑名单')
};

var LIMIT_ROWS = [
	{ k: 'maxSession', arg: 'sessiontimeout', label: _('连接时长限制'), unit: _('分钟'), ph: '0' },
	{ k: 'uploadRate', arg: 'uploadrate', label: _('上传速度限制'), unit: 'kb/s', ph: '0' },
	{ k: 'downloadRate', arg: 'downloadrate', label: _('下载速度限制'), unit: 'kb/s', ph: '0' },
	{ k: 'uploadQuota', arg: 'uploadquota', label: _('上传流量限制'), unit: 'kB', ph: '0' },
	{ k: 'downloadQuota', arg: 'downloadquota', label: _('下载流量限制'), unit: 'kB', ph: '0' }
];

return view.extend({
	load: function () {
		return L.require('opennds_cpd.common').then(function (m) { CPD = m; });
	},

	render: function () {
		ensureOvdStyle();
		CPD.style();

		var state = {
			running: false, enabled: false, engaged: 1, busy: 0, scope: 'default',
			counts: {}, managed: { iface: '', ip: '' }, aps: [],
			clients: [],
			filter: 'online', ap: null, query: '', fupEnabled: true,
			confErr: '',
			sortKey: null, sortDir: 1
		};
		var locked = false, lockTimer = null, pollTimer = null, modalOpen = 0;
		var editRow = null;

		var body = E('div', { 'class': 'ovd-page' });

		/* ---------- 应用弹窗（openwrt 原生样式：ui.showModal + 自旋指示器） ---------- */
		var lockSubText = '';
		var nativeModalShown = false;

		function lockModalBody() {
			return [
				E('p', { 'class': 'spinning' }, _('正在应用…')),
				E('p', { 'class': 'ovd-lock-sub' }, lockSubText)
			];
		}

		function ensureNativeModal() {
			if (nativeModalShown) return;
			nativeModalShown = true;
			/* CPD.modal 内部处理了 LuCI 24.10 showModal 参数变化，统一入口 */
			CPD.modal('', lockModalBody());
		}

		function lock(secs) {
			locked = true;
			lockSubText = _('预计还需 %s 秒').format(String(secs));
			ensureNativeModal();
			if (lockTimer) window.clearInterval(lockTimer);
			var remain = secs;
			lockTimer = window.setInterval(function () {
				remain--;
				lockSubText = _('预计还需 %s 秒').format(String(remain < 0 ? 0 : remain));
				if (!nativeModalShown) return;
				ui.hideModal();
				CPD.modal('', lockModalBody());
			}, 1000);
		}

		function unlock() {
			locked = false;
			if (lockTimer) { window.clearInterval(lockTimer); lockTimer = null; }
			nativeModalShown = false;
			if (typeof ui !== 'undefined' && typeof ui.hideModal === 'function') ui.hideModal();
		}

		/* ---------- 通用操作执行（锁定 → 接口 → 解锁） ---------- */
		function runOp(secs, fn, opts) {
			if (locked) return;
			lock(secs);
			fn().then(function (j) {
				if (j && j.error === 'busy') {
					unlock();
					CPD.toast(_('等待上一步完成，请稍候重试'), 'warn');
					return;
				}
				if (!j || !j.ok) {
					unlock();
					CPD.toast((j && j.error) || _('操作失败'), 'err');
					return;
				}
				unlock();
				if (opts && opts.onok) opts.onok(j);
			}, function (e) {
				unlock();
				CPD.toast((e && e.error) || _('操作失败'), 'err');
			});
		}

		/* ---------- 顶部提示条（busy；「未接管」横幅已按用户要求移除） ---------- */
		var warnbar = E('div', { 'class': 'cpd-warnbar', 'style': 'display:none' }, '');

		function renderWarnbar() {
			if (state.busy) {
				warnbar.textContent = _('等待上一步完成，请稍候重试');
				warnbar.style.display = '';
			} else {
				warnbar.style.display = 'none';
			}
			renderConfBar();
		}

		/* 配置解析失败：uci 读写都会失败，必须直说 */
		var confBar = E('div', { 'class': 'cpd-warnbar', 'style': 'display:none' });

		function renderConfBar() {
			if (!confBar) return;
			if (!state.confErr) {
				confBar.style.display = 'none';
				return;
			}
			confBar.innerHTML = '';
			confBar.appendChild(E('span', {},
				_('openNDS 配置文件无法解析，读取与写入都会失败：%s。请先在 SSH 里修复 /etc/config/opennds（uci show opennds 可看到具体行号）。')
					.format(state.confErr)));
			confBar.style.display = '';
		}

		/* ---------- 数据拉取与 10 秒轮询 ----------
		 * 只发一个 dashboard 请求：后端一次解析 ndsctl、一次读 uci，
		 * 状态与客户端列表一起回来（之前两个请求串行，首屏要等两轮）。
		 * 另外两条规矩：
		 * ① 上一轮没回来就不发下一轮（否则请求会越积越多）；
		 * ② 失败只占一条通知栏、同一原因不重复弹。 */
		var refreshing = false;
		var offTimer = null;
		var loaded = false;

		function applyStatus(st) {
			if (!st || !st.ok) return;
			state.enabled = st.enabled === 1;
			state.engaged = st.engaged;
			state.busy = st.busy;
			state.fupEnabled = (st.fupEnabled === 1 || st.fupEnabled === true);
			state.scope = st.session_scope || 'default';
			state.counts = st.counts || {};
			state.managed = st.managed || { iface: '', ip: '' };
			state.aps = st.aps || [];
			state.confErr = st.confErr || '';

			if (st.running === 1) {
				if (offTimer) { window.clearTimeout(offTimer); offTimer = null; }
				state.running = true;
				return;
			}
			/* 刚变成「未运行」：procd 重启 openNDS 时进程会短暂消失，一次轮询
			 * 撞上就翻红会来回闪。1.2 秒后复核一次，仍是未运行才真的翻红。 */
			if (state.running && !offTimer) {
				offTimer = window.setTimeout(function () {
					offTimer = null;
					CPD.api('overview', 'run_state').then(function (j) {
						if (j && j.ok) {
							state.running = (j.running === 1);
							renderStatus();
						}
					}).catch(function () {});
				}, 1200);
				return;
			}
			state.running = false;
		}

		function renderAllSafe() {
			/* 任何一段渲染抛异常都不能连累后面的区块 */
			[renderStatus, renderWarnbar, renderStats, renderIface, renderAps, renderList]
				.forEach(function (fn) {
					try { fn(); } catch (e) {
						if (window.console && console.error) console.error('[opennds-cpd] render', e);
					}
				});
		}

		function refresh() {
			if (refreshing) return Promise.resolve();
			refreshing = true;
			return CPD.api('overview', 'dashboard').then(function (st) {
				refreshing = false;
				CPD.clearOnce();
				applyStatus(st);
				state.clients = (st && st.clients) || [];
				loaded = true;
				renderAllSafe();
			}, function (e) {
				refreshing = false;
				/* 同一原因只占一条通知栏，恢复后自动清掉 */
				CPD.notifyOnce(CPD.errText(e, _('获取概览数据失败')), 'err');
			});
		}

		pollTimer = window.setInterval(function () {
			if (!locked && !modalOpen) refresh();
		}, 10000);

		/* ---------- 运行状态 ---------- */
		var statusDot = E('span', { 'class': 'ovd-dot', 'aria-hidden': 'true' });
		var statusText = E('span', { 'class': 'ovd-status-text', 'role': 'status' }, '');
		var runSwitch = E('button', {
			'class': 'ovd-switch', 'type': 'button', 'role': 'switch',
			'aria-checked': 'false', 'aria-label': _('openNDS 运行状态开关'),
			'click': handleSwitch
		}, E('span', { 'class': 'knob', 'aria-hidden': 'true' }));
		var restartLabel = E('span', {}, _('重启'));
		var restartBtn = E('button', {
			'class': 'cbi-button', 'type': 'button', 'click': handleRestart
		}, [
			E('img', {
				'src': 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 24 24%22 fill=%22none%22 stroke=%22currentColor%22 stroke-width=%222%22 stroke-linecap=%22round%22%3E%3Cpath d=%22M21 12a9 9 0 1 1-2.64-6.36%22/%3E%3Cpath d=%22M21 3v6h-6%22/%3E%3C/svg%3E',
				'style': 'width:13px;height:13px', 'alt': ''
			}),
			restartLabel
		]);

		function renderStatus() {
			if (!loaded) {
				/* 首屏数据还没回来：不要先亮一下「未运行」再变绿 */
				statusDot.className = 'ovd-dot';
				statusText.className = 'ovd-status-text pending';
				statusText.textContent = _('读取中…');
				runSwitch.setAttribute('aria-checked', 'false');
				return;
			}
			var on = state.running;
			statusDot.className = 'ovd-dot' + (on ? '' : ' off');
			statusText.className = 'ovd-status-text' + (on ? '' : ' off');
			statusText.textContent = on ? _('运行') : _('未运行');
			runSwitch.setAttribute('aria-checked', on ? 'true' : 'false');
		}

		function doSetRun(want) {
			/* 后端启动要等 openNDS 就绪（最长约 10 秒）+ init.d 开销，锁要留够 */
			runOp(30, function () {
				return CPD.api('overview', 'set_run', [want]);
			}, {
				onok: function (j) {
					state.running = j.running === 1;
					state.enabled = j.enabled === 1;
					renderStatus();
					if (String(j.running) === want) {
						/* 3 秒自动消失，不用手动点叉 */
						CPD.notifyTimed(want === '1' ? _('openNDS 已启动') : _('openNDS 已停止'),
							want === '1' ? 'ok' : 'warn', 3000);
					} else {
						CPD.toast(_('操作未完全生效，请查看 openNDS 日志'), 'err');
					}
					refresh();
				}
			});
		}

		function handleSwitch() {
			if (locked) return;
			var want = state.running ? '0' : '1';
			if (want === '0') {
				CPD.confirm(_('停用 openNDS'), _(
					'停用后 openNDS 立即退出：门户页面消失，免认证、可信任、黑名单、' +
					'限速全部失效，所有设备将直接上网。确定停用？'), _('确定停用'), true,
					function () { doSetRun('0'); });
			} else {
				doSetRun('1');
			}
		}

		function pollReady(cb) {
			var tries = 0;
			var t = window.setInterval(function () {
				tries++;
				CPD.api('overview', 'run_state').then(function (j) {
					if (j && j.ok && j.running === 1) {
						window.clearInterval(t);
						cb(true);
					} else if (tries >= 20) {
						window.clearInterval(t);
						cb(false);
					}
				}, function () {
					if (tries >= 20) { window.clearInterval(t); cb(false); }
				});
			}, 1000);
		}

		function handleRestart() {
			if (locked) return;
			lock(15);
			restartBtn.disabled = true;
			runSwitch.disabled = true;
			restartLabel.textContent = _('重启中…');
			CPD.api('overview', 'restart').then(function (j) {
				if (j && j.error === 'busy') {
					unlock();
					restartBtn.disabled = false;
					runSwitch.disabled = false;
					restartLabel.textContent = _('重启');
					CPD.toast(_('等待上一步完成，请稍候重试'), 'warn');
					return;
				}
				if (!j || !j.ok) {
					unlock();
					restartBtn.disabled = false;
					runSwitch.disabled = false;
					restartLabel.textContent = _('重启');
					CPD.toast((j && j.error) || _('重启失败'), 'err');
					return;
				}
				/* 返回 0 只代表脚本跑完；1 秒一次轮询 run_state（锁定期间唯一允许的后台请求） */
				pollReady(function (ready) {
					unlock();
					restartBtn.disabled = false;
					runSwitch.disabled = false;
					restartLabel.textContent = _('重启');
					if (ready) {
						CPD.notifyTimed(_('openNDS 已重启'), 'ok', 3000);
					} else {
						CPD.toast(_('openNDS 未能在 20 秒内就绪，请查看 openNDS 日志'), 'err');
					}
					refresh();
				});
			}, function (e) {
				unlock();
				restartBtn.disabled = false;
				runSwitch.disabled = false;
				restartLabel.textContent = _('重启');
				CPD.toast((e && e.error) || _('重启失败'), 'err');
			});
		}

		/* ---------- 分类与筛选（黑名单 > 可信任 > 免认证 > 已认证 > 未认证） ----------
		 * "在线" = 有访问权限的在线客户端（已认证 / 免认证已登录 / 可信任）；
		 * 还没通过认证的单独归"未认证"。计数与列表用的是后端同一组标记
		 * （online / authorized），不会出现卡片数与列表条数对不上。 */
		function isOnline(c) { return !!c.online; }

		function inFilter(c) {
			var online = !!c.online;
			switch (state.filter) {
				case 'blacklist':
					return !!c.blocked;
				case 'trusted':
					return !!c.trusted;
				case 'preauth':
					/* 名单内且已登录算免认证 */
					return online && !!c.preauth && !!c.authenticated && !c.trusted && !c.blocked;
				case 'auth':
					return online && !!c.authenticated && !c.trusted && !c.preauth && !c.blocked;
				case 'unauth':
					return online && !c.authorized && !c.blocked;
				default: /* online */
					return online && !!c.authorized && !c.blocked;
			}
		}

		function normSearch(v) {
			return String(v == null ? '' : v).toLowerCase()
				.replace(/[^a-z0-9\u4e00-\u9fff]/g, '');
		}

		function ipSortValue(ip) {
			var p = String(ip || '').split('.'), n = 0;
			for (var i = 0; i < 4; i++) n = n * 256 + (Number(p[i]) || 0);
			return n;
		}

		/* 接入点一列显示 SSID。后端已经把运行时接口对应的 SSID 一并给了（c.ssid），
		 * 这里再兜一层：接口名 → AP 卡片 → SSID。 */
		function apName(iface) {
			if (!iface) return '—';
			for (var i = 0; i < state.aps.length; i++) {
				if (state.aps[i].iface === iface && state.aps[i].ssid) return state.aps[i].ssid;
			}
			if (iface === state.managed.iface) return iface + _('（有线）');
			return iface;
		}

		/* AP 卡片的唯一键：uci section 名是唯一的，放最前面——
		 * 运行时接口名（phyN-apM）在 ubus 解析失败时可能两张卡拿到同一个值，
		 * 之前就出现过点一张卡两张同时选中的联动 */
		function apKey(a) { return a.section || a.iface || a.ssid || ''; }

		function apLabel(key) {
			for (var i = 0; i < state.aps.length; i++) {
				if (apKey(state.aps[i]) === key) return state.aps[i].ssid || key;
			}
			return key;
		}

		function clientAp(c) {
			if (c.ssid) return c.ssid;
			return apName(c.iface);
		}

		/* 按接入点筛选客户端：openNDS 的 clientif（get_client_interface.sh）
		 * 在没装 iw 的机器上是 br-lan 这类网桥名，和 AP 卡片的运行时接口名
		 * （phyN-apM）对不上——所以先按后端按 MAC 反查关联表得到的 SSID 比，
		 * SSID 缺失时再退回接口名比对 */
		function apFilterMatch(c) {
			if (!state.ap) return true;
			for (var i = 0; i < state.aps.length; i++) {
				var a = state.aps[i];
				if (apKey(a) !== state.ap) continue;
				/* 段名最准：同一 SSID 同时开在 2.4G/5G 上是两个段、两张卡片 */
				if (a.section && c.apsec) return c.apsec === a.section;
				if (a.ssid && c.ssid) return c.ssid === a.ssid;
				return !!a.iface && !!c.iface && c.iface === a.iface;
			}
			return c.ssid === state.ap || c.iface === state.ap;
		}

		function filteredClients() {
			var b = state.clients.filter(inFilter).filter(apFilterMatch);
			var q = normSearch(state.query);
			if (q) {
				b = b.filter(function (c) {
					return normSearch(c.host).indexOf(q) >= 0 ||
						normSearch(c.ip).indexOf(q) >= 0 ||
						normSearch(c.mac).indexOf(q) >= 0;
				});
			}
			if (!state.sortKey) return b;
			var key = state.sortKey, dir = state.sortDir;
			return b.slice().sort(function (a, b2) {
				var va, vb;
				if (key === 'ip') { va = ipSortValue(a.ip); vb = ipSortValue(b2.ip); }
				else if (key === 'ap') { va = clientAp(a); vb = clientAp(b2); }
				else { va = a[key] || ''; vb = b2[key] || ''; }
				if (typeof va === 'number' && typeof vb === 'number') return (va - vb) * dir;
				return String(va).localeCompare(String(vb), 'zh-CN', { numeric: true }) * dir;
			});
		}

		/* ---------- 渲染：统计卡片 ---------- */
		var statGrid = E('div', { 'class': 'ovd-stat-grid' });

		function renderStats() {
			var n = state.counts;
			var defs = [
				{ k: 'online', label: _('在线客户端'), num: n.online },
				{ k: 'auth', label: _('已认证客户端'), num: n.authenticated },
				{ k: 'preauth', label: _('免认证客户端'), num: n.preauth },
				{ k: 'trusted', label: _('可信任客户端'), num: n.trusted },
				{ k: 'unauth', label: _('未认证客户端'), num: n.unauthenticated },
				{ k: 'blacklist', label: _('黑名单'), num: n.blacklist }
			];
			var h = '';
			defs.forEach(function (d) {
				var sel = (state.filter === d.k) ? ' selected' : '';
				h += '<button type="button" class="ovd-stat' + sel + '" data-filter="' + d.k +
					'" aria-pressed="' + (state.filter === d.k ? 'true' : 'false') + '">' +
					'<span class="ovd-num">' + (d.num == null ? 0 : d.num) + '</span>' +
					'<span class="ovd-slabel">' + esc(d.label) + '</span></button>';
			});
			h += '<div class="ovd-stat static"><span class="ovd-num">' +
				(n.maxclients == null ? 0 : n.maxclients) + '</span>' +
				'<span class="ovd-slabel">' + _('最大客户端') + '</span></div>';
			statGrid.innerHTML = h;
			statGrid.querySelectorAll('[data-filter]').forEach(function (b) {
				b.addEventListener('click', function () {
					goFilter(b.getAttribute('data-filter'));
				});
			});
		}

		function goFilter(k) {
			state.filter = k;
			state.ap = null;
			renderStats();
			renderAps();
			renderList();
			scrollToClients();
		}

		function scrollToClients() {
			var el = clientsSec;
			if (el && el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
		}

		/* ---------- 渲染：网络接口 ---------- */
		var ifaceGrid = E('div', { 'class': 'ovd-iface-grid' });

		function renderIface() {
			var m = state.managed;
			var name = m.iface || '—';
			ifaceGrid.innerHTML = '';
			ifaceGrid.appendChild(E('div', { 'class': 'ovd-card' }, [
				E('div', { 'class': 'ovd-iface-name ovd-mono' }, name),
				E('div', { 'class': 'ovd-info-row' }, [
					E('span', {}, _('IP 地址')),
					E('b', { 'class': 'ovd-mono' }, m.ip || '—')
				]),
				E('div', { 'class': 'ovd-info-row' }, [
					E('span', {}, _('当前管理状态')),
					E('b', {}, state.running ? _('正在管理') : _('未管理'))
				])
			]));
		}

		/* ---------- 渲染：无线接入点 ---------- */
		var apGrid = E('div', { 'class': 'ovd-ap-grid' });

		function renderAps() {
			var h = state.aps.map(function (a) {
				var key = apKey(a);
				var sel = (state.ap === key) ? ' selected' : '';
				return '<button type="button" class="ovd-card ovd-ap' + sel +
					'" data-ap="' + esc(key) + '" aria-pressed="' +
					(state.ap === key ? 'true' : 'false') + '">' +
					'<div class="ovd-ap-name">' + esc(a.ssid || '—') + '</div>' +
					'<div class="ovd-ap-count"><span class="ovd-ap-count-num">' +
					(a.count == null ? 0 : a.count) + '</span>' +
					'<span class="ovd-ap-count-label">' + _('已连接客户端') + '</span></div>' +
					'</button>';
			}).join('');
			apGrid.innerHTML = h || '<div class="ovd-count">' + _('暂无启用的无线接入点') + '</div>';
			apGrid.querySelectorAll('[data-ap]').forEach(function (b) {
				b.addEventListener('click', function () {
					var key = b.getAttribute('data-ap');
					state.ap = (state.ap === key) ? null : key;
					state.filter = 'online';
					renderStats();
					renderAps();
					renderList();
					scrollToClients();
				});
			});
		}

		/* ---------- 渲染：客户端列表 ---------- */
		var clientsSec = E('div', { 'class': 'ovd-sec', 'id': 'ovd-clients', 'style': 'scroll-margin-top:14px' });
		var listTitle = E('h3', {}, '');
		var listCount = E('span', { 'class': 'ovd-count' }, '');
		var searchInput = E('input', {
			'class': 'ovd-search', 'type': 'search',
			'placeholder': _('搜索主机名、IP 地址或 MAC 地址'),
			'aria-label': _('搜索客户端'), 'autocomplete': 'off'
		});
		var tbody = E('tbody', {});
		var headRow = E('tr', {}, [
			E('th', { 'data-key': 'host' }, sortBtn('host', _('主机名'))),
			E('th', { 'data-key': 'ip' }, sortBtn('ip', _('IP 地址'))),
			E('th', { 'data-key': 'mac' }, sortBtn('mac', _('MAC 地址'))),
			E('th', { 'data-key': 'ap' }, sortBtn('ap', _('接入点'))),
			E('th', {}, _('操作'))
		]);

		function sortBtn(key, label) {
			return E('button', {
				'type': 'button', 'class': 'ovd-sortbtn', 'data-sort': key,
				'click': function () { setSort(key); }
			}, [label, E('span', { 'class': 'ovd-arrow', 'aria-hidden': 'true' }, '')]);
		}

		function setSort(key) {
			if (state.sortKey === key) state.sortDir = -state.sortDir;
			else { state.sortKey = key; state.sortDir = 1; }
			renderList();
		}

		function updateSortUI() {
			headRow.querySelectorAll('[data-sort]').forEach(function (btn) {
				var on = (state.sortKey === btn.getAttribute('data-sort'));
				var arrow = btn.querySelector('.ovd-arrow');
				if (arrow) arrow.textContent = on ? (state.sortDir > 0 ? '↑' : '↓') : '';
				var th = btn.parentNode;
				if (th) th.setAttribute('aria-sort',
					on ? (state.sortDir > 0 ? 'ascending' : 'descending') : 'none');
			});
		}

		function tagOf(c) {
			if (c.blocked) return ['t-black', _('黑名单')];
			if (c.trusted) return ['t-trusted', _('可信任')];
			if (c.preauth && c.authenticated) return ['t-pre', _('免认证')];
			if (c.authenticated) return ['t-auth', _('已认证')];
			return ['t-unauth', _('未认证')];
		}

		function renderList() {
			var items = filteredClients();
			listTitle.textContent = TITLES[state.filter] || TITLES.online;
			listCount.textContent = _('共 %s 个').format(String(items.length)) +
				(state.ap ? ' · ' + _('接入点 %s').format(apLabel(state.ap)) : '');
			updateSortUI();

			if (!items.length) {
				tbody.innerHTML = '<tr><td colspan="5" class="ovd-empty">' +
					(loaded ? _('暂无符合条件的客户端') : _('读取中…')) + '</td></tr>';
				return;
			}

			var unauthView = (state.filter === 'unauth');
			var blackView = (state.filter === 'blacklist');
			var disView = unauthView || blackView;

			tbody.innerHTML = items.map(function (c) {
				var preAct = c.preauth ? 'unpreauth' : 'preauth';
				var preLabel = c.preauth ? _('移除免认证') : _('免认证');
				var trustAct = c.trusted ? 'untrust' : 'trust';
				var trustLabel = c.trusted ? _('移除可信任') : _('可信任客户端');
				var tg = tagOf(c);
				var tags = '<span class="ovd-tag ' + tg[0] + '">' + tg[1] + '</span>';
				/* 可信任整行特例：不渲染编辑/免认证，解除认证置灰（黑名单视图下置灰见 disView） */
				var editHTML = (c.trusted && !blackView) ? '' :
					'<button type="button" class="ovd-rowbtn" data-act="edit" data-mac="' + esc(c.mac) + '"' +
					(disView ? ' disabled' : '') + '>' + _('编辑') + '</button>';
				var deauthDis = (c.trusted || (!c.authenticated && !c.preauth)) ? ' disabled' : '';
				return '<tr>' +
					'<td><div class="ovd-host"><span class="ovd-host-name">' +
					esc(c.host || '—') + '</span><div class="ovd-tags">' + tags + '</div></div></td>' +
					'<td class="ovd-mono">' + esc(c.ip || '—') + '</td>' +
					'<td class="ovd-mono">' + esc(c.mac) + '</td>' +
					'<td>' + esc(clientAp(c)) + '</td>' +
					'<td><div class="ovd-acts">' +
					'<button type="button" class="ovd-rowbtn" data-act="detail" data-mac="' + esc(c.mac) + '"' +
					(disView ? ' disabled' : '') + '>' + _('详情') + '</button>' +
					'<button type="button" class="ovd-rowbtn" data-act="' + preAct + '" data-mac="' + esc(c.mac) + '"' +
					(blackView ? ' disabled' : '') + '>' + preLabel + '</button>' +
					'<button type="button" class="ovd-rowbtn" data-act="' + trustAct + '" data-mac="' + esc(c.mac) + '"' +
					(blackView ? ' disabled' : '') + '>' + trustLabel + '</button>' +
					editHTML +
					'<button type="button" class="ovd-rowbtn danger" data-act="deauth" data-mac="' + esc(c.mac) + '"' +
					deauthDis + '>' + _('解除认证') + '</button>' +
					'<button type="button" class="ovd-rowbtn' + (blackView ? '' : ' danger') +
					'" data-act="' + (blackView ? 'unblock' : 'block') + '" data-mac="' + esc(c.mac) + '">' +
					(blackView ? _('解除拉黑') : _('拉黑')) + '</button>' +
					'</div></td></tr>';
			}).join('');

			tbody.querySelectorAll('[data-act]').forEach(function (b) {
				b.addEventListener('click', function () {
					if (locked) return;
					var act = b.getAttribute('data-act');
					var mac = b.getAttribute('data-mac');
					var row = state.clients.filter(function (c) { return c.mac === mac; })[0];
					if (!row) return;
					if (act === 'detail') openDetail(row);
					else if (act === 'edit') openEdit(row);
					else askAction(act, row);
				});
			});
		}

		/* ---------- 行内操作（二次确认文案照演示页） ---------- */
		var CONFIRM_TEXT = {
			preauth: {
				title: _('免认证'),
				msg: function (h) {
					return _('将「%s」设为免认证（预先认证）后，它无需经过普通认证流程即可获得访问权限，但仍受 NDS 的流量统计和相关限制。').format(h);
				},
				ok: _('免认证'), danger: false
			},
			unpreauth: {
				title: _('移除免认证'),
				msg: function (h) {
					return _('确定要移除「%s」的免认证吗？移除后它将恢复为普通未认证客户端，需要重新认证才能访问网络。').format(h);
				},
				ok: _('移除免认证'), danger: false
			},
			trust: {
				title: _('可信任客户端'),
				msg: function (h) {
					return _('将「%s」设为可信任客户端后，它无需普通认证流程，且不受 NDS 的流量统计和超时限制。').format(h);
				},
				ok: _('可信任'), danger: false
			},
			untrust: {
				title: _('移除可信任'),
				msg: function (h) {
					return _('确定要移除「%s」的可信任状态吗？移除后它将重新受 NDS 的流量统计和超时限制。').format(h);
				},
				ok: _('移除可信任'), danger: false
			},
			deauth: {
				title: _('解除认证'),
				msg: function (h) {
					return _('确定要解除「%s」的认证吗？解除后该客户端需要重新认证才能访问网络。').format(h);
				},
				ok: _('解除认证'), danger: true
			},
			block: {
				title: _('拉黑客户端'),
				msg: function (h) {
					return _('确定要拉黑「%s」吗？拉黑后该客户端将无法访问网络，并从在线列表中移除。').format(h);
				},
				ok: _('拉黑'), danger: true
			},
			unblock: {
				title: _('解除拉黑'),
				msg: function (h) {
					return _('确定要将「%s」移出黑名单吗？解除后该客户端可以重新接入网络。').format(h);
				},
				ok: _('解除拉黑'), danger: false
			}
		};

		/* 断开 / 拉黑二次确认后立即生效；其余动作只写增量，等 openwrt「保存并应用」 */
		var ACTION_TOAST = {
			preauth: _('让「%s」免认证'),
			unpreauth: _('取消「%s」的免认证'),
			trust: _('把「%s」设为可信任客户端'),
			untrust: _('取消「%s」的可信任状态'),
			deauth: _('已断开「%s」'),
			block: _('已拉黑「%s」'),
			unblock: _('把「%s」移出黑名单')
		};
		/* 这两个是即时动作：不走暂存、不等「保存并应用」 */
		var ACTION_IMMEDIATE = { deauth: true, block: true };

		function askAction(act, row) {
			var d = CONFIRM_TEXT[act];
			if (!d) return;
			/* 一个客户端只能属于一个名单：黑名单里的必须先解除拉黑 */
			if (row.blocked && (act === 'trust' || act === 'preauth')) {
				CPD.notify(_('该客户端在黑名单中，请先解除拉黑'), 'warn');
				return;
			}
			var h = row.host || row.mac;
			/* 即时动作（断开 / 拉黑）确认后立刻执行；其余动作要说明「还需点保存并应用」 */
			var msg = d.msg(h);
			if (!ACTION_IMMEDIATE[act])
				msg += ' ' + _('该操作先记为待应用，点页面底部的「保存并应用」后生效。');
			CPD.confirm(d.title, msg, d.ok, d.danger, function () {
				performAction(act, row);
			});
		}

		/* 只暂存的动作：直接把结果名单交给 openwrt 的 uci 增量（与其它页面同一条通道），
		 * 这样右上角一定会出现「未保存的配置: N」，点开就是原生 diff 弹窗 */
		function stageAction(act, mac) {
			var lm = String(mac || '').toLowerCase();
			function low(x) { return String(x || '').toLowerCase(); }
			function macOf(e) { return low(String(e).split(';')[0].replace(/^mac=/i, '')); }
			if (act === 'unblock') {
				return CPD.api('blacklist', 'status').then(function (j) {
					var list = (j.macs || []).filter(function (m) { return low(m) !== lm; });
					return CPD.stageUci('opennds', '@opennds[0]', 'blockedmac', 'list', list);
				});
			}
			return CPD.api('exempt', 'status').then(function (j) {
				var tr = (j.trusted || []).map(low);
				var pre = (j.preempt || []).map(function (e) {
					return { mac: macOf(e), raw: String(e) };
				});
				if (act === 'trust') {
					tr = tr.filter(function (m) { return m !== lm; }).concat([lm]);
					pre = pre.filter(function (e) { return e.mac !== lm; });
				} else if (act === 'untrust') {
					tr = tr.filter(function (m) { return m !== lm; });
				} else if (act === 'preauth') {
					tr = tr.filter(function (m) { return m !== lm; });
					if (!pre.some(function (e) { return e.mac === lm; }))
						pre = pre.concat([{ mac: lm, raw: 'mac=' + lm.toUpperCase() +
							';sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0' }]);
				} else if (act === 'unpreauth') {
					pre = pre.filter(function (e) { return e.mac !== lm; });
				}
				return CPD.stageUci('opennds', '@opennds[0]', 'trustedmac', 'list', tr)
					.then(function () {
						return CPD.stageUci('opennds', '@opennds[0]', 'preemptivemac', 'list',
							pre.map(function (e) { return e.raw; }));
					});
			});
		}

		function performAction(act, row) {
			var h = row.host || row.mac;
			var immediate = !!ACTION_IMMEDIATE[act];
			if (!immediate) {
				/* 只暂存：不弹任何横幅，右上角「未保存的配置」就是反馈 */
				stageAction(act, row.mac).then(function () {
					refresh();
				}, function (e) {
					CPD.notify(CPD.errText(e, _('记录失败')), 'err');
				});
				return;
			}
			/* 断开 / 拉黑：不受 openwrt 三个按钮控制，二次确认后立即生效 */
			runOp(act === 'block' ? 15 : 5, function () {
				return CPD.api('overview', 'client_action', [act, row.mac]);
			}, {
				onok: function (j) {
					/* 无 DHCP 租约等 warnings：只显示 warn，不报成功 */
					if (j.warnings && j.warnings.length) {
						CPD.showWarnings(j.warnings);
						refresh();
						return;
					}
					CPD.clearNotice();
					CPD.notify(ACTION_TOAST[act].format(h), act === 'block' ? 'warn' : 'ok');
					refresh();
				}
			});
		}

		/* ---------- 编辑弹窗（5 项限制；「确定」只暂存，落盘交给 openwrt「保存并应用」） ---------- */
		var editMask = E('div', { 'class': 'ovd-mask' }, E('div', {
			'class': 'ovd-dialog', 'role': 'dialog', 'aria-modal': 'true'
		}, [
			E('div', { 'class': 'ovd-dhead' }, [
				E('h3', {}, _('客户端编辑')),
				E('span', { 'class': 'ovd-dsub', 'id': 'ovd-ed-sub' }, '')
			]),
			E('div', { 'class': 'ovd-dbody', 'id': 'ovd-ed-body' }),
			E('div', { 'class': 'ovd-dfoot' }, [
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': cancelEdit }, _('取消')),
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-positive', 'click': saveEdit }, _('确定'))
			])
		]));
		var editInputs = {};

		function limitRowEd(row) {
			var inp = E('input', {
				'type': 'number', 'min': '0', 'step': '1',
				'placeholder': row.ph, 'data-v': row.k
			});
			editInputs[row.k] = { input: inp, row: row };
			return E('div', { 'class': 'ovd-ed-row' }, [
				E('div', { 'class': 'ovd-ed-label' }, row.label),
				E('div', { 'class': 'ovd-ed-ctrl' }, [
					E('div', { 'class': 'ovd-limit-input' }, [
						inp,
						E('span', { 'class': 'ovd-unit' }, row.unit)
					]),
					E('p', { 'class': 'ovd-note' }, _('设置值为 0 时表示不限制。'))
				])
			]);
		}

		function openEdit(row) {
			editRow = row;
			editInputs = {};
			var sub = document.getElementById('ovd-ed-sub');
			if (sub) sub.textContent = (row.host || '—') + ' · ' + (row.ip || '—') + ' · ' + row.mac;
			var edBody = document.getElementById('ovd-ed-body');
			edBody.innerHTML = '';

			var timeSec = E('div', { 'class': 'ovd-dsec' }, [
				E('h4', {}, _('连接时间')),
				limitRowEd(LIMIT_ROWS[0]),
				E('p', { 'class': 'ovd-note' }, _('设置该客户端允许保持登录状态的最长时间。'))
			]);
			var speedSec = E('div', { 'class': 'ovd-dsec' }, [
				E('h4', {}, _('网络速度')),
				limitRowEd(LIMIT_ROWS[1]),
				limitRowEd(LIMIT_ROWS[2]),
				E('p', { 'class': 'ovd-note' }, _('上传与下载速度分别独立设置，可只限制其中一个方向。'))
			]);
			/* 流量限制：公平使用策略没开启时不允许编辑（输入框置灰）+ 红字说明；
			 * 开启后红字消失、输入框可编辑。不用灰蒙层盖住 —— 蒙层会把数值一起
			 * 挡住，用户看不出当前设置是多少。 */
			var quotaSec = E('div', { 'class': 'ovd-dsec' }, [
				E('h4', {}, _('流量限制'))
			]);
			if (!state.fupEnabled) {
				quotaSec.appendChild(E('p', { 'class': 'ovd-warn' },
					_('请先到设置页开启并配置“公平使用策略”。')));
			}
			quotaSec.appendChild(limitRowEd(LIMIT_ROWS[3]));
			quotaSec.appendChild(limitRowEd(LIMIT_ROWS[4]));
			if (!state.fupEnabled) {
				[LIMIT_ROWS[3], LIMIT_ROWS[4]].forEach(function (row) {
					var e = editInputs[row.k];
					if (e && e.input) e.input.disabled = true;
				});
			}
			edBody.appendChild(timeSec);
			edBody.appendChild(speedSec);
			edBody.appendChild(quotaSec);

			LIMIT_ROWS.forEach(function (row) {
				var v = (editRow.limits && editRow.limits[row.k]) ?
					String(editRow.limits[row.k].value || '0') : '0';
				editInputs[row.k].input.value = (v === '0') ? '' : v;
			});

			/* 「覆盖」模式：所有客户端会话时长统一跟随全局 → 连接时间置灰、应用时写 0 */
			if (state.scope === 'override') {
				var mi = editInputs.maxSession.input;
				mi.disabled = true;
				mi.value = '';
				timeSec.appendChild(E('p', { 'class': 'ovd-note' }, _(
					'当前为「覆盖」模式：所有客户端的会话时长统一跟随「客户端会话管理」页的全局设置')));
			}

			editMask.classList.add('on');
			modalOpen++;
		}

		function closeEdit() {
			editMask.classList.remove('on');
			editRow = null;
			if (modalOpen > 0) modalOpen--;
		}

		function cancelEdit() {
			closeEdit();
			CPD.toast(_('已取消编辑，未应用本次修改'));
		}

		/* 单客户端限额：改写 preemptivemac 里该 MAC 的条目（custom= 原样保留）。
		 * 与其它页面共用同一条 uci 增量通道，保存后右上角出现「未保存的配置」。 */
		function stageEditLimits(lm, v) {
			function macOf(e) { return String(e).split(';')[0].replace(/^mac=/i, '').toLowerCase(); }
			return CPD.api('exempt', 'status').then(function (j) {
				var found = false;
				var out = (j.preempt || []).map(function (e) {
					if (macOf(e) !== lm) return String(e);
					found = true;
					var custom = '';
					var m = /;custom=([\s\S]*)$/.exec(String(e));
					if (m) custom = ';custom=' + m[1];
					return 'mac=' + lm + ';sessiontimeout=' + v.sessiontimeout +
						';uploadrate=' + v.uploadrate + ';downloadrate=' + v.downloadrate +
						';uploadquota=' + v.uploadquota + ';downloadquota=' + v.downloadquota + custom;
				});
				if (!found) throw { error: _('该客户端不在授权名单里，无法设置单独限制') };
				return CPD.stageUci('opennds', '@opennds[0]', 'preemptivemac', 'list', out);
			});
		}

		function saveEdit() {
			if (!editRow) return;
			var args = { mac: editRow.mac };
			var order = ['maxSession', 'uploadRate', 'downloadRate', 'uploadQuota', 'downloadQuota'];
			for (var i = 0; i < order.length; i++) {
				var ed = editInputs[order[i]];
				var v = String(ed.input.value == null ? '' : ed.input.value).trim();
				if (ed.row.k === 'maxSession' && state.scope === 'override') v = '0';
				/* 公平使用策略未开启：配额区不可编辑，按 0 提交，避免带上被蒙层的旧值 */
				if (!state.fupEnabled && (ed.row.k === 'uploadQuota' || ed.row.k === 'downloadQuota')) v = '0';
				if (v === '') v = '0';
				if (!/^[0-9]+$/.test(v)) {
					CPD.toast(_('请填写不小于 0 的「%s」数值（%s），0 表示不限制')
						.format(ed.row.label, ed.row.unit), 'warn');
					return;
				}
				args[ed.row.arg] = v;
			}
			var mac = editRow.mac;
			var lm = String(mac || '').toLowerCase();
			stageEditLimits(lm, args).then(function () {
				closeEdit();
				/* 编辑框下的「确定」只写 uci 增量，不 commit、不重启；
				   反馈就是右上角「未保存的配置」，不弹任何横幅 */
				refresh();
			}, function (e) {
				CPD.notify(CPD.errText(e, _('记录失败')), 'err');
			});
		}

		/* ---------- 详情弹窗（只读） ---------- */
		var detailMask = E('div', { 'class': 'ovd-mask' }, E('div', {
			'class': 'ovd-dialog dtl', 'role': 'dialog', 'aria-modal': 'true'
		}, [
			E('div', { 'class': 'ovd-dhead' }, [
				E('h3', {}, _('客户端详情')),
				E('span', { 'class': 'ovd-dsub', 'id': 'ovd-dtl-sub' }, '')
			]),
			E('div', { 'class': 'ovd-dbody', 'id': 'ovd-dtl-body' }),
			E('div', { 'class': 'ovd-dfoot' }, [
				E('button', { 'type': 'button', 'class': 'cbi-button', 'click': closeDetail }, _('关闭'))
			])
		]));

		function fmtTraffic(bytes) {
			var n = Number(bytes) || 0;
			if (n >= 1073741824) return String(Math.round(n / 1073741824 * 100) / 100) + ' GB';
			if (n >= 1048576) return String(Math.round(n / 1048576 * 10) / 10) + ' MB';
			if (n >= 1024) return String(Math.round(n / 1024 * 10) / 10) + ' KB';
			return n + ' B';
		}

		function limText(lim, trusted) {
			if (trusted) return _('不受限制');
			if (!lim || !lim.enabled) return _('未单独设置');
			return String(lim.value);
		}

		function dtlRow(k, v, mono) {
			return E('div', { 'class': 'ovd-dtl-row' }, [
				E('span', { 'class': 'ovd-dtl-k' }, k),
				E('span', { 'class': 'ovd-dtl-v' + (mono ? ' mono' : '') }, v)
			]);
		}

		function dtlSec(title, rows) {
			return E('div', { 'class': 'ovd-dtl-sec' }, [
				E('h4', {}, title)
			].concat(rows));
		}

		function openDetail(row) {
			var sub = document.getElementById('ovd-dtl-sub');
			if (sub) sub.textContent = (row.host || '—') + ' · ' + (row.ip || '—');
			var dtlBody = document.getElementById('ovd-dtl-body');
			var tr = !!row.trusted;
			var auth = row.preauth ? _('免认证') :
				(row.authenticated ? _('已认证') : _('未认证'));
			if (tr) auth += ' · ' + _('可信任');
			var expires;
			if (tr) expires = _('不受限制');
			else if (!row.authenticated) expires = '—';
			else expires = row.expires || '—';
			var timeout = tr ? _('不受限制') :
				(row.timeout ? String(row.timeout) : _('使用全局设置'));
			var lim = row.limits || {};

			dtlBody.innerHTML = '';
			dtlBody.appendChild(dtlSec(_('状态'), [
				dtlRow(_('拉黑状态'), row.blocked ? _('已拉黑') : _('未拉黑'))
			]));
			dtlBody.appendChild(dtlSec(_('基本信息'), [
				dtlRow(_('主机名'), row.host || '—'),
				dtlRow(_('IP 地址'), row.ip || '—', true),
				dtlRow(_('MAC 地址'), row.mac, true),
				dtlRow(_('接入点'), clientAp(row)),
				dtlRow(_('认证状态'), auth)
			]));
			dtlBody.appendChild(dtlSec(_('时间与超时'), [
				dtlRow(_('加入时间'), row.joined || '—'),
				dtlRow(_('到期时间'), expires),
				dtlRow(_('中断超时（分钟）'), timeout),
				dtlRow(_('最大会话时间（分钟）'), limText(lim.maxSession, tr))
			]));
			dtlBody.appendChild(dtlSec(_('速度限制'), [
				dtlRow(_('上传速度限制（Kb/s）'), limText(lim.uploadRate, tr)),
				dtlRow(_('下载速度限制（Kb/s）'), limText(lim.downloadRate, tr))
			]));
			dtlBody.appendChild(dtlSec(_('流量总量'), [
				dtlRow(_('上传总量'), tr ? _('不受限制') : fmtTraffic(row.trafficUp)),
				dtlRow(_('下载总量'), tr ? _('不受限制') : fmtTraffic(row.trafficDown))
			]));
			dtlBody.appendChild(dtlSec(_('超额限速'), [
				dtlRow(_('上传超额限速（Kb/s）'), limText(lim.overQuotaUploadRate, tr)),
				dtlRow(_('下载超额限速（Kb/s）'), limText(lim.overQuotaDownloadRate, tr))
			]));
			detailMask.classList.add('on');
		}

		function closeDetail() {
			detailMask.classList.remove('on');
		}

		detailMask.addEventListener('click', function (ev) {
			if (ev.target === detailMask) closeDetail();
		});

		document.addEventListener('keydown', function (ev) {
			if (ev.key !== 'Escape') return;
			if (editMask.classList.contains('on')) { closeEdit(); return; }
			if (detailMask.classList.contains('on')) closeDetail();
		});

		/* ---------- 搜索 ---------- */
		searchInput.addEventListener('input', function () {
			state.query = this.value;
			renderList();
		});
		searchInput.addEventListener('search', function () {
			state.query = this.value;
			renderList();
		});

		/* ---------- 组装页面 ---------- */
		body.appendChild(E('div', { 'class': 'cpd-head' },
			E('h2', {}, _('openNDS 概览'))));
		body.appendChild(warnbar);
		body.appendChild(confBar);

		body.appendChild(E('div', { 'class': 'ovd-sec' }, [
			E('h3', {}, _('状态')),
			E('div', { 'class': 'ovd-status-line' }, [
				statusDot, statusText, runSwitch, restartBtn
			])
		]));
		body.appendChild(E('hr', { 'class': 'ovd-divider' }));

		body.appendChild(E('div', { 'class': 'ovd-sec' }, [
			E('h3', {}, _('客户端统计')),
			statGrid
		]));
		body.appendChild(E('hr', { 'class': 'ovd-divider' }));

		body.appendChild(E('div', { 'class': 'ovd-sec' }, [
			E('h3', {}, _('网络接口')),
			ifaceGrid
		]));
		body.appendChild(E('hr', { 'class': 'ovd-divider' }));

		body.appendChild(E('div', { 'class': 'ovd-sec' }, [
			E('h3', {}, _('无线接入点')),
			apGrid
		]));
		body.appendChild(E('hr', { 'class': 'ovd-divider' }));

		clientsSec.appendChild(E('div', { 'class': 'ovd-listhead' }, [
			listTitle, listCount, searchInput
		]));
		clientsSec.appendChild(E('div', { 'class': 'ovd-tablewrap' },
			E('table', { 'class': 'ovd-tbl' }, [
				E('colgroup', {}, [
					E('col', { 'style': 'width:18%' }),
					E('col', { 'style': 'width:14%' }),
					E('col', { 'style': 'width:16%' }),
					E('col', { 'style': 'width:14%' }),
					E('col', { 'style': 'width:38%' })
				]),
				E('thead', {}, headRow),
				tbody
			])));
		body.appendChild(clientsSec);

		body.appendChild(editMask);
		body.appendChild(detailMask);

		/* 先把骨架画出来（标题、卡片、空表格立刻可见），数据回来再填。
		 * 之前整页要等两次后端请求才出现，看着像卡住了。 */
		renderAllSafe();
		refresh();

		/* ---------- LuCI 框架底部按钮：本页只有运行控制，配置写入只走暂存 ---------- */
		/* 本页没有需要「保存」的常驻配置项：保存 = 保持现状（增量已在编辑时写好） */
		this.handleSave = function () {
			return Promise.resolve();
		};
		/* 保存并应用：交给 openwrt 原生变更流程（commit + 重启由 post_apply 补） */
		this.handleSaveApply = function () {
			return CPD.notifyChanges().then(function () {
				return CPD.applyStaged();
			}).catch(function (e) {
				CPD.notify(CPD.errText(e, _('应用失败')), 'err');
			});
		};
		this.handleReset = function () {
			/* 复位 = 丢弃本会话未提交的增量 */
			return CPD.revertStaged().catch(function (e) {
				CPD.notify(CPD.errText(e, _('复位失败')), 'err');
			});
		};

		return body;
	}
});
