#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成厂商 Realtek USB MP Tool 格式的线刷包（install.img）。

依据（全部来自对厂商包的逆向，见 docs/10-vendor-usb-mp-tool-package.md）：

  install.img = POSIX tar，含
    layout.txt        绝对字节偏移表（刷到 eMMC 哪里）
    config.txt        包配置（fw = 名字 文件 RAM地址；part = ...）
    mbr.bin           分区表（512 字节，写在 offset=0）
    fw_tbl.bin        固件表（VERONA__，0x20 头 + 分区块 + 记录块，末尾 4 字节校验）
    <各个载荷>

  fw_tbl.bin 记录（64 字节）：
    0x00 u16 kind        0x8002 内核 / 0x8003 救援DTB / 0x8004 内核DTB
                         0x8005 救援rootfs / 0x8007 音频内核
    0x06 u32 target      加载到 RAM 的地址
    0x0A u32 offset      eMMC 绝对字节偏移
    0x12 u32 size        载荷精确大小
    0x16 u32 size_align  size 向上取整到 512
    0x1A 32B SHA-256(载荷)
    0x3A 6B 零填充

  头部校验：u32@0x08 == sum(bytes[0x0C:]) & 0xFFFFFFFF

注意：本脚本只负责“按格式造包”。厂商工具是否接受自定义条目、是否接受本板
引导链布局，**尚未实测**（需要 Windows + 物理 SW5 进 USB 下载模式）。
默认只造“系统部分”（MBR + p1 + p2），引导链保持厂商 bootcode 机制不启用。

用法：
  ./tools/make-lineflash-package.py                      # 造系统包（含 p2，约 7.8 GB）
  ./tools/make-lineflash-package.py --no-p2              # 不含 p2，用于快速验证格式
  ./tools/make-lineflash-package.py --out DIR            # 指定输出目录（建议放外置盘）
  ./tools/make-lineflash-package.py --dry-run            # 只校验并打印，不写 tar
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- 厂商 fw_tbl 的 kind 常量（从厂商表逆出） ----
K_KERNEL = 0x8002
K_RESCUE_DT = 0x8003
K_KERNEL_DT = 0x8004
K_RESCUE_ROOTFS = 0x8005
K_AUDIO_KERNEL = 0x8007

# fw_tbl 头部（固定 32 字节）
FW_TBL_MAGIC = b"VERONA__"
FW_TBL_VER = 2
FW_TBL_SECTOR = 512

# 记录块里每条记录的大小（厂商 fw_tbl: 320/5=64，gold: 256/4=64）
REC_SIZE = 64
# fw_tbl 的载荷 SHA-256 在记录内的偏移
REC_SHA_OFF = 0x1A

# 记录区在“各段”里的加载地址（沿用厂商 target，含义 = 加载到 RAM 的地址）
TARGET_KERNEL = 0x03000000
TARGET_KERNEL_DT = 0x02100000
TARGET_RESCUE_DT = 0x02140000
TARGET_RESCUE_ROOTFS = 0x30000000
TARGET_AUDIO_KERNEL = 0x01B00000

# 分区块条目：48 字节
PART_ENTRY_SIZE = 48


def align_up(n: int, a: int) -> int:
    return (n + a - 1) // a * a


def sha256_file(path: str) -> bytes:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.digest()


def read_mbr_from_lowregion(low: str) -> bytes:
    """低区镜像的前 512 字节就是 MBR（含 55aa 与 p1/p2 条目）。"""
    with open(low, "rb") as f:
        mbr = f.read(512)
    if mbr[0x1FE:0x200] != b"\x55\xaa":
        raise SystemExit(f"[!] {low} 前 512 字节没有 55aa 引导签名，不是 MBR")
    return mbr


def parse_mbr(mbr: bytes) -> list[dict]:
    out = []
    for i in range(4):
        e = mbr[0x1BE + i * 16: 0x1BE + i * 16 + 16]
        lba, sec = struct.unpack_from("<II", e, 8)
        if lba and sec:
            out.append({"idx": i + 1, "type": e[4], "lba": lba, "sectors": sec,
                        "offset": lba * 512, "bytes": sec * 512})
    return out


