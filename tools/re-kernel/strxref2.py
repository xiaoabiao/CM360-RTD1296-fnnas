#!/usr/bin/env python3
"""strxref.py —— fnOS 6.18.18-trim 内核「字符串锚定交叉引用」工具 v2

用途：找出**没有新符号的厂商改动**。示例：让 btrfs/ext4 接受 `trimacl` 选项
这类改动发生在上游函数体内部，唯一可靠锚点就是厂商私有字符串：
    找到字符串 → 反查引用它的指令 → 指认被改的上游函数。

v2 修正了两个致命 bug（v1 因此漏报全部引用）：
  1) ADRP 之后的 ADD/LDR 必须比对 **Rn（基址寄存器）**，v1 错比了 Rd；
  2) printk 格式串在内存里的**真实起点前面还有控制前缀**（\\001 + loglevel 数字），
     正则捞到的地址偏后 1~3 字节 → 必须按"字符串区间"反查引用，而不是精确等值。

用法：
  ./strxref.py find 'trimacl'          # 字符串 → 引用它的函数（含前缀修正）
  ./strxref.py find-re 'trim.*'        # 正则批量
  ./strxref.py refs 0xffff80008152e160 # 指定 VA 的引用点（含落在串内的引用）
  ./strxref.py allrefs 'trim|trash'    # 所有指向"含该词的字符串"的代码位置
  ./strxref.py dumpstr 'trim'          # 列出字符串及其 VA
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

TEXT_END = 0x1170000
RODATA_START = 0x1170000
RODATA_END = 0x16F1000

IMG_DATA = open(IMG, "rb").read()


def load_syms():
    syms = []
    for line in open(MAP):
        p = line.split()
        if len(p) == 3:
            try:
                syms.append((int(p[0], 16), p[2], p[1]))
            except ValueError:
                pass
    syms.sort()
    return syms, [s[0] for s in syms]


SYMS, ADDRS = load_syms()


def sym_of(a):
    i = bisect_right(ADDRS, a) - 1
    if i < 0:
        return f"<{a:#x}>"
    ad, n, t = SYMS[i]
    return f"{n}+0x{a-ad:x}" if a != ad else n


def sign_ext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def collect_strings():
    """收集 rodata 里所有可打印串（起点前允许 1~3 个控制字节前缀）"""
    out = []
    seg = IMG_DATA[RODATA_START:RODATA_END]
    for m in re.finditer(rb"[\x20-\x7e]{4,}\x00", seg):
        start = m.start()
        # 向前吞掉控制前缀（\\001 + loglevel），这些是 printk 格式串的一部分
        while start > 0 and 1 <= seg[start - 1] <= 7 and (m.start() - start) < 4:
            start -= 1
        va = BASE + RODATA_START + start
        body = seg[start:m.start()].decode("latin1") + m.group()[:-1].decode("latin1")
        out.append((va, len(m.group()) + (m.start() - start), body))
    return out


STRINGS = collect_strings()
# 覆盖索引：落在字符串区间内的任意 VA -> 该字符串起点
COVER = {}
for va, ln, body in STRINGS:
    for k in range(ln):
        COVER[va + k] = va
STR_BY_VA = {va: body for va, ln, body in STRINGS}


def scan_text():
    """扫描 .text，返回 {target_va: set(caller_va)}"""
    refs = {}
    text = IMG_DATA[:TEXT_END]

    def add(t, c):
        refs.setdefault(t, set()).add(c)

    for off in range(0, len(text) - 3, 4):
        (insn,) = struct.unpack_from("<I", text, off)
        pc = BASE + off
        opc = insn & 0x9F000000
        if opc in (0x10000000, 0x90000000):          # ADR / ADRP
            rd = insn & 0x1F
            imm = sign_ext((((insn >> 5) & 0x7FFFF) << 2) | ((insn >> 29) & 3), 21)
            is_page = opc == 0x90000000
            base_val = ((pc & ~0xFFF) + (imm << 12)) if is_page else (pc + imm)
            for j in range(1, 9):
                o2 = off + j * 4
                if o2 + 4 > len(text):
                    break
                (i2,) = struct.unpack_from("<I", text, o2)
                rn = (i2 >> 5) & 0x1F
                if rn != rd:
                    continue
                if (i2 & 0xFFC00000) == 0x91000000:      # ADD (imm) 64-bit
                    add(base_val + ((i2 >> 10) & 0xFFF), pc)
                    break
                if (i2 & 0xFFC00000) == 0xF9400000:      # LDR (imm) 64-bit
                    add(base_val + ((i2 >> 10) & 0xFFF) * 8, pc)
                    break
                if (i2 & 0xFF800000) in (0x52800000, 0x72800000, 0x12800000):
                    continue                              # mov/movk 变体，继续找
                break
        elif (insn & 0xFF000000) == 0x58000000:          # LDR (literal)
            add(pc + sign_ext((insn >> 5) & 0x7FFFF, 19) * 4, pc)
    return refs


REFS = scan_text()


def refs_of(va):
    """对某字符串起点，汇总落在它区间内的所有代码引用"""
    hits = set()
    for k in range(len(STR_BY_VA.get(va, "")) + 4):
        hits |= REFS.get(va + k, set())
    return hits


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd in ("find", "find-re"):
        pat = re.compile(sys.argv[2], re.I if cmd == "find-re" else 0)
        for va, body in sorted(STR_BY_VA.items()):
            if not pat.search(body):
                continue
            hits = refs_of(va)
            print(f"--- 0x{va:x}  {body!r}   [{len(hits)} 个引用]")
            for c in sorted(hits):
                print(f"      code 0x{c:x}  {sym_of(c)}")
    elif cmd == "allrefs":
        pat = re.compile(sys.argv[2], re.I)
        rows = []
        for va, body in STR_BY_VA.items():
            if not pat.search(body):
                continue
            hits = refs_of(va)
            if hits:
                rows.append((va, body, hits))
        rows.sort()
        for va, body, hits in rows:
            print(f"0x{va:x}  {body[:70]!r}")
            for c in sorted(hits):
                print(f"    <= 0x{c:x} {sym_of(c)}")
    elif cmd == "refs":
        va = int(sys.argv[2], 16)
        start = COVER.get(va, va)
        print(f"string@0x{start:x}: {STR_BY_VA.get(start)!r}")
        for c in sorted(refs_of(start)):
            print(f"  code 0x{c:x}  {sym_of(c)}")
    elif cmd == "dumpstr":
        pat = re.compile(sys.argv[2] if len(sys.argv) > 2 else "trim", re.I)
        for va, body in sorted(STR_BY_VA.items()):
            if pat.search(body):
                print(f"0x{va:x}  {body!r}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
