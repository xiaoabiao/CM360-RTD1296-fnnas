#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""phoenix_recover.py —— 用 SoC 的 ROM 级 "Phoenix Monitor" 重刷 hwsetting + u-boot

背景（2026-10-05 事故）
-----------------------
我们把 eMMC 前 1 MiB 清零（为了给"兜底裸内核"腾地方），结果抹掉了 RTD1296 在
**eMMC 隐藏块**里的 hwsetting。ROM 级代码启动时会去读它：
    emmc: do_hide_hwsetting_e() read blk 0x...
    hwsetting size: 0xBE4
读不到就重试 ~300 ms，然后重启 C1/C2 并死等 —— 表现就是串口只打到
    C1:80000000 / C2 / ? / C3hswitch frequency ... / switch bus width ... success
    → 卡死，不进 FSBL、不进 u-boot。

官方恢复流程（Banana Pi W2 / 小睿 RTD1296 通用，见 wiki.banana-pi.org「Getting
Started with BPI-W2」与「小睿私人云刷机方法」）：
    1) **按住 Ctrl+Q 再上电** → ROM 里的 Phoenix Monitor 出 `d/g/r>` 提示符
    2) 按 `h` → 串口开始刷 'C' → YMODEM 发 RTD1296_hwsetting_..._padding.bin
    3) 按 `s` → 依次输入 98007058 [Enter]、01500000 [Enter]
    4) 按 `d` → 刷 'C' → YMODEM 发 dvrboot.exe.bin
    5) 按 `g` → 开始烧写

★ 单字母命令 h/s/d/g **不要按回车**（按下即执行）；只有 `s` 里的两个数值才要回车。
★ '.' 号刷 'C' 期间不要乱按键，否则会 Invalid Pkt / 软锁。
★ 本脚本独占 /dev/ttyUSB0 → 跑之前必须先停掉 serial_agent。

用法：
    python3 phoenix_recover.py --hwsetting <hwsetting_padding.bin> --dvrboot <dvrboot.exe.bin>
    python3 phoenix_recover.py ... --no-flood     # 已经手动进了 monitor，跳过洪流
