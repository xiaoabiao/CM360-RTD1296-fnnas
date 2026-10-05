#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""20-bootcap.py —— 干净的受损态启动基线捕获（只读，一个字节都不发）

为什么需要它
------------
2026-10-05 那次 phoenix 尝试的日志 `logs/phoenix-raw.bin` 是**边灌洪水边记**的，
里面混进了大量 0x11 / 0x44 串扰杂波，"switch bus width … success" 之后那个
本该是 `hwsetting size: 00000BE4` 的位置只留下一串残缺字节。
而那串值恰恰是**唯一能反推"ROM 在哪个 LBA 读 hwsetting"**的线索：
  - 若读到全 0      → hwsetting 在被我清零的前 1 MiB 内
  - 若读到 56190527  → 读的是我们写的裸内核（uImage 魔数 0x27051956，小端显示）
  - 若读到 00000BE4  → 其实没坏，问题在别处（那整个复盘都要重写）
所以必须**纯被动**重抓一次，且带毫秒时间戳。

用法（配合断电上电）：
    /usr/bin/python3 20-bootcap.py --max 180 --quiet-stop 15
      → 脚本开好后提示你断电→上电；收到最后一个字节后静默 15s 就收工。
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
    ap.add_argument("--max", type=float, default=180.0, help="最长监听秒数")
    ap.add_argument("--quiet-stop", type=float, default=15.0, help="收到最后字节后静默多少秒收工")
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    raw_path = os.path.join(args.outdir, f"bootcap-{TS}.bin")
    txt_path = os.path.join(args.outdir, f"bootcap-{TS}.log")

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

    def both(s):
        sys.stdout.write(s)
        sys.stdout.flush()
        txt.write(s)

    both(f"### 受损态启动基线捕获  开始 {time.strftime('%F %T')}\n")
    both(f"### 设备 {args.dev} @ {args.baud}  （全程只读，TX 静默）\n")
    both(f"### 原始字节 -> {raw_path}\n")
    both(">>> 请给板子断电 → 等 5 秒 → 上电 <<<\n\n")

    t_start = time.time()
    t_first = None
    t_last_rx = None
    total = 0
    # 行缓冲：按 \r 或 \n 断行，带毫秒时间戳
    line = bytearray()

    def flush_line(now):
        if not line:
            return
        try:
            s = line.decode("utf-8", "replace")
        except Exception:
            s = repr(bytes(line))
        dt = (now - t_first) * 1000 if t_first is not None else 0.0
        both(f"[{dt:9.1f} ms] {s}\n")
        line.clear()

    while time.time() - t_start < args.max:
        d = ser.read(4096)
        now = time.time()
        if d:
            if t_first is None:
                t_first = now
                both(f"### 首个字节到达（t0 校准点）\n")
            t_last_rx = now
            total += len(d)
            raw.write(d)
            for b in d:
                if b in (0x0A, 0x0D):
                    flush_line(now)
                elif len(line) < 4096:
                    line.append(b)
        else:
            if t_last_rx and (now - t_last_rx) > args.quiet_stop:
                flush_line(now)
                both(f"\n### 静默 {args.quiet_stop:.0f}s，收工\n")
                break

    flush_line(time.time())
    ser.close()
    raw.close()

    data = open(raw_path, "rb").read()
    both(f"\n### 汇总：共 {total} 字节，raw -> {raw_path}\n")
    if data:
        both("### 非打印字节直方图：\n")
        from collections import Counter
        c = Counter(data)
        weird = [(hex(b), n) for b, n in c.most_common(15) if not (32 <= b < 127 or b in (10, 13))]
        both(f"    {weird}\n")
        both(f"### 全部内容（latin1 转义）：\n")
        both("".join(chr(b) if 32 <= b < 127 else f"\\x{b:02x}" for b in data) + "\n")
    txt.close()
    print(f"\n[完成] {txt_path}")


if __name__ == "__main__":
    main()
