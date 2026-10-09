#!/usr/bin/env python3
"""cmp-syms.py —— fnOS 6.18.18-trim 与【上游自建 v6.18.18】的符号级对照

产物：
  1) fnOS 有、上游无的函数  → 厂商新增（比"标识符差集"权威：无宏生成假阳性）
  2) 上游有、fnOS 无的函数  → 被删除/改名（如 acl_permission_check）
  3) 同名但尺寸不同的函数    → 被修改的候选（GCC 12.2 vs 12.5 有噪声，故给分布并标注阈值）
"""
import os
import re, sys
from collections import defaultdict

DIR = os.environ.get("RE_DIR", "/home/xiaoabiao/.cache/fnnas/re-6.18")
REF = os.environ.get("RE_REF_DIR", "/home/xiaoabiao/.cache/fnnas/upstream/build618")

def load(path):
    syms=[]
    for line in open(path):
        p=line.split()
        if len(p)==3:
            try: syms.append((int(p[0],16),p[2],p[1]))
            except ValueError: pass
    syms.sort()
    return syms

def sizes(syms):
    """同名符号取第一个；size = 下一个符号地址 - 本地址（按地址序）"""
    out={}
    for i,(a,n,t) in enumerate(syms):
        if t not in 'tTwW': continue
        if n in out: continue
        nxt = syms[i+1][0] if i+1 < len(syms) else a
        out[n]=(a,nxt-a,t)
    return out

fnos=sizes(load(os.environ.get("RE_MAP", f"{DIR}/System.map-6.18.18-trim")))
up=sizes(load(f"{REF}/System.map"))

only_fnos=sorted(set(fnos)-set(up))
only_up=sorted(set(up)-set(fnos))
common=set(fnos)&set(up)
deltas=[]
for n in common:
    d=fnos[n][1]-up[n][1]
    if d: deltas.append((abs(d),d,n,up[n][1],fnos[n][1]))
deltas.sort(reverse=True)

print(f"fnOS 函数总数 {len(fnos)} / 上游 {len(up)} / 同名 {len(common)}")
print(f"仅 fnOS 有: {len(only_fnos)}   仅上游有: {len(only_up)}   尺寸不同: {len(deltas)} ({100*len(deltas)/max(1,len(common)):.1f}%)")
# 噪声基线：尺寸差 <=16 字节的占比
small=sum(1 for _,d,_,_,_ in deltas if abs(d)<=16)
print(f"其中 |Δ|<=16 字节（大概率 GCC 12.2/12.5 代码生成噪声）: {small}")

def dump(names, title, limit=None):
    print(f"\n===== {title} =====")
    for n in (names if limit is None else names[:limit]):
        print("   ", n)

pat=re.compile(sys.argv[1]) if len(sys.argv)>1 else None
vf=[n for n in only_fnos if not pat or pat.search(n)]
dump(sorted(vf), f"仅 fnOS 有的函数（厂商新增，共 {len(vf)}）", 400)

up_only=[n for n in only_up if not pat or pat.search(n)]
dump(sorted(up_only), f"仅上游有的函数（被删/改名，共 {len(up_only)}）", 200)

print(f"\n===== 尺寸差异最大的 80 个（候选：被改过的上游函数）=====")
for _,d,n,su,sf in deltas[:80]:
    print(f"   Δ={d:+6d}  上游 {su:5d} → fnOS {sf:5d}   {n}")
