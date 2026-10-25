#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make-factory-tar.py —— 从低区镜像里抽出 u-boot env，打成线刷工具用的 factory.tar

背景（docs/10 §16.3 ⑧）：
  厂商 USB MP Tool 在整机刷写的**最后一步**会往 eMMC 0x220000/0x420000 写一份
  factory.tar（u-boot 的 env 就存在里面的 `tmp/factory/env.txt`）。包内不放
  `omv/factory.tar` 时它写空白版本 → env 被清空 → 开机进默认环境。

  工具的处理流程是：解包 `omv/factory.tar` 到它自己的 factory 根目录 →
  再统一加 `tmp/factory/` 前缀重打包 → 写回 eMMC。
  所以**输入 tar 的成员必须是根相对路径**（`env.txt`），不能带 `tmp/factory/`，
  否则会被套成 `tmp/factory/tmp/factory/env.txt`，u-boot 找不到。

用法：
  ./tools/make-factory-tar.py firmware/low-region-38MiB.img.gz -o factory.tar
  ./tools/make-lineflash-official.sh ... --factory-tar factory.tar

默认从低区镜像 0x220000 的 factory tar 里取 `tmp/factory/env.txt`（131072 B）。
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile

FACTORY_OFF = 0x220000          # 低区里第一份 factory tar 的偏移
FACTORY_LEN = 0x20A00           # 该区域长度（docs/10 §16.1）


def load_image(path: str) -> bytes:
    if path.endswith(".gz"):
        with gzip.open(path, "rb") as f:
            return f.read()
    with open(path, "rb") as f:
        return f.read()


def main() -> int:
    ap = argparse.ArgumentParser(description="从低区镜像生成线刷工具用的 factory.tar")
    ap.add_argument("image", help="low-region-38MiB.img[.gz]")
    ap.add_argument("-o", "--out", default="factory.tar")
    ap.add_argument("--offset", type=lambda s: int(s, 0), default=FACTORY_OFF,
                    help="factory 区偏移（默认 0x220000）")
    ap.add_argument("--length", type=lambda s: int(s, 0), default=FACTORY_LEN)
    args = ap.parse_args()

    raw = load_image(args.image)
    if len(raw) < args.offset + args.length:
        print(f"!! 镜像太小：{len(raw):#x} < {args.offset + args.length:#x}", file=sys.stderr)
        return 1
    blob = raw[args.offset:args.offset + args.length]

    # 低区里的 factory tar 成员是 tmp/factory/env.txt（含 NUL 填充），取出 env 原文
    try:
        tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:")
        env = tf.extractfile("tmp/factory/env.txt").read()
    except Exception as e:  # noqa: BLE001
        print(f"!! 解析 factory 区失败：{e}", file=sys.stderr)
        return 1

    # 以“根相对路径 env.txt”重新打包（工具会自己加 tmp/factory/ 前缀）
    with tarfile.open(args.out, "w", format=tarfile.GNU_FORMAT) as out:
        ti = tarfile.TarInfo("env.txt")
        ti.size = len(env)
        ti.mode = 0o644
        out.addfile(ti, io.BytesIO(env))

    size = os.path.getsize(args.out)
    md5 = hashlib.md5(open(args.out, "rb").read()).hexdigest()
    print(f"OK {args.out}  {size} B  md5={md5}")
    print(f"  env.txt = {len(env)} B（来自 {args.image} @ {args.offset:#x}）")
    print(f"  校验: bootcmd = {next((p for p in env.split(b'\x00') if p.startswith(b'bootcmd')), b'')[:100].decode('latin1')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
