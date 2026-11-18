#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编译前静态自检（不依赖设备）。

为什么要有这个脚本：之前只做 `node --check`（语法）+ 沙箱跑后端，
语法全过、后端全过，但装到机器上仍然整页空白 / 点按钮没反应 ——
因为下面这些问题只有"读代码语义"才能发现：

  1) refresh() 里调了已删除的 scanRestore() → ReferenceError，
     后面所有渲染函数一个都没跑 → 整页空白；
  2) ui.showModal(title, body, buttons) 在 LuCI 24.10 里第三个参数是
     CSS class 名，按钮数组被当 class 名 → classList.add 抛异常 →
     确认框根本弹不出来，表现就是"点了没反应"；
  3) 保存后弹 100 秒倒计时横幅，而 openwrt 原生行为是右上角
     「未保存的配置: N」——两者不能混用。

用法：python _selfcheck.py
       CPD_CHECK_ROOT=/path/to/old/tree python _selfcheck.py   # 回归自检本身
退出码 0 = 全绿。
"""

import io
import json
import os
import re
import shlex
import subprocess
import sys

ROOT = os.environ.get('CPD_CHECK_ROOT') or os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(ROOT, 'luci-app-opennds-cpd')

errors = []
warnings = []


def rel(p):
    return os.path.relpath(p, ROOT).replace('\\', '/')


def walk(ext):
    for base, _dirs, files in os.walk(PKG):
        for f in files:
            if f.endswith(ext):
                yield os.path.join(base, f)


# ============================================================
# 1. 语法：sh / js / json
# ============================================================
for p in walk('.sh'):
    r = subprocess.run(['bash', '-n', p], capture_output=True, text=True)
    if r.returncode != 0:
        errors.append('%s: bash -n 失败\n%s' % (rel(p), r.stderr.strip()))

for p in walk('.js'):
    r = subprocess.run(['node', '--check', p], capture_output=True, text=True)
    if r.returncode != 0:
        errors.append('%s: node --check 失败\n%s' % (rel(p), r.stderr.strip()))

for p in walk('.json'):
    try:
        json.loads(io.open(p, encoding='utf-8').read())
    except Exception as e:
        errors.append('%s: JSON 解析失败 %s' % (rel(p), e))

# ============================================================
# 2. 换行：一律 LF（CRLF 会让 sh 脚本在路由器上报 bad interpreter）
# ============================================================
for ext in ('.js', '.sh', '.json', '.orig'):
    for p in walk(ext):
        with io.open(p, 'rb') as f:
            if b'\r\n' in f.read():
                errors.append('%s: 含 CRLF（必须 LF）' % rel(p))


# ============================================================
# 3. 剥掉 JS 里的注释 / 字符串 / 正则字面量（保留行号）
# ============================================================
def strip_js(src):
    """逐字符扫描去掉注释与字符串（保留换行，行号不偏移）。

    用正则做这件事容易被"字符串里嵌了另一种引号"带偏（CSS 里到处是
    "Courier New"），一错位后面全判断错，所以这里老老实实做状态机。
    """
    out = []
    i, n = 0, len(src)
    state = None  # None | 'sq' | 'dq' | 'bt' | 'line' | 'block'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line'; out.append('  '); i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block'; out.append('  '); i += 2; continue
            if c == "'":
                state = 'sq'; out.append(' '); i += 1; continue
            if c == '"':
                state = 'dq'; out.append(' '); i += 1; continue
            if c == '`':
                state = 'bt'; out.append(' '); i += 1; continue
            if c == '/':
                # 正则字面量：/.../ ，里面可能带引号（如 /[&<>"']/g）。
                # 只看"前一个非空字符"判断是不是正则起始，够用且不会误吞除号。
                prev = ''
                for ch in reversed(out):
                    if not ch.isspace():
                        prev = ch
                        break
                if prev in ('', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', ';', '\n'):
                    j = i + 1
                    in_class = False
                    while j < n:
                        cj = src[j]
                        if cj == '\\':
                            j += 2; continue
                        if cj == '[':
                            in_class = True
                        elif cj == ']':
                            in_class = False
                        elif cj == '/' and not in_class:
                            j += 1
                            break
                        elif cj == '\n':
                            break
                        j += 1
                    out.append(' ' * (j - i))
                    i = j
                    continue
            out.append(c); i += 1; continue
        if state == 'line':
            if c == '\n':
                state = None; out.append('\n')
            else:
                out.append(' ')
            i += 1; continue
        if state == 'block':
            if c == '*' and nxt == '/':
                state = None; out.append('  '); i += 2; continue
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        # 字符串内部
        if c == '\\':
            out.append('  '); i += 2; continue
        if (state == 'sq' and c == "'") or (state == 'dq' and c == '"') or \
           (state == 'bt' and c == '`'):
            state = None; out.append(' '); i += 1; continue
        out.append('\n' if c == '\n' else ' '); i += 1; continue
    return ''.join(out)


GLOBALS = {
    # JS 内建
    'Array', 'Boolean', 'Date', 'Error', 'Function', 'JSON', 'Math', 'Number',
    'Object', 'Promise', 'RegExp', 'String', 'Symbol', 'Map', 'Set',
    'encodeURIComponent', 'decodeURIComponent', 'encodeURI', 'decodeURI',
    'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'btoa', 'atob',
    'unescape', 'escape', 'setTimeout', 'clearTimeout', 'setInterval',
    'clearInterval', 'console', 'window', 'document', 'alert', 'confirm',
    'require', 'define', 'CustomEvent', 'Event', 'Node', 'Element', 'HTMLElement',
    'FileReader', 'Blob', 'FormData', 'URL', 'localStorage', 'sessionStorage',
    'navigator', 'location', 'history', 'fetch', 'XMLHttpRequest',
    # LuCI / 视图环境
    'E', '_', 'L', 'ui', 'fs', 'uci', 'request', 'poll', 'dom', 'baseclass',
    'CPD', 'view',
    # 语言关键字误判
    'if', 'for', 'while', 'switch', 'catch', 'return', 'typeof', 'function',
    'new', 'delete', 'void', 'in', 'of', 'do', 'else', 'try', 'finally',
    'case', 'break', 'continue', 'throw', 'instanceof', 'await', 'yield',
}

# 常见 DOM/BOM API 命名，避免误报
METHODISH = {
    'addEventListener', 'removeEventListener', 'querySelector', 'querySelectorAll',
    'getElementById', 'appendChild', 'createElement', 'setAttribute',
    'getAttribute', 'removeAttribute', 'classList', 'textContent', 'innerHTML',
    'setSelectionRange', 'focus', 'blur', 'click', 'preventDefault',
    'scrollIntoView', 'forEach', 'filter', 'map', 'slice', 'concat', 'join',
    'split', 'replace', 'trim', 'push', 'pop', 'shift', 'unshift', 'indexOf',
    'lastIndexOf', 'includes', 'some', 'every', 'reduce', 'sort', 'reverse',
    'toLowerCase', 'toUpperCase', 'format', 'then', 'catch', 'resolve',
    'reject', 'hasOwnProperty', 'toString', 'valueOf', 'toFixed', 'localeCompare',
    'charAt', 'substr', 'substring', 'match', 'exec', 'test', 'keys',
}

# ============================================================
# 4. 未定义标识符（只查本地函数调用）
#    抓的就是"删了函数忘了删调用点"这类会把整页带崩的错误
# ============================================================
for p in walk('.js'):
    raw = io.open(p, encoding='utf-8').read()
    src = strip_js(raw)

    declared = set()
    for m in re.finditer(r'\bfunction\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)', src):
        declared.add(m.group(1))
        for a in m.group(2).split(','):
            a = a.strip()
            if a:
                declared.add(a)
    for m in re.finditer(r'function\s*\(([^)]*)\)', src):
        for a in m.group(1).split(','):
            a = a.strip()
            if a:
                declared.add(a)
    for m in re.finditer(r'\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)', src):
        declared.add(m.group(1))
    for m in re.finditer(r'\b(?:var|let|const)\s+([^;\n]+)', src):
        for n in re.findall(r'[A-Za-z_$][\w$]*', m.group(1)):
            declared.add(n)
    for m in re.finditer(r'([A-Za-z_$][\w$]*)\s*:\s*function', src):
        declared.add(m.group(1))
    declared |= GLOBALS | METHODISH

    for m in re.finditer(r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*\(', src):
        name = m.group(1)
        if name in declared or name in GLOBALS:
            continue
        if name.isupper():
            continue
        line = src[:m.start()].count('\n') + 1
        errors.append('%s:%d: 调用了未定义的函数 %s()（删除函数后忘了删调用点？）'
                      % (rel(p), line, name))

# ============================================================
# 5. 危险 / 过时的 API 用法
# ============================================================
for p in walk('.js'):
    raw = io.open(p, encoding='utf-8').read()
    src = strip_js(raw)
    is_common = p.endswith('common.js')

    if not is_common:
        for m in re.finditer(r'\bui\.showModal\s*\(', src):
            line = src[:m.start()].count('\n') + 1
            errors.append('%s:%d: 视图里直接用 ui.showModal —— 新版第三个参数是 class 名，'
                          '按钮请用 CPD.modal()/CPD.confirm()' % (rel(p), line))

    # 括号感知：数一数 ui.showModal(...) 到底传了几个顶格参数
    for m in re.finditer(r'\bui\.showModal\s*\(', src):
        i = m.end()
        depth = 1
        commas = 0
        while i < len(src) and depth > 0:
            ch = src[i]
            if ch in '([{':
                depth += 1
            elif ch in ')]}':
                depth -= 1
            elif ch == ',' and depth == 1:
                commas += 1
            i += 1
        if commas >= 2:
            line = src[:m.start()].count('\n') + 1
            errors.append('%s:%d: ui.showModal 传了 3 个以上参数 —— 新版第三参是 class 名，'
                          '按钮必须塞进第二个数组里（用 CPD.modal/CPD.confirm）' % (rel(p), line))

    # ui.changes.apply(checked)：必须有参数。无参调用在老版是"应用全部"，
    # 新版签名变成 apply(checked)，漏参数会走到 checked=undefined（≈unchecked），
    # 行为随版本漂移，所以统一走 CPD.applyStaged()。
    for m in re.finditer(r'\bui\.changes\.apply\s*\(\s*\)', src):
        line = src[:m.start()].count('\n') + 1
        errors.append('%s:%d: ui.changes.apply() 少了 checked 参数，请用 CPD.applyStaged()'
                      % (rel(p), line))
    if not is_common:
        for m in re.finditer(r'\bui\.changes\.(apply|revert|init)\s*\(', src):
            line = src[:m.start()].count('\n') + 1
            errors.append('%s:%d: 视图里直接调 ui.changes.%s —— 统一走 '
                          'CPD.applyStaged()/CPD.revertStaged()/CPD.notifyChanges()'
                          % (rel(p), line, m.group(1)))

    for pat, msg in [
        (r'CPD\.statusBar\s*\(', 'CPD.statusBar 会弹 100 秒倒计时横幅，保存类反馈请用右上角「未保存的配置」'),
        (r'CPD\.nativeNotice\s*\(', '保存成功不需要额外横幅，指示器本身就是反馈'),
    ]:
        for m in re.finditer(pat, src):
            line = src[:m.start()].count('\n') + 1
            warnings.append('%s:%d: %s' % (rel(p), line, msg))

    # 「应用」一律走 CPD.applyStaged()（原生 commit + post_apply 补重启）。
    # 任何 apiConfirmable(…, 'apply', …) / CPD.api(…, 'apply', …) 都是旧通道：
    # 它在后端自己 uci commit + 重启，绕过会话增量 —— 结果就是"改了但右上角没数"。
    for m in re.finditer(r"""(apiConfirmable|CPD\.api)\([^)]*['"]apply['"]""", raw):
        line = raw[:m.start()].count('\n') + 1
        errors.append('%s:%d: 又走了旧的后端 apply 通道 —— 保存并应用必须用 CPD.applyStaged()'
                      % (rel(p), line))

