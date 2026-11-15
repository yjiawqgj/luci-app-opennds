# -*- coding: utf-8 -*-
import os, re, glob

os.chdir(r'J:/TDDOWNLOAD/OpenNDS/汇总')
docs = {}
for p in glob.glob('*.md') + glob.glob('*/*.md'):
    docs[os.path.basename(p)] = open(p, encoding='utf-8').read()

heads = {}
for name, txt in docs.items():
    hs = set()
    for m in re.finditer(r'^#{2,4}\s+(\d+(?:\.\d+)*)', txt, re.M):
        hs.add(m.group(1))
    heads[name] = hs

problems = []

for name, txt in docs.items():
    for m in re.finditer(r'《([^》]+?\.md)》\s*§(\d+(?:\.\d+)*)', txt):
        tgt, sec = m.group(1), m.group(2)
        if tgt not in docs:
            problems.append(f'{name}: 引用不存在的文档 {tgt}')
        elif sec not in heads[tgt]:
            problems.append(f'{name}: 《{tgt}》§{sec} 不存在')
        elif '.' in sec:
            par = sec.rsplit('.', 1)[0]
            if par not in heads[tgt]:
                problems.append(f'{name}: 《{tgt}》§{sec} 的父节 §{par} 不存在')

for name, txt in docs.items():
    for m in re.finditer(r'§(\d+(?:\.\d+)*)', txt):
        sec = m.group(1)
        start = m.start()
        pre = txt[max(0, start - 60):start]
        if re.search(r'《[^》]*\.md》\s*$', pre):
            continue
        if sec not in heads[name]:
            problems.append(f'{name}: 文内 §{sec} 不存在')
        elif '.' in sec:
            par = sec.rsplit('.', 1)[0]
            if par not in heads[name]:
                problems.append(f'{name}: 文内 §{sec} 的父节 §{par} 不存在')

# 决策编号：只认「| # | 决策点 | 结论 |」这种带编号的表
decs = {}
for name, txt in docs.items():
    nums = set()
    for m in re.finditer(r'^\|\s*(\d+)\s*\|', txt, re.M):
        nums.add(int(m.group(1)))
    decs[name] = nums

PAGE_ALIAS = {'路由器访问页': '路由器访问.md', 'WalledGarden 页': 'WalledGarden.md',
              'Walled Garden 页': 'WalledGarden.md', '黑名单页': '客户端黑名单.md',
              '豁免页': '客户端豁免管理.md', '会话页': '客户端会话管理.md',
              '区域识别页': '区域识别.md', '设置页': 'OpenNDS设置.md'}

for name, txt in docs.items():
    for m in re.finditer(r'决策\s*#(\d+)', txt):
        n = int(m.group(1))
        start = m.start()
        pre = txt[max(0, start - 24):start]
        # 1) 《X.md》决策 #n
        md = re.search(r'《([^》]+?\.md)》\s*$', pre)
        if md:
            tgt = md.group(1)
            if tgt not in docs:
                problems.append(f'{name}:{txt[:start].count(chr(10))+1}: 决策引用不存在的文档 {tgt}')
            elif n not in decs[tgt]:
                problems.append(f'{name}:{txt[:start].count(chr(10))+1}: 《{tgt}》决策 #{n} 不存在（该文档决策编号 {sorted(decs[tgt])}）')
            continue
        # 2) <页面简称>决策 #n / 该页文档决策 #n
        al = re.search(r'([\u4e00-\u9fa5A-Za-z ]{2,8}?页)\s*$', pre)
        if al and al.group(1) in PAGE_ALIAS:
            tgt = PAGE_ALIAS[al.group(1)]
            if n not in decs[tgt]:
                problems.append(f'{name}:{txt[:start].count(chr(10))+1}: {al.group(1)}决策 #{n} 不存在')
            continue
        if re.search(r'该页文档\s*$', pre):
            continue  # 指向的是被引用页面，无法静态判定，跳过
        # 3) 本文内决策 #n
        if n not in decs[name]:
            problems.append(f'{name}:{txt[:start].count(chr(10))+1}: 文内决策 #{n} 不存在（本文决策编号 {sorted(decs[name])}）')

for name, txt in docs.items():
    lines = txt.split('\n')
    i = 0
    while i < len(lines):
        if lines[i].strip().startswith('|') and i + 1 < len(lines) and re.match(r'^\s*\|[\s:\-|]+\|\s*$', lines[i + 1]):
            hdr = lines[i].strip().strip('|')
            n = hdr.count('|') + 1
            sep = lines[i + 1].strip().strip('|').count('|') + 1
            if sep != n:
                problems.append(f'{name}:{i+2}: 分隔行列数 {sep}!={n}')
            j = i + 2
            while j < len(lines) and lines[j].strip().startswith('|'):
                cells = lines[j].strip().strip('|').replace('\\|', '')
                c = cells.count('|') + 1
                if c != n:
                    problems.append(f'{name}:{j+1}: 表格列数 {c}!={n}')
                j += 1
            i = j
        else:
            i += 1

for name, txt in docs.items():
    for pat in ['TODO', '待定', '，，', '。。', '、、', '；；', '（（', ')）']:
        for m in re.finditer(re.escape(pat), txt):
            line = txt[:m.start()].count('\n') + 1
            problems.append(f'{name}:{line}: 疑似笔误 {pat!r}')

# 代码块之外的双空格（中文正文里几乎一定是误留）
for name, txt in docs.items():
    in_fence = False
    for idx, line in enumerate(txt.split('\n'), 1):
        s = re.sub(r'^[ \t]*(>[ \t]?)*', '', line)  # 去掉缩进与引用符
        if s.strip().startswith('```'):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.search(r'\S  +\S', s)
        if m:
            problems.append(f'{name}:{idx}: 正文里有连续空格 {m.group(0)!r}')

# 「」括号配对
for name, txt in docs.items():
    if txt.count('「') != txt.count('」'):
        problems.append(f'{name}: 「」不配对 {txt.count("「")}/{txt.count("」")}')

print('\n'.join(problems) if problems else '问题 0')