def build_fw_tbl(records: list[dict], parts: list[dict]) -> bytes:
    """
    records: [{'kind':int,'target':int,'offset':int,'path':str}]
    parts:   [{'index':int,'name':str,'offset':int,'bytes':int,'fs':int,'flags':int}]
    """
    rec_block = bytearray()
    for r in records:
        size = os.path.getsize(r["path"])
        rec = bytearray(REC_SIZE)
        struct.pack_into("<H", rec, 0x00, r["kind"])
        struct.pack_into("<I", rec, 0x06, r["target"])
        struct.pack_into("<I", rec, 0x0A, r["offset"])
        struct.pack_into("<I", rec, 0x12, size)
        struct.pack_into("<I", rec, 0x16, align_up(size, FW_TBL_SECTOR))
        rec[REC_SHA_OFF:REC_SHA_OFF + 32] = sha256_file(r["path"])
        rec_block += rec

    part_block = bytearray()
    for p in parts:
        e = bytearray(PART_ENTRY_SIZE)
        struct.pack_into("<I", e, 0x00, 2)                    # 类型：2 = 分区
        struct.pack_into("<I", e, 0x04, p["bytes"] >> 16)     # 大小（>>16，已验证）
        struct.pack_into("<B", e, 0x0A, p.get("flags", 1))
        struct.pack_into("<B", e, 0x0B, p.get("fs", 4))       # 2=squashfs, 4=ext4
        struct.pack_into("<B", e, 0x0C, p["index"])           # 分区号
        name = p["name"].encode("ascii", "replace")[:15]
        e[16:16 + len(name)] = name
        part_block += e

    head = bytearray(0x20)
    head[0:8] = FW_TBL_MAGIC
    struct.pack_into("<I", head, 0x0C, FW_TBL_VER)
    struct.pack_into("<I", head, 0x10, 0)
    struct.pack_into("<I", head, 0x14, FW_TBL_SECTOR)
    struct.pack_into("<I", head, 0x18, len(part_block))
    struct.pack_into("<I", head, 0x1C, len(rec_block))

    body = bytes(head) + bytes(part_block) + bytes(rec_block)
    checksum = sum(body[0x0C:]) & 0xFFFFFFFF
    body = body[:0x08] + struct.pack("<I", checksum) + body[0x0C:]
    return body


def verify_fw_tbl(blob: bytes) -> list[str]:
    """回读校验：magic / 校验和 / 记录块大小 / 每条 SHA-256 是否能重算。"""
    errs = []
    if blob[:8] != FW_TBL_MAGIC:
        errs.append("magic 不对")
    want = struct.unpack_from("<I", blob, 0x08)[0]
    got = sum(blob[0x0C:]) & 0xFFFFFFFF
    if want != got:
        errs.append(f"校验和 {want:#x} != 重算 {got:#x}")
    part_sz = struct.unpack_from("<I", blob, 0x18)[0]
    rec_sz = struct.unpack_from("<I", blob, 0x1C)[0]
    if 0x20 + part_sz + rec_sz != len(blob):
        errs.append(f"块大小不自洽：0x20+{part_sz}+{rec_sz} != {len(blob)}")
    if rec_sz % REC_SIZE:
        errs.append(f"记录块 {rec_sz} 不是 {REC_SIZE} 的整数倍")
    return errs


def build_layout_txt(entries: dict) -> str:
    L = []
    A = L.append
    A('#define CREATE_DATE " %s "' % entries.get("date", ""))
    A('#define CREATE_TIME " %s "' % entries.get("time", ""))
    A('#define BOOTTYPE " BOOTTYPE_COMPLETE "')
    A("#define SSUWORKPART 0")
    A("#define BOOTPART 0")
    for name, off, size, fname in entries["fw"]:
        A('#define %s " target=%x offset=%x size=%x type=bin name=%s "'
          % (name, entries["fw_target"][name], off, size, fname))
    for i, (part, off, size, mount, fs, fname) in enumerate(entries["part"]):
        A('#define PART%d " offset=%x size=%x mount_point=%s mount_dev=/dev/block/mmcblk0p%d '
          'filesystem=%s partname=%s type=img name=%s "'
          % (i, off, size, mount, i + 1, fs, part, fname))
    A('#define MBR0 " offset=0 size=200 name=mbr.bin "')
    for name, off, size, fname in entries.get("extra", []):
        A('#define %s " target=0 offset=%x size=%x type=bin name=%s "' % (name, off, size, fname))
    A("#define TAG 45")
    return "\n".join(L) + "\n"


