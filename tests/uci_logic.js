/* 用真实的 luci uci.js 跑一遍暂存链路，确认 set/save 真会下发到 ubus。
 * 用法：LUCI_SRC=/path/to/lucisrc node tests/uci_logic.js
 * （lucisrc 里需要 uci.js，可从 openwrt/luci 的
 *   modules/luci-base/htdocs/luci-static/resources/uci.js 取得） */
const fs = require('fs');
const path = require('path');

const SRC = process.env.LUCI_SRC || '/tmp/lucisrc';
const file = path.join(SRC, 'uci.js');
if (!fs.existsSync(file)) {
	console.error('找不到 %s，请用 LUCI_SRC 指向含 uci.js 的目录', file);
	process.exit(2);
}

const code = fs.readFileSync(file, 'utf8').replace(/^'require [^']+';$/gm, '');

const calls = [];
const RPC = {
	declare(def) {
		const fn = function () { return Promise.resolve(null); };
		fn.__def = def;
		return fn;
	}
};

const baseclass = {
	extend(proto) {
		function C() { if (proto.__init__) proto.__init__.call(this); }
		Object.assign(C.prototype, proto);
		return C;
	}
};

const document = { dispatchEvent() {} };
const L = { env: {}, url: (a, b) => '/cgi-bin/luci/' + a + '/' + b };

const factory = new Function('rpc', 'baseclass', 'document', 'L', '_', 'window',
	'"use strict";' + code.replace(/^'use strict';\n/, ''));
const Uci = factory(RPC, baseclass, document, L, s => s, {});

function mk(data) {
	const u = new Uci();
	u.callLoad = conf => Promise.resolve(data[conf] || {});
	u.callSet = (conf, sid, values) => {
		calls.push(['set', conf, sid, JSON.stringify(values)]);
		return Promise.resolve(0);
	};
	u.callAdd = (conf, type, name, values) => {
		calls.push(['add', conf, type, name, JSON.stringify(values)]);
		return Promise.resolve('cfgNEW');
	};
	u.callDelete = (conf, sid, opts) => {
		calls.push(['del', conf, sid, JSON.stringify(opts)]);
		return Promise.resolve(0);
	};
	u.callApply = () => Promise.resolve(0);
	u.callConfirm = () => Promise.resolve(0);
	u.reorderSections = () => Promise.resolve();
	return u;
}

let fail = 0;
function ck(name, ok, extra) {
	console.log('  %s %s%s', ok ? 'OK  ' : 'FAIL', name, extra ? '  ' + extra : '');
	if (!ok) fail = 1;
}

async function t(name, data, body) {
	calls.length = 0;
	console.log('--- %s ---', name);
	await body(mk(data));
}

(async () => {
	await t('黑名单 blockedmac list 写入（opennds @opennds[0]）', {
		opennds: { opennds: { '.name': 'opennds', '.type': 'opennds', '.index': 0,
			blockedmac: [], macmechanism: '' } }
	}, async u => {
		await u.load('opennds');
		ck('resolveSID @opennds[0] 有值',
			u.resolveSID('opennds', '@opennds[0]') === 'opennds');
		u.set('opennds', '@opennds[0]', 'blockedmac', ['aa:bb:cc:dd:ee:ff']);
		await u.save();
		ck('下发了 set', calls.length === 1, JSON.stringify(calls));
	});

	await t('opennds 匿名节 @opennds[0]', {
		opennds: { opennds: { '.name': 'opennds', '.type': 'opennds', '.index': 0, login_option_enabled: '3' } }
	}, async u => {
		await u.load('opennds');
		ck('resolveSID @opennds[0] = opennds',
			u.resolveSID('opennds', '@opennds[0]') === 'opennds',
			String(u.resolveSID('opennds', '@opennds[0]')));
		u.set('opennds', '@opennds[0]', 'login_option_enabled', '1');
		await u.save();
		ck('下发了 set', calls.length === 1, JSON.stringify(calls));
	});

	await t('zone_detect 新增 option', {
		zone_detect: { main: { '.name': 'main', '.type': 'zone_detect', '.index': 0, session_scope: 'default' } }
	}, async u => {
		await u.load('zone_detect');
		u.set('zone_detect', 'main', 'scope', 'global');
		await u.save();
		ck('下发了 set', calls.length === 1, JSON.stringify(calls));
	});

	await t('清空 list（传 null）', {
		opennds: { opennds: { '.name': 'opennds', '.type': 'opennds', '.index': 0,
			blockedmac: ['aa:bb:cc:dd:ee:ff'] } }
	}, async u => {
		await u.load('opennds');
		u.set('opennds', '@opennds[0]', 'blockedmac', null);
		await u.save();
		ck('下发了 del', calls.length && calls[0][0] === 'del', JSON.stringify(calls));
	});

	process.exit(fail);
})();
