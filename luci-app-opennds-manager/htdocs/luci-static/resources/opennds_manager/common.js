/*
 * openNDS CPD 前端公共模块（被各 view 通过 L.require 加载）
 * 统一封装：后端 API 调用 / toast / 二次确认 / base64 / 停用态确认流程 / 公共样式
 */
'use strict';
'require ui';
'require fs';
'require dom';

var API_PATH = '/usr/lib/opennds/opennds-manager-api.sh';

var CSS = '\
.cpd-page{max-width:none;width:100%;padding:18px 4px 60px;color:var(--text,#222a31)}\
.cpd-head{padding-bottom:14px;border-bottom:1px solid var(--line,#d7dde3)}\
.cpd-head h2{font-size:18px;font-weight:650;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0}\
.cpd-desc{font-size:12.5px;color:var(--muted,#657585);margin-top:6px;line-height:1.6}\
.cpd-sec{padding:18px 0 6px}\
.cpd-sec h3{font-size:15px;font-weight:650;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0 0 6px}\
.cpd-note{font-size:12.5px;color:var(--muted,#657585);line-height:1.65;max-width:920px}\
.cpd-warnline{font-size:12.5px;color:var(--red,#c94848);line-height:1.65}\
.cpd-warnbar{font-size:12.5px;line-height:1.6;padding:9px 12px;border:1px solid var(--amber,#b57d17);border-radius:6px;color:var(--amber,#b57d17);margin-top:8px}\
.cpd-state{font-size:11.5px;color:#9aa6b2;margin-top:8px}\
.cpd-viewer-label{margin-top:14px;font-size:12.5px;font-weight:600;color:var(--muted,#657585)}\
.cpd-viewer{margin-top:7px;max-width:100%;padding:12px 14px;border:1px solid #ccd5dd;border-radius:5px;background:#f5f7f9;box-shadow:inset 0 1px 3px rgba(28,44,58,.07)}\
.cpd-viewer pre{margin:0;background:transparent;border:0;font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:13px;line-height:1.7;color:#26323c;white-space:pre-wrap;word-break:break-all}\
.cpd-ta{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:13px;line-height:1.6;width:100%;max-width:900px;min-height:132px;padding:9px 11px;background:#fff;border:1px solid var(--line,#d7dde3);border-radius:6px;resize:vertical;color:var(--text,#222a31)}\
.cpd-ta:focus{outline:none;border-color:var(--primary,#2274a5)}\
.cpd-field{margin-top:12px}\
.cpd-field>label{display:block;font-size:13px;font-weight:600;margin-bottom:6px}\
.cpd-input{width:100%;max-width:900px;padding:8px 10px;font-size:14px;border:1px solid var(--line,#d7dde3);border-radius:6px;background:#fff;color:var(--text,#222a31)}\
.cpd-actions{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}\
.cpd-actions-right{margin-top:22px;padding-top:14px;border-top:1px solid var(--line,#d7dde3);display:flex;justify-content:flex-end;gap:8px}\
#cpd-toasts{position:fixed;right:18px;bottom:18px;z-index:600;display:flex;flex-direction:column;gap:10px;max-width:min(420px,calc(100vw - 36px))}\
.cpd-toast{background:#fff;border:1px solid #d7dde3;border-left:3px solid #2274a5;border-radius:8px;padding:11px 14px;font-size:13px;color:#222a31;box-shadow:0 6px 20px rgba(30,42,54,.12)}\
.cpd-toast.cpd-ok{border-left-color:#2e9468}\
.cpd-toast.cpd-warn{border-left-color:#b57d17}\
.cpd-toast.cpd-err{border-left-color:#c94848}\
#cpd-toasts-center{position:fixed;left:50%;bottom:26px;transform:translateX(-50%);z-index:600;pointer-events:none}\
.cpd-pill{background:rgba(28,40,52,.92);color:#fff;border-radius:999px;padding:10px 20px;font-size:13px;box-shadow:0 6px 20px rgba(30,42,54,.25);pointer-events:none;transition:opacity .25s}\
.cpd-pill.cpd-ok{background:rgba(30,94,62,.94)}\
.cpd-pill.cpd-warn{background:rgba(150,100,20,.94)}\
.cpd-pill.cpd-err{background:rgba(160,50,50,.94)}\
.cpd-statusbar{position:fixed;left:50%;top:56px;transform:translateX(-50%);z-index:700;display:none;align-items:center;gap:12px;padding:9px 14px;border-radius:8px;background:#fff;border:1px solid #d7dde3;border-left:3px solid #2274a5;box-shadow:0 6px 20px rgba(30,42,54,.16);font-size:13px;color:#222a31;max-width:min(720px,calc(100vw - 40px))}\
.cpd-statusbar.cpd-ok{border-left-color:#2e9468}\
.cpd-statusbar.cpd-warn{border-left-color:#b57d17}\
.cpd-statusbar.cpd-err{border-left-color:#c94848}\
.cpd-sb-text{flex:1 1 auto;line-height:1.5}\
.cpd-sb-count{font-family:ui-monospace,Consolas,monospace;font-size:11.5px;color:#8a97a3;min-width:22px;text-align:right}\
.cpd-sb-x{border:0;background:transparent;cursor:pointer;font-size:16px;line-height:1;color:#8a97a3;padding:0 2px}\
.cpd-sb-x:hover{color:#222a31}\
.cpd-badge{font-size:11px;color:#2e9468;margin-left:6px}\
.cpd-tab{font-family:inherit;font-size:13px;line-height:1.4;padding:9px 14px;border:0;border-bottom:2px solid transparent;background:transparent!important;cursor:pointer;color:inherit;margin-bottom:-1px;outline:none!important;box-shadow:none!important}\
.cpd-tab:hover,.cpd-tab:focus,.cpd-tab:active{background:transparent!important;outline:none!important;box-shadow:none!important;border-top:0;border-left:0;border-right:0}\
.cpd-tab.on{font-weight:700;border-bottom-color:#2274a5}\
.cpd-switch{position:relative;width:42px;height:24px;flex:none;padding:0;border:1px solid #c9d2da;border-radius:999px;background:#e3e8ec;cursor:pointer;transition:background .15s,border-color .15s;vertical-align:middle}\
.cpd-switch .knob{position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(20,30,40,.22);transition:transform .15s}\
.cpd-switch[aria-checked="true"]{background:#2e9468;border-color:#2e9468}\
.cpd-switch[aria-checked="true"] .knob{transform:translateX(18px)}\
.cpd-switch-row{display:inline-flex;align-items:center;gap:10px;padding:6px 0;cursor:pointer}\
@media (max-width:640px){.cpd-ta{font-size:16px}.cpd-actions .cbi-button,.cpd-actions .btn{flex:1 1 30%}}\
';

