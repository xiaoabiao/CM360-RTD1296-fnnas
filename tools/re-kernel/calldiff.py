#!/usr/bin/env python3
"""calldiff.py —— 对比同一函数的【调用目标集合】：fnOS 6.18.18-trim  vs  上游自建 v6.18.18

为什么需要：`xref.py` 只能抓"调用厂商符号"的改动；厂商有些改动**不调用新符号**
（直接在原函数内操作厂商全局表）。calldiff 把两侧的 `bl` 目标解成符号名做差集，
新增的目标就是厂商插进去的逻辑 —— 这是最省事的"改动点定位器"。

用法：
  ./calldiff.py path_mount path_umount do_mkdirat
"""
import re, subprocess, sys
from bisect import bisect_right

BASE = 0xFFFF800080000000
import os
DIR = os.environ.get("RE_DIR", "/home/xiaoabiao/.cache/fnnas/re-6.18")
IMG = os.environ.get("RE_IMG", f"{DIR}/vmlinuz-6.18.18-trim")
REF = os.environ.get("RE_REF_VMLINUX", "/home/xiaoabiao/.cache/fnnas/upstream/build618/vmlinux")
OB = "aarch64-linux-gnu-objdump"

def load_map(p):
    s = []
    for line in open(p):
        x = line.split()
        if len(x) == 3:
            try: s.append((int(x[0], 16), x[2]))
            except ValueError: pass
    s.sort()
    return s, [y[0] for y in s]

FS, FSA = load_map(os.environ.get("RE_MAP", f"{DIR}/System.map-6.18.18-trim"))
US, USA = load_map(os.environ.get("RE_REF_MAP", "/home/xiaoabiao/.cache/fnnas/upstream/build618/System.map"))

def nm(sym, mp, ma):
    i = bisect_right(ma, sym) - 1
    if i < 0: return f"<0x{sym:x}>"
    return mp[i][1] + (f"+0x{sym-mp[i][0]:x}" if sym != mp[i][0] else "")

# ★ 坑：ELF 反汇编的 bl 目标**不带 0x 前缀**，二进制反汇编带 → 必须都兼容
BL_ELF = re.compile(r"^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+bl\s+(?:0x)?([0-9a-f]+)", re.M)
BL_BIN = re.compile(r"^\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+bl\s+0x([0-9a-f]+)", re.M)

def calls_ref(sym):
    out = subprocess.run([OB, "-d", f"--disassemble={sym}", REF],
                         capture_output=True, text=True).stdout
    return [int(m.group(1), 16) for m in BL_ELF.finditer(out)]

def calls_fnos(sym):
    addr = next((a for a, n in FS if n == sym), None)
    if addr is None: return []
    off = addr - BASE
    raw = subprocess.run(["dd", f"if={IMG}", "bs=1M", "iflag=skip_bytes,count_bytes",
                          f"skip={off}", "count=6000", "status=none"],
                         capture_output=True).stdout
    with open("/tmp/calldiff.bin", "wb") as f: f.write(raw)
    out = subprocess.run([OB, "-D", "-b", "binary", "-m", "aarch64",
                          f"--adjust-vma={addr}", "/tmp/calldiff.bin"],
                         capture_output=True, text=True).stdout
    nxt = min([a for a, _ in FS if a > addr], default=addr + 6000)
    return [int(m.group(2), 16) for m in BL_BIN.finditer(out)
            if addr <= int(m.group(1), 16) < nxt]

for sym in sys.argv[1:]:
    A, B = calls_ref(sym), calls_fnos(sym)
    na = {nm(x, US, USA) for x in A}
    nb = {nm(x, FS, FSA) for x in B}
    print(f"=== {sym}：上游 {len(A)} / fnOS {len(B)} 个调用点 ===")
    add, rm = sorted(nb - na), sorted(na - nb)
    print("  ★ fnOS 新增调用目标:", ", ".join(add) if add else "（无）")
    print("  上游有、fnOS 无   :", ", ".join(rm) if rm else "（无）")