# ============================================================
# 6. common.js 的契约：暂存/应用/复位/指示器四个入口一个都不能少
# ============================================================
common = os.path.join(PKG, 'htdocs', 'luci-static', 'resources', 'opennds_cpd', 'common.js')
if not os.path.isfile(common):
    errors.append('缺少 common.js')
else:
    craw = io.open(common, encoding='utf-8').read()
    csrc = strip_js(craw)
    for fn in ('stageUci', 'stageOne', 'applyStaged', 'revertStaged',
               'notifyChanges', 'modal', 'confirm', 'ensureSection'):
        if not re.search(r'\b%s\s*:\s*function' % fn, csrc):
            errors.append('common.js: 缺少 %s（各页保存链路依赖它）' % fn)
    # 这两条要查原始源码：strip_js 会把字符串内容一起抹掉
    if not re.search(r"""addEventListener\(\s*['"]uci-applied['"]""", craw):
        errors.append('common.js: 少了 uci-applied 监听 —— 原生 commit 后不会重启 openNDS')
    if not re.search(r"""['"]sys['"]\s*,\s*['"]post_apply['"]""", craw):
        errors.append('common.js: uci-applied 里没调 sys post_apply')

# ============================================================
# 7. 每个视图都必须接上 LuCI 底部三个按钮
# ============================================================
VIEW_DIR = os.path.join(PKG, 'htdocs', 'luci-static', 'resources', 'view', 'opennds_cpd')
if os.path.isdir(VIEW_DIR):
    for f in sorted(os.listdir(VIEW_DIR)):
        if not f.endswith('.js'):
            continue
        src = strip_js(io.open(os.path.join(VIEW_DIR, f), encoding='utf-8').read())
        for h in ('handleSave', 'handleSaveApply'):
            if not re.search(r'this\.%s\s*=\s*function' % h, src):
                errors.append('view/%s: 没挂 this.%s，底部「保存」按钮点了不会有任何反应'
                              % (f, h))
        # 有暂存就必须有应用：只 stageUci 不 applyStaged 的页面，点「保存并应用」
        # 之后配置永远不会 commit，表现出来就是"保存了但配置文件没变"。
        if 'CPD.stageUci(' in src and 'CPD.applyStaged(' not in src:
            errors.append('view/%s: 用了 CPD.stageUci 却没有 CPD.applyStaged —— '
                          '「保存并应用」不会提交，配置永远不会落盘' % f)