function ensureStyle() {
	if (document.getElementById('cpd-style')) return;
	var st = document.createElement('style');
	st.id = 'cpd-style';
	st.textContent = CSS;
	document.head.appendChild(st);
}


/* ============================================================
 * 「保存并应用」全流程（所有页面共用）
 * ------------------------------------------------------------
 * openwrt 原生的应用流程是：commit → 原生弹窗（「正在等待配置被应用…90s」
 * 倒计时）→ confirm 成功后显示「配置更改已应用。」并在 apply_display
 * （默认 1.5 秒）后刷新页面。
 * commit 本身不会让 openNDS 重启（它的 init 没有 procd reload trigger），
 * 所以补一次 post_apply：后端秒回、重活全在后台孤儿 worker（页面刷新
 * 杀不掉它）。因此这里完全走原生节奏：
 *  - 倒计时、「配置更改已应用。」、刷新页面全部由原生自己管，不覆盖；
 *  - 我们只在 uci-applied（commit + confirm 成功）后补发一次 post_apply；
 *  - 不再轮询、不再推迟刷新 —— 之前轮询等 worker 跑完才刷新，会让
 *    「配置更改已应用。」的弹窗挂住几十秒（worker 重启 openNDS 的时长），
 *    页面像卡死一样（2026-11-20 用户反馈，已回归原生）。
 * ============================================================ */
var APPLY = { active: false };

/* 当前会话里待提交的 uci 增量条数（LuCI 24.10 没有 changesCount 属性） */
function changeCount(ui) {
	var ch = ui && ui.changes && ui.changes.changes, n = 0, k;
	if (!ch) return 0;
	for (k in ch) if (ch.hasOwnProperty(k)) n += (ch[k] || []).length;
	return n;
}

