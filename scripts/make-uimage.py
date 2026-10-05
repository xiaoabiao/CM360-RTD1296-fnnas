#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mk-uimage.py —— 把裸 arm64 Image 包成 legacy uImage（64 字节大端头）

为什么需要它
------------
板上 `booti` 报 `Wrong Image Format for do_booti command`。u-boot 2015.07 的
do_booti 只认 genimg_get_format() 能识别的东西 —— 也就是
  * IMAGE_FORMAT_LEGACY：64 字节 legacy uImage 头，magic 0x27051956
  * IMAGE_FORMAT_FIT   ：FIT (DTB) 容器
裸 arm64 Image 的头（magic 0x644d5241 @ offset 0x38、text_offset、image_size…）
它根本不看。所以在 u-boot 里给内核套一层 legacy uImage 头是标准做法：
脚本体（payload）仍然是裸 arm64 Image，u-boot 会自己往里面找 LINUX_ARM64_MAGIC。

头部布局（image_header_t，全部大端）
    0x00 ih_magic  0x27051956
    0x04 ih_hcrc   header crc32（算的时候这一栏先置 0）
    0x08 ih_time   unix 时间
    0x0C ih_size   payload 字节数
    0x10 ih_load   加载地址
    0x14 ih_ep     入口地址
    0x18 ih_dcrc   payload crc32
    0x1C ih_os     IH_OS_LINUX   = 5
    0x1D ih_arch   IH_ARCH_ARM64 = 22
    0x1E ih_type   IH_TYPE_KERNEL= 2
    0x1F ih_comp   IH_COMP_NONE  = 0
    0x20 ih_name[32]

用法：
    ./mk-uimage.py Image Image.uimage [load_addr] [entry_addr]
默认 load/entry 都是 0x03000000（= 板上 kernel_loadaddr）。
"""
import os
import struct
import sys
import time
import zlib

IH_MAGIC = 0x27051956
IH_OS_LINUX = 5
IH_ARCH_ARM64 = 22
IH_TYPE_KERNEL = 2
IH_COMP_NONE = 0
ARM64_MAGIC = 0x644d5241  # 裸 Image 头里 offset 0x38 处的 'ARM\x64'


def arm64_image_info(data: bytes) -> dict:
    """顺手校验一下 payload 是不是真的裸 arm64 Image。"""
    if len(data) < 0x40:
        return {"ok": False, "why": "文件太短"}
    # 注意：u-boot 里的 arm64 Image header 是**小端**的
    magic_le = struct.unpack_from("<I", data, 0x38)[0]
    magic_be = struct.unpack_from(">I", data, 0x38)[0]
    if magic_le != ARM64_MAGIC and magic_be != ARM64_MAGIC:
        return {"ok": False, "why": "offset 0x38 不是 0x644d5241"}
    code0, code1 = struct.unpack_from("<II", data, 0)
    text_offset, image_size = struct.unpack_from("<QQ", data, 8)
    flags = struct.unpack_from("<Q", data, 24)[0]
    return {
        "ok": True,
        "code0": code0,
        "code1": code1,
        "text_offset": text_offset,
        "image_size": image_size,
        "flags": flags,
    }


def build_header(payload: bytes, load: int, ep: int, name: str) -> bytes:
    hdr = bytearray(64)
    struct.pack_into(">I", hdr, 0x00, IH_MAGIC)
    struct.pack_into(">I", hdr, 0x04, 0)                 # hcrc 先置 0
    struct.pack_into(">I", hdr, 0x08, int(time.time()))
    struct.pack_into(">I", hdr, 0x0C, len(payload))
    struct.pack_into(">I", hdr, 0x10, load)
    struct.pack_into(">I", hdr, 0x14, ep)
    struct.pack_into(">I", hdr, 0x18, zlib.crc32(payload) & 0xFFFFFFFF)
    hdr[0x1C] = IH_OS_LINUX
    hdr[0x1D] = IH_ARCH_ARM64
    hdr[0x1E] = IH_TYPE_KERNEL
    hdr[0x1F] = IH_COMP_NONE
    nm = name.encode()[:31]
    hdr[0x20:0x20 + len(nm)] = nm
    struct.pack_into(">I", hdr, 0x04, zlib.crc32(bytes(hdr)) & 0xFFFFFFFF)
    return bytes(hdr)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    load = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x03000000
    ep = int(sys.argv[4], 0) if len(sys.argv) > 4 else load

    payload = open(src, "rb").read()
    info = arm64_image_info(payload)
    print("payload      : %s (%d 字节)" % (src, len(payload)))
    if not info["ok"]:
        print("!! 警告：不像裸 arm64 Image —— %s" % info["why"])
    else:
        print("arm64 头     : text_offset=0x%x image_size=0x%x flags=0x%x"
              % (info["text_offset"], info["image_size"], info["flags"]))

    hdr = build_header(payload, load, ep, os.path.basename(src))
    with open(dst, "wb") as f:
        f.write(hdr)
        f.write(payload)
    print("uImage       : %s (%d 字节 = 64 头 + %d 体)"
          % (dst, 64 + len(payload), len(payload)))
    print("  load=0x%x entry=0x%x os=linux arch=arm64 type=kernel comp=none"
          % (load, ep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
