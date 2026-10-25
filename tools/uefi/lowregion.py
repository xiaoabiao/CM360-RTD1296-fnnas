#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lowregion.py —— CM360（RTD1296）低区镜像布局解析 / 校验 / 解包 / 重排规划

背景（全部来自本仓库实测，见 firmware/RECOVERY.md、evidence/build-artifacts/catch-uboot.txt）：

    eMMC 偏移        内容                       长度来源
    0x0000_0000      MBR                        （本脚本不碰）
    0x0002_0000      hwsetting                 3200 B + 0xFF 填充到 0xE00
    0x0002_0E00      bootcode（Realtek 容器，内含 U-Boot）   hwsetting[1] + 0x20
    0x0009_EC00      FSBL                                    hwsetting[2] + 0x20
    0x000B_0600      TEE / BL32                              hwsetting[3] + 0x20
    0x0012_C400      BL31（ATF v1.2）                        hwsetting[4] + 0x20
    0x0013_2800      未知固件块（≈972 KiB，ARM64 代码）       —— 长度无字段，含义未定，★别动
    0x0022_0000      u-boot 环境（生效副本，blk# 0x1100）   0x20A00
    0x0042_0000      u-boot 环境（旧副本）

  四段镜像按顺序放置，每段起始按 0x200 对齐，段间用 0xFF 填充；
  hwsetting 头部字段（LE u32，偏移 0x20000 起）：
    +0x00 = 0xC00        hwsetting 寄存器脚本长度（3200 = 128 字节头 + 3072 字节脚本）
    +0x04 = bootcode 长度 - 0x20
    +0x08 = FSBL     长度 - 0x20
    +0x0C = TEE      长度 - 0x20
    +0x10 = BL31     长度 - 0x20

  本脚本只做"读 + 校验 + 解包 + 规划"，**不写任何设备**；`plan` 输出的是纸面推演。

用法：
    ./lowregion.py info        # 打印布局表（默认读 firmware/low-region-38MiB.img.gz）
    ./lowregion.py check       # 校验上面这套模型（不符合就退出码 1）
    ./lowregion.py selftest    # 用解析出的四段镜像原地重排，逐字节比对（应是 PASS）
    ./lowregion.py extract --name bootcode --out /tmp/bootcode.bin
    ./lowregion.py plan --bootcode /tmp/new-bootcode.bin   # 换 bootcode 的尺寸/位移推演

退出码：0 正常，1 校验失败/参数错误，2 文件读不到。
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import struct
import sys

# ── 常量（实测） ────────────────────────────────────────────────────────────
LOW_SIZE        = 0x2600000        # 38 MiB（39,845,888 B）
HW_OFF          = 0x20000          # hwsetting 起点（blk# 0x100）
HW_SIZE         = 3200             # hw_setting.bin 实测 3200 B
HW_PAD_TO       = 0x20E00          # hwsetting 区被 0xFF 填充到 bootcode 起点
CHAIN_START     = 0x20E00          # 第一段镜像（bootcode）起点
ALIGN           = 0x200            # 段起始对齐
FILL            = 0xFF             # 段间/空区填充字节
ENV_OFF         = 0x220000         # 生效 env（saveenv 实测落点 0x20A00 字节）
ENV_OLD_OFF     = 0x420000         # 旧 env 副本
ENV_MAGIC       = b"tmp/factory/"  # 两个 env 区开头都能看到这个串（本板实测）

# 镜像段：名字、RAM 侧信息（bootcode 头里读）、hwsetting 字段序号
IMAGES = ("bootcode", "fsbl", "tee", "bl31")


def die(msg: str, code: int = 1) -> "NoReturn":
    print("!! " + msg, file=sys.stderr)
    raise SystemExit(code)


def find_default_image() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    for name in ("low-region-38MiB.img.gz", "low-region-38MiB.img"):
        p = os.path.join(repo, "firmware", name)
        if os.path.exists(p):
            return p
    die("找不到默认低区镜像 firmware/low-region-38MiB.img.gz（可用 --image 指定）", 2)


def load_image(path: str) -> bytes:
    if not os.path.exists(path):
        die("镜像不存在: " + path, 2)
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return raw


def parse_hwsetting(img: bytes) -> dict:
    if len(img) < HW_OFF + HW_SIZE:
        die("镜像太小，读不到 hwsetting")
    blob = img[HW_OFF:HW_OFF + HW_SIZE]
    fields = list(struct.unpack_from("<5I", blob, 0))
    if fields[0] == 0:
        die("hwsetting 字段全 0：镜像可能不是本板的低区？")
    sizes = {name: fields[i + 1] + 0x20 for i, name in enumerate(IMAGES)}
    return {
        "blob": blob,
        "fields": fields,
        "script_size": fields[0],
        "sizes": sizes,
    }