/* 原生 ui.changes.apply() 不返回 Promise，自己管理全部界面（倒计时、
 * 「配置更改已应用。」、定时刷新）。这里只负责触发它，并立刻给按钮一个
 * 已定的 Promise —— 底部按钮的加载圈不该挂到 worker 跑完。 */
APPLY.start = function (ui) {
	/* 连点两次「保存并应用」：原生 commit 幂等（无增量的 apply 是空操作），
	 * 第二次会被 changeCount 检查拦成「没有需要应用的更改」，这里不加锁 */
	try {
		ui.changes.apply(false);
	} catch (e) {
		return Promise.reject({ error: (e && e.message) || _('应用失败') });
	}
	return Promise.resolve({ ok: 1 });
};

/* uci-applied（原生 commit + confirm 成功）之后的唯一收尾：
 * 补发 post_apply（秒回）。重活在后台 worker，页面刷新不影响它；
 * worker 完成后的 openNDS 状态由概览页自己的轮询如实展示。 */
APPLY.onApplied = function () {
	L.require('opennds_manager.common').then(function (m) {
		return m.api('sys', 'post_apply').then(function (j) {
			/* 有设备踢不下来：原生应用随后就刷新页面，提示会被冲掉。
			 * 跨刷新用 sessionStorage 带到概览页；后端同时保留这条待办，
			 * 下次应用会自动重试。 */
			if (j && Number(j.deauth_failed) > 0) {
				try {
					sessionStorage.setItem('cpd_deauth_failed',
						Number(j.deauth_failed) + '|' + Date.now());
				} catch (e) {}
			}
		});
	}).catch(function () { /* 秒回失败不影响原生流程，worker 由下次应用补 */ });
};

/* uci-applied 事件：原生 commit + confirm 成功的唯一可靠信号。
 * 不改 apply_display —— 原生按默认 1.5 秒刷新页面，「配置更改已应用。」
 * 弹窗随刷新消失，不再挂住几十秒。按钮路径与右上角指示器路径共用这里。 */
document.addEventListener('uci-applied', function () {
	APPLY.onApplied();
});

/* LuCI 模块加载器要求 L.require() 的模块返回 L.Class 子类（加载器实例化后缓存），
 * 因此这里必须是 extend 而非普通对象字面量 */
