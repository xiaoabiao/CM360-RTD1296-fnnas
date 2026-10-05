#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""22-mon-g.py —— 在 Phoenix Monitor 里补发按键（默认 g）并观察烧写过程

为什么单独一个脚本
------------------
`20-phoenix-v2.py --no-press-g` 跑完 h/s/d 后会主动停在提示符，**不触发烧写**。
ROM Monitor 是常驻的（不会因为脚本退出而消失），所以在同一个 monitor 会话里
用本脚本补发 `g` 即可开始 recovery，不需要再断电上电。

`g` 的实际语义（据 bootcode 反汇编）：
    `s 98007058` + `01500000` 已经把 DRAM 装载地址写进 scratch 寄存器 0x98007058，
    `d` 把 bootloader YMODEM 下到该地址，`g` 则**跳转执行**这段刚下载的
    "bootloader with burning program" —— 由它去把 hwsetting + bootloader 写进闪存。

用法：
    /usr/bin/python3 22-mon-g.py                 # 发 g，观察 180s
    /usr/bin/python3 22-mon-g.py --key 68 --secs 60
"""
import argparse
import os
import sys
import time

import serial

TS = time.strftime("%m%d-%H%M%S")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--key", default="67", help="要发的按键（十六进制），默认 67='g'")
    ap.add_argument("--secs", type=float, default=180.0)
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    raw_path = f"{args.outdir}/mon-g-{TS}.bin"
    txt_path = f"{args.outdir}/mon-g-{TS}.log"

    ser = serial.Serial()
    ser.port = args.dev
    ser.baudrate = args.baud
    ser.timeout = 0.05
    ser.dsrdtr = False
    ser.rtscts = False
    ser.open()
    ser.dtr = False
    ser.rts = False
    ser.reset_input_buffer()

    raw = open(raw_path, "wb", buffering=0)
    txt = open(txt_path, "w", buffering=1)
    t0 = time.time()
    line = bytearray()

    def out(s):
        sys.stdout.write(s)
        sys.stdout.flush()
        txt.write(s)

    out(f"### 补发按键 0x{args.key} 于 {time.strftime('%F %T')}，观察 {args.secs}s\n")
    ser.write(bytes([int(args.key, 16)]))
    ser.flush()
    out(f"### 已发送 0x{args.key}（= '{chr(int(args.key, 16))}'）\n")

    total = 0
    while time.time() - t0 < args.secs:
        d = ser.read(4096)
        if not d:
            continue
        total += len(d)
        raw.write(d)
        for b in d:
            if b in (0x0A, 0x0D):
                if line:
                    out(f"[{(time.time()-t0)*1000:9.1f} ms] "
                        f"{line.decode('utf-8', 'replace')}\n")
                    line.clear()
            elif len(line) < 8192:
                line.append(b)
    if line:
        out(f"[{(time.time()-t0)*1000:9.1f} ms] {line.decode('utf-8','replace')}\n")

    ser.close()
    raw.close()
    out(f"\n### 共收到 {total} 字节；raw -> {raw_path}\n")
    txt.close()
    print(f"[完成] {txt_path}")


if __name__ == "__main__":
    main()
