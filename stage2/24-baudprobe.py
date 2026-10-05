#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""24-baudprobe.py —— 逐个候选波特率试读串口，找出板子在用哪个速率

背景（2026-10-05）：修 reboot 的新内核上电后，115200 下收到的是乱码
（大量 0x88/0x90/0x95/0x96/0xa6/0xe2 等非 ASCII，夹杂字母），
典型的采样率不匹配。这个脚本挨个波特率读一小段，用"可打印 ASCII 占比"
给每个候选打分，把最像人话的那个找出来。
"""
import argparse
import sys
import time

import serial

CANDIDATES = [115200, 57600, 38400, 19200, 9600, 230400, 460800, 921600, 1500000, 250000, 500000]


def score(data: bytes) -> float:
    if not data:
        return 0.0
    ok = sum(1 for b in data if 32 <= b < 127 or b in (9, 10, 13))
    return ok / len(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--secs", type=float, default=2.5, help="每个波特率读多久")
    ap.add_argument("--bauds", default="", help="逗号分隔的自定义列表")
    args = ap.parse_args()

    bauds = [int(x) for x in args.bauds.split(",")] if args.bauds else CANDIDATES
    results = []
    for b in bauds:
        try:
            ser = serial.Serial()
            ser.port = args.dev
            ser.baudrate = b
            ser.timeout = 0.2
            ser.dsrdtr = False
            ser.rtscts = False
            ser.open()
            ser.dtr = False
            ser.rts = False
            ser.reset_input_buffer()
            t = time.time()
            buf = bytearray()
            while time.time() - t < args.secs:
                d = ser.read(4096)
                if d:
                    buf += d
            ser.close()
        except Exception as e:
            print(f"{b:>8}: 打开失败 {e}")
            continue
        s = score(buf)
        results.append((s, b, bytes(buf)))
        sample = buf[:60].decode("utf-8", "replace").replace("\r", "").replace("\n", "⏎")
        print(f"{b:>8}: {len(buf):>6} B  可打印占比 {s*100:5.1f}%  | {sample}")

    print("\n=== 结论 ===")
    if not results:
        print("所有波特率都没读到数据")
        return
    results.sort(key=lambda x: -x[0])
    best = results[0]
    print(f"最像人话的波特率: {best[1]}（可打印占比 {best[0]*100:.1f}%）")
    print("全文预览:")
    sys.stdout.write(best[2][:2000].decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