def parse_layout(img: bytes, hw: dict) -> dict:
    """按 hwsetting 的尺寸字段顺序排布四段镜像（对齐 0x200）。"""
    starts = {}
    sizes = hw["sizes"]
    cur = CHAIN_START
    for name in IMAGES:
        starts[name] = cur
        cur = (cur + sizes[name] + ALIGN - 1) // ALIGN * ALIGN
    # 每段实际结束点 + 对齐填充
    ends = {name: starts[name] + sizes[name] for name in IMAGES}
    pads = {}
    for i, name in enumerate(IMAGES):
        nxt = starts[IMAGES[i + 1]] if i + 1 < len(IMAGES) else cur
        pads[name] = nxt - ends[name]
    return {"starts": starts, "ends": ends, "pads": pads, "chain_end": cur}


def parse_bootcode_header(img: bytes, off: int) -> dict:
    """bootcode 的 Realtek 容器头（0x28 字节）：branch/nop/load/size/size/???。

    实测（本板 2025 低区）：0x1400000a(b .+0x28), 0xd503201f(nop),
    +0x08 = 0x00020000（加载地址）, +0x10 = +0x18 = 长度-0x60, +0x20 = 0xCFCF8。
    头部字段语义尚未完全逆向，这里只做"能核对多少核对多少"。
    """
    h = img[off:off + 0x28]
    if len(h) < 0x28:
        return {}
    branch, nop = struct.unpack_from("<2I", h, 0)
    load, a, b, c = struct.unpack_from("<4Q", h, 0x08)
    return {
        "branch": branch, "nop": nop,
        "load": load, "a": a, "b": b, "c": c,
    }


def describe(img: bytes) -> dict:
    hw = parse_hwsetting(img)
    lay = parse_layout(img, hw)
    hdr = parse_bootcode_header(img, lay["starts"]["bootcode"])
    return {"hw": hw, "layout": lay, "hdr": hdr}


