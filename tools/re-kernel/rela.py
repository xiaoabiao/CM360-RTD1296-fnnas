#!/usr/bin/env python3
"""rela.py —— fnOS 6.18.18-trim 内核「重定位感知」结构体解码器

背景（关键发现）：这个内核开了 CONFIG_RELOCATABLE，指针**不是原地存储**的，
而是以 R_AARCH64_RELATIVE(1027) 重定位记录的形式存在于 .rela.dyn：
    Elf64_Rela = { u64 r_offset; u64 r_info; i64 r_addend }
    r_offset = 指针槽位的 VA，r_addend = 指针值
所以直接按 8 字节读结构体字段会读到 0；必须查 RELA 表还原指针。

用法：
  ./rela.py rela <slot_va>              # 查槽位里的指针值（含符号名）
  ./rela.py str <va>                    # 读 VA 处的 NUL 结尾字符串
  ./rela.py sym <va>                    # 地址落在哪个符号
  ./rela.py fields <va> <size>          # 按 8 字节列出结构体字段（自动查 RELA）
  ./rela.py fs-params <va>              # 解码 struct fs_parameter_spec[]（挂载选项表）
  ./rela.py word <va>                   # 读原地 u32/u64 等
"""
import struct
import sys
from bisect import bisect_right

BASE = 0xFFFF800080000000
import os
DIR = os.environ.get("RE_DIR", "/home/xiaoabiao/.cache/fnnas/re-6.18")          # 素材目录（vmlinuz + System.map）
IMG = os.environ.get("RE_IMG", f"{DIR}/vmlinuz-6.18.18-trim")
MAP = os.environ.get("RE_MAP", f"{DIR}/System.map-6.18.18-trim")

RELA_SCAN_START = 0x1710000   # 含 .init.* 与 .rela.dyn
RELA_SCAN_END = 0x1C80000

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


def build_rela():
    """返回 {slot_va: addend}，只收 R_AARCH64_RELATIVE"""
    out = {}
    for off in range(RELA_SCAN_START, RELA_SCAN_END - 23, 8):
        roff, rinfo, radd = struct.unpack_from("<QQQ", IMG_DATA, off)
        if (rinfo & 0xFFFFFFFF) != 1027:
            continue
        if not (BASE <= roff < 0xFFFF800083000000):
            continue
        out[roff] = radd
    return out


RELA = build_rela()


def raw(va, n):
    off = va - BASE
    return IMG_DATA[off:off + n]


def word(va, size=8, signed=False):
    """字段值：优先查 RELA（指针），否则读原地字节"""
    if size == 8 and va in RELA:
        return RELA[va], "rela"
    return int.from_bytes(raw(va, size), "little", signed=signed), "inline"


def cstr(va):
    if va == 0:
        return None
    out = bytearray()
    off = va - BASE
    while off < len(IMG_DATA) and IMG_DATA[off] != 0 and len(out) < 512:
        out.append(IMG_DATA[off])
        off += 1
    try:
        return out.decode()
    except UnicodeDecodeError:
        return repr(bytes(out))


RODATA_LO, RODATA_HI = 0xFFFF800081170000, 0xFFFF8000816F1000


def pv(v):
    """打印指针值：只有落在 .rodata 才当字符串解（避免把代码字节误显示成字符串）"""
    if v == 0:
        return "NULL"
    if RODATA_LO <= v < RODATA_HI:
        s = cstr(v)
        if s and s.isprintable():
            return f"0x{v:x} {sym_of(v)}  str={s!r}"
    return f"0x{v:x} {sym_of(v)}"


def fs_params(va):
    print(f"=== struct fs_parameter_spec[] @ 0x{va:x} ===")
    print("    （name / type=NULL 表示布尔 flag / opt / flags / data）")
    for i in range(64):
        ent = va + i * 32
        name_v, _ = word(ent)
        if name_v == 0:
            print(f"  [{i:2d}] NULL —— 数组结束 @ 0x{ent:x}")
            break
        type_v, _ = word(ent + 8)
        opt, _ = word(ent + 16, 1)
        flags, _ = word(ent + 18, 2)
        data_v, _ = word(ent + 24)
        print(f"  [{i:2d}] name={cstr(name_v)!r:28s} type={sym_of(type_v) if type_v else 'NULL(=bool flag)':26s} "
              f"opt={opt:<4d} flags=0x{flags:x} data={pv(data_v)}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "rela":
        for a in sys.argv[2:]:
            va = int(a, 16)
            v, src = word(va)
            print(f"slot 0x{va:x} ({sym_of(va)}) = {pv(v)}  [{src}]")
    elif cmd == "str":
        for a in sys.argv[2:]:
            print(repr(cstr(int(a, 16))))
    elif cmd == "sym":
        for a in sys.argv[2:]:
            print(f"0x{int(a,16):x} -> {sym_of(int(a,16))}")
    elif cmd == "fields":
        va = int(sys.argv[2], 16)
        size = int(sys.argv[3], 0)
        print(f"=== 0x{va:x} ({sym_of(va)}) 起 {size:#x} 字节，按 8 字节字段 ===")
        for i in range(0, size, 8):
            v, src = word(va + i)
            if v == 0:
                continue
            print(f"  +0x{i:03x}: {pv(v)}  [{src}]")
    elif cmd == "fs-params":
        fs_params(int(sys.argv[2], 16))
    elif cmd == "word":
        va = int(sys.argv[2], 16)
        size = int(sys.argv[3], 0) if len(sys.argv) > 3 else 8
        v, src = word(va, size)
        print(f"0x{va:x} = {v:#x} ({v}) [{src}]")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
