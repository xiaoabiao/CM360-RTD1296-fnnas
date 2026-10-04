#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""18-monsniff.py —— 无损嗅探串口（只读，不发任何字节）

用途：恢复前确认板子当前到底在想什么 —— 是还在 C1/C2 重启循环、还是纯静默、
还是已经停在某个提示符。全程只读，绝不写一个字节（不碰 DTR/RTS）。

用法：
    /usr/bin/python3 18-monsniff.py [秒数] [--tx-flood 0x11]

    默认 15 秒纯监听。加 --tx-flood 才会发字节（那时就不再是无损的了）。
"""
import argparse
import sys
import time

import serial

NONPRINT = {0x00: "·", 0x0a: "\n", 0x0d: ""}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("secs", type=float, nargs="?", default=15.0)
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--tx-flood", default=None,
                    help="发字节的十六进制值（如 11 = Ctrl+Q）；默认不发")
    ap.add_argument("--tx-gap", type=float, default=0.05, help="发字节间隔秒")
    args = ap.parse_args()

    # ★ 关键：dsrdtr/rtscts 都关掉，且不主动拉起 DTR/RTS，避免"打开串口"
    #   这个动作本身给板子带电平变化。
    ser = serial.Serial()
    ser.port = args.dev
    ser.baudrate = args.baud
    ser.timeout = 0.1
    ser.dsrdtr = False
    ser.rtscts = False
    ser.open()
    ser.dtr = False
    ser.rts = False
    print(f"[sniff] {args.dev} @ {args.baud} 监听 {args.secs}s"
          f"{'（只读，TX 静默）' if not args.tx_flood else '（会发 TX！）'}")
    try:
        ser.reset_input_buffer()
    except Exception:
        pass

    t0 = time.time()
    last_tx = 0.0
    total = 0
    uniq = {}
    text = sys.stdout
    prefix_buf = b""
    while time.time() - t0 < args.secs:
        if args.tx_flood:
            now = time.time()
            if now - last_tx >= args.tx_gap:
                ser.write(bytes([int(args.tx_flood, 16)]))
                last_tx = now
        d = ser.read(4096)
        if not d:
            continue
        total += len(d)
        for b in d:
            uniq[b] = uniq.get(b, 0) + 1
        prefix_buf += d
        # 实时打印可见文本
        s = "".join(NONPRINT.get(b, chr(b)) if 32 <= b < 127 else NONPRINT.get(b, f"<{b:02x}>")
                    for b in d)
        text.write(s)
        text.flush()

    ser.close()
    print()
    print(f"[sniff] 共收到 {total} 字节；唯一字节表（字节:次数）")
    for b in sorted(uniq):
        c = uniq[b]
        ch = chr(b) if 32 <= b < 127 else "."
        print(f"  0x{b:02x} {ch!r:4} x{c}")
    if total == 0:
        print("[sniff] 结论：串口全程静默 —— 板子要么没上电，要么已死等（无重启循环）")


if __name__ == "__main__":
    main()