else:
    errors.append('缺少 view/opennds_cpd 目录')

# ============================================================
# 7b. 黑名单门户的三方契约（用户明确要求这一组功能必须在）
#     openNDS 9.4 起主进程不再读 blockedmac，拦截靠分发脚本；
#     前端选门户 → 后端扫/删/传 → 分发脚本按选中项出示页面，
#     任何一环被删掉，黑名单就会变成"名单里有人但没人被拦"。
# ============================================================
_api = os.path.join(PKG, 'root', 'usr', 'lib', 'opennds', 'opennds-cpd-api.sh')
_theme = os.path.join(PKG, 'root', 'usr', 'lib', 'opennds', 'theme_zone_detect.sh')
_blj = os.path.join(VIEW_DIR, 'blacklist.js')
if os.path.isfile(_api):
    a = io.open(_api, encoding='utf-8').read()
    for fn in ('bl_portals_scan', 'bl_portal_delete', 'bl_upload_begin', 'bl_upload_store'):
        if not re.search(r'^%s\(\)' % fn, a, re.M):
            errors.append('api.sh: 缺少 %s —— 黑名单门户的上传/删除/列表会失效' % fn)
    if 'portal_blacklist' not in a:
        errors.append('api.sh: 没读 zone_detect.main.portal_blacklist —— '
                      '选中的门户存不住')
