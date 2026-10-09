#!/usr/bin/env python3
"""vtab.py —— 枚举厂商的「操作表」结构体（file_operations / inode_operations / super_operations …）

原理：厂商函数在二进制里只以两种方式被"挂载"：
  1) 代码里直接 BL 调用（调用点级证据，见 xref.py）
  2) 被填进某个 struct 的函数指针字段（**操作表**），由 VFS 按 vtable 分发
第 2 类才是"设备表/接口表"的全貌：把 RELA 记录里所有指到厂商函数的槽位收集起来，
按槽位所在的符号（= 表名）分组，就得到每张表的逐字段内容。

用法：
  ./vtab.py vendor                 # 全部厂商函数所在的表（按表名分组）
  ./vtab.py table trimafs_dir_inode_operations   # 单张表的逐字段
  ./vtab.py find trimafs                 # 表名含 trimafs 的所有数据符号
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
RELA_LO, RELA_HI = 0x1710000, 0x1C80000

IMG_DATA = open(IMG, "rb").read()

SYMS = []
for line in open(MAP):
    p = line.split()
    if len(p) == 3:
        try:
            SYMS.append((int(p[0], 16), p[2], p[1]))
        except ValueError:
            pass
SYMS.sort()
ADDRS = [s[0] for s in SYMS]


def sym_of(a):
    i = bisect_right(ADDRS, a) - 1
    if i < 0:
        return f"<{a:#x}>"
    ad, n, t = SYMS[i]
    return f"{n}+0x{a-ad:x}" if a != ad else n


def sym_at(a):
    """仅当 a 正好是符号起点时返回名字"""
    i = bisect_right(ADDRS, a) - 1
    if i >= 0 and SYMS[i][0] == a:
        return SYMS[i][1]
    return None


def build_maps():
    """返回 (slot->value, value->[slots])"""
    fwd, rev = {}, {}
    for off in range(RELA_LO, RELA_HI - 23, 8):
        roff, rinfo, radd = struct.unpack_from("<QQQ", IMG_DATA, off)
        if (rinfo & 0xFFFFFFFF) != 1027:
            continue
        if not (BASE <= roff < 0xFFFF800083000000):
            continue
        fwd[roff] = radd
        rev.setdefault(radd, []).append(roff)
    return fwd, rev


FWD, REV = build_maps()


# ★ 只收"确认的厂商命名族"：宏生成的 token-paste 名字（bql_show_limit 之类）会
#   污染"上游标识符差集"，故这里必须用显式命名族，而不是"不在上游标识符里"。
VENDOR_RE = (r"^(trimafs_|trim_trashbin|trim_(check_acl|access_|acl_permission|is_in_group|do_trashbin|"
             r"mounts_query_by_sb|syscall_|is_on_trashbin)|is_vol|is_mount_on_vol|vol_setattr_force|"
             r"do_statfs_sum|is_user_dir|may_user_dir_d|is_str_num|is_team_trashbin|"
             r"get_team_trashbin|is_move_to_trash|do_trimafs|init_trimafs|exit_trimafs|_trim_is_on_trashbin)")


def vendor_funcs(pat=VENDOR_RE):
    rx = re.compile(pat)
    out = {}
    for a, n, t in SYMS:
        if t not in "tTwW":
            continue
        base = re.sub(r"\.(constprop|isra|part|cold|clone|noclone)\.\d+$", "", n)
        if rx.search(base):
            out[a] = n
    return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd in ("vendor", "tables"):
        vf = vendor_funcs(sys.argv[2] if len(sys.argv) > 2 else VENDOR_RE)
        # 表名 -> [(字段偏移, 函数名)]
        tables = {}
        loose = []
        for a, n in vf.items():
            slots = REV.get(a, [])
            if not slots:
                loose.append(n)
            for s in slots:
                tbl = sym_at(s)
                if tbl is None:
                    # 槽位不在符号起点 → 归到"最近的表"（同符号内偏移不一定为 0）
                    tbl = sym_of(s)
                tables.setdefault(tbl, []).append((s, n))
        for tbl in sorted(tables):
            # 只保留"表"形态：同一名字有 >=2 个厂商函数，或名字含 operations/fops/attr
            entries = tables[tbl]
            base_name = tbl.split("+")[0]
            if cmd == "tables" and len(entries) < 2 and not re.search(
                    r"operations|fops|_ops$|parameters|attribute|xattr", base_name):
                continue
            print(f"\n== {tbl}  ({len(entries)} 个厂商函数指针) ==")
            for s, n in sorted(entries):
                print(f"    slot 0x{s:x}  -> {n}")
        print(f"\n== 未被任何表引用、也不在任何表内的厂商函数（{len(loose)} 个，靠 BL 调用）==")
        for n in sorted(loose):
            print(f"    {n}")
    elif cmd == "table":
        name = sys.argv[2]
        addr = None
        for a, n, t in SYMS:
            if n == name:
                addr = a
                break
        if addr is None:
            print("符号未找到")
            return
        print(f"== {name} @ 0x{addr:x} ==")
        i = ADDRS.index(addr)
        end = SYMS[i + 1][0] if i + 1 < len(SYMS) else addr + 0x400
        for s in range(addr, end, 8):
            v = FWD.get(s, 0)
            if v:
                print(f"    +0x{s-addr:03x} -> 0x{v:x} {sym_of(v)}")
    elif cmd == "find":
        pat = re.compile(sys.argv[2])
        for a, n, t in SYMS:
            if pat.search(n) and t in "dDbBrR":
                print(f"    {t} 0x{a:x} {n}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
