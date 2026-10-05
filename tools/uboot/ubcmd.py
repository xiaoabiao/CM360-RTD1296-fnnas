#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""23-ubcmd.py —— 与**新 u-boot（BPI-W2）**的命令行交互

背景：2026-10-05 07:30 用 ROM Monitor 把板子救回来之后，板上的 u-boot 已经是
BPI-W2 的（`U-Boot 2015.07 (Apr 27 2018 - 09:10:25 -0700)`，提示符 `BPI-W2>`），
原来的 `15-uboot.sh` 依赖 `session02.ctl` + serial_agent 代理那一套，不再适用。

本脚本直接独占串口、逐条发命令、等到提示符再读下一批，并把全过程留档。

用法：
    /usr/bin/python3 23-ubcmd.py 'version' 'printenv'
    /usr/bin/python3 23-ubcmd.py --prompt 'BPI-W2> ' 'mmc dev 0' 'mmc part'
    /usr/bin/python3 23-ubcmd.py --wait 20 'ext4ls mmc 0:1 /'
"""
import argparse
import os
import re
import sys
import time

import serial

TS = time.strftime("%m%d-%H%M%S")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmds", nargs="*", help="要依次发送的命令")
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--prompt", default=r"BPI-W2>\s*$", help="提示符正则（默认 BPI-W2>）")
    ap.add_argument("--wait", type=float, default=10.0, help="每条命令最多等多少秒")
    ap.add_argument("--gap", type=float, default=0.5, help="命令之间额外停顿")
    ap.add_argument("--wait-prompt", type=float, default=0.0,
                    help="发命令前先等提示符出现，最多等这么多秒（配合断电上电用）")
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    logpath = f"{args.outdir}/ubcmd-{TS}.log"
    rawpath = f"{args.outdir}/ubcmd-{TS}.bin"
    log = open(logpath, "w", buffering=1)
    raw = open(rawpath, "wb", buffering=0)

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

    def emit(s):
        sys.stdout.write(s)
        sys.stdout.flush()
        log.write(s)

    emit(f"### u-boot 交互 {time.strftime('%F %T')}  设备 {args.dev}@{args.baud}\n")
    pat = re.compile(args.prompt.encode())

    def read_until_prompt(timeout):
        buf = bytearray()
        end = time.time() + timeout
        while time.time() < end:
            d = ser.read(4096)
            if not d:
                continue
            raw.write(d)
            buf += d
            if pat.search(buf):
                break
        return bytes(buf)

    # 先敲一个回车探一下当前是不是在提示符上
    ser.write(b"\r")
    ser.flush()
    hello = read_until_prompt(3.0)
    emit("### 起始探针:\n" + hello.decode("utf-8", "replace") + "\n")

    # 可选：等提示符出现（板子还在启动 / 等断电上电时用）
    if args.wait_prompt > 0 and not pat.search(hello):
        emit(f"### 等 u-boot 提示符，最多 {args.wait_prompt:.0f}s ...\n")
        got = read_until_prompt(args.wait_prompt)
        emit("### 等到的内容（尾部）:\n"
             + got[-2000:].decode("utf-8", "replace") + "\n")
        if not pat.search(got):
            emit("!! 没等到提示符，放弃\n")
            ser.close(); log.close(); raw.close()
            sys.exit(2)
        # 提示符上再敲个回车，拿干净上下文
        ser.write(b"\r"); ser.flush()
        read_until_prompt(3.0)

    for c in args.cmds:
        emit(f"\n########## $ {c}\n")
        ser.write(c.encode() + b"\r")
        ser.flush()
        out = read_until_prompt(args.wait)
        emit(out.decode("utf-8", "replace"))
        emit("\n")
        time.sleep(args.gap)

    ser.close()
    log.close()
    raw.close()
    print(f"\n[完成] 日志 {logpath}")


if __name__ == "__main__":
    main()
