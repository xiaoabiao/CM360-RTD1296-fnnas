#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mk-uboot-script.py —— 把纯文本命令包成 u-boot 可 `source` 的 legacy script uImage

为什么需要它
------------
串口无流控，板上实测"主机→板子"方向单条命令超过 ~32 字符会被截断（见 README 141 行）。
而改 env 的 bootcmd 动辄上百字符，根本敲不进去。

u-boot 2015.07 有 `source - run script from memory`（实测板上 `help` 列表里确实有），
于是：脚本本体走 TFTP（可靠、无损），串口上只敲三条短命令：

    setenv l 0xa000000
    tftpboot $l recon.scr
    source $l

头布局（image_header_t，全大端；与内核 uImage 同格式，只有 ih_type 不同）
    0x00 ih_magic  0x27051956
    0x04 ih_hcrc   header crc32（算时此栏先置 0）
    0x08 ih_time   unix 时间
    0x0C ih_size   payload 字节数
    0x10 ih_load   0（脚本不需要）
    0x14 ih_ep     0
    0x18 ih_dcrc   payload crc32
    0x1C ih_os     IH_OS_LINUX   = 5
    0x1D ih_arch   IH_ARCH_ARM64 = 22
    0x1E ih_type   IH_TYPE_SCRIPT= 6   ← 关键
    0x1F ih_comp   IH_COMP_NONE  = 0
    0x20 ih_name[32]

用法：
    ./mk-uboot-script.py <输入.cmd> <输出.scr> [name]
"""
import os
import struct
import sys
import time
import zlib

IH_MAGIC = 0x27051956
IH_OS_LINUX = 5
IH_ARCH_ARM64 = 22
IH_TYPE_SCRIPT = 6
IH_COMP_NONE = 0


def build(payload: bytes, name: str = "cm360-uboot-script") -> bytes:
    hdr = bytearray(64)
    struct.pack_into(">I", hdr, 0x00, IH_MAGIC)
    struct.pack_into(">I", hdr, 0x04, 0)                     # hcrc 先置 0
    struct.pack_into(">I", hdr, 0x08, int(time.time()))
    struct.pack_into(">I", hdr, 0x0C, len(payload))
    struct.pack_into(">I", hdr, 0x10, 0)                     # load
    struct.pack_into(">I", hdr, 0x14, 0)                     # ep
    struct.pack_into(">I", hdr, 0x18, zlib.crc32(payload) & 0xFFFFFFFF)
    hdr[0x1C] = IH_OS_LINUX
    hdr[0x1D] = IH_ARCH_ARM64
    hdr[0x1E] = IH_TYPE_SCRIPT
    hdr[0x1F] = IH_COMP_NONE
    nm = name.encode()[:31]
    hdr[0x20:0x20 + len(nm)] = nm
    struct.pack_into(">I", hdr, 0x04, zlib.crc32(bytes(hdr)) & 0xFFFFFFFF)
    return bytes(hdr) + payload


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else os.path.basename(src)
    payload = open(src, "rb").read()
    if not payload.endswith(b"\n"):
        payload += b"\n"
    img = build(payload, name)
    open(dst, "wb").write(img)
    print(f"{dst}: payload {len(payload)} B -> 总 {len(img)} B  (ih_type=6 script, crc ok)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
