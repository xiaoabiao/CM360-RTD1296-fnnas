#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
串口常驻代理（serial_agent）—— 让 Agent 可以跨多次调用持续接管一条 TTY。

为什么需要它
------------
每次 shell 调用都是独立进程，串口没法"保持打开"。如果每次都重新 open/close：
  1. 每次打开 tty 都可能触发 DTR/RTS 电平变化 → 某些板子会因此复位（CH340 尤其常见）
  2. 板子打到一半的启动日志会被漏掉
  3. 没法"先听一会儿再决定发什么"

这个守护进程只打开串口一次，然后做两件事：
  * 一直读 → 追加写入 <前缀>.log（带时间戳）/ <前缀>.raw（原始字节）
  * 一直盯 <前缀>.ctl 这个控制文件的新增行 → 按行投递到串口

于是跨进程交互就变成：
    echo "help" >> session01.ctl          # 发一条 help
    tail -n 60 session01.log              # 看回应

控制文件语法（每行一条）
------------------------
    help                      普通文本 → 原样发送并自动补回车
    @key:ESC                  发单个按键（ESC/TAB/CR/SPACE/BS）
    @key:TAB
    @raw:1b09                 发原始十六进制字节
    @sleep:2                  推迟 2 秒 —— 之后解析到的命令都会等满这 2 秒
    @burst:8 esc tab          连打打断键 8 秒（交替 esc/tab）
    @mark:上电前               只在本地日志里打个标记，不往串口发东西
    @quit                     让代理退出

发送节流（重要）
----------------
代理内部有一个"时间游标"：每条命令最早只能在 `游标` 时刻发出，发完把游标推到
`发出时刻 + gap`。所以即使你一次性往 .ctl 里追加十条命令，它们也会**一条一条、
间隔 gap 秒**地发出去。

这不是画蛇添足：u-boot 打印长 help 文本时来不及读 UART 接收 FIFO（通常只有 16 字节），
一口气灌多条命令会导致**输入溢出错位**（实测现象：`help sata` 收到的是 `hehelp sata`，
中间还丢了一条命令的完整输出）。间隔由 `--gap` 控制，默认 0.6 秒；
输出很长的命令（如 `help`、`printenv`）建议自己再加 `@sleep:2`。

安全约束
--------
本代理只做"读串口 + 写普通文本/按键"。它自己不会构造任何烧写类命令，
但请在 u-boot 提示符下也不要手敲 erase / sf / mmc write / nand erase / setenv / saveenv。

@flood —— 满线 ESC 洪流（2026-10-04 新增，抢 bootcode console 窗口专用）
------------------------------------------------------------------------
语法：
    @flood:1800 esc         开洪流 1800 秒，间隙用默认 8ms
    @flood:90/12 esc        开洪流 90 秒，间隙 12ms
    @flood:0                立刻停洪流（@floodstop 同义）

为什么不能用 @burst 干这件事
    @burst 是"排队发按键"：_enqueue_burst 里 `t += 0.15` 是硬编码的，
    也就是**每 0.15 秒才发一个 0x1b**。而 Realtek bootcode 的判据是
    "打印 'Hit Esc or Tab key ...: 0' 之后 ~10~16ms 内在 UART 接收 FIFO 里看到 ESC"。
    两次实测并排：
        成功: [14525.614] Hit Esc ... -> [14525.630] Press Esc Key        （16ms 内）
        失败: [16854.823] Hit Esc ... -> [16854.844] Checking android recovery（没 Press Esc）
    150ms 一个 ESC 去碰 16ms 的窗口 = 抽奖 → 这就是"上电了却没进 console"的根因之一。

★★ 但"满线狂灌"也不行（2026-10-04 第二次实测，0/2 全失手）
    把占线率拉到 ~100%（主循环非阻塞狂写，把内核 tty 输出队列顶到常满）之后，
    板子照样没进 console —— 而且比稀疏连打**更差**（满线 0/2，稀疏 1/2）。
    最合理的解释：bootcode 在检测前会**先等串口"空闲"**（线路上一段时间没有新字节），
    满线灌的时候线路永远不空闲 → 它直接跳过检测。
    （旁证：board's RX 是好的 —— DSM 下板子把我们灌的 ESC 原样回显回来，
     回显速率 ≈ 11.2KB/s ≈ 满线率，说明线路确实 100% 占线、字节也没坏。）