def cmd_info(img: bytes, _args) -> int:
    d = describe(img)
    hw, lay, hdr = d["hw"], d["layout"], d["hdr"]
    print("镜像大小 : %d (0x%x)  %s" % (len(img), len(img),
                                       "✔ 38 MiB" if len(img) == LOW_SIZE else "✘ 与 38 MiB 不符"))
    print("镜像 md5 : " + hashlib.md5(img).hexdigest())
    print()
    print("hwsetting @0x%05x：脚本 %d B，文件 %d B" % (HW_OFF, hw["script_size"], HW_SIZE))
    print("  字段：" + " ".join("0x%x" % f for f in hw["fields"]))
    print()
    print("%-8s %-10s %-10s %-10s %-8s %s" % ("段", "eMMC 偏移", "长度", "结束", "对齐填充", "备注"))
    for name in IMAGES:
        st, sz, en = lay["starts"][name], hw["sizes"][name], lay["ends"][name]
        note = ""
        if name == "bootcode":
            note = "RAM load=0x%x, 头字段 a=0x%x b=0x%x c=0x%x" % (
                hdr.get("load", 0), hdr.get("a", 0), hdr.get("b", 0), hdr.get("c", 0))
        print("%-8s 0x%08x 0x%08x 0x%08x 0x%06x %s" % (name, st, sz, en, lay["pads"][name], note))
    print()
    print("四段镜像链结束于 0x%08x；其后是未知固件块（本板约 972 KiB），再往后：" % lay["chain_end"])
    print("  生效 env     @0x%08x（%s）" % (ENV_OFF, "✔" if img[ENV_OFF:ENV_OFF + len(ENV_MAGIC)] == ENV_MAGIC else "✘"))
    print("  旧 env 副本  @0x%08x（%s）" % (ENV_OLD_OFF, "✔" if img[ENV_OLD_OFF:ENV_OLD_OFF + len(ENV_MAGIC)] == ENV_MAGIC else "✘"))
    print()
    print("直接换 bootcode 的余量（只算到 env，不含未知块的影响）：")
    room = ENV_OFF - lay["chain_end"]
    print("  当前链尾 → env 之间还有 0x%x (%d KiB)" % (room, room // 1024))
    print("  ⇒ bootcode 最多可加长约 %d KiB（之后每段还会顺延，实际更小）" % (room // 1024))
    return 0


def cmd_check(img: bytes, _args) -> int:
    fails = []

    def ck(cond, msg):
        print(("  ✔ " if cond else "  ✘ ") + msg)
        if not cond:
            fails.append(msg)

    print("== 1) 镜像与 hwsetting ==")
    ck(len(img) == LOW_SIZE, "镜像大小 = 38 MiB（实测 0x%x）" % len(img))
    d = describe(img)
    hw, lay, hdr = d["hw"], d["layout"], d["hdr"]
    ck(hw["script_size"] == 0xC00, "hwsetting 脚本长度 = 0xC00（实测 3072）")
    ck(img[HW_OFF + HW_SIZE:HW_PAD_TO] == b"\xff" * (HW_PAD_TO - HW_OFF - HW_SIZE),
       "hwsetting 尾部用 0xFF 填充到 0x20E00")

    print("== 2) bootcode 容器头 ==")
    ck(hdr.get("branch") == 0x1400000A, "首指令 = b .+0x28（0x1400000a）")
    ck(hdr.get("nop") == 0xD503201F, "第二条 = NOP")
    ck(hdr.get("load") == 0x20000, "加载地址 = 0x20000（FSBL 日志：FW Image to 0x00020000）")
    ck(hdr.get("a") == hw["sizes"]["bootcode"] - 0x60,
       "头 size 字段 = 段长 - 0x60（0x%x）" % hdr.get("a", 0))

    print("== 3) 四段布局 ==")
    ck(lay["starts"]["bootcode"] == 0x20E00, "bootcode 起点 = 0x20E00")
    for name in IMAGES:
        ck(lay["starts"][name] % ALIGN == 0, "%s 起点按 0x200 对齐（0x%x）" % (name, lay["starts"][name]))
        ck(img[lay["ends"][name]:lay["ends"][name] + lay["pads"][name]] ==
           b"\xff" * lay["pads"][name], "%s 段尾 0xFF 对齐填充（%d B）" % (name, lay["pads"][name]))
    ck(lay["chain_end"] < ENV_OFF, "链尾 0x%x 在 env 0x%x 之前" % (lay["chain_end"], ENV_OFF))

    print("== 4) 环境变量区 ==")
    ck(img[ENV_OFF:ENV_OFF + len(ENV_MAGIC)] == ENV_MAGIC, "生效 env @0x220000 魔数对得上")
    ck(img[ENV_OLD_OFF:ENV_OLD_OFF + len(ENV_MAGIC)] == ENV_MAGIC, "旧 env @0x420000 魔数对得上")

    print("== 5) 与仓库里的原厂文件交叉核对 ==")
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    vf = os.path.join(repo, "boards", "rtd1296-cm360", "vendor-firmware")
    bl31 = os.path.join(vf, "bl31.bin")
    if os.path.exists(bl31):
        b = open(bl31, "rb").read()
        st = lay["starts"]["bl31"]
        ck(img[st:st + len(b)] == b, "BL31 段 == vendor-firmware/bl31.bin（%d B）" % len(b))
    else:
        print("  - 跳过：没有 boards/.../vendor-firmware/bl31.bin")

    print()
    if fails:
        print("结果：%d 项不符 —— 这不是本脚本预期的低区布局。" % len(fails))
        return 1
    print("结果：全部通过（低区布局模型与实际镜像一致）")
    return 0


def rebuild_chain(img: bytes, new_sizes: dict | None = None) -> bytes:
    """按布局模型重排四段镜像，返回 [0x20E00, chain_end) 的字节。"""
    d = describe(img)
    hw, lay = d["hw"], d["layout"]
    sizes = dict(hw["sizes"])
    if new_sizes:
        sizes.update(new_sizes)
    starts, cur = {}, CHAIN_START
    for name in IMAGES:
        starts[name] = cur
        cur = (cur + sizes[name] + ALIGN - 1) // ALIGN * ALIGN
    out = bytearray(b"\xff" * (cur - CHAIN_START))
    for name in IMAGES:
        src = lay["starts"][name]
        data = img[src:src + hw["sizes"][name]]
        if len(data) != sizes[name]:
            if len(data) > sizes[name]:
                data = data[:sizes[name]]
            else:
                data = data + b"\xff" * (sizes[name] - len(data))
        pos = starts[name] - CHAIN_START
        out[pos:pos + sizes[name]] = data
    return bytes(out)


def cmd_selftest(img: bytes, _args) -> int:
    d = describe(img)
    old = img[CHAIN_START:d["layout"]["chain_end"]]
    new = rebuild_chain(img)
    print("链区长度 : 原 0x%x / 重排 0x%x" % (len(old), len(new)))
    ok = old == new
    if ok:
        print("PASS：四段镜像 + 对齐填充可以逐字节重建 —— 布局模型自洽。")
        return 0
    print("FAIL：重排结果与原镜像不一致。")
    n = min(len(old), len(new))
    for i in range(n):
        if old[i] != new[i]:
            print("  首个差异 @0x%x：原 %02x / 新 %02x" % (CHAIN_START + i, old[i], new[i]))
            break
    return 1


def cmd_extract(img: bytes, args) -> int:
    d = describe(img)
    if args.name == "hwsetting":
        data, off = d["hw"]["blob"], HW_OFF
    else:
        off = d["layout"]["starts"].get(args.name)
        if off is None:
            die("未知段名 %r（可选：hwsetting %s）" % (args.name, " ".join(IMAGES)))
        data = img[off:off + d["hw"]["sizes"][args.name]]
    open(args.out, "wb").write(data)
    print("已导出 %-9s %6d B @0x%08x → %s" % (args.name, len(data), off, args.out))
    return 0


def cmd_plan(img: bytes, args) -> int:
    d = describe(img)
    hw, lay = d["hw"], d["layout"]
    if args.bootcode:
        try:
            new = open(args.bootcode, "rb").read()
        except OSError as e:
            die("读不到 bootcode: %s" % e, 2)
        if len(new) <= 0x20:
            die("bootcode 太小（至少要 > 0x20，hwsetting 存的是 长度-0x20）")
        sizes = dict(hw["sizes"])
        sizes["bootcode"] = len(new)
        delta = len(new) - hw["sizes"]["bootcode"]
        starts, cur = {}, CHAIN_START
        for name in IMAGES:
            starts[name] = cur
            cur = (cur + sizes[name] + ALIGN - 1) // ALIGN * ALIGN
        print("新 bootcode : %d B（现 %d B，%+d B / %+d KiB）" %
              (len(new), hw["sizes"]["bootcode"], delta, delta // 1024))
        print()
        print("%-8s %-12s %-12s %s" % ("段", "原偏移", "新偏移", "位移"))
        for name in IMAGES:
            old_s, new_s = lay["starts"][name], starts[name]
            print("%-8s 0x%08x   0x%08x   %+d" % (name, old_s, new_s, new_s - old_s))
        print()
        print("新链尾 : 0x%08x（现 0x%08x）" % (cur, lay["chain_end"]))
        if cur > ENV_OFF:
            print("✘ 越界：链尾已超过生效 env 0x%08x，绝对不可行。不能这样换。" % ENV_OFF)
            return 1
        if delta > 0:
            print("⚠ 后续每段都会右移，紧跟在链尾的 0x%08x 起的未知固件块（≈972 KiB）" % lay["chain_end"])
            print("  也会被推着走。它的偏移由谁计算（FSBL 按尺寸顺推 / 固定 LBA）**尚未确认**，")
            print("  在确认之前不要用这个方案写 eMMC；本命令只做纸面推演，不写任何东西。")
        print()
        print("还差的关键一步：bootcode 必须由 Realtek 打包工具生成容器（0x28 头 + 载荷 + 尾部），")
        print("不是把 u-boot.bin 直接拷进来。参考 BPI-W2 BSP 的 u-boot-rtk（2015.07）及其 flash_writer。")
        print("hwsetting 需要同步改：+0x04 = 新长度 - 0x20 = 0x%x。" % (len(new) - 0x20))
        return 0
    if args.extract_to:
        open(args.extract_to, "wb").write(rebuild_chain(img))
        print("已导出重排后的链区（不含未知块/env）→ %s" % args.extract_to)
        return 0
    die("plan 至少给一个参数：--bootcode FILE 或 --extract-to FILE")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="CM360 RTD1296 低区镜像布局解析/校验（只读）")
    ap.add_argument("--image", default=None, help="低区镜像 .img / .img.gz（默认 firmware/low-region-38MiB.img.gz）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info", help="打印布局表")
    sub.add_parser("check", help="校验布局模型（不符合退出码 1）")
    sub.add_parser("selftest", help="原地重排并逐字节比对")

    ex = sub.add_parser("extract", help="导出一段镜像")
    ex.add_argument("--name", required=True, help="hwsetting / " + " / ".join(IMAGES))
    ex.add_argument("--out", required=True)

    pl = sub.add_parser("plan", help="换 bootcode 的尺寸/位移推演（不写设备）")
    pl.add_argument("--bootcode", help="待换入的 bootcode 容器文件")
    pl.add_argument("--extract-to", help="导出重排后的链区到文件")

    args = ap.parse_args(argv)
    img = load_image(args.image or find_default_image())
    handler = {"info": cmd_info, "check": cmd_check, "selftest": cmd_selftest,
               "extract": cmd_extract, "plan": cmd_plan}[args.cmd]
    return handler(img, args)


if __name__ == "__main__":
    sys.exit(main())