"""
import argparse
import os
import sys
import time

import serial  # pyserial

SOH = 0x01
STX = 0x02
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
CRC_CHAR = 0x43  # 'C'


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc & 0xFFFF


class Mon:
    def __init__(self, dev, baud, logpath):
        self.ser = serial.Serial(dev, baud, timeout=0.05, write_timeout=5)
        self.log = open(logpath, "ab", buffering=0)
        self.buf = bytearray()

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass
        self.log.close()

    def note(self, s):
        msg = f"\n[recover] {s}\n".encode()
        sys.stderr.write(msg.decode())
        sys.stderr.flush()
        self.log.write(msg)

    def note_plain(self, s):
        """只写日志/终端，不加 [recover] 前缀（给用户看的提示用这个，避免污染原始流分析）。"""
        msg = f"\n### {s}\n".encode()
        sys.stderr.write(msg.decode())
        sys.stderr.flush()
        self.log.write(msg)

    def write(self, b: bytes):
        self.ser.write(b)
        self.log.write(b)

    def pump(self, seconds):
        """读 seconds 秒，记录并返回新数据。"""
        end = time.time() + seconds
        out = bytearray()
        while time.time() < end:
            n = self.ser.in_waiting
            d = self.ser.read(n or 1)
            if d:
                out += d
                self.buf += d
                self.log.write(d)
        return bytes(out)

    def wait_for(self, needle, timeout):
        """等 needle 出现（needle 为 bytes）。返回 True/False。"""
        if isinstance(needle, str):
            needle = needle.encode()
        end = time.time() + timeout
        seen = bytearray()
        while time.time() < end:
            d = self.ser.read(self.ser.in_waiting or 1)
            if d:
                seen += d
                self.buf += d
                self.log.write(d)
                if needle in seen:
                    return True
        return False

    def drain(self, quiet=0.4, maxsec=5.0):
        """读到静默为止。"""
        out = bytearray()
        end = time.time() + maxsec
        last = time.time()
        while time.time() < end:
            d = self.ser.read(self.ser.in_waiting or 1)
            if d:
                out += d
                self.buf += d
                self.log.write(d)
                last = time.time()
            elif time.time() - last > quiet:
                break
        return bytes(out)


def ymodem_send(mon: Mon, data: bytes, name: str, pkt=128, retry=10, verbose=True) -> bool:
    """YMODEM 发送（CRC 模式）。pkt=128 用 SOH，pkt=1024 用 STX。
    ★ 多数 bootloader 只吃 128 字节包，默认就用 128。"""
    total = (len(data) + pkt - 1) // pkt
    if verbose:
        mon.note(f"YMODEM 发送 {name}: {len(data)} B, {total} 个 {pkt}B 包")

    def send_block(blk, payload, want):
        """发一个数据块并等 ACK。返回 True 成功。"""
        for attempt in range(retry):
            assert len(payload) in (128, 1024)
            head = bytes([SOH]) if len(payload) == 128 else bytes([STX])
            frame = head + bytes([blk & 0xFF, (~blk) & 0xFF]) + payload
            c = crc16_xmodem(payload)
            frame += bytes([(c >> 8) & 0xFF, c & 0xFF])
            mon.write(frame)
            r = mon.wait_for_any([ACK, NAK, CAN, CRC_CHAR], 3.0)
            if r == ACK:
                return True
            if r == CAN:
                mon.note("!! 收到 CAN，接收端中止")
                return False
            if verbose:
                mon.note(f"  块 {blk} 重传 #{attempt+1}（收到 {r!r}）")
        return False

    # 1) 等接收端发 'C'
    if not mon.wait_for(CRC_CHAR, 30):
        mon.note("!! 30s 内没等到 'C'，接收端可能没进入 YMODEM 模式")
        return False

    # 2) 头块（含文件名与大小）
    hdr = (name.encode()[:100] + b"\x00" + str(len(data)).encode() + b"\x00")
    hdr = hdr[:128].ljust(128, b"\x00")
    if not send_block(0, hdr, ACK):
        mon.note("!! 头块发送失败")
        return False
    if not mon.wait_for(CRC_CHAR, 10):
        mon.note("!! 头块后没等到 'C'")
        return False

    # 3) 数据块
    for i in range(total):
        blk = (i + 1) & 0xFF
        chunk = data[i * pkt:(i + 1) * pkt].ljust(pkt, b"\x00")
        if not send_block(blk, chunk, ACK):
            mon.note(f"!! 数据块 {blk} 失败（i={i}）")
            return False
        if verbose and (i + 1) % 200 == 0:
            mon.note(f"  ... {i+1}/{total} 块")

    # 4) EOT
    for _ in range(retry):
        mon.write(bytes([EOT]))
        r = mon.wait_for_any([ACK, NAK, CRC_CHAR], 3.0)
        if r == ACK:
            break
        if r == NAK:          # 有些实现第一次 EOT 回 NAK
            mon.write(bytes([EOT]))
            if mon.wait_for_any([ACK], 3.0) == ACK:
                break
    # 5) 结束批（YMODEM 的收尾空块），失败无所谓
    mon.write(bytes([SOH, 0x00, 0xFF]) + b"\x00" * 128 + bytes([0, 0]))
    mon.pump(1.0)
    return True


def wait_for_any(self, choices, timeout):
    end = time.time() + timeout
    while time.time() < end:
        d = self.ser.read(self.ser.in_waiting or 1)
        if d:
            self.buf += d
            self.log.write(d)
            for b in d:
                if b in choices:
                    return b
    return None


Mon.wait_for_any = wait_for_any


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--hwsetting", required=True)
    ap.add_argument("--dvrboot", required=True)
    ap.add_argument("--log", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "evidence", "logs", "phoenix-raw.bin"))
    ap.add_argument("--no-flood", action="store_true", help="已在 monitor 里，跳过 Ctrl+Q 洪流")
    ap.add_argument("--flood-secs", type=int, default=180, help="Ctrl+Q 洪流持续秒数（等上电）")
    ap.add_argument("--flood-gap", type=int, default=12, help="洪流每批之间的间隔毫秒（越小越密）")
    ap.add_argument("--flood-chunk", type=int, default=16, help="洪流每批字节数")
    ap.add_argument("--no-press-g", action="store_true", help="只做 h/s/d，不按 g（不烧写）")
    ap.add_argument("--pkt", type=int, default=128, choices=[128, 1024])
    args = ap.parse_args()

    for f in (args.hwsetting, args.dvrboot):
        if not os.path.isfile(f):
            sys.exit(f"!! 文件不存在: {f}")
    os.makedirs(os.path.dirname(args.log), exist_ok=True)

    hw = open(args.hwsetting, "rb").read()
    db = open(args.dvrboot, "rb").read()
    print(f"hwsetting : {args.hwsetting} ({len(hw)} B)")
    print(f"dvrboot   : {args.dvrboot} ({len(db)} B)")
    print(f"日志       : {args.log}")

    mon = Mon(args.dev, args.baud, args.log)
    try:
        if not args.no_flood:
            # ★ 关键：必须是**持续稳流**，不能"爆发+长静默"。
            #   第一版用 64 字节爆发 + 250ms 读等待 → 占空比仅 ~2%，
            #   而 ROM 的按键检测窗口很短（参考 ESC 那个 ~16ms 窗口），
            #   极易撞在静默期 → 识别不到 Ctrl+Q。
            #   这里用后台线程按 flood_gap 毫秒的节奏持续写 flood_chunk 字节，
            #   保证 UART 接收 FIFO 里**始终有 0x11**。
            import threading
            stop = threading.Event()

            def flood_worker():
                gap = max(0.002, args.flood_gap / 1000.0)
                chunk = b"\x11" * max(1, args.flood_chunk)
                while not stop.is_set():
                    try:
                        mon.ser.write(chunk)
                    except Exception:
                        pass
                    time.sleep(gap)

            mon.note(f"开始**持续**灌 Ctrl+Q (0x11)（{args.flood_chunk}B / {args.flood_gap}ms "
                     f"≈ {int(args.flood_chunk*1000/args.flood_gap)} B/s，最多 {args.flood_secs}s）")
            mon.note_plain(">>> 请给板子断电 → 等 5 秒 → 上电 <<<")
            th = threading.Thread(target=flood_worker, daemon=True)
            th.start()
            t0 = time.time()
            found = False
            try:
                while time.time() - t0 < args.flood_secs:
                    d = mon.ser.read(mon.ser.in_waiting or 1)
                    if not d:
                        continue
                    mon.buf += d
                    mon.log.write(d)
                    if any(x in mon.buf for x in (b"d/g/r", b"ymodem", b"YMODEM",
                                                  b"Invalid", b">")):
                        found = True
                        break
            finally:
                stop.set()
                th.join(timeout=1)
            mon.drain(0.3, 2)
            if found:
                mon.note("★ 板子有回包（疑似进入 Phoenix Monitor）")
            else:
                mon.note("!! 没识别到 monitor 提示符 —— 已停洪流，看原始字节确认")
            mon.write(b"\r")

        mon.note("== 步骤 1/4: 按 h 并用 YMODEM 发 hwsetting ==")
        mon.buf.clear()
        mon.write(b"h")
        mon.pump(0.5)
        ok = ymodem_send(mon, hw, os.path.basename(args.hwsetting), pkt=args.pkt)
        mon.note(f"hwsetting 发送: {'成功' if ok else '失败'}")
        mon.drain(0.5, 3)

        mon.note("== 步骤 2/4: 按 s，输入两个地址 ==")
        mon.write(b"s")
        mon.pump(0.6)
        mon.write(b"98007058\r")
        mon.pump(0.8)
        mon.write(b"01500000\r")
        mon.pump(1.2)
        mon.drain(0.4, 3)

        mon.note("== 步骤 3/4: 按 d 并用 YMODEM 发 dvrboot.exe.bin ==")
        mon.buf.clear()
        mon.write(b"d")
        mon.pump(0.5)
        ok2 = ymodem_send(mon, db, "dvrboot.exe.bin", pkt=args.pkt)
        mon.note(f"dvrboot 发送: {'成功' if ok2 else '失败'}")
        mon.drain(0.5, 5)

        if args.no_press_g:
            mon.note("--no-press-g：不发 g，停止在 monitor 提示符")
        else:
            mon.note("== 步骤 4/4: 按 g 开始烧写（会自动重启）==")
            mon.buf.clear()
            mon.write(b"g")
            mon.note("烧写中，观察 120s ...")
            mon.pump(120)
        mon.note("完成。")
    finally:
        mon.close()


if __name__ == "__main__":
    main()