def build_config_txt(entries: dict) -> str:
    L = []
    A = L.append
    A("# Package Information")
    A('company="CM360"')
    A('description="CM360 RTD1296 fnOS (community build)"')
    A('modelname="CM360"')
    A('version="%s"' % entries["version"])
    A('releaseDate="%s"' % entries.get("date", ""))
    A('signature=""')
    A("# Package Configuration")
    A("start_customer=y")
    A("verify=y")
    if entries.get("bootcode_y"):
        A("bootcode=y            # 启用工具原生引导链刷写路径（实验）")
    else:
        A("# bootcode=y            # 引导链由本包的 FW_LOWREGION/MBR 条目写入（或厂商工具单独刷）")
    A("install_dtb=y")
    A("# update_etc=y")
    A("install_avfile_count=0")
    A("reboot_delay=5")
    A("efuse_key=0")
    A("efuse_fw=0")
    A("rpmb_fw=0")
    A("secure_boot=0")
    A("###")
    A("###\t  fw = (type file target)")
    for name, _off, _size, fname in entries["fw"]:
        A("fw = %s %s 0x%x" % (entries["fw_cfg_name"][name], fname, entries["fw_target"][name]))
    A("###")
    A("###\t  part = (name mount_point filesystem file size)")
    for part, _off, size, mount, fs, fname in entries["part"]:
        A("part = %s %s %s %s %d" % (part, mount, fs, fname, size))
    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/run/media/xiaoabiao/1877ec11-c65c-4b5e-a220-344ffae7ba61/cm360-lineflash")
    ap.add_argument("--version", default="1.2.0302")
    ap.add_argument("--low", default=os.path.join(REPO, "dist/dd-set/low-region.img"))
    ap.add_argument("--p1", default=os.path.join(REPO, "dist/dd-set/p1.img"))
    ap.add_argument("--p2", default=os.path.join(REPO, "dist/dd-set/p2.img"))
    ap.add_argument("--kernel", default=os.path.join(REPO, "artifacts/kernel-6.6.54/Image-6.6.uimage"))
    ap.add_argument("--dtb", default=os.path.join(REPO, "artifacts/kernel-6.6.54/rtd1296-cm360.dtb"))
    ap.add_argument("--no-p2", action="store_true", help="不打包 p2（快速验证格式用）")
    ap.add_argument("--dry-run", action="store_true", help="只生成元数据并自检，不写 tar")
    ap.add_argument("--keep-dir", action="store_true", help="保留暂存目录")
    ap.add_argument("--with-lowregion", action="store_true",
                    help="★ 把本板低区 38MiB 整块编入包（= 连 u-boot 一起刷，能救砖/一次刷全）")
    ap.add_argument("--lowregion-split", action="store_true",
                    help="低区拆成 MBR/HWSETTING/BOOTCODE/UBOOT/TEE/BL31 各一条（实验性，见文档 §11）")
    ap.add_argument("--bootcode-y", action="store_true",
                    help="在 config.txt 里启用 bootcode=y（测试工具原生引导链刷写路径）")
    ap.add_argument("--no-fw-tbl", action="store_true",
                    help="不把 fw_tbl.bin 放进包（本板引导链不使用该表）")
    ap.add_argument("--p2-compact", nargs="?", const="auto", default=None,
                    metavar="PATH",
                    help="用精简 p2 镜像（firmware/shrink-p2.sh 的产物）代替整分区裸镜像；"
                         "分区大小仍按真实分区声明。不带值则用 firmware/images/p2-compact.img")
    args = ap.parse_args()

    print("=" * 72)
    print("  CM360 线刷包生成器（Realtek USB MP Tool 格式）")
    print("=" * 72)

    # ---------- 1. 输入检查 ----------
    need = [("低区", args.low), ("p1", args.p1), ("内核", args.kernel), ("DTB", args.dtb)]
    if not args.no_p2:
        need.append(("p2", args.p2))
    for label, p in need:
        if not os.path.isfile(p):
            print(f"[!] 缺少{label}：{p}")
            return 2
        print(f"  [输入] {label:<4} {os.path.getsize(p):>13,}  {p}")

    # ---------- 2. 从低区取 MBR，读分区真实位置 ----------
    mbr = read_mbr_from_lowregion(args.low)
    parts = parse_mbr(mbr)
    print("\n  [MBR] 从低区镜像读出：")
    for p in parts:
        print(f"    分区{p['idx']} type={p['type']:#04x} 起始={p['offset']:,}({p['offset']/1048576:.0f} MiB) "
              f"大小={p['bytes']:,} ({p['bytes']/1073741824:.3f} GiB)")

    p1_bytes = os.path.getsize(args.p1)
    p2_bytes = 0 if args.no_p2 else os.path.getsize(args.p2)
    # 用 MBR 里的真实大小做一致性检查（p2 可能与 MBR 记录略有差异，以 MBR 为准并在包内说明）
    mbr_p1 = next((p for p in parts if p["offset"] == 0x13000 * 512), None)
    mbr_p2 = next((p for p in parts if p["offset"] == 0x93000 * 512), None)
    if mbr_p1 and p1_bytes > mbr_p1["bytes"]:
        print(f"  [!] p1 镜像 {p1_bytes:,} 超过 MBR 分区大小 {mbr_p1['bytes']:,}")
        return 2
    if mbr_p2 and p2_bytes and p2_bytes > mbr_p2["bytes"]:
        print(f"  [!] p2 镜像 {p2_bytes:,} 超过 MBR 分区大小 {mbr_p2['bytes']:,}")
        return 2
    print("  [校验] p1/p2 镜像大小均未超过分区容量 ✅")

    # ---------- 2b. 精简 p2（可选）----------
    # ★ 关键正确性：layout/config 里声明的 “分区大小” 必须取 **MBR 里的真实分区大小**，
    #   而不是随包文件的大小 —— 否则用精简镜像时会把分区声明成小尺寸。
    #   （厂商同样如此：rootfs 分区 128MiB 只带 97.9MB 镜像；etc 分区 6.875GiB 只带 512B。）
    p2_declared = mbr_p2["bytes"] if mbr_p2 else p2_bytes
    p2_payload = args.p2
    if args.p2_compact is not None:
        if args.no_p2:
            print("  [!] --p2-compact 与 --no-p2 互斥")
            return 2
        cp = args.p2_compact
        if cp == "auto":
            cp = os.path.join(REPO, "firmware/images/p2-compact.img")
        if not os.path.isfile(cp):
            print(f"  [!] 找不到精简 p2 镜像：{cp}")
            print("      先用 sudo firmware/shrink-p2.sh 生成")
            return 2
        cs = os.path.getsize(cp)
        if cs > p2_declared:
            print(f"  [!] 精简镜像 {cs:,} 反而大于分区 {p2_declared:,}")
            return 2
        # ★ 校验它是真的 btrfs，且超级块里的 total_bytes 与文件大小一致
        #   （防止把截断/半成品文件静默打进包 —— 那会刷出一个起不来的系统）
        try:
            ds = subprocess.run(["btrfs", "inspect-internal", "dump-super", "-f", cp],
                                capture_output=True, text=True, timeout=120)
            if ds.returncode != 0:
                print(f"  [!] {cp} 不是 btrfs 镜像（dump-super 失败）—— 拒绝打包")
                return 2
            tb = 0
            for ln in ds.stdout.splitlines():
                if ln.startswith("total_bytes"):
                    tb = int(ln.split()[1])
                    break
            if tb != cs:
                print(f"  [!] 精简镜像超级块 total_bytes={tb:,} 与文件大小 {cs:,} 不一致"
                      f"（截断或未收缩干净？）—— 拒绝打包")
                return 2
            print(f"  [精简 p2] btrfs 校验 ✅ 超级块 total_bytes={tb:,} 与文件大小一致")
        except FileNotFoundError:
            print("  [精简 p2] ⚠️ 没装 btrfs-progs，跳过 btrfs 校验（建议装上再打包）")
        p2_payload = cp
        p2_bytes = cs
        print(f"\n  [精简 p2] 随包 {cs:,} ({cs/1073741824:.3f} GiB)"
              f"  分区声明 {p2_declared:,} ({p2_declared/1073741824:.3f} GiB)"
              f"  节省 {(p2_declared-cs)/1073741824:.3f} GiB")

    # ---------- 3. 组装条目 ----------
    # 本板引导链从 p1 的 ext4 读内核，所以内核/DTB 只作为“原料”放进包（可选槽位），
    # 系统本体靠 PART0/PART1 写入。
    date = subprocess.run(["date", "+%b %d %Y"], capture_output=True, text=True,
                          env={**os.environ, "LC_ALL": "C"}).stdout.strip()
    time_ = subprocess.run(["date", "+%H:%M:%S"], capture_output=True, text=True,
                           env={**os.environ, "LC_ALL": "C"}).stdout.strip()

    fw_entries = [
        ("FW_KERNEL", 0x00B28C00, args.kernel),
        ("FW_KERNEL_DT", 0x00B1CE00, args.dtb),
    ]
    fw_target = {"FW_KERNEL": TARGET_KERNEL, "FW_KERNEL_DT": TARGET_KERNEL_DT}
    fw_cfg_name = {"FW_KERNEL": "linuxKernel", "FW_KERNEL_DT": "kernelDT"}

    part_entries = [
        ("rootfs", 0x13000 * 512, p1_bytes, "/", "ext4", "p1.img"),
    ]
    if not args.no_p2:
        part_entries.append(("etc", 0x93000 * 512, p2_declared, "etc", "btrfs", "p2.img"))

    # ---------- 3b. 低区（引导链）可选编入 ----------
    # 低区各段起点（已知）。注意：实测 0x20E00→0x220886 之间没有任何 >=64KiB 的空白，
    # 各段是紧挨着连续排布的，**无法靠空白可靠切分**；因此默认整块写入（等价于 dd）。
    low_size = os.path.getsize(args.low)
    LOW_SEGMENTS = [
        ("MBR", 0x0, 0x200),
        ("HWSETTING", 0x20000, 0x20E00),
        ("BOOTCODE", 0x20E00, 0x7F300),
        ("UBOOT", 0x7F300, 0xB0600),
        ("TEE", 0xB0600, 0x12C400),
        ("BL31", 0x12C400, 0x220000),
    ]
    extra = []          # (NAME, offset, size, filename) → 写进 layout.txt
    low_split_files = {}  # filename -> 需要在暂存目录里物化的字节
    if args.lowregion_split:
        with open(args.low, "rb") as f:
            blob = f.read()
        for name, off, end in LOW_SEGMENTS:
            fn = f"{name.lower()}.bin"
            low_split_files[fn] = blob[off:end]
            extra.append((name, off, end - off, fn))
        print(f"\n  [低区] 拆分模式（实验性）：{len(extra)} 段，"
              f"合计 {sum(len(v) for v in low_split_files.values()):,} 字节")
    elif args.with_lowregion:
        extra.append(("FW_LOWREGION", 0, low_size, "low-region.img"))
        print(f"\n  [低区] 整块模式：offset=0 size={low_size:,}（含 MBR 与全部引导链段）")
        print("         ⚠️ 写入低区 = 连 u-boot 一起刷；中途断电/失败可能变砖（需 SW5 救回）")
    else:
        print("\n  [低区] 未编入：本包只含系统部分（MBR + p1/p2），不能救砖")

    recs = [{"kind": K_KERNEL, "target": TARGET_KERNEL, "offset": 0x00B28C00, "path": args.kernel},
            {"kind": K_KERNEL_DT, "target": TARGET_KERNEL_DT, "offset": 0x00B1CE00, "path": args.dtb}]
    tbl_parts = [{"index": i + 1, "name": ("/" if p[0] == "rootfs" else p[0]),
                  "offset": p[1], "bytes": p[2],
                  "fs": (4 if p[4] == "ext4" else 3)} for i, p in enumerate(part_entries)]

    fw_tbl = build_fw_tbl(recs, tbl_parts)
    errs = verify_fw_tbl(fw_tbl)
    print(f"\n  [fw_tbl.bin] 生成 {len(fw_tbl)} 字节，自检：{'✅ 全部通过' if not errs else '❌ ' + '; '.join(errs)}")
    if errs:
        return 2
    print(f"     头部校验 = {sum(fw_tbl[0x0C:]) & 0xFFFFFFFF:#010x}"
          f"   分区块 = {struct.unpack_from('<I', fw_tbl, 0x18)[0]} 字节"
          f"   记录块 = {struct.unpack_from('<I', fw_tbl, 0x1C)[0]} 字节")

    # ---------- 4. 打包（载荷直接从原路径写入 tar，零拷贝） ----------
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    staged = tempfile.mkdtemp(prefix="lineflash-", dir=out_dir)
    try:
        entries = {
            "version": args.version, "date": date, "time": time_,
            "fw": [(n, off, os.path.getsize(p), os.path.basename(p)) for n, off, p in fw_entries],
            "fw_target": fw_target, "fw_cfg_name": fw_cfg_name,
            "part": part_entries,
            "extra": extra,
            "bootcode_y": bool(args.bootcode_y),
        }
        small = {
            "layout.txt": build_layout_txt(entries).encode(),
            "config.txt": build_config_txt(entries).encode(),
            "mbr.bin": mbr,
            "README-线刷.txt": (LINEFLASH_README % {
                "ver": args.version,
                "p1": f"{p1_bytes:,}",
                "p2": (f"{p2_bytes:,}" + (f"（精简镜像；分区实际 {p2_declared:,} 字节，首启自动扩容）"
                                          if p2_payload != args.p2 else "")) if p2_bytes else "（未包含）",
                "low": ("未包含（只刷系统，不能救砖）" if not extra else
                        f"已包含：{extra[0][3]}，offset=0 size={extra[0][2]:,} 字节"),
                "bootnote": (
                    "  · 本包**含引导链**（低区整块 offset=0 写入，连 u-boot 一起刷）。\n"
                    "    ⇒ 从砖头状态开始刷也可以；但**写入低区期间断电会变砖**（需 SW5 救回）。\n"
                    "    ⇒ 刷新前建议先用 dd 或工具单独确认低区可用（或准备 SW5 救援环境）。"
                    if extra else
                    "  · 本包为“系统部分”，**不含引导链**（低区未编入；config.txt 里 bootcode=y 被注释）。\n"
                    "    ⇒ 板子必须已经能进 u-boot / 已有可用引导链；砖头状态刷本包救不回来。"),
            }).encode(),
        }
        if not args.no_fw_tbl:
            small["fw_tbl.bin"] = fw_tbl
        # 载荷：fw 条目用原文件；分区条目用 p1/p2；低区用原镜像或拆分产物
        payloads = [(p, os.path.basename(p)) for _n, _off, p in fw_entries]
        payloads += [(args.p1 if f[5] == "p1.img" else p2_payload, f[5]) for f in part_entries]
        if low_split_files:
            for fn, data in low_split_files.items():
                with open(os.path.join(staged, fn), "wb") as fh:
                    fh.write(data)
                payloads.append((os.path.join(staged, fn), fn))
        elif args.with_lowregion:
            payloads.append((args.low, "low-region.img"))

        print("\n  [包内容]")
        for n, d in sorted(small.items()):
            print(f"     {len(d):>13,}  {n}")
        for src, arc in payloads:
            print(f"     {os.path.getsize(src):>13,}  {arc}   ← {src}")

        if args.dry_run:
            for n, d in small.items():
                with open(os.path.join(staged, n), "wb") as f:
                    f.write(d)
            for src, arc in payloads:
                if os.path.dirname(src) != staged:      # 只物化拆分出来的临时段
                    print(f"     （载荷 {arc} 直接从 {src} 读取，不复制）")
            print("\n  --dry-run：不写 tar。生成的元数据保留在：", staged)
            print("\n✅ 格式自检通过（未实测厂商工具是否接受）")
            return 0

        img = os.path.join(
            out_dir,
            "install-cm360-fnos-%s-%s%s%s.img" % (
                args.version,
                "boot-" if extra else "",
                "compact-" if p2_payload != args.p2 else "",
                "full" if not args.no_p2 else "sysonly"))
        print(f"\n  [打包] → {img}")
        import io as _io
        import time as _time
        with tarfile.open(img, "w", format=tarfile.GNU_FORMAT) as tf:
            # 元数据小文件：直接从内存写入
            for n, d in sorted(small.items()):
                ti = tarfile.TarInfo(n)
                ti.size = len(d)
                ti.mtime = int(_time.time())
                ti.mode = 0o644
                tf.addfile(ti, _io.BytesIO(d))
            # 载荷：直接从原路径写入（零拷贝，不占额外空间）
            for src, arc in payloads:
                tf.add(src, arcname=arc, recursive=False)
        size = os.path.getsize(img)
        print(f"  [完成] {size:,} 字节 ({size/1073741824:.3f} GiB)")
        with open(img + ".md5", "w") as f:
            f.write(f"{hashlib.md5(open(img,'rb').read()).hexdigest()}  {os.path.basename(img)}\n")

        # 回读校验：解 tar 列表 + 从 tar 里取出 fw_tbl 重新自检（确认落盘内容正确）
        with tarfile.open(img) as tf:
            names = [m.name.lstrip("./") for m in tf.getmembers() if m.isfile()]
        back = tf_check(img, "fw_tbl.bin")
        errs2 = verify_fw_tbl(back)
        print(f"  [回读] tar 内 {len(names)} 个文件：{', '.join(sorted(names))}")
        print(f"  [回读] tar 内 fw_tbl.bin 自检：{'✅ 通过（%d 字节）' % len(back) if not errs2 else '❌ ' + '; '.join(errs2)}")
        if errs2:
            return 2
        print("\n✅ 生成完毕。未实测项：厂商工具是否接受自定义 layout 条目（需 Windows + SW5）")
        return 0
    finally:
        if not args.keep_dir and not args.dry_run:
            shutil.rmtree(staged, ignore_errors=True)