正确姿势：**节流洪流（带间隙）**
    间隙要同时满足两端：
      ① 足够大 → 线路看起来是"空闲"的（8ms = 92 个 bit time，任何空闲判据都该认）
      ② 足够小 → 10~16ms 的检测窗口里必有 ESC 到达（8ms < 16ms ✓）
    默认间隙 8ms（≈125 次/秒）。实测里 "150ms 间隙" 能中（1/2），"0 间隙" 必不中，
    8ms 取的是两头兼顾。若还不中，按 12ms → 20ms → 30ms 的阶梯往上调。
    这时候主机侧也**不会**积压（125 B/s << 11520 B/s），命中后排空几乎瞬时。

为什么必须做在代理内部（而不是另起一个进程直接写 tty）
    本机 USB-TTL 是 CH340（ch341-uart，1a86:7523），这条 tty **只允许一个进程
    打开**：第二个 open 一律 EBUSY —— O_RDONLY / O_WRONLY / O_RDWR / ±O_NONBLOCK
    六种组合全试过，连 `echo x > /dev/ttyUSB0` 都报"设备或资源忙"。代理已经持有
    那个 fd，所以洪流只能由它自己发。顺带也符合"读只归一个进程"的纪律。

⚠ 洪流开着的时候别发普通命令：要发命令先 `@flood:0`，再等 ~1 秒。
"""

import argparse
import os
import select
import signal
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from serial_capture import BAUDS, Recorder, _key_seq, open_serial  # noqa: E402


class Agent:
    def __init__(self, fd, rec, ctl_path, quiet=False, gap=0.6):
        self.fd = fd
        self.rec = rec
        self.ctl_path = ctl_path
        self.quiet = quiet

        # 控制文件：从头读，避免把上次遗留的命令重放一遍
        self.ctl_off = os.path.getsize(ctl_path) if os.path.exists(ctl_path) else 0
        self.ctl_buf = b""
        self.pending = []          # [(due_ts, payload, note)]
        self.last_rx = time.time()
        self.rx_total = 0

        # ★ 时间游标：下一条指令最早允许发送的时刻。
        #   没有它的话，同一轮从 ctl 解析出来的多条命令会在同一毫秒全灌进串口，
        #   而 u-boot 打印长 help 时来不及读 UART 接收 FIFO → 输入溢出错位
        #   （实测现象：`help sata` 变成 `hehelp sata`，中间还丢了一条命令的输出）。
        self.cursor = time.time()
        self.gap = gap

        # ★ 洪流状态（@flood，见文件头说明）
        #   flood_until > now 时，主循环按 flood_interval 的节奏发 ESC。
        self.flood_until = 0.0
        self.flood_buf = b"\x1b"
        self.flood_interval = 0.008   # ★ 两个 ESC 之间的间隙（秒）。0 = 满线狂灌
        self.flood_last = 0.0

    def note(self, msg):
        if not self.quiet:
            sys.stderr.write("[agent] %s\n" % msg)
            sys.stderr.flush()

    # ---------- 收 ----------
    def poll_serial(self, timeout=0.05):
        try:
            r, _w, _x = select.select([self.fd], [], [], timeout)
        except InterruptedError:
            return
        if not r:
            return
        try:
            data = os.read(self.fd, 4096)
        except OSError:
            return
        if data:
            self.rec.feed(data)
            self.last_rx = time.time()
            self.rx_total += len(data)

    # ---------- 发 ----------
    def _enqueue_burst(self, seconds, keys):
        """连打打断键。起点也要尊重游标。"""
        base = max(time.time(), self.cursor)
        seq = []
        for k in keys:
            seq += _key_seq(k)
        if not seq:
            return 0
        i = 0
        n = 0
        t = base
        while t < base + seconds:
            self.pending.append((t, seq[i % len(seq)], None))
            i += 1
            n += 1
            t += 0.15
        self.pending.sort(key=lambda x: x[0])
        self.cursor = base + seconds + self.gap
        return n

    def _schedule(self, payload, note):
        """排入一条待发数据，并推进时间游标。"""
        t = max(time.time(), self.cursor)
        self.pending.append((t, payload, note))
        self.pending.sort(key=lambda x: x[0])
        self.cursor = t + self.gap
        return t

    # ---------- 洪流（@flood）----------
    def pump_flood(self):
        """按 flood_interval 的节奏把 ESC 发出去（节流版）。

        ★★ 2026-10-04 第二次实测教训：**"满线狂灌"（占线率 100%）反而 0/2 全失手，
        而旧的稀疏连打（150ms 一个）是 1/2**。最合理的解释是 bootcode 在检测前会
        先等串口"空闲"（线路上一段时间没有新字节）—— 满线灌的时候线路永远不空闲，
        它就直接跳过检测。所以正确姿势是：**间隙要足够大（让线路看起来空闲），
        又要足够小（检测窗口 ~10~16ms 里必有 ESC 到达）**。
        默认 8ms 间隙 = 92 个 bit time，任何"空闲"判据都该认；
        同时 8ms < 16ms 检测窗口，窗口内必有一条 ESC。两端都满足。

        间隔由 flood_interval 控制；=0 退回"满线狂灌"（保留作对照，别默认用）。
        """
        if time.time() >= self.flood_until:
            return
        now = time.time()
        if self.flood_interval > 0 and now - self.flood_last < self.flood_interval:
            return
        self.flood_last = now
        try:
            os.write(self.fd, self.flood_buf)
        except (BlockingIOError, OSError):
            pass

    def handle_line(self, line):
        line = line.rstrip("\r")
        if not line.strip():
            return True
        if line.startswith("@"):
            body = line[1:]
            cmd, _, arg = body.partition(":")
            cmd = cmd.strip().lower()
            arg = arg.strip()

            if cmd == "quit":
                self.note("收到 @quit，退出")
                return False
            if cmd == "mark":
                self.note("标记：%s" % arg)
                return True
            if cmd == "sleep":
                try:
                    sec = float(arg)
                except ValueError:
                    self.note("忽略非法 @sleep: %r" % arg)
                    return True
                # 不动 pending，只推迟游标 —— 后面解析到的命令自然会等到那时
                self.cursor = max(self.cursor, time.time()) + sec
                self.note("推迟 %.1fs（后续命令将等待）" % sec)
                return True
            if cmd == "key":
                seq = _key_seq(arg.lower())
                self._schedule(seq[0], "key %s" % arg.upper())
                return True
            if cmd == "raw":
                try:
                    payload = bytes.fromhex(arg.replace(" ", ""))
                except ValueError:
                    self.note("忽略非法 @raw: %r" % arg)
                    return True
                self._schedule(payload, "raw %s" % arg)
                return True
            if cmd == "burst":
                parts = arg.lower().split()
                if not parts:
                    self.note("忽略空 @burst")
                    return True
                try:
                    sec = float(parts[0])
                except ValueError:
                    self.note("忽略非法 @burst: %r" % arg)
                    return True
                keys = parts[1:] or ["both"]
                n = self._enqueue_burst(sec, keys)
                self.note("开始连打打断键 %.1fs（%d 次，键=%s）" % (sec, n, ",".join(keys)))
                return True

            if cmd in ("flood", "floodstop"):
                if cmd == "floodstop":
                    self.flood_until = 0.0
                    self.note("停洪流")
                    return True
                parts = arg.lower().split()
                spec = parts[0] if parts else "5"
                # 语法 @flood:<秒>[/<间隙ms>] [key]，缺省间隙 8ms
                if "/" in spec:
                    s_sec, s_ms = spec.split("/", 1)
                else:
                    s_sec, s_ms = spec, ""
                try:
                    sec = float(s_sec)
                    interval = float(s_ms) / 1000.0 if s_ms else 0.008
                except ValueError:
                    self.note("忽略非法 @flood: %r" % arg)
                    return True
                if sec <= 0:
                    self.flood_until = 0.0
                    self.note("停洪流")
                    return True
                keys = parts[1:] or ["esc"]
                seq = b""
                for k in keys:
                    seq += _key_seq(k)[0]
                self.flood_buf = seq or b"\x1b"
                self.flood_interval = max(0.0, interval)
                self.flood_last = 0.0
                self.flood_until = time.time() + sec
                if self.flood_interval > 0:
                    self.note("开始洪流 %.1fs（键=%s，间隙 %.0fms ≈ %.0f 次/秒）"
                              % (sec, ",".join(keys), self.flood_interval * 1000,
                                 1.0 / self.flood_interval))
                else:
                    self.note("开始洪流 %.1fs（键=%s，满线狂灌模式）" % (sec, ",".join(keys)))
                return True

            self.note("未知控制指令，忽略：%r" % line)
            return True

        self._schedule(line.encode() + b"\r", line)
        self.note(">>> 排入命令: %s（%.1fs 后发出）"
                  % (line, max(0.0, self.cursor - self.gap - time.time())))
        return True

    def poll_ctl(self):
        if not os.path.exists(self.ctl_path):
            return True
        try:
            size = os.path.getsize(self.ctl_path)
        except OSError:
            return True
        if size < self.ctl_off:
            # 文件被截断/重建，从头读
            self.ctl_off = 0
            self.ctl_buf = b""
        if size == self.ctl_off:
            return True
        try:
            with open(self.ctl_path, "rb") as f:
                f.seek(self.ctl_off)
                chunk = f.read()
                self.ctl_off = f.tell()
        except OSError:
            return True
        self.ctl_buf += chunk
        while b"\n" in self.ctl_buf:
            raw, _, self.ctl_buf = self.ctl_buf.partition(b"\n")
            keep_going = self.handle_line(raw.decode("utf-8", "replace"))
            if not keep_going:
                return False
        return True

    def flush_pending(self):
        now = time.time()
        while self.pending and self.pending[0][0] <= now:
            _due, payload, note = self.pending.pop(0)
            if payload:
                try:
                    os.write(self.fd, payload)
                except OSError:
                    pass
            if note and not self.quiet:
                sys.stderr.write("[agent]     -> %s\n" % note)
                sys.stderr.flush()

    def run(self):
        self.note("串口已打开，开始监听。控制文件：%s" % self.ctl_path)
        self.note("读串口 -> %s / %s" % (self.rec.logpath, self.rec.rawpath))
        last_hb = 0.0
        while True:
            # ★ 洪流开着时把 select 超时压到 1ms，否则 50ms 的轮询间隔
            #   会把 8ms 的节流间隔实际变成 50ms（间隙过大 → 命中率掉下来）。
            flooding = time.time() < self.flood_until
            self.poll_serial(0.001 if flooding else 0.05)
            self.pump_flood()      # ★ @flood 开着时在这里按节奏发
            if not self.poll_ctl():
                break
            self.flush_pending()
            now = time.time()
            if not self.quiet and now - last_hb > 20.0:
                last_hb = now
                idle = now - self.last_rx
                sys.stderr.write(
                    "[agent] 心跳：累计收 %d 字节，静默 %.0f 秒\n" % (self.rx_total, idle)
                )
                sys.stderr.flush()
        self.note("退出，累计收 %d 字节" % self.rx_total)


def main():
    ap = argparse.ArgumentParser(description="串口常驻代理")
    ap.add_argument("-d", "--dev", default="/dev/ttyUSB0")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-o", "--out", required=True, help="输出前缀（同时用作 .log/.raw/.ctl）")
    ap.add_argument("-g", "--gap", type=float, default=0.6,
                    help="命令之间的最小间隔秒数（默认 0.6，输出长的命令请自行加 @sleep）")
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--append", action="store_true",
                    help="续写 .log/.raw（代理重启时保留历史；默认截断）")
    args = ap.parse_args()

    if args.baud not in BAUDS:
        sys.exit("[错误] 不支持的波特率：%d" % args.baud)

    ctl_path = args.out + ".ctl"
    if not os.path.exists(ctl_path):
        open(ctl_path, "w").close()

    fd = open_serial(args.dev, BAUDS[args.baud], args.baud)
    rec = Recorder(args.out, append=args.append)
    agent = Agent(fd, rec, ctl_path, quiet=args.quiet, gap=args.gap)
    agent.note("命令间隔 gap = %.2fs（可用 --gap 调整）" % args.gap)

    def on_sig(_s, _f):
        agent.note("收到信号，收尾退出")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, on_sig)
    signal.signal(signal.SIGINT, on_sig)

    try:
        agent.run()
    finally:
        rec.close()
        try:
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    main()