var CPD = L.Class.extend({
	/* ---------- 后端 API ---------- */
	api: function (page, subcmd, args) {
		args = args || [];
		return fs.exec(API_PATH, [page, subcmd].concat(args)).then(function (res) {
			var j = null;
			try { j = JSON.parse(res.stdout); } catch (e) {}
			if (!j) {
				return Promise.reject({
					error: (res.stderr || res.stdout || '后端无输出（脚本异常）')
				});
			}
			return j;
		}, function (e) {
			return Promise.reject({ error: (e && e.message) ? e.message : '调用后端失败' });
		});
	},

	/* 带停用态二次确认的调用：need_confirm → 弹框 → confirm_enable=1 重发 */
	apiConfirmable: function (page, subcmd, args) {
		var self = this;
		return self.api(page, subcmd, args).then(function (j) {
			if (j.error === 'need_confirm') {
				return new Promise(function (resolve) {
					self.modal(_('openNDS 已停用'), [
						E('p', {}, _(
							'openNDS 当前处于停用状态。继续应用将同时启用它并重启服务：所有设备会短暂断线，' +
							'未认证的设备将被重新挡在门户外。确定继续？')),
						E('div', {
							'style': 'margin-top:18px;display:flex;justify-content:flex-end;gap:8px'
						}, [
							E('button', {
								'class': 'btn cbi-button',
								'click': function () { ui.hideModal(); }
							}, _('取消')),
							E('button', {
								'class': 'btn cbi-button cbi-button-positive',
								'click': function () {
									ui.hideModal();
									resolve(self.api(page, subcmd, args.concat(['confirm_enable=1'])));
								}
							}, _('确认'))
						])
					]);
				}).then(function (j2) {
					if (j2 && j2.enabled_by_apply === 1) {
						self.toast(_('openNDS 已同时启用'), 'warn');
					}
					return j2;
				});
			}
			return j;
		});
	},

	/* ---------- 通用校验错误展示：errors 数组 → 逐条 toast（err） ---------- */
	showErrors: function (errors) {
		var self = this;
		(errors || []).forEach(function (e) {
			self.toast((e.line > 0 ? _('第 %s 行：').format(e.line) : '') + e.msg, 'err');
		});
	},

	/* warnings 数组 → 逐条 toast（warn） */
	showWarnings: function (ws) {
		var self = this;
		(ws || []).forEach(function (w) {
			self.toast(w, 'warn');
		});
	},

	/* ---------- 通知 ----------
	 * 一律走 openwrt 自带通知（ui.addNotification）：不再自己弹右下角卡片。
	 * 运行环境没有该能力时，退化为页面顶部的一条通知栏，
	 * 默认 100 秒倒计时自动关闭；应用完成后由 clearNotice() 立即关闭。
	 */
	notifyKinds: { ok: 'info', warn: 'warning', err: 'error', '': 'info' },

	notify: function (msg, kind) {
		var self = this;
		var k = self.notifyKinds[kind === undefined ? '' : kind] || 'info';
		if (typeof ui.addNotification === 'function') {
			ui.addNotification(null, E('p', {}, msg), k);
			return true;
		}
		return self.statusBar(msg, kind);
	},

	/* 兼容老调用点：toast / toastCenter 现在都等于 notify */
	toast: function (msg, kind) { return this.notify(msg, kind); },
	toastCenter: function (msg, kind) { return this.notify(msg, kind); },

	/* 自动消失的横幅：ms（默认 3000）后移除，用户不用再手动点叉。
	 * ui.addNotification 返回它创建的节点；环境不返回节点时退化为普通横幅。 */
	notifyTimed: function (msg, kind, ms) {
		var self = this;
		var k = self.notifyKinds[kind === undefined ? '' : kind] || 'info';
		if (typeof ui.addNotification === 'function') {
			var node = ui.addNotification(null, E('p', {}, msg), k);
			window.setTimeout(function () {
				if (!node) return;
				if (node.parentNode) node.parentNode.removeChild(node);
				else if (typeof node.remove === 'function') node.remove();
			}, ms || 3000);
			return true;
		}
		return self.statusBar(msg, kind);
	},

	/* 轮询类失败专用：单条通知栏、同一原因不重复弹、恢复后可被 clearNotice 清掉。
	 * 轮询每 10 秒失败一次若走 addNotification，红色横幅会一条条往上摞。 */
	notifyOnce: function (msg, kind) {
		var self = this;
		if (self._notifyOnceMsg === msg) return true;
		self._notifyOnceMsg = msg;
		return self.statusBar(msg, kind);
	},
	/* 成功恢复后清掉单条通知栏（仅供轮询路径调用） */
	clearOnce: function () {
		this._notifyOnceMsg = '';
		return this.clearNotice();
	},

	/* 页面顶部通知栏（单条）：100 秒倒计时，可手动关闭 */
	statusBar: function (msg, kind) {
		var self = this;
		var bar = document.getElementById('cpd-statusbar');
		if (!bar) {
			bar = document.createElement('div');
			bar.id = 'cpd-statusbar';
			bar.setAttribute('role', 'status');
			document.body.appendChild(bar);
		}
		bar.innerHTML = '';
		bar.className = 'cpd-statusbar' + (kind ? ' cpd-' + kind : '');
		var txt = document.createElement('span');
		txt.className = 'cpd-sb-text';
		txt.textContent = msg;
		var cnt = document.createElement('span');
		cnt.className = 'cpd-sb-count';
		var x = document.createElement('button');
		x.type = 'button';
		x.className = 'cpd-sb-x';
		x.setAttribute('aria-label', _('关闭通知'));
		x.textContent = '×';
		x.addEventListener('click', function () { self.clearNotice(); });
		bar.appendChild(txt);
		bar.appendChild(cnt);
		bar.appendChild(x);
		bar.style.display = 'flex';

		if (self._sbTimer) { clearInterval(self._sbTimer); self._sbTimer = null; }
		var left = 100;
		cnt.textContent = String(left);
		self._sbTimer = setInterval(function () {
			left--;
			if (left <= 0) { self.clearNotice(); return; }
			cnt.textContent = String(left);
		}, 1000);
		return true;
	},

	clearNotice: function () {
		var bar = document.getElementById('cpd-statusbar');
		if (bar) { bar.style.display = 'none'; bar.innerHTML = ''; }
		if (this._sbTimer) { clearInterval(this._sbTimer); this._sbTimer = null; }
		return true;
	},

	/* ---------- 弹窗 ----------
	 * LuCI 24.10 起 ui.showModal(title, children, ...classes)：第三个参数是 CSS class，
	 * 不再是按钮数组（23.05 及更早才是）。把按钮数组当第三个参数传进去会被当 class 名，
	 * classList.add 直接抛异常 —— 弹窗根本不出现，看起来就是"点了没反应"。
	 * 这里统一把正文与按钮装进同一个数组交给 showModal，新旧版本都能正确渲染。 */
	modal: function (title, nodes) {
		var list = Array.isArray(nodes) ? nodes.filter(function (n) { return n != null; }) : [nodes];
		return ui.showModal(title, list);
	},

	/* 二次确认弹窗：统一不显示标题栏，只留正文一句确认语 + 按钮。
	 * title 参数保留是为了兼容旧调用（传了也不渲染），新调用一律只写正文。 */
	confirm: function (title, text, okText, danger, onok, noTitle) {
		var row = E('div', {
			'style': 'margin-top:18px;display:flex;justify-content:flex-end;gap:8px'
		}, [
			E('button', {
				'class': 'btn cbi-button',
				'click': function () { ui.hideModal(); }
			}, _('取消')),
			E('button', {
				'class': 'btn cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-positive'),
				'click': function () {
					ui.hideModal();
					onok();
				}
			}, okText)
		]);
		/* 所有二次确认一律无标题：传 null 给原生 showModal，它不渲染标题栏，
		 * 弹窗只剩正文和按钮（用户要求） */
		return ui.showModal(null, [E('p', {}, text), row]);
	},

	/* ---------- base64（UTF-8 安全） ---------- */
	b64encode: function (s) {
		return btoa(unescape(encodeURIComponent(s)));
	},
	b64decode: function (s) {
		return decodeURIComponent(escape(atob(s)));
	},

	/* ---------- 页面骨架 ---------- */
	style: ensureStyle,
	pageHead: function (title, en, desc) {
		/* en 参数保留只为兼容老调用点；页面标题后面的英文按需求一律不显示 */
		ensureStyle();
		return E('div', { 'class': 'cpd-head' }, [
			E('h2', {}, [title]),
			desc ? E('div', { 'class': 'cpd-desc' }, desc) : E([])
		]);
	},
	/* 区块标题不再带英文小字（用户要求所有标题只保留中文） */
	section: function (title) {
		return E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [title])
		]);
	},
	/* 与概览页一致的开关按钮（.cpd-switch + 滑块 + aria-checked）。
	 * checked: 布尔初值；label: aria-label；onChange(checked): 点击回调。
	 * 返回 button，并挂 setChecked(v) 供外部在异步后同步视觉。 */
	switchBtn: function (checked, label, onChange) {
		ensureStyle();
		var btn = E('button', {
			'class': 'cpd-switch', 'type': 'button', 'role': 'switch',
			'aria-label': label || ''
		}, E('span', { 'class': 'knob', 'aria-hidden': 'true' }));
		btn.setAttribute('aria-checked', checked ? 'true' : 'false');
		btn.addEventListener('click', function () {
			var next = btn.getAttribute('aria-checked') !== 'true';
			btn.setAttribute('aria-checked', next ? 'true' : 'false');
			if (typeof onChange === 'function') onChange(next);
		});
		btn.setChecked = function (v) {
			btn.setAttribute('aria-checked', v ? 'true' : 'false');
		};
		return btn;
	},

	/* ---------- 与 openwrt 原生「未保存的配置」对接 ----------
	 * 关键事实（openwrt/rpcd uci.c）：ubus uci 的增量不是 /tmp/.uci，
	 * 而是按会话隔离的 RPC_UCI_SAVEDIR_PREFIX<会话目录>；LuCI 前端的
	 * uci.changes() 走的就是这条带会话的通道。shell 里直接 uci set 写的是
	 * /tmp/.uci，两边不是同一个目录 —— 所以后端 staging 永远读不到，
	 * 右上角指示器也不会出现。
	 *
	 * 因此暂存一律走 LuCI 自己的 uci 模块（uci.set → uci.save），
	 * 这样：① uci.changes() 能读到 → 右上角出现「未保存的配置: N」；
	 *       ② 点它弹的是 openwrt 原生「配置 / 更改」diff 弹窗（绿加红减）；
	 *       ③ 弹窗里的「保存并应用」直接触发原生 commit + reload_config。
	 */

	/* openwrt 原生限时横幅（仅用于失败/提示类，不再用于"已保存"） */
	nativeNotice: function (msg, timeout) {
		var self = this;
		var LC = window.L;
		if (!LC || typeof LC.require !== 'function') return self.statusBar(msg);
		return LC.require('ui').then(function (ui) {
			var p = document.createElement('p');
			p.textContent = msg;
			if (ui && typeof ui.addTimeLimitedNotification === 'function') {
				ui.addTimeLimitedNotification(null, p, timeout || 6000, 'info');
			} else if (ui && typeof ui.addNotification === 'function') {
				ui.addNotification(null, p, 'info');
			} else {
				self.statusBar(msg);
			}
		}).catch(function () { self.statusBar(msg); });
	},

	/* 让右上角指示器按真实增量重画（同时把 changes 存进 ui.changes，
	 * 点指示器时 displayChanges() 才有数据可画 diff） */
	notifyChanges: function () {
		var self = this;
		var LC = window.L;
		if (!LC || typeof LC.require !== 'function')
			return Promise.resolve();
		return LC.require('ui').then(function (ui) {
			if (ui && ui.changes && typeof ui.changes.init === 'function')
				return ui.changes.init();
			if (ui && ui.changes && typeof ui.changes.setIndicator === 'function')
				return LC.require('uci').then(function (uci) {
					return uci.changes().then(function (ch) {
						var n = 0, k;
						if (ch) for (k in ch) if (ch.hasOwnProperty(k)) n += (ch[k] || []).length;
						ui.changes.setIndicator(n);
					});
				});
		}).catch(function () {});
	},

	/* 兼容旧调用：后端直接数 /tmp/.uci，现在只作为诊断信息 */
	fallbackChangeCount: function () { return Promise.resolve(); },

	/* 错误对象 → 展示文本（fs.exec 的异常带 message，后端应答带 error，
	 * rpc 失败时可能只有一个状态码数字 —— 数字也要说人话，不能吞成"操作失败"） */
	errText: function (e, fallback) {
		if (typeof e === 'number') return _('请求失败（错误码 %d）').format(e);
		return (e && e.error) || (e && e.message) || fallback || _('操作失败');
	},

	/* section 类型（新建节时用；与出厂模板一致） */
	secType: function (conf) {
		return conf;
	},

	/* 确保 section 可写：存在就直接用，不存在就按类型建一个 */
	ensureSection: function (uci, conf, sid) {
		if (uci.get(conf, sid)) return true;
		var m = /^@([A-Za-z0-9_]+)(\[\d+\])?$/.exec(sid);
		if (m) {
			var secs = uci.sections(conf, m[1]) || [];
			if (secs.length) return true;
			uci.add(conf, m[1]);
			return !!uci.get(conf, sid);
		}
		uci.add(conf, this.secType(conf), sid);
		return !!uci.get(conf, sid);
	},

	/* uci 暂存：typ='opt' 时 values 是标量（null/''=删除该键）；
	 * typ='list' 时 values 是数组（空数组=清空该 list，等价于删掉这个 option）。
	 * 串行队列：uci.save() 会整批下发本地状态，并发会互相覆盖。 */
	stageUci: function (conf, sid, opt, typ, values) {
		var self = this;
		var prev = (self._stageQ || Promise.resolve()).catch(function () {});
		self._stageQ = prev.then(function () {
			return self.stageOne(conf, sid, opt, typ, values);
		});
		return self._stageQ;
	},

	stageOne: function (conf, sid, opt, typ, values) {
		var self = this;
		var LC = window.L;
		if (!LC || typeof LC.require !== 'function')
			return Promise.reject({ error: _('当前页面环境不支持 uci 模块') });
		var wrote = false;
		return LC.require('uci').then(function (uci) {
			return uci.load(conf).then(function () {
				if (!self.ensureSection(uci, conf, sid))
					throw { error: _('配置节不存在且无法新建：%s').format(conf + '.' + sid) };
				/* uci.set 在节解析不到时会"静默什么都不做"，那样点了保存
				 * 右上角不会出现任何增量 —— 这里显式拦下来，宁可报错也不装成功 */
				if (typeof uci.resolveSID === 'function' && uci.resolveSID(conf, sid) == null)
					throw { error: _('配置节不存在：%s').format(conf + '.' + sid) };
				if (typ === 'opt') {
					var v = (values === null || values === undefined) ? '' : String(values);
					var cur = uci.get(conf, sid, opt);
					var curS = (cur == null) ? '' : String(cur);
					if (curS === v) return;      /* 没变就别造无效增量 */
					uci.set(conf, sid, opt, v === '' ? null : v);
				} else {
					var arr = (values || []).map(function (x) { return String(x); });
					var cv = uci.get(conf, sid, opt);
					var ca = Array.isArray(cv) ? cv.map(String) : (cv == null ? [] : [String(cv)]);
					if (ca.length === arr.length && ca.join('\n') === arr.join('\n'))
						return;                  /* 名单没变，不写增量 */
					/* 空数组在 rpcd 会被判 INVALID_ARGUMENT，用"删除该 option"表达清空 */
					uci.set(conf, sid, opt, arr.length ? arr : null);
				}
				wrote = true;
				return uci.save();
			}, function (e) {
				/* uci/load 失败（配置文件不存在等）时，官方 uci.js 会把这个
				 * rejected Promise 缓存进 loaded 表，不清掉后面每次都失败。
				 * 后端 bl_status/status 会在读配置前自动补建缺失的
				 * /etc/config/opennds；这里给出人话错误并清缓存。 */
				try { uci.unload(conf); } catch (e2) {}
				throw { error: _('配置文件 %s 不存在或无法读取，无法写入该配置').format(conf) };
			}).then(function () {
				if (!wrote) return null;
				/* 写后自检：rpcd 的 uci changes 读的就是「未保存的配置」那个
				 * 会话增量目录，是唯一权威口径。里面没有这个配置，说明刚才的
				 * set/save 被静默吞掉了（权限不足、节名解析错、后端报错被
				 * Promise 链吃掉）—— 这种情况必须报出来，不能装成保存成功。 */
				return uci.changes().then(function (ch) {
					if (ch && ch[conf]) return null;
					throw {
						error: _('配置未能写入：%s.%s.%s（会话增量里没有这条记录）')
							.format(conf, sid, opt)
					};
				});
			});
		}).then(function () {
			return self.notifyChanges();
		}, function (e) {
			throw { error: self.errText(e, _('暂存配置失败')) };
		});
	},

	/* 列表增量编辑：fn(当前值数组) → 新值数组。当前值读的是 LuCI 会话里的
	 * 暂存态（uci.get 反映本地未保存修改），所以连续多次操作是叠加而不是
	 * 互相覆盖 —— 之前概览页连续给两个客户端设可信任，第二次用后端返回的
	 * 已提交名单整个重写，第一次的暂存就被冲掉了。
	 * fn 返回 null/undefined 表示「没变」，不写无效增量。 */
	stageListEdit: function (conf, sid, opt, fn) {
		var self = this;
		var LC = window.L;
		if (!LC || typeof LC.require !== 'function')
			return Promise.reject({ error: _('当前页面环境不支持 uci 模块') });
		var wrote = false;
		return LC.require('uci').then(function (uci) {
			return uci.load(conf).then(function () {
				if (!self.ensureSection(uci, conf, sid))
					throw { error: _('配置节不存在且无法新建：%s').format(conf + '.' + sid) };
				if (typeof uci.resolveSID === 'function' && uci.resolveSID(conf, sid) == null)
					throw { error: _('配置节不存在：%s').format(conf + '.' + sid) };
				var cur = uci.get(conf, sid, opt);
				var arr = Array.isArray(cur) ? cur.map(String) : (cur == null ? [] : [String(cur)]);
				var next = fn(arr);
				if (next == null) return null;
				next = next.map(String);
				if (arr.length === next.length && arr.join('\n') === next.join('\n'))
					return null;
				uci.set(conf, sid, opt, next.length ? next : null);
				wrote = true;
				return uci.save();
			}, function (e) {
				try { uci.unload(conf); } catch (e2) {}
				throw { error: _('配置文件 %s 不存在或无法读取，无法写入该配置').format(conf) };
			}).then(function () {
				if (!wrote) return null;
				return uci.changes().then(function (ch) {
					if (ch && ch[conf]) return null;
					throw {
						error: _('配置未能写入：%s.%s.%s（会话增量里没有这条记录）')
							.format(conf, sid, opt)
					};
				});
			});
		}).then(function () {
			return self.notifyChanges();
		}, function (e) {
			throw { error: self.errText(e, _('暂存配置失败')) };
		});
	},

	/* 待踢一次性令牌：MAC|时间戳。pending_deauth 是「应用后即删」的瞬态键，
	 * 用纯 MAC 去重会让残留时二次操作零增量（右上角无提示、应用无反应）。
	 * 所有会解除认证的前端操作都用它，后端按 | 取 MAC，兼容旧纯 MAC 值。 */
	deauthToken: function (mac) {
		return String(mac || '').toLowerCase() + '|' + Date.now().toString(36);
	},

	/* 名单「按本页改动」差量同步：base 是上一次同步后的快照，want 是本页
	 * 现在的名单。只把 want 相对 base 的增删写进当前 uci 暂存值——其它页面
	 * 先暂存、还没应用的条目不在 base 里，自然不会被本页的整表保存冲掉。
	 * 每次同步成功后调用方把 base 更新成 want，本页连续编辑就能正确撤销。 */
	stageListSync: function (conf, sid, opt, base, want) {
		var self = this;
		var b = {}, w = {}, add = [], rem = [];
		(base || []).forEach(function (x) { b[String(x)] = 1; });
		(want || []).forEach(function (x) { w[String(x)] = 1; });
		(want || []).forEach(function (x) { if (!b[String(x)]) add.push(String(x)); });
		(base || []).forEach(function (x) { if (!w[String(x)]) rem.push(String(x)); });
		var p = Promise.resolve(null);
		if (add.length) {
			p = p.then(function () {
				return self.stageListEdit(conf, sid, opt, function (arr) {
					var out = arr.slice();
					add.forEach(function (x) { if (out.indexOf(x) < 0) out.push(x); });
					return out;
				});
			});
		}
		if (rem.length) {
			p = p.then(function () {
				return self.stageListEdit(conf, sid, opt, function (arr) {
					return arr.filter(function (x) { return rem.indexOf(x) < 0; });
				});
			});
		}
		return p;
	},

	/* 保存并应用：完全走 openwrt 原生流程（倒计时弹窗、「配置更改已应用。」、
	 * 刷新页面全部由原生管理）。openNDS 的部署/重启在 uci-applied 之后由
	 * post_apply 派生的后台孤儿 worker 完成，页面刷新杀不掉它，所以不再
	 * 推迟原生刷新 —— 详见上方 APPLY 注释。 */
	applyStaged: function () {
		var self = this;
		return self.notifyChanges().then(function () {
			var LC = window.L;
			if (!LC || typeof LC.require !== 'function')
				throw { error: _('当前页面环境不支持 uci 模块') };
			return LC.require('ui').then(function (ui) {
				if (!(ui && ui.changes && typeof ui.changes.apply === 'function'))
					throw { error: _('当前 LuCI 版本不支持原生应用流程') };
				/* 没有增量就不走应用：避免"点一下保存并应用把 openNDS 重启一遍"。
				 * 静默跳过——这类"没有可做的操作"提示一律不弹横幅。 */
				if (changeCount(ui) === 0)
					return { ok: 1, nochange: 1 };
				return APPLY.start(ui);
			});
		}, function (e) {
			throw { error: self.errText(e, _('应用失败')) };
		});
	},

	/* 复位：走原生 revert（丢弃本会话所有未提交增量） */
	revertStaged: function () {
		var LC = window.L;
		if (!LC || typeof LC.require !== 'function')
			return Promise.reject({ error: _('当前页面环境不支持 uci 模块') });
		return LC.require('ui').then(function (ui) {
			if (ui && ui.changes && typeof ui.changes.revert === 'function')
				return ui.changes.revert();
			throw { error: _('当前 LuCI 版本不支持原生复位') };
		});
	}
});

return CPD;
