#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""21-mon-lab.py —— 进 Phoenix Monitor 之后做 YMODEM 协议实验（字节级时间戳）

背景（2026-10-05 07:10 那次实测）
--------------------------------
稀疏 Ctrl+Q 已经**成功进入 monitor**（2055 ms 打出 `d/g/r>`），按 h 也换来了
YMODEM 的 'C' 握手。但真正的数据传输几乎全废：
  * 一共发了 23 帧，板子只回了 3 个 ACK（0x06），**一个 NAK 都没有**
  * 每帧都要等满我们自己的 3 s 超时、重传一次后才"好像"过去
  * 26 秒后板子放弃 monitor，退回正常启动（`C3h…u3-1`）并死等
所以现在必须搞清楚：**接收端到底是收不到、收错了，还是收得慢。**

本脚本在**同一次 monitor 会话内**依次试 4 种发法，并记录每一次 TX/RX 的毫秒
时间戳，用来区分三种可能：
  (a) 接收端 FIFO 跟不上 → 全速帧失败、**降速分片帧成功**
  (b) 接收端只认 1024 字节 DATA 包（YMODEM-1K）→ 128 字节数据帧失败、STX 成功
  (c) 接收端能收但 ACK 有固定延迟 → 帧本身成功、只是我们超时设太短

用法（配合断电上电）：
    /usr/bin/python3 21-mon-lab.py
