#!/usr/bin/env python3
"""xref.py —— fnOS 6.18.18-trim 内核交叉引用扫描器

原理：arm64 的 BL/B 指令编码里带 26 位相对偏移。整段 .text 逐条扫描即可
反查出"谁调用了某个厂商符号" —— 这条线索直接指认**被厂商改过的上游函数**
（例如 namei.c/open.c 里插入的 trim_check_acl 调用）。

用法：
  ./xref.py callers trim_acl_permission          # 谁 call 了它（BL/B）
  ./xref.py callers-re 'trim_.*'                 # 批量：所有 trim_* 的调用者
  ./xref.py sym <addr>                           # 地址落在哪个符号内
  ./xref.py ncallers                             # 厂商符号被调用计数排序
"""
import re
import struct
import sys
from bisect import bisect_right

BASE = 0xFFFF800080000000
import os
DIR = os.environ.get("RE_DIR", "/home/xiaoabiao/.cache/fnnas/re-6.18")          # 素材目录（vmlinuz + System.map）
IMG = os.environ.get("RE_IMG", f"{DIR}/vmlinuz-6.18.18-trim")
MAP = os.environ.get("RE_MAP", f"{DIR}/System.map-6.18.18-trim")

TEXT_END = 0x1170000  # _etext - _text（实测锚点）


def load_syms():
    """返回 (按地址排序的 [(addr, name, type)], sorted_addrs)"""
    syms = []
    with open(MAP) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3:
                try:
                    syms.append((int(parts[0], 16), parts[2], parts[1]))
                except ValueError:
                    continue
    syms.sort()
    return syms, [s[0] for s in syms]


SYMS, ADDRS = load_syms()


def sym_of(addr):
    i = bisect_right(ADDRS, addr) - 1
    if i < 0:
        return None
    a, n, t = SYMS[i]
    return f"{n}+0x{addr - a:x}" if addr != a else n


def exact(name):
    for a, n, t in SYMS:
        if n == name:
            return a
    return None


def read_text():
    with open(IMG, "rb") as f:
        return f.read(TEXT_END)


def decode_calls(text):
    """扫描 .text，返回 {target_addr: [caller_addr,...]}（BL 与 B 都算）"""
    xref = {}
    # 4 字节对齐逐条
    for off in range(0, len(text) - 3, 4):
        (insn,) = struct.unpack_from("<I", text, off)
        op = insn & 0xFC000000
        if op not in (0x94000000, 0x14000000):  # BL, B
            continue
        imm = insn & 0x03FFFFFF
        if imm & 0x02000000:
            imm -= 0x04000000
        target = BASE + off + imm * 4
        xref.setdefault(target, []).append(BASE + off)
    return xref


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    text = read_text()
    xref = decode_calls(text)

    if cmd == "callers":
        for name in sys.argv[2:]:
            a = exact(name)
            if a is None:
                print(f"{name}: 符号不存在")
                continue
            cs = xref.get(a, [])
            print(f"== {name} @ 0x{a:x} —— 被调用 {len(cs)} 次 ==")
            for c in sorted(cs):
                print(f"   caller 0x{c:x}  {sym_of(c)}")
    elif cmd == "sym":
        for s in sys.argv[2:]:
            print(f"0x{int(s,16):x} -> {sym_of(int(s,16))}")
    elif cmd == "callers-re":
        pat = re.compile(sys.argv[2])
        targets = [(a, n, t) for a, n, t in SYMS if pat.search(n) and t in "tTwW"]
        rows = []
        for a, n, t in targets:
            cs = xref.get(a, [])
            if cs:
                rows.append((len(cs), n, a, cs))
        rows.sort(reverse=True)
        for cnt, n, a, cs in rows:
            callers = sorted({sym_of(c) for c in cs})
            print(f"{cnt:3d}x {n} @0x{a:x}  <= {', '.join(callers[:8])}")
    elif cmd == "ncallers":
        pat = re.compile(sys.argv[2] if len(sys.argv) > 2 else r"^trim_")
        targets = [(a, n) for a, n, t in SYMS if pat.search(n) and t in "tTwW"]
        for a, n in sorted(targets):
            print(f"{len(xref.get(a, [])):3d}  {n}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