if os.path.isfile(_theme):
    t = io.open(_theme, encoding='utf-8').read()
    if 'blockedmac' not in t:
        errors.append('theme_zone_detect.sh: 没有 blockedmac 分支 —— '
                      'openNDS 主进程不拦 MAC，这脚本不拦就等于黑名单不生效')
    if 'portal_blacklist' not in t:
        errors.append('theme_zone_detect.sh: 没读 portal_blacklist —— '
                      '黑名单客户端拿不到本页选的门户')
if os.path.isfile(_blj):
    b = io.open(_blj, encoding='utf-8').read()
    for pat in ('门户选择', 'portal_delete', 'portal_blacklist'):
        if pat not in b:
            errors.append('view/blacklist.js: 缺少「%s」—— 门户区块被删了' % pat)

# ============================================================
# 8. 后端：add_list/del_list 必须是单参数「键=值」
#    （多参数写法在真机 uci 上直接打 usage 并以非 0 退出）
# ============================================================
for p in walk('.sh'):
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        if 'add_list' not in line and 'del_list' not in line:
            continue
        try:
            toks = shlex.split(line, comments=True)
        except ValueError:
            continue
        for k, t in enumerate(toks):
            if t in ('add_list', 'del_list'):
                if k == 0 or toks[k - 1] not in ('uci', 'uci_w'):
                    continue
                args = []
                for a in toks[k + 1:]:
                    if a in ('||', '&&', ';', '{', '}', '|', '&') or a.startswith(('2>', '1>', '>')):
                        break
                    args.append(a)
                bad = [a for a in args if '=' not in a or a.startswith('=')]
                if len(args) != 1 or bad:
                    errors.append('%s:%d: add_list/del_list 必须写成 键=值 单参数'
                                  '（真机 uci 会打 usage）：%s' % (rel(p), i, line.strip()))

