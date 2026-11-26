/* 临时仿真：直接抽取 overview.js 里的 finishRun/pollRunState 代码跑两种时序。
 * 不是沙箱用例，只是验证"黄灯/横幅"逻辑在会话过期那类场景下的行为。 */
const fs = require('fs');
const path = require('path');
const file = path.join(__dirname, '..', 'luci-app-opennds-manager',
  'htdocs/luci-static/resources/view/opennds_manager/overview.js');
const src = fs.readFileSync(file, 'utf8');

function grab(name) {
  const marker = '\t\tfunction ' + name + '(';
  const s = src.indexOf(marker);
  if (s < 0) throw new Error('not found: ' + name);
  let depth = 0, started = false;
  for (let i = s; i < src.length; i++) {
    if (src[i] === '{') { depth++; started = true; }
    else if (src[i] === '}') {
      depth--;
      if (started && depth === 0) return src.slice(s, i + 1);
    }
  }
  throw new Error('unbalanced: ' + name);
}

function harness(replies) {
  const env = {
    runNotice: null,
    lastRunWant: '0',
    runPollTimer: null,
    state: { running: true },
    loaded: false,
    locked: true,
    _: (s) => s,
    CPD: {
      api: () => {
        const r = replies.shift();
        return r && r.__reject ? Promise.reject(r.value) : Promise.resolve(r);
      },
      notify: () => ({ removed: false }),
      dismissNotice: (n) => { if (n) n.removed = true; }
    },
    transitionCleared: false,
    transitionClear: () => { env.transitionCleared = true; },
    renderStatus: () => {},
    clearRunNotice: () => {
      if (env.runNotice) { env.CPD.dismissNotice(env.runNotice); env.runNotice = null; }
    },
    maybeClearRunNotice: () => {
      if (!env.runNotice || !env.lastRunWant) return;
      if (env.state.running === (env.lastRunWant === '1')) env.clearRunNotice();
    },
    window: { setTimeout: (fn) => { queue.push(fn); return queue.length; }, clearTimeout: () => {} },
    queue: [],
    Date: Date
  };
  const body = [grab('isSessionError'), grab('sessionInterrupted'),
    grab('finishRun'), grab('pollRunState'),
    'return { finishRun: finishRun, pollRunState: pollRunState };'].join('\n');
  const api = new Function('env', 'with (env) { ' + body + ' }')(env);
  const queue = env.queue;
  const tick = async () => {
    let guard = 0;
    while (guard++ < 20) {
      await new Promise((r) => setTimeout(r, 0));
      if (!queue.length) break;
      const fn = queue.shift();
      fn();
    }
    await new Promise((r) => setTimeout(r, 0));
  };
  return { env, api, tick };
}

(async () => {
  // A: worker 残留 busy，但进程已经停了 → 不弹失败横幅
  let h = harness([
    { ok: 1, running: 1, busy: 1, done: 0 },
    { ok: 1, running: 0, busy: 1, done: 0 },
    { ok: 1, running: 0, busy: 1, done: 0 }
  ]);
  h.api.pollRunState('0', Date.now(), 0);
  await h.tick();
  console.log('A 停透无横幅:', h.env.state.running === false && h.env.runNotice === null ? 'PASS' : 'FAIL');

  // B: worker 报 done 但进程还在 → 弹失败；随后进程停了、dashboard 复核 → 横幅撤掉
  h = harness([{ ok: 1, running: 1, busy: 0, done: 1 }]);
  h.api.pollRunState('0', Date.now(), 0);
  await h.tick();
  const shown = !!h.env.runNotice;
  h.env.state.running = false;
  h.env.maybeClearRunNotice();
  console.log('B 失败可见且可撤:', shown && h.env.runNotice === null ? 'PASS' : 'FAIL');

  // C: 一小时会话过期，LuCI 抛 SessionError → 不弹横幅、撤黄灯、解锁
  h = harness([{ __reject: true,
    value: { name: 'SessionError', error: 'Login session is expired' } }]);
  h.api.pollRunState('0', Date.now(), 0);
  await h.tick();
  console.log('C 会话过期不误报:',
    h.env.runNotice === null && h.env.transitionCleared && h.env.locked === false ? 'PASS' : 'FAIL');
})();
