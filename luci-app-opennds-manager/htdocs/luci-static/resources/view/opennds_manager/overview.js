/*
 * openNDS 概览（仪表盘） · openNDS CPD（LuCI view）
 * 照《OpenNDS概览.md》：运行状态（开关+重启）、客户端统计（筛选器）、网络接口、
 * 无线接入点、客户端列表（搜索/排序/行内 6 按钮）+ 编辑/详情弹窗。
 * 开关与重启都是：二次确认 → 暂存请求键 → openwrt 原生应用流程（原生等待弹窗）；
 * 真正的启停/重启由后端 apply_worker 在应用之后执行。
 * 5 秒自动轮询，弹窗打开期间暂停。
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
.ovd-dot.busy{background:#d98c13;box-shadow:0 0 0 3px #fbeed6}\
.ovd-status-text{font-size:20px;font-weight:650;color:#2e9468;letter-spacing:.5px}\
.ovd-status-text.off{color:#c94848}\
.ovd-status-text.busy{color:#c07a0c}\
.ovd-status-text.pending{color:#9aa6b2}\
.ovd-switch{position:relative;width:42px;height:24px;flex:none;padding:0;border:1px solid #c9d2da;border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s}\
.ovd-switch .knob{position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(20,30,40,.22);transition:transform .15s}\
.ovd-switch[aria-checked="true"]{background:#2e9468;border-color:#2e9468}\
.ovd-switch[aria-checked="true"] .knob{transform:translateX(18px)}\
.ovd-switch.busy{background:#d98c13;border-color:#d98c13}\
.ovd-switch.busy .knob{transform:translateX(18px)}\
.ovd-switch.busy.off{background:#d98c13;border-color:#d98c13}\
.ovd-switch.busy.off .knob{transform:translateX(0)}\
.ovd-stat-grid{display:grid;grid-template-columns:repeat(8,1fr);gap:10px;margin-top:14px}\
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
.ovd-tag.t-pre{color:#fff;border-color:#2e9468;background:#2e9468}\
.ovd-tag.t-trusted{color:#fff;border-color:#f0c419;background:#f0c419}\
.ovd-tag.t-black{color:#fff;border-color:#252b31;background:#252b31}\
.ovd-acts{display:flex;flex-wrap:wrap;gap:5px}\
.ovd-rowbtn{font-family:inherit;font-size:11px;color:#222a31;background:#fff;border:1px solid #d7dde3;border-radius:4px;height:26px;padding:0 8px;cursor:pointer;white-space:nowrap}\
.ovd-rowbtn:hover{background:#f4f7f9;border-color:#c4ccd4}\
.ovd-rowbtn:disabled{opacity:.45;cursor:default;background:#f7f9fa}\
.ovd-rowbtn.danger{color:#c94848;border-color:#e8c9c9}\
.ovd-rowbtn.danger:hover{background:#fdf4f4;border-color:#d9a8a8}\
.ovd-empty{text-align:center;color:#9aa6b2;font-size:12.5px;padding:26px 10px}\
.ovd-mask{position:absolute;top:0;left:0;right:0;min-height:100vh;background:rgba(22,30,38,.5);display:none;padding:18px;z-index:700}\
.ovd-mask.on{display:flex}\
.ovd-dialog{background:#fff;border-radius:10px;width:100%;max-width:660px;margin:auto;box-shadow:0 18px 48px rgba(20,30,40,.24)}\
.ovd-dialog.dtl{max-width:460px}\
.ovd-dhead{padding:15px 20px;border-bottom:1px solid #d7dde3;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}\
.ovd-dhead h3{font-size:16px;font-weight:650;margin:0}\
.ovd-dsub{font-size:11.5px;color:#9aa6b2;font-family:ui-monospace,Consolas,monospace;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\
.ovd-dbody{padding:0 20px 8px}\
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
	wired: _('有线客户端'),
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
		return L.require('opennds_manager.common').then(function (m) { CPD = m; });
	},

	render: function () {
		ensureOvdStyle();
		CPD.style();

		var state = {
			running: false, enabled: false, engaged: 1, busy: 0, scope: 'default',
			counts: {}, managed: { iface: '', ip: '' }, aps: [],
			clients: [],
			/* 不默认选中任何卡片：进来先看全部客户端，点哪张卡筛哪类
			 * （2026-11-19 用户口径，此前默认选中「在线客户端」） */
			filter: null, ap: null, query: '', fupEnabled: true,
			confErr: '',
			sortKey: null, sortDir: 1
		};
		var locked = false, pollTimer = null, modalOpen = 0;
		var editRow = null;

		/* 开关过渡态（2026-11-22 用户口径）：点关闭/开启后，等待后端真正生效
		 * 的这几秒里，按钮与文字显示黄色「正在关闭 / 正在启动」，而不是继续
		 * 显示旧的绿色/红色——避免用户以为没点上。下一轮轮询确认 running
		 * 到达目标后才清除，切回红色「未运行」/绿色「运行」。
		 * 原生 apply 流程会刷新页面，所以过渡态用 sessionStorage 跨刷新保留；
		 * 带时间戳，超过 90 秒视为 stale 直接丢弃，避免卡在黄灯。 */
		var TRANS_KEY = 'cpd.runTransition';
		function transitionRead() {
			try {
				var v = sessionStorage.getItem(TRANS_KEY);
				if (!v) return null;
				var p = v.split('|');
				if (p[0] !== 'off' && p[0] !== 'on') { sessionStorage.removeItem(TRANS_KEY); return null; }
				var ts = Number(p[1]);
				if (!ts || Date.now() - ts > 90000) { sessionStorage.removeItem(TRANS_KEY); return null; }
				return p[0];
			} catch (e) { return null; }
		}
		function transitionSet(want) {
			try { sessionStorage.setItem(TRANS_KEY, want + '|' + Date.now()); } catch (e) {}
		}
		function transitionClear() {
			try { sessionStorage.removeItem(TRANS_KEY); } catch (e) {}
		}
		var transition = transitionRead(); // 'off' | 'on' | null

		var body = E('div', { 'class': 'ovd-page' });

		/* ---------- 顶部提示条（只剩「配置无法解析」这一种） ---------- */
		function renderWarnbar() {
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

		/* ---------- 数据拉取与 5 秒轮询 ----------
		 * 只发一个 dashboard 请求：后端一次解析 ndsctl、一次读 uci，
		 * 状态与客户端列表一起回来（之前两个请求串行，首屏要等两轮）。
		 * 5 秒一档：客户端认证完最多 5 秒就上卡（10 秒时用户反馈
		 * 「认证后要等十几秒才能看到」）。
		 * 另外两条规矩：
		 * ① 上一轮没回来就不发下一轮（否则请求会越积越多）；
		 * ② 失败只占一条通知栏、同一原因不重复弹。 */
		var refreshing = false;
		var offTimer = null;
		var loaded = false;

		/* 轮询确认 running 到达本次目标后，撤掉黄灯恢复常规配色。
		 * 只在状态"稳下来"时清：点关闭时旧值可能仍是 true，不能提前撤。 */
		function settleTransition() {
			if (!transition) return;
			if ((transition === 'off' && state.running === false) ||
				(transition === 'on' && state.running === true)) {
				transition = null;
				transitionClear();
			}
		}

		function applyStatus(st) {
			if (!st || !st.ok) return;
			state.enabled = st.enabled === 1;
			state.engaged = st.engaged;
			state.busy = st.busy;
			state.fupEnabled = (st.fupEnabled === 1 || st.fupEnabled === true);
			state.scope = st.session_scope || 'default';
			state.counts = st.counts || {};
			state.defaultSession = st.defaultSession || 1440;
			state.managed = st.managed || { iface: '', ip: '' };
			state.aps = st.aps || [];
			state.confErr = st.confErr || '';

			if (st.running === 1) {
				if (offTimer) { window.clearTimeout(offTimer); offTimer = null; }
				state.running = true;
				settleTransition();
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
							settleTransition();
							renderStatus();
						}
					}).catch(function () {});
				}, 1200);
				return;
			}
			state.running = false;
			settleTransition();
		}

		function renderAllSafe() {
			/* 任何一段渲染抛异常都不能连累后面的区块 */
			[renderStatus, renderWarnbar, renderStats, renderIface, renderAps, renderList]
				.forEach(function (fn) {
					try { fn(); } catch (e) {
						if (window.console && console.error) console.error('[opennds-manager] render', e);
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
		}, 5000);

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
			/* 过渡态优先：已点开关、后端还没确认到位 → 整块黄灯，标题写
			 * 「正在关闭 / 正在启动」，旋钮拨向目标位置。等 settleTransition
			 * 确认到位后清除，才回到下面的常规配色。 */
			if (transition) {
				var closing = (transition === 'off');
				statusDot.className = 'ovd-dot busy';
				statusText.className = 'ovd-status-text busy';
				statusText.textContent = closing ? _('正在关闭') : _('正在启动');
				runSwitch.className = 'ovd-switch busy' + (closing ? ' off' : '');
				runSwitch.setAttribute('aria-checked', closing ? 'false' : 'true');
				return;
			}
			runSwitch.className = 'ovd-switch';
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

		function doToggle(want) {
			/* 开关走 openwrt 原生暂存流程（和底部「保存并应用」同一节奏）：
			 * 倒计时、「配置更改已应用。」、刷新页面全由原生管理。
			 * opennds 的 enabled 与 zone_detect.main.pending_run 一起 commit，
			 * 后台 worker 读到 pending_run 才真正执行启停 —— 普通页面的应用
			 * 不带这个键，永远不会替用户改 openNDS 的运行状态。
			 *
			 * pending_run 带一次性令牌：worker 执行完会把这个键删掉，但
			 * 若上一轮 worker 抢锁失败 / post_apply 被页面刷新掐断，键会
			 * 留在配置里。此时若再写同样的 0/1，uci 增量里两条都没变化，
			 * 点开关只会得到「没有需要应用的更改」，开关永远切不动。
			 * 令牌保证每次点击都产生真实增量，worker 只看首位 0/1。 */
			/* 先亮黄灯：原生 apply 会刷新页面，过渡态写进 sessionStorage，
			 * 刷新后由 transitionRead() 读回继续显示，直到轮询确认到位。 */
			transition = (want === '0') ? 'off' : 'on';
			transitionSet(transition);
			renderStatus();
			var token = want + '-' + Date.now().toString(36);
			CPD.stageUci('opennds', '@opennds[0]', 'enabled', 'opt', want)
				.then(function () {
					return CPD.stageUci('zone_detect', 'main', 'pending_run', 'opt', token);
				})
				.then(function () {
					return CPD.applyStaged();
				})
				.catch(function (e) {
					transition = null;
					transitionClear();
					renderStatus();
					CPD.toast(CPD.errText(e, _('操作失败')), 'err');
				});
		}

		function handleSwitch() {
			if (locked) return;
			var want = state.running ? '0' : '1';
			if (want === '0') {
				CPD.confirm(null, _('确认关闭？'), _('确定停用'), true,
					function () { doToggle('0'); }, true);
			} else {
				CPD.confirm(null, _('确认开启？'), _('确定启用'), false,
					function () { doToggle('1'); }, true);
			}
		}

		function handleRestart() {
			if (locked) return;
			/* 重启与开关同一节奏：二次确认 → 暂存 pending_restart → 原生应用流程。
			 * 真正的重启由 apply_worker 在应用后执行（stop → 等退出 → start → 等就绪），
			 * 页面按原生节奏刷新，状态由本页轮询如实展示 —— 不再出现"先报已重启、
			 * 过两秒又变未运行"的假横幅。 */
			CPD.confirm(null, _('确认重启？'), _('确定重启'), false,
				function () {
					CPD.stageUci('zone_detect', 'main', 'pending_restart', 'opt', '1')
						.then(function () {
							return CPD.applyStaged();
						})
						.catch(function (e) {
							CPD.toast(CPD.errText(e, _('操作失败')), 'err');
						});
				});
		}

		/* ---------- 分类与筛选（黑名单 > 可信任 > 免认证 > 已认证 > 未认证） ----------
		 * 「在线客户端」是身份卡：只算「正在连着且有访问权限」的设备
		 * （已认证 / 免认证已登录 / 可信任）；未认证不算在线，黑名单更不算。
		 * 「有线客户端」和无线接入点卡片一样是连接卡：连着就算，不分身份。
		 * 免认证 / 可信任 / 有线 / 黑名单四张卡读配置名单或邻居表统计，
		 * 不受 openNDS 是否运行影响；在线 / 已认证 / 未认证三张身份卡在
		 * NDS 未运行时归零，列表也同步为空（2026-11-19 用户口径）。
		 * filter=null = 没选任何卡片：显示全部客户端。
		 * 点接入点卡片时列表不按身份过滤（看该 AP 上的全部在线客户端），
		 * 操作按钮的可用性只由客户端身份决定（见 renderList）。 */
		function inFilter(c) {
			var online = !!c.online;
			switch (state.filter) {
				case null:
					/* 未选卡片：全部客户端 */
					return true;
				case 'blacklist':
					return !!c.blocked;
				case 'trusted':
					return !!c.trusted;
				case 'preauth':
					/* 免认证以 preemptivemac 名单为准（离线也在），黑名单除外 */
					return !!c.preauth && !c.trusted && !c.blocked;
				case 'auth':
					/* 已认证 = 认证还在有效期内就算，不管在线不在线、NDS 在不在跑
					 * （读 openNDS 原生落盘记录，不用等客户端连上 WiFi） */
					return !!c.authenticated && !c.trusted && !c.preauth && !c.blocked;
				case 'unauth':
					if (!state.running) return false;
					return online && !c.authorized && !c.preauth && !c.blocked;
				case 'wired':
					/* 有线卡 = 连着的有线设备，不分身份、黑名单客户端连着也算
					 * （与 AP 卡片同口径：连上 br-lan 就有 IP，2026-11-21 用户口径） */
					return online && !!c.wired;
				case '':
					/* 接入点筛选模式：不看身份（filteredClients 里另有 online 限定） */
					return true;
				default: /* online */
					if (!state.running) return false;
					/* 在线 = 连着且有访问权限；未认证（还没过门户）不算 */
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
		 * 这里再兜一层：接口名 → AP 卡片 → SSID。
		 * 对不上任何一张 AP 卡片的接口就是有线：显示接口名并标注「（有线）」，
		 * 例如 br-lan（有线）——不能只显示 br-lan，否则和无线接口名分不清。 */
		function apName(iface) {
			if (!iface) return '—';
			for (var i = 0; i < state.aps.length; i++) {
				if (state.aps[i].iface !== iface) continue;
				/* 是 AP 的接口：有 SSID 就用 SSID，SSID 反查失败也别标成有线 */
				return state.aps[i].ssid || iface;
			}
			return iface + _('（有线）');
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
			/* 接入点筛选模式：该 AP 上「正在连着」的全部客户端（不分身份，
			 * 黑名单客户端连着也算——它已连上 WIFI、有 IP，卡片不依赖 NDS） */
			var b = state.clients.filter(function (c) {
				if (state.ap) return apFilterMatch(c) && !!c.online;
				return inFilter(c);
			});
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
			/* 卡片顺序：有线放在已认证后面（2026-11-19 用户口径） */
			var defs = [
				{ k: 'online', label: _('在线客户端'), num: n.online },
				{ k: 'auth', label: _('已认证客户端'), num: n.authenticated },
				{ k: 'wired', label: _('有线'), num: n.wired },
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
			/* 再点同一张卡 = 取消选中，回到「全部客户端」 */
			state.filter = (state.filter === k) ? null : k;
			state.ap = null;
			renderStats();
			renderAps();
			renderList();
			if (state.filter) scrollToClients();
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
					/* 接入点筛选模式不套身份过滤：列表显示该 AP 上的全部
					 * 在线客户端（含未认证），按钮可用性由身份决定。
					 * 取消选中时回到「没选任何卡片」态（显示全部客户端），
					 * 标题跟着变——之前取消后标题还停在上一张卡，与列表对不上 */
					state.filter = state.ap ? '' : null;
					renderStats();
					renderAps();
					renderList();
					scrollToClients();
				});
			});
		}

		/* 点卡片以外的空白处取消选中：按钮、输入框、弹窗里的事务不算空白 */
		document.addEventListener('click', function (ev) {
			if (!loaded || modalOpen > 0) return;
			var t = ev.target;
			if (!t || typeof t.closest !== 'function') return;
			if (t.closest('button, a, input, select, textarea, label, .ovd-mask')) return;
			if (statGrid.contains(t) || apGrid.contains(t)) return;
			if (state.filter == null && !state.ap) return;
			state.filter = null;
			state.ap = null;
			renderStats();
			renderAps();
			renderList();
		});

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
			if (state.ap) {
				listTitle.textContent = _('接入点 %s').format(apLabel(state.ap));
			} else if (state.filter) {
				listTitle.textContent = TITLES[state.filter] || _('全部客户端');
			} else {
				listTitle.textContent = _('全部客户端');
			}
			listCount.textContent = _('共 %s 个').format(String(items.length)) +
				(state.ap ? ' · ' + _('接入点 %s').format(apLabel(state.ap)) : '');
			updateSortUI();

			if (!items.length) {
				tbody.innerHTML = '<tr><td colspan="5" class="ovd-empty">' +
					(loaded ? _('暂无符合条件的客户端') : _('读取中…')) + '</td></tr>';
				return;
			}

			/* 操作按钮的可用性只由客户端身份决定（黑名单 > 可信任 > 免认证 >
			 * 已认证 > 未认证），与当前在哪个卡片/接入点视图无关（照演示页）：
			 *   详情   —— 黑名单客户端置灰（其余身份都可见）
			 *   编辑   —— 可信任不显示（演示页：不受超时与流量限制，无需编辑），
			 *             其余身份都可点（黑名单置灰）；给普通客户端设限额 = 写入
			 *             preemptivemac 条目，下次接入自动登录，真实状态是「免认证」
			 *   免认证/可信任 —— 黑名单客户端也可点（2026-11-21 用户口径）：
			 *             操作 = 从黑名单移除 + 加入对应名单（应用后重启 NDS 生效）
			 *   解除认证 —— 已认证/免认证/可信任都可点；未认证没有会话可解除，
			 *             黑名单要先解除拉黑。可信任/免认证的解除认证会同时把
			 *             客户端从对应名单里清除（2026-11-20 用户口径，双向一致）
			 *   拉黑/解除拉黑 —— 永远可用（身份切换的入口） */
			tbody.innerHTML = items.map(function (c) {
				var blocked = !!c.blocked, trusted = !!c.trusted;
				var authed = !!c.authenticated, pre = !!c.preauth;
				var trustAct = trusted ? 'untrust' : 'trust';
				var trustLabel = trusted ? _('移除可信任') : _('可信任客户端');
				var tg = tagOf(c);
				var tags = '<span class="ovd-tag ' + tg[0] + '">' + tg[1] + '</span>';
				/* 独立的「免认证 / 移除免认证」按钮已取消（2026-11-22 用户口径）：
				 * 未认证客户端的「编辑」按钮改叫「免认证」，点它弹参数窗，
				 * 窗内「确定」= 执行原 preauth 那一套（加入免认证名单）+ 写入参数。 */
				var editLabel = (tg[0] === 't-unauth') ? _('免认证') : _('编辑');
				var editHTML = trusted ? '' :
					'<button type="button" class="ovd-rowbtn" data-act="edit" data-mac="' + esc(c.mac) + '"' +
					(blocked ? ' disabled' : '') + '>' + editLabel + '</button>';
				var deauthDis = ((!authed && !pre && !trusted) || blocked) ? ' disabled' : '';
				return '<tr>' +
					'<td><div class="ovd-host"><span class="ovd-host-name">' +
					esc(c.host || '—') + '</span><div class="ovd-tags">' + tags + '</div></div></td>' +
					'<td class="ovd-mono">' + esc(c.ip || '—') + '</td>' +
					'<td class="ovd-mono">' + esc(c.mac) + '</td>' +
					'<td>' + esc(clientAp(c)) + '</td>' +
				'<td><div class="ovd-acts">' +
				'<button type="button" class="ovd-rowbtn" data-act="detail" data-mac="' + esc(c.mac) + '"' +
				(blocked ? ' disabled' : '') + '>' + _('详情') + '</button>' +
				'<button type="button" class="ovd-rowbtn" data-act="' + trustAct + '" data-mac="' + esc(c.mac) + '"' +
				'>' + trustLabel + '</button>' +
					editHTML +
					'<button type="button" class="ovd-rowbtn danger" data-act="deauth" data-mac="' + esc(c.mac) + '"' +
					deauthDis + '>' + _('解除认证') + '</button>' +
					'<button type="button" class="ovd-rowbtn danger" data-act="' + (blocked ? 'unblock' : 'block') + '" data-mac="' + esc(c.mac) + '">' +
					(blocked ? _('解除拉黑') : _('拉黑')) + '</button>' +
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

		/* ---------- 行内操作（二次确认只显示一句确认语，无标题） ---------- */
		var CONFIRM_TEXT = {
			preauth: {
				msg: function () { return _('确认加入免认证？'); },
				ok: _('免认证'), danger: false
			},
			unpreauth: {
				msg: function () { return _('确认取消免认证？'); },
				ok: _('移除免认证'), danger: false
			},
			trust: {
				msg: function () { return _('确认设为可信任？'); },
				ok: _('可信任'), danger: false
			},
			untrust: {
				msg: function () { return _('确认移除可信任？'); },
				ok: _('移除可信任'), danger: false
			},
			deauth: {
				msg: function () { return _('确认解除认证？'); },
				ok: _('解除认证'), danger: true
			},
			block: {
				msg: function () { return _('确认拉黑？'); },
				ok: _('拉黑'), danger: true
			},
			unblock: {
				msg: function () { return _('确认解除拉黑？'); },
				ok: _('解除拉黑'), danger: false
			}
		};

		/* 断言文案照演示页。所有动作（含断开 / 拉黑）都只写 uci 暂存，
		 * 等 openwrt 底部「保存并应用」一起生效——它是本页所有变更的总开关。 */
		var ACTION_TOAST = {
			preauth: _('让「%s」免认证'),
			unpreauth: _('取消「%s」的免认证'),
			trust: _('把「%s」设为可信任客户端'),
			untrust: _('取消「%s」的可信任状态'),
			deauth: _('待应用：断开「%s」'),
			block: _('待应用：拉黑「%s」'),
			unblock: _('待应用：把「%s」移出黑名单')
		};

		function askAction(act, row) {
			var d = CONFIRM_TEXT[act];
			if (!d) return;
			var h = row.host || row.mac;
			CPD.confirm(null, d.msg(h), d.ok, d.danger, function () {
				performAction(act, row);
			});
		}

		/* 所有动作都落成 uci 暂存（右上角「未保存的配置」随之出现）：
		 * 名单类用 stageListEdit 在「当前暂存值」上做增删——连续操作多个
		 * 客户端是叠加，不会互相覆盖；断开（解除认证）暂存到
		 * zone_detect.main.pending_deauth，应用后由后端 post_apply 执行踢下线。 */
		function pmIndexOf(arr, lm) {
			for (var i = 0; i < arr.length; i++) {
				var m = String(arr[i]).split(';')[0].replace(/^mac=/i, '').toLowerCase();
				if (m === lm) return i;
			}
			return -1;
		}

		function stageAction(act, mac) {
			var lm = String(mac || '').toLowerCase();
			function pmDefault() {
				return 'mac=' + lm + ';sessiontimeout=0;uploadrate=0;downloadrate=0;uploadquota=0;downloadquota=0';
			}
			function unstageBlocked() {
				/* 黑名单互斥（2026-11-21 用户口径）：设为可信任/免认证前先把它
				 * 从 blockedmac 摘掉（不在名单里时返回 null，不产生增量）。
				 * blockedmac 是 openNDS 主进程启动时读的配置，应用后随 worker
				 * 重启 NDS 一起生效。 */
				return CPD.stageListEdit('opennds', '@opennds[0]', 'blockedmac', function (arr) {
					var out = arr.filter(function (x) { return x.toLowerCase() !== lm; });
					return out.length === arr.length ? null : out;
				});
			}
			switch (act) {
				case 'deauth':
					/* 踢下线是运行时动作，没有对应的配置项：暂存到
					 * zone_detect.main.pending_deauth，应用后 post_apply 执行。
					 * 双向一致（2026-11-20 用户口径）：解除认证同时把客户端从
					 * 免认证名单和可信任名单里清掉 —— 不然可信任客户端被踢后
					 * 下一次请求又被自动登录，等于没解除。 */
					return CPD.stageListEdit('zone_detect', 'main', 'pending_deauth', function (arr) {
						if (arr.indexOf(lm) >= 0) return null;
						return arr.concat([lm]);
					}).then(function () {
						return CPD.stageListEdit('opennds', '@opennds[0]', 'preemptivemac', function (arr) {
							var i = pmIndexOf(arr, lm);
							if (i < 0) return null;
							arr = arr.slice();
							arr.splice(i, 1);
							return arr;
						});
					}).then(function () {
						return CPD.stageListEdit('opennds', '@opennds[0]', 'trustedmac', function (arr) {
							var out = arr.filter(function (x) { return x.toLowerCase() !== lm; });
							return out.length === arr.length ? null : out;
						});
					});
				case 'block':
					/* 拉黑 = blockedmac 追加 + 从另两个名单摘除（互斥）。
					 * macmechanism 没设置时补成官方 'block' 语义（与后端同一口径）。 */
					return CPD.stageListEdit('opennds', '@opennds[0]', 'blockedmac', function (arr) {
						if (arr.map(function (x) { return x.toLowerCase(); }).indexOf(lm) >= 0) return null;
						return arr.concat([lm]);
					}).then(function (changed) {
						var p = CPD.stageListEdit('opennds', '@opennds[0]', 'trustedmac', function (arr) {
							var out = arr.filter(function (x) { return x.toLowerCase() !== lm; });
							return out.length === arr.length ? null : out;
						});
						p = p.then(function () {
							return CPD.stageListEdit('opennds', '@opennds[0]', 'preemptivemac', function (arr) {
								var i = pmIndexOf(arr, lm);
								if (i < 0) return null;
								arr = arr.slice();
								arr.splice(i, 1);
								return arr;
							});
						});
						if (changed !== null) {
							/* 这次真的往 blockedmac 写了增量才检查 macmechanism */
							p = p.then(function () {
								return CPD.api('blacklist', 'status').then(function (j) {
									if (j && j.mechanism) return null;
									return CPD.stageUci('opennds', '@opennds[0]', 'macmechanism', 'opt', 'block');
								});
							});
						}
						return p;
					});
				case 'unblock':
					return CPD.stageListEdit('opennds', '@opennds[0]', 'blockedmac', function (arr) {
						var out = arr.filter(function (x) { return x.toLowerCase() !== lm; });
						return out.length === arr.length ? null : out;
					});
			case 'trust':
				/* 黑名单客户端直接设可信任：先摘黑名单（互斥），再加 trustedmac */
				return unstageBlocked().then(function () {
					return CPD.stageListEdit('opennds', '@opennds[0]', 'trustedmac', function (arr) {
						if (arr.map(function (x) { return x.toLowerCase(); }).indexOf(lm) >= 0) return arr;
						return arr.concat([lm]);
					}).then(function () {
						return CPD.stageListEdit('opennds', '@opennds[0]', 'preemptivemac', function (arr) {
							var i = pmIndexOf(arr, lm);
							if (i < 0) return null;
							arr = arr.slice();
							arr.splice(i, 1);
							return arr;
						});
					});
				});
				case 'untrust':
					/* 移除可信任必须同时解除认证：可信任客户端有自动登录的会话，
					 * 只摘名单不踢人，NDS 里还留着认证信息，移出后照样能上网
					 * （2026-11-20 用户口径）。 */
					return CPD.stageListEdit('opennds', '@opennds[0]', 'trustedmac', function (arr) {
						var out = arr.filter(function (x) { return x.toLowerCase() !== lm; });
						return out.length === arr.length ? null : out;
					}).then(function (changed) {
						return CPD.stageListEdit('zone_detect', 'main', 'pending_deauth', function (arr) {
							if (arr.indexOf(lm) >= 0) return null;
							return arr.concat([lm]);
						}).then(function () {
							return changed;
						});
					});
			case 'preauth':
				/* 黑名单客户端直接设免认证：先摘黑名单（互斥），再写 preemptivemac */
				return unstageBlocked().then(function () {
					return CPD.stageListEdit('opennds', '@opennds[0]', 'trustedmac', function (arr) {
						var out = arr.filter(function (x) { return x.toLowerCase() !== lm; });
						return out.length === arr.length ? null : out;
					}).then(function () {
						return CPD.stageListEdit('opennds', '@opennds[0]', 'preemptivemac', function (arr) {
							if (pmIndexOf(arr, lm) >= 0) return null;
							return arr.concat([pmDefault()]);
						});
					});
				});
				case 'unpreauth':
					/* 移除免认证同样要先解除认证：免认证客户端也带着自动登录的
					 * 会话，只摘名单不踢人，它仍然是已认证状态（2026-11-20 用户口径）。 */
					return CPD.stageListEdit('opennds', '@opennds[0]', 'preemptivemac', function (arr) {
						var i = pmIndexOf(arr, lm);
						if (i < 0) return null;
						arr = arr.slice();
						arr.splice(i, 1);
						return arr;
					}).then(function (changed) {
						return CPD.stageListEdit('zone_detect', 'main', 'pending_deauth', function (arr) {
							if (arr.indexOf(lm) >= 0) return null;
							return arr.concat([lm]);
						}).then(function () {
							return changed;
						});
					});
			}
			return Promise.reject({ error: _('未知操作：%s').format(act) });
		}

		function performAction(act, row) {
			stageAction(act, row.mac).then(function () {
				refresh();
			}, function (e) {
				CPD.notify(CPD.errText(e, _('记录失败')), 'err');
			});
		}

		/* ---------- 编辑弹窗（5 项限制；「确定」只暂存，落盘交给 openwrt「保存并应用」） ---------- */
		var editMask = E('div', { 'class': 'ovd-mask' }, E('div', {
			'class': 'ovd-dialog', 'role': 'dialog', 'aria-modal': 'true'
		}, [
			E('div', { 'class': 'ovd-dhead' }, [
				E('h3', { 'id': 'ovd-ed-title' }, _('客户端编辑')),
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
			/* 照演示页：可信任客户端不受超时与流量限制，编辑按钮本来就不显示 */
			if (row.trusted) return;
			editRow = row;
			editInputs = {};
			/* 未认证客户端点的是改名后的「免认证」按钮：标题跟着叫「免认证」；
			 * 其余身份点的是「编辑」按钮，标题仍是「客户端编辑」。 */
			var titleEl = document.getElementById('ovd-ed-title');
			if (titleEl) titleEl.textContent = (tagOf(row)[0] === 't-unauth') ? _('免认证') : _('客户端编辑');
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
			/* 会话时长只对免认证客户端有意义：它写进 preemptivemac 条目，重启后
			 * 按新参数重新认证才生效（2026-11-22 用户口径）。所以「连接时间」区域
			 * 只在免认证相关场景出现——未认证点「免认证」进去、已是免认证点「编辑」进去。
			 * 已认证/黑名单的编辑弹窗不显示这一块。
			 * 注意：输入框本身仍由 limitRowEd 建好存入 editInputs，保证保存逻辑读得到。 */
			var edKind = tagOf(row)[0];
			if (edKind === 't-pre' || edKind === 't-unauth') edBody.appendChild(timeSec);
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
		}

		/* 单客户端限额：改写 preemptivemac 里该 MAC 的条目（custom= 原样保留）。
		 * 没有条目就新建（照演示页：给普通/已认证客户端设限额 = 写入
		 * preemptivemac 条目，下次接入自动登录，真实状态是「免认证」）。
		 * 与其它页面共用同一条 uci 增量通道，保存后右上角出现「未保存的配置」。
		 * 用 stageListEdit 在当前暂存值上改写——不读后端已提交名单，
		 * 连续的暂存操作（先设可信任再改限额）不会互相覆盖。 */
		function stageEditLimits(lm, v) {
			return CPD.stageListEdit('opennds', '@opennds[0]', 'preemptivemac', function (arr) {
				var found = false;
				var out = arr.map(function (e) {
					var m = String(e).split(';')[0].replace(/^mac=/i, '').toLowerCase();
					if (m !== lm) return String(e);
					found = true;
					var custom = '';
					var mm = /;custom=([\s\S]*)$/.exec(String(e));
					if (mm) custom = ';custom=' + mm[1];
					return 'mac=' + lm + ';sessiontimeout=' + v.sessiontimeout +
						';uploadrate=' + v.uploadrate + ';downloadrate=' + v.downloadrate +
						';uploadquota=' + v.uploadquota + ';downloadquota=' + v.downloadquota + custom;
				});
				if (!found) {
					out.push('mac=' + lm + ';sessiontimeout=' + v.sessiontimeout +
						';uploadrate=' + v.uploadrate + ';downloadrate=' + v.downloadrate +
						';uploadquota=' + v.uploadquota + ';downloadquota=' + v.downloadquota);
				}
				return out;
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
			var isUnauthEntry = (tagOf(editRow)[0] === 't-unauth');
			var done = function () {
				closeEdit();
				/* 确定只写 uci 增量，不 commit、不重启；
				   反馈就是右上角「未保存的配置」，不弹任何横幅 */
				refresh();
			};
			var failed = function (e) {
				CPD.notify(CPD.errText(e, _('记录失败')), 'err');
			};
			if (isUnauthEntry) {
				/* 改名后的「免认证」按钮：确定 = 跑原来 preauth 那一套（摘黑名单、
				 * 摘可信任、写 preemptivemac），再叠加窗里填的参数，一步到位加入免认证。 */
				stageAction('preauth', mac).then(function () {
					return stageEditLimits(lm, args);
				}).then(done, failed);
			} else {
				stageEditLimits(lm, args).then(done, failed);
			}
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

		/* 最大会话时间：没单独设置时显示全局默认值（openNDS 实际按它执行），
		 * 而不是含糊的「未单独设置」。单独设置了就显示设置值。 */
		function sessionText(lim, trusted) {
			if (trusted) return _('不受限制');
			if (lim && lim.enabled) return String(lim.value);
			return String(state.defaultSession || 1440);
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
			var tg = tagOf(row);
			dtlBody.appendChild(dtlSec(_('状态'), [
				dtlRow(_('属性'), E('span', { 'class': 'ovd-tag ' + tg[0] }, tg[1]))
			]));
			dtlBody.appendChild(dtlSec(_('基本信息'), [
				dtlRow(_('主机名'), row.host || '—'),
				dtlRow(_('IP 地址'), row.ip || '—', true),
				dtlRow(_('MAC 地址'), row.mac, true),
				dtlRow(_('接入点'), clientAp(row)),
				dtlRow(_('认证状态'), auth)
			]));
			/* 时间与超时：认证时间取首次认证通过的落盘时刻（离线也在），
			 * 到期时间不变；客户端正连着 WiFi 时，在两者中间插一行上线时间。 */
			var timeRows = [
				dtlRow(_('认证时间'), row.authTime || '—')
			];
			if (row.onlineTime) timeRows.push(dtlRow(_('上线时间'), row.onlineTime));
			timeRows.push(dtlRow(_('到期时间'), expires));
			timeRows.push(dtlRow(_('中断超时（分钟）'), timeout));
			timeRows.push(dtlRow(_('最大会话时间（分钟）'), sessionText(lim.maxSession, tr)));
			dtlBody.appendChild(dtlSec(_('时间与超时'), timeRows));
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
			E('h2', {}, _('概览'))));
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
