#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""19-txprobe.py —— 判断"主机→板子"方向到底通不通（不回环/不回显）

为什么需要它
------------
2026-10-05 那次 Phoenix Monitor 恢复失败：灌了 240s、52104 个 0x11，板子照样
走完 C1/C2/C3 然后死掉，从没进 monitor。失败原因只有两类：
  (a) 按键/时序不对（软件问题）
  (b) 主机 TX 根本没到 SoC（硬件/线序问题）
在没区分这两类之前，再灌十次洪流都是白费。本脚本用两个互补测试来区分：

  测试 1「自环」：发一串唯一特征字节，看是否原样回来。
      回来 → 适配器或线缆把 TX/RX 短在一起（本地回显），说明我们在自说自话。
      没回来 → 至少不存在低层自环。

  测试 2「0x11 洪水回声」：发 64 字节 0x11，看回多少。
      ★ 复盘里那条"洪流计数 52104"值得警惕：脚本的 flood 线程是**直接**
        ser.write() 的（不经 Mon.write），所以那些 0x11 理论上不该出现在日志里。
        如果它们其实是回环回来的，就必须重新解释那次失败。

用法：
    /usr/bin/python3 19-txprobe.py            # 板子可以保持当前状态（不用断电）
    /usr/bin/python3 19-txprobe.py --secs 3
"""
import argparse
import time

import serial


def open_port(dev, baud):
    ser = serial.Serial()
    ser.port = dev
    ser.baudrate = baud
    ser.timeout = 0.1
    ser.dsrdtr = False
    ser.rtscts = False
    ser.open()
    ser.dtr = False
    ser.rts = False
    return ser


def read_for(ser, secs):
    out = bytearray()
    end = time.time() + secs
    while time.time() < end:
        d = ser.read(4096)
        if d:
            out += d
    return bytes(out)


def show(tag, data):
    if not data:
        print(f"  {tag}: <无数据>")
        return
    txt = "".join(chr(b) if 32 <= b < 127 else f"\\x{b:02x}" for b in data)
    print(f"  {tag}: {len(data)} B  首64字节: {txt[:200]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--secs", type=float, default=2.0)
    args = ap.parse_args()

    ser = open_port(args.dev, args.baud)
    print(f"[probe] {args.dev} @ {args.baud}")

    # ---------- 测试 1：唯一特征串，看是否本地回环 ----------
    ser.reset_input_buffer()
    tag = b"TXPROBE-A1B2C3D4E5F6\r\n"
    ser.write(tag)
    ser.flush()
    got = read_for(ser, args.secs)
    print("[测试1] 自环检测（发 21B 唯一特征串）")
    show("发出", tag)
    show("收到", got)
    if tag.strip() in got:
        print("  !! 特征串原样回来了 → 存在本地回环/回显，TPO：TX 与 RX 在近端被短接")
    elif got:
        print("  ?  收到了别的东西（板子有输出），但特征串没原样回 —— 不是简单自环")
    else:
        print("  OK 没有回环、板子也没说话（符合 板子死等或未上电）")

    # ---------- 测试 2：0x11 洪水回声计数 ----------
    ser.reset_input_buffer()
    n = 64
    ser.write(b"\x11" * n)
    ser.flush()
    got2 = read_for(ser, args.secs)
    print(f"[测试2] 发 {n} 个 0x11，看回多少")
    show("收到", got2)
    c11 = got2.count(0x11)
    print(f"  收到 0x11 个数 = {c11}")
    if c11 >= n * 0.8:
        print("  !! 几乎全回来了 → 强证据表明 0x11 被原样送回，"
              "上次日志里那 52104 个 0x11 极可能就是自环，不是板子收到")
    elif c11:
        print("  ?  回来一部分 0x11，需要结合 C1/C2 打印一起判断")
    else:
        print("  OK 0x11 没有被送回来")

    ser.close()
    print("[probe] 完成")


if __name__ == "__main__":
    main()
