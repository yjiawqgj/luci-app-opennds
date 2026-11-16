/*
 * openNDS CPD 前端公共模块（被各 view 通过 L.require 加载）
 * 统一封装：后端 API 调用 / toast / 二次确认 / base64 / 停用态确认流程 / 公共样式
 */
'use strict';
'require ui';
'require fs';
'require dom';

var API_PATH = '/usr/lib/opennds/opennds-cpd-api.sh';

var CSS = '\
.cpd-page{max-width:none;width:100%;padding:18px 4px 60px;color:var(--text,#222a31)}\
.cpd-head{padding-bottom:14px;border-bottom:1px solid var(--line,#d7dde3)}\
.cpd-head h2{font-size:18px;font-weight:650;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0}\
.cpd-head h2 .cpd-en{font-size:11.5px;font-weight:500;color:#9aa6b2}\
.cpd-desc{font-size:12.5px;color:var(--muted,#657585);margin-top:6px;line-height:1.6}\
.cpd-sec{padding:18px 0 6px}\
.cpd-sec h3{font-size:15px;font-weight:650;display:flex;align-items:baseline;gap:8px;flex-wrap:wrap;margin:0 0 6px}\
.cpd-sec h3 .cpd-en{font-size:10.5px;font-weight:500;color:#9aa6b2}\
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
.cpd-badge{font-size:11px;color:#2e9468;margin-left:6px}\
.cpd-tab{font-family:inherit;font-size:13px;line-height:1.4;padding:9px 14px;border:0;border-bottom:2px solid transparent;background:transparent!important;cursor:pointer;color:inherit;margin-bottom:-1px;outline:none!important;box-shadow:none!important}\
.cpd-tab:hover,.cpd-tab:focus,.cpd-tab:active{background:transparent!important;outline:none!important;box-shadow:none!important;border-top:0;border-left:0;border-right:0}\
.cpd-tab.on{font-weight:700;border-bottom-color:#2274a5}\
@media (max-width:640px){.cpd-ta{font-size:16px}.cpd-actions .cbi-button,.cpd-actions .btn{flex:1 1 30%}}\
';

function ensureStyle() {
	if (document.getElementById('cpd-style')) return;
	var st = document.createElement('style');
	st.id = 'cpd-style';
	st.textContent = CSS;
	document.head.appendChild(st);
}

function ensureToasts() {
	var c = document.getElementById('cpd-toasts');
	if (!c) {
		c = document.createElement('div');
		c.id = 'cpd-toasts';
		c.setAttribute('aria-live', 'polite');
		document.body.appendChild(c);
	}
	return c;
}

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
					ui.showModal(_('openNDS 已停用'), E('p', {}, _(
						'openNDS 当前处于停用状态。继续应用将同时启用它并重启服务：所有设备会短暂断线，' +
						'未认证的设备将被重新挡在门户外。确定继续？')), [
						E('div', { 'class': 'right' }, [
							E('button', {
								'class': 'cbi-button',
								'click': ui.hideModal
							}, _('取消')),
							' ',
							E('button', {
								'class': 'cbi-button cbi-button-positive',
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

	/* ---------- toast（右下角白底卡片，WalledGarden/路由器访问同款） ---------- */
	toast: function (msg, kind) {
		ensureToasts();
		var t = document.createElement('div');
		t.className = 'cpd-toast' + (kind ? ' cpd-' + kind : '');
		t.textContent = msg;
		document.getElementById('cpd-toasts').appendChild(t);
		window.setTimeout(function () {
			t.style.opacity = '0';
			t.style.transition = 'opacity .3s';
			window.setTimeout(function () { dom.remove(t); }, 320);
		}, 3000);
	},

	/* 底部居中深色胶囊 toast（访问限制 / 黑名单页同款） */
	toastCenter: function (msg, kind) {
		var c = document.getElementById('cpd-toasts-center');
		if (!c) {
			c = document.createElement('div');
			c.id = 'cpd-toasts-center';
			c.setAttribute('aria-live', 'polite');
			document.body.appendChild(c);
		}
		var t = document.createElement('div');
		t.className = 'cpd-pill' + (kind ? ' cpd-' + kind : '');
		t.textContent = msg;
		c.appendChild(t);
		window.setTimeout(function () {
			t.style.opacity = '0';
			window.setTimeout(function () { dom.remove(t); }, 260);
		}, 2400);
	},

	/* ---------- 二次确认弹窗 ---------- */
	confirm: function (title, text, okText, danger, onok) {
		ui.showModal(title, E('p', {}, text), [
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('取消')),
				' ',
				E('button', {
					'class': 'cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-positive'),
					'click': function () {
						ui.hideModal();
						onok();
					}
				}, okText)
			])
		]);
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
		ensureStyle();
		return E('div', { 'class': 'cpd-head' }, [
			E('h2', {}, [title, E('span', { 'class': 'cpd-en' }, en)]),
			desc ? E('div', { 'class': 'cpd-desc' }, desc) : E([])
		]);
	},
	section: function (title, en) {
		return E('div', { 'class': 'cpd-sec' }, [
			E('h3', {}, [title, E('span', { 'class': 'cpd-en' }, en)])
		]);
	},

	/* ---------- OpenWRT 框架保存流程对接 ----------
	 * 顶部「未保存的配置: N」指示器读的是 ubus uci changes，
	 * 即 /tmp/.uci 里未 commit 的增量；uci-loaded 事件触发指示器刷新。
	 * sys uci_stage 只写增量不 commit → 保存后指示器出现、复位可还原；
	 * 后端 apply commit 时一并清掉增量 → 指示器归零。
	 */

	/* 通知顶部刷新未保存配置指示器 */
	notifyChanges: function () {
		document.dispatchEvent(new CustomEvent('uci-loaded'));
		return true;
	},

	/* 错误对象 → 展示文本（fs.exec 的异常带 message，后端应答带 error） */
	errText: function (e, fallback) {
		return (e && e.error) || (e && e.message) || fallback || _('操作失败');
	},

	/* uci 暂存：typ='opt' 时 values 是标量（null=删除该键）；
	 * typ='list' 时 values 是数组（空数组=清空该 list） */
	stageUci: function (conf, sid, opt, typ, values) {
		var self = this;
		var args = [conf, sid, opt, typ];
		if (typ === 'opt') {
			if (values !== null && values !== undefined) args.push(String(values));
		} else if (Array.isArray(values)) {
			args = args.concat(values.map(function (v) { return String(v); }));
		}
		return self.api('sys', 'uci_stage', args).then(function (j) {
			if (!j || !j.ok) throw { error: (j && j.error) || _('暂存配置失败') };
			self.notifyChanges();
			return j;
		});
	},

	/* 复位：丢弃指定配置的未提交增量（对应 openwrt 复位按钮语义） */
	revertStaged: function (confs) {
		var self = this;
		return Promise.all(confs.map(function (c) {
			return self.api('sys', 'uci_revert', [c]);
		})).then(function () {
			self.notifyChanges();
		}, function (e) {
			throw { error: self.errText(e, _('复位失败')) };
		});
	}
});

return CPD;