# ============================================================
# 已删除机制 / 预设内容的残留（回归守卫：删了定义忘了删引用会直接白页）
# ============================================================
REMOVED = [
    # 豁免页恢复机制（用户明确要求整组删除）
    'restore_scan', 'trustedmac.orig', 'restoreDismissed', 'cpd-restore-dismiss',
    # 概览页脚本路径提示（改为点「启动」时才在后端补）
    'themeBar', 'renderThemeBar', 'fixThemespec', 'themeOk', 'set_themespec',
    'ov_set_themespec',
    # 预设 MAC —— 任何形态都不许出现
    'AA:BB:CC:DD:EE:FF', 'aa:bb:cc:dd:ee:ff', 'D8:3A:DD:41:6F:22',
    # 黑名单自建配置 /etc/config/zone_blacklist（第 58 轮起名单改存 opennds
    # 的 blockedmac；门户选中项存插件自己的 zone_detect.main.portal_blacklist）。
    # 唯一合法残留是 api.sh 里 bl_migrate_legacy 的一次性迁移，它只读 main.mac。
    # 门户库目录 /usr/lib/opennds/cpd/blacklist/ 是正式功能，不在此列。
    'zone_blacklist.main.portal', "stageUci('zone_blacklist'", "'zone_blacklist', 'main'",
    'bl_save_macs', 'bl_apply', 'bl_save_portal',
    'ZONE_ROOT_BLACKLIST', 'BLACKLIST_CONFIG',
]
for p in list(walk('.js')) + list(walk('.sh')):
    raw = io.open(p, encoding='utf-8').read()
    for pat in REMOVED:
        if pat in raw:
            errors.append('%s: 残留已删除机制/预设内容「%s」—— 删了定义就要删光所有引用'
                          % (rel(p), pat))

# ============================================================
# awk 正则可移植性：方括号字符类里写 \t 只有 gawk 当制表符，
# Ubuntu 的 mawk、busybox awk 会把它当成字面的反斜杠和字母 t，
# 于是"以 tab 缩进的行"永远匹配不上（iw/ubus 的输出全是 tab 缩进）。
# 一律用 POSIX 的 [[:space:]]。
# ============================================================
AWK_CLASS = re.compile(r'\[[^\]\n]*\\[tn][^\]\n]*\]')
for p in walk('.sh'):
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        if '[[:space:]]' in line:
            continue
        m = AWK_CLASS.search(line)
        if m:
            errors.append('%s:%d: awk 字符类里用了 %s——gawk 之外不当转义'
                          '（mawk/busybox awk），改用 [[:space:]]'
                          % (rel(p), i, m.group(0)))

# ============================================================
# 输出
# ============================================================
for w in warnings:
    print('[warn] ' + w)
for e in errors:
    print('[FAIL] ' + e)

print('---')
print('错误 %d 条，警告 %d 条' % (len(errors), len(warnings)))
sys.exit(1 if errors else 0)
