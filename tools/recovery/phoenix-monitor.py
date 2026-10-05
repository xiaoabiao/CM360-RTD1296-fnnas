#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""20-phoenix-v2.py —— Phoenix Monitor 恢复 v2：稀疏按键 + TX/RX 分离记录

相对 v1（phoenix_recover.py）改了什么、为什么
---------------------------------------------
v1 用后台线程以 **16B/4ms ≈ 4000 B/s** 持续灌 Ctrl+Q。上一轮 240s、5 万多次按键
仍然没进 monitor。复盘把原因归为"洪流不够稳"，但从 UART 机理看，这个改动方向可能
是**反的**：

  * 115200 8N1 下 4000 B/s ≈ 每秒 4000 个字节，而 SoC ROM 的串口 FIFO 通常只有
    16 字节、且 ROM 在早期阶段并不会去排空它 → RX 处于**永久 overrun**状态。
    相当一部分 ROM 实现里，overrun 会置错误标志并**丢弃/清空**接收数据，
    于是"我们灌得越猛，它越看不见"。
  * 官方文档写的是 "Press ctrl+q when booting up"——人在 HyperTerm 里**按住**
    Ctrl+Q，终端按键盘重复率只发 ~30 字节/秒，而不是 4000 字节/秒。

所以 v2 默认改成**稀疏单字节**：每 `--key-gap-ms`（默认 30ms）发 **1 个** 0x11
→ ≈33 B/s，正好落在"人按住键"的量级，既不溢出 FIFO，也保证任何检测窗口里都有
Ctrl+Q 在线上。

第二处改动：**TX 与 RX 彻底分开记录**。
v1 把自发字节和板子回包写进同一个日志（`mon.write()` 也写 log），结果上一轮那份
`phoenix-raw.bin` 里 52104 个 0x11 到底是"板子回声"还是"自己写的"根本分不清，
白耗了一轮分析。v2 里：
  * `*-tx.bin`  只存我们发出去的字节（可逐字节核对送了什么）
  * `*-rx.bin`  只存串口收到的字节（纯板子输出）
  * `*-timeline.log`  RX 的**带毫秒时间戳文本**，用来精确对齐 C1/C2/C3/? 各阶段

用法（需要配合断电上电）：
    # 默认：稀疏 Ctrl+Q，等 d/g/r> 出现后自动走 h/s/d/g
    /usr/bin/python3 20-phoenix-v2.py \
        --hwsetting out/rec/RTD1296_hwsetting_BOOT_4DDR4_4Gb_s1866_padding.bin \
        --dvrboot   out/rec/dvrboot.exe.bin

    # 只侦察不烧写（进了 monitor 就停）
    /usr/bin/python3 20-phoenix-v2.py ... --no-download

    # 换别的按键试（一次上电只试一种，别混）
    /usr/bin/python3 20-phoenix-v2.py ... --tx-byte 1b      # ESC