"""
import argparse
import os
import sys
import threading
import time

import serial

TS = time.strftime("%m%d-%H%M%S")
SOH, STX, EOT, ACK, NAK, CAN, CRC_C = 0x01, 0x02, 0x04, 0x06, 0x15, 0x18, 0x43


def crc16(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc & 0xFFFF


def ymodem_frame(blk: int, payload: bytes, size: int) -> bytes:
    payload = payload[:size].ljust(size, b"\x00")
    head = bytes([SOH]) if size == 128 else bytes([STX])
    c = crc16(payload)
    return head + bytes([blk & 0xFF, (~blk) & 0xFF]) + payload + bytes([(c >> 8) & 0xFF, c & 0xFF])


class Lab:
    def __init__(self, dev, baud, outdir):
        self.ser = serial.Serial()
        self.ser.port = dev
        self.ser.baudrate = baud
        self.ser.timeout = 0.02
        self.ser.write_timeout = 10
        self.ser.dsrdtr = False
        self.ser.rtscts = False
        self.ser.open()
        self.ser.dtr = False
        self.ser.rts = False
        self.ser.reset_input_buffer()
        self.t0 = None
        self.rxbin = open(f"{outdir}/lab-{TS}-rx.bin", "wb", buffering=0)
        self.txbin = open(f"{outdir}/lab-{TS}-tx.bin", "wb", buffering=0)
        self.evlog = open(f"{outdir}/lab-{TS}-events.log", "w", buffering=1)

    def now(self):
        if self.t0 is None:
            self.t0 = time.time()
        return (time.time() - self.t0) * 1000.0

    def ev(self, msg):
        line = f"[{self.now():9.1f} ms] {msg}\n"
        self.evlog.write(line)
        sys.stdout.write(line)
        sys.stdout.flush()

    def collect(self, secs, stop_on=None):
        """读 secs 秒；每个 chunk 单独打时间戳。返回 (data, events)."""
        end = time.time() + secs
        out = bytearray()
        events = []
        while time.time() < end:
            d = self.ser.read(256)
            if not d:
                continue
            self.rxbin.write(d)
            out += d
            t = self.now()
            events.append((t, bytes(d)))
            for b in d:
                name = {ACK: "ACK", NAK: "NAK", CAN: "CAN", CRC_C: "'C'", SOH: "SOH",
                        STX: "STX", EOT: "EOT"}.get(b)
                self.ev(f"  RX t={t:9.1f} {'← ' + name if name else ''} "
                        f"0x{b:02x} ({chr(b) if 32 <= b < 127 else '.'})")
            if stop_on and any(b in stop_on for b in d):
                break
        return bytes(out), events

    def tx(self, data: bytes, label, pace=(0, 0.0)):
        """发一帧。pace=(每次字节数, 间隔秒)，(0,0) 表示全速一次写完。"""
        t_before = self.now()
        if pace[0] > 0:
            step = pace[0]
            for i in range(0, len(data), step):
                self.ser.write(data[i:i + step])
                time.sleep(pace[1])
        else:
            self.ser.write(data)
        self.ser.flush()
        t_after = self.now()
        self.txbin.write(data)
        self.ev(f"TX {label}: {len(data)}B 用时 {t_after - t_before:.1f} ms "
                f"(首字节 0x{data[0]:02x} blk={data[1] if len(data) > 1 else '-'})")
        return t_after


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    ap.add_argument("--window", type=float, default=90.0, help="灌 Ctrl+Q 等上电的秒数")
    ap.add_argument("--watch", type=float, default=3.0, help="每帧之后观察多少秒")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    lab = Lab(args.dev, args.baud, args.outdir)
    lab.ev(f"### monitor YMODEM 实验开始 {time.strftime('%F %T')}")
    lab.ev(">>> 请给板子断电 → 等 5 秒 → 上电 <<<")

    # ---- 阶段 0：稀疏 Ctrl+Q 进 monitor ----
    stop = threading.Event()

    def keys():
        while not stop.is_set():
            try:
                lab.ser.write(b"\x11")
            except Exception:
                pass
            stop.wait(0.03)

    th = threading.Thread(target=keys, daemon=True)
    th.start()
    found = False
    deadline = time.time() + args.window
    buf = bytearray()
    while time.time() < deadline:
        d = lab.ser.read(256)
        if d:
            lab.rxbin.write(d)
            buf += d
            lab.ev(f"  RX(入场) {d!r}")
            if b"d/g/r" in buf:
                found = True
                break
    stop.set()
    th.join(timeout=1)
    if not found:
        lab.ev("!! 没进 monitor，实验结束")
        return
    lab.ev("★★ 已进入 monitor")

    # ---- 阶段 1：按 h，等 YMODEM 的 'C' ----
    lab.tx(b"h", "按键 h")
    _, _ = lab.collect(3.0, stop_on=(CRC_C,))

    # ---- 阶段 2：四种发法各试一帧 ----
    results = []

    def trial(label, frame, pace=(0, 0.0)):
        t = lab.tx(frame, label, pace)
        data, events = lab.collect(args.watch, stop_on=(ACK, NAK, CAN))
        kinds = [(f"{tt - t:.0f}ms", hex(b)) for tt, chunk in events for b in chunk]
        first = kinds[0] if kinds else None
        acks = sum(1 for _, h in kinds if h == hex(ACK))
        naks = sum(1 for _, h in kinds if h == hex(NAK))
        cs = sum(1 for _, h in kinds if h == hex(CRC_C))
        results.append((label, first, acks, naks, cs, len(data)))
        lab.ev(f"  ⇒ {label}: 首回包={first} ACK={acks} NAK={naks} 'C'={cs} 共{len(data)}B")

    # ★ 顺序很关键：接收端此时处于"等头块(blk0)"状态，所以先反复用不同速率试**头块**，
    #   只有头块被 ACK 了才谈得上发数据块。这样即使 monitor 提前退出，也能拿到
    #   最有价值的信息："头块在哪个速率下能被收下"。
    hdr = (b"TEST.BIN\x00" + b"128\x00").ljust(128, b"\x00")

    trial("T1 头块 SOH/blk0 全速(~11.5KB/s)", ymodem_frame(0, hdr, 128))
    trial("T2 头块 SOH/blk0 降速 4B/5ms(~0.8KB/s)", ymodem_frame(0, hdr, 128), pace=(4, 0.005))
    trial("T3 头块 SOH/blk0 降速 32B/10ms(~3.2KB/s)", ymodem_frame(0, hdr, 128), pace=(32, 0.010))
    trial("T4 数据 SOH/blk1 降速 4B/5ms", ymodem_frame(1, b"A" * 128, 128), pace=(4, 0.005))
    trial("T5 数据 STX/blk2 1024B 降速 4B/5ms", ymodem_frame(2, b"B" * 1024, 1024), pace=(4, 0.005))
    trial("T6 数据 SOH/blk2 全速(128B)", ymodem_frame(2, b"C" * 128, 128))

    lab.ev("=== 实验汇总 ===")
    for label, first, acks, naks, cs, n in results:
        lab.ev(f"  {label:<40} 首回包={first} ACK={acks} NAK={naks} 'C'={cs} 收{n}B")
    lab.ev("原始流见 lab-*-rx.bin / -events.log / -tx.bin")


if __name__ == "__main__":
    main()