LINEFLASH_README = """CM360 (RTD1296) fnOS 线刷包 v%(ver)s
================================================================

包内容
  layout.txt / config.txt / mbr.bin [ / fw_tbl.bin ]   元数据（偏移表 / 配置 / 分区表 / 固件表）
  p1.img  %(p1)s 字节   内核分区（ext4）
  p2.img  %(p2)s 字节   fnOS 根分区（btrfs）
  低区    %(low)s

⚠️ 重要说明
%(bootnote)s
  · 本包格式依据对厂商包的逆向生成，**厂商工具是否接受尚未实测**。
  · 本板 u-boot 从 p1 的 ext4 读取内核，不使用固件表里的裸偏移内核槽位。

使用步骤（Windows）
  1. 工具目录放在**纯 ASCII 路径**（勿放中文路径/桌面）
  2. 按住主板上电源插座旁的 SW5 键，只插 Type-C 线（不接 DC 电源），约 3 秒
  3. 电脑识别为 Realtek generic USB Device（需先装 usb_driver）
  4. 打开 usb mp tool → flash type = EMMC，DDR Type = 4DDR4_2GB
  5. open 选择本 install-cm360-fnos-*.img → 点小绿人开始刷 → 到 100%% 结束

已验证的替代方案（推荐）
  用仓库的 dd 四件套（dist/dd-set/）在板内直接刷，已实测通过：
    低区 3.7 s / p1 1.7 s / p2 146 s
"""


def tf_check(img: str, member: str):
    with tarfile.open(img) as tf:
        return tf.extractfile(member).read()


if __name__ == "__main__":
    sys.exit(main())