"""
import argparse
import os
import sys
import threading
import time

import serial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from phoenix_recover import ymodem_send  # noqa: E402  复用已验证的 YMODEM 发送器

TS = time.strftime("%m%d-%H%M%S")


class Mon2:
    """与 phoenix_recover.Mon 接口兼容，但 TX/RX 分离记录 + 时间戳。"""

    def __init__(self, dev, baud, tag):
        self.dev = dev
        self.baud = baud
        self._open()
        self.reconnects = 0

        self.rx = open(f"{tag}-rx.bin", "wb", buffering=0)
        self.tx = open(f"{tag}-tx.bin", "wb", buffering=0)
        self.log = open(f"{tag}-timeline.log", "w", buffering=1)  # 人看的：带时间戳
        self.buf = bytearray()
        self.t0 = None
        self.total_rx = 0
        self.total_tx = 0
        self._line = bytearray()

    def _open(self):
        """★ CH340 在这台机器上会偶发 USB 重枚举（07:06 就发生过一次），
        句柄会突然失效。v1 那次就是被这个打断的，所以这里允许重连。"""
        self.ser = serial.Serial()
        self.ser.port = self.dev
        self.ser.baudrate = self.baud
        self.ser.timeout = 0.05
        self.ser.write_timeout = 10
        self.ser.dsrdtr = False
        self.ser.rtscts = False
        self.ser.open()
        self.ser.dtr = False
        self.ser.rts = False
        try:
            self.ser.reset_input_buffer()
        except Exception:
            pass

    def reopen(self):
        for _ in range(40):
            try:
                self._open()
                self.reconnects += 1
                return True
            except Exception:
                time.sleep(0.5)
        return False

    # ---------- 记录 ----------
    def _stamp(self):
        if self.t0 is None:
            self.t0 = time.time()
        return (time.time() - self.t0) * 1000.0

    def _emit_line(self, raw: bytes):
        s = raw.decode("utf-8", "replace")
        self.log.write(f"[{self._stamp():9.1f} ms] {s}\n")
        sys.stdout.write(f"[{self._stamp():9.1f} ms] {s}\n")
        sys.stdout.flush()

    def _ingest(self, d: bytes):
        if self.t0 is None:
            self.t0 = time.time()
            self.log.write("### 首个字节到达，t0 校准\n")
        self.total_rx += len(d)
        self.rx.write(d)
        self.buf += d
        for b in d:
            if b in (0x0A, 0x0D):
                if self._line:
                    self._emit_line(bytes(self._line))
                    self._line.clear()
            elif len(self._line) < 8192:
                self._line.append(b)

    def flush_line(self):
        if self._line:
            self._emit_line(bytes(self._line))
            self._line.clear()

    # ---------- Mon 兼容接口 ----------
    def note(self, s):
        self.flush_line()
        self.log.write(f"\n[note {time.strftime('%H:%M:%S')}] {s}\n")
        sys.stdout.write(f"\n[note] {s}\n")
        sys.stdout.flush()

    note_plain = note

    def write(self, b: bytes):
        try:
            self.ser.write(b)
        except serial.SerialException as e:
            self._ser_warn = f"TX 失败({e})，尝试重连"
            if not self.reopen():
                raise
            self.ser.write(b)
        self.tx.write(b)
        self.total_tx += len(b)

    def read_some(self):
        try:
            d = self.ser.read(4096)
        except serial.SerialException as e:
            # 典型信息：device reports readiness to read but returned no data
            self.log.write(f"\n### 串口异常：{e}；重连中（第 {self.reconnects + 1} 次）\n")
            sys.stdout.write(f"\n### 串口异常，重连中：{e}\n")
            sys.stdout.flush()
            if not self.reopen():
                raise
            return b""
        if d:
            self._ingest(d)
        return d

    def pump(self, seconds):
        end = time.time() + seconds
        out = bytearray()
        while time.time() < end:
            d = self.read_some()
            if d:
                out += d
        self.flush_line()
        return bytes(out)

    def drain(self, quiet=0.4, maxsec=5.0):
        out = bytearray()
        end = time.time() + maxsec
        last = time.time()
        while time.time() < end:
            d = self.read_some()
            if d:
                out += d
                last = time.time()
            elif time.time() - last > quiet:
                break
        self.flush_line()
        return bytes(out)

    def wait_for(self, needle, timeout):
        if isinstance(needle, str):
            needle = needle.encode()
        end = time.time() + timeout
        while time.time() < end:
            self.read_some()
            if needle in self.buf:
                return True
        return False

    def wait_for_any(self, choices, timeout):
        end = time.time() + timeout
        while time.time() < end:
            d = self.read_some()
            if d:
                for b in d:
                    if b in choices:
                        return b
        return None

    def close(self):
        self.flush_line()
        for f in (self.rx, self.tx, self.log):
            try:
                f.close()
            except Exception:
                pass
        try:
            self.ser.close()
        except Exception:
            pass


MONITOR_HINTS = (b"d/g/r", b"g/r>", b"ymodem", b"YMODEM", b"Invalid Pkt")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--hwsetting", required=True)
    ap.add_argument("--dvrboot", required=True)
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    ap.add_argument("--tx-mode", choices=["sparse", "flood", "none"], default="sparse")
    ap.add_argument("--tx-byte", default="11", help="按键字节（十六进制）：11=Ctrl+Q, 1b=ESC, 09=Tab")
    ap.add_argument("--key-gap-ms", type=int, default=30,
                    help="sparse 模式下每个按键之间的毫秒间隔（30ms ≈ 33 B/s ≈ 人按住键）")
    ap.add_argument("--flood-chunk", type=int, default=16)
    ap.add_argument("--flood-gap-ms", type=int, default=4)
    ap.add_argument("--window", type=float, default=120.0, help="最多灌多少秒等上电")
    ap.add_argument("--settle", type=float, default=8.0, help="没等到 monitor 后再多记多少秒")
    ap.add_argument("--no-download", action="store_true", help="进了 monitor 也不烧写")
    ap.add_argument("--no-press-g", action="store_true", help="做完 h/s/d 不按 g")
    ap.add_argument("--pkt", type=int, default=128, choices=[128, 1024])
    args = ap.parse_args()

    for f in (args.hwsetting, args.dvrboot):
        if not os.path.isfile(f):
            sys.exit(f"!! 文件不存在: {f}")
    os.makedirs(args.outdir, exist_ok=True)
    tag = os.path.join(args.outdir, f"phoenix2-{TS}")
    key = bytes([int(args.tx_byte, 16)])

    hw = open(args.hwsetting, "rb").read()
    db = open(args.dvrboot, "rb").read()

    print(f"hwsetting : {args.hwsetting} ({len(hw)} B)")
    print(f"dvrboot   : {args.dvrboot} ({len(db)} B)")
    print(f"日志前缀   : {tag}-{{tx,rx,timeline}}")
    print(f"TX 模式    : {args.tx_mode}  按键 0x{key.hex()}"
          + (f"  间隔 {args.key_gap_ms}ms ≈ {1000//max(1,args.key_gap_ms)} B/s"
             if args.tx_mode == "sparse" else ""))

    mon = Mon2(args.dev, args.baud, tag)
    stop = threading.Event()

    def tx_worker():
        if args.tx_mode == "none":
            return
        if args.tx_mode == "sparse":
            gap = max(0.005, args.key_gap_ms / 1000.0)
            while not stop.is_set():
                try:
                    mon.write(key)
                except Exception:
                    pass
                stop.wait(gap)
        else:
            gap = max(0.002, args.flood_gap_ms / 1000.0)
            chunk = key * max(1, args.flood_chunk)
            while not stop.is_set():
                try:
                    mon.write(chunk)
                except Exception:
                    pass
                stop.wait(gap)

    found = False
    try:
        mon.note(f"统计起点；TX 模式={args.tx_mode} 按键=0x{key.hex()}")
        mon.note(">>> 请给板子断电 → 等 5 秒 → 上电（窗口内什么时候上都行）<<<")
        th = threading.Thread(target=tx_worker, daemon=True)
        th.start()
        t0 = time.time()
        try:
            while time.time() - t0 < args.window:
                d = mon.read_some()
                if not d:
                    continue
                if any(h in mon.buf[-512:] for h in MONITOR_HINTS):
                    found = True
                    break
        finally:
            stop.set()
            th.join(timeout=2)
        mon.drain(0.4, 3)

        if not found:
            mon.note("!! 窗口内没识别到 Phoenix Monitor 提示符")
            mon.note(f"已收 {mon.total_rx} B / 已发 {mon.total_tx} B；"
                     f"再空记 {args.settle}s 看有没有迟到的输出")
            mon.pump(args.settle)
            mon.note("本次未进入 monitor。原始流见 "
                     f"{os.path.basename(tag)}-rx.bin / -timeline.log")
            return

        mon.note("★★ 疑似进入 Phoenix Monitor（回包命中提示符）—— 已停按键")

        if args.no_download:
            mon.note("--no-download：停在 monitor，不烧写")
            mon.pump(5)
            return

        mon.note("== 步骤 1/4: 按 h → YMODEM 发 hwsetting ==")
        mon.buf.clear()
        mon.write(b"h")
        mon.pump(0.6)
        ok = ymodem_send(mon, hw, os.path.basename(args.hwsetting), pkt=args.pkt)
        mon.note(f"hwsetting 发送: {'成功' if ok else '失败'}")
        mon.drain(0.5, 3)

        mon.note("== 步骤 2/4: 按 s → 输入两个地址 ==")
        mon.write(b"s")
        mon.pump(0.6)
        mon.write(b"98007058\r")
        mon.pump(0.8)
        mon.write(b"01500000\r")
        mon.pump(1.2)
        mon.drain(0.4, 3)

        mon.note("== 步骤 3/4: 按 d → YMODEM 发 dvrboot ==")
        mon.buf.clear()
        mon.write(b"d")
        mon.pump(0.6)
        ok2 = ymodem_send(mon, db, "dvrboot.exe.bin", pkt=args.pkt)
        mon.note(f"dvrboot 发送: {'成功' if ok2 else '失败'}")
        mon.drain(0.5, 5)

        if args.no_press_g:
            mon.note("--no-press-g：不发 g")
        else:
            mon.note("== 步骤 4/4: 按 g 开始烧写 ==")
            mon.buf.clear()
            mon.write(b"g")
            mon.note("烧写中，观察 120s ...")
            mon.pump(120)
        mon.note("流程结束。")
    finally:
        stop.set()
        mon.close()
        print(f"\n[完成] TX {tag}-tx.bin / RX {tag}-rx.bin / 时间线 {tag}-timeline.log")


if __name__ == "__main__":
    main()
