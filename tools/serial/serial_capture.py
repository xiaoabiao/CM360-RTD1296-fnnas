#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RTD1296 / 小睿 CM360 串口抓取工具

纯 Python 标准库实现，不需要 pip 安装任何东西（不用 pyserial）。

用法
----
1) 抓启动日志（只读，不发送任何按键）
   sudo python3 serial_capture.py log -t 120
   运行后立刻给板子上电。

2) 进 u-boot 抓环境变量（会在开机瞬间连打 Esc/Tab 打断 autoboot，再发 printenv）
   sudo python3 serial_capture.py uboot -t 90
   运行后立刻给板子上电。

3) 探查 u-boot 支持哪些命令（全只读：help / version / help usb / help tftpboot ...）
   sudo python3 serial_capture.py probe -t 45 -o shot_uboot_02
   运行后立刻给板子上电。

4) 自定义按键时序
   sudo python3 serial_capture.py keys -t 45 -o shot_x --burst-until 9 \
        -p '10:help,14:version,18:help tftpboot'
   --burst-until 会在前 N 秒自动补上 Esc/Tab 打断键。

可选参数
--------
   -d /dev/ttyUSB0   串口设备节点
   -b 115200         波特率
   -o <名字>         输出文件名前缀（默认按时间戳命名）
   -t <秒>           总抓取时长
   -k both|esc|tab   打断键（默认 both = Esc/Tab 交替）
   -c <命令>         uboot 模式打断后执行的命令（默认 printenv）
   --burst-until N   keys 模式自动补 N 秒打断键

输出（放在脚本同目录）
--------------------
   <前缀>.log    带时间戳、已把 CR 规范成 LF，方便人看
   <前缀>.raw    原始字节，一个不丢，便于事后按二进制解析

安全说明
--------
本脚本只做两件事：读串口、往串口写普通文本按键。
绝对不会发送任何烧写/擦除类命令。请在 u-boot 提示符下也不要手工敲
erase / sf / mmc write / nand erase 之类的命令。
"""

import argparse
import datetime
import errno
import os
import select
import sys
import termios
import time

CHUNK = 4096


def open_serial(dev, baud_const, baud_int):
    """以 raw 8N1 打开串口，返回 fd。"""
    try:
        fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno in (errno.EACCES, errno.EPERM):
            sys.exit(
                f"[错误] 没有权限打开 {dev} (errno={e.errno})\n"
                f"       请用 sudo 运行，或把当前用户加入 dialout 组：\n"
                f"       sudo usermod -aG dialout $USER   # 之后要重新登录"
            )
        if e.errno == errno.ENOENT:
            sys.exit(
                f"[错误] 找不到 {dev}\n"
                f"       插拔一下 USB-TTL，然后确认设备名：ls -l /dev/ttyUSB*"
            )
        raise

    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = attrs
    # 输入：关掉所有字符转换
    iflag = 0
    # 输出：关掉所有字符转换（不把 \n 变成 \r\n 等）
    oflag = 0
    # 本地：关掉 echo / 信号 / 规范模式 -> 完全透传
    lflag = 0
    # 控制：8 位、忽略 modem 控制线、使能接收
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(
        fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, baud_const, baud_const, cc]
    )
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def human_baud(fd):
    try:
        a = termios.tcgetattr(fd)
        return a[4]
    except Exception:
        return "?"


class Recorder:
    def __init__(self, prefix, append=False):
        self.logpath = prefix + ".log"
        self.rawpath = prefix + ".raw"
        # ★ append=True：代理重启时续写同一份日志（否则 "wb" 会把历史整段抹掉）。
        #   注意重启后 [秒] 前缀会从 0 重新计（t0 是本次进程启动时刻）——
        #   定位增量一律用字节偏移(stat -c %s)，不要用那个秒数。
        mode = "ab" if append else "wb"
        self.logf = open(self.logpath, mode, buffering=0)
        self.rawf = open(self.rawpath, mode, buffering=0)
        self.t0 = time.time()
        self.bytes = 0
        self.carry = b""
        self.pending_cr = False

    def _stamp(self):
        return ("[%7.3f] " % (time.time() - self.t0)).encode()

    def feed(self, data):
        self.bytes += len(data)
        self.rawf.write(data)

        buf = self.carry + data
        self.carry = b""
        out = bytearray()
        i = 0
        n = len(buf)
        while i < n:
            ch = buf[i : i + 1]
            if ch == b"\r":
                out += b"\n"
                self.pending_cr = True
                i += 1
                continue
            if ch == b"\n":
                if self.pending_cr:
                    # \r\n 成对：已被上一个 \r 处理，跳过
                    self.pending_cr = False
                else:
                    out += b"\n"
                i += 1
                continue
            if ch == b"\x08":  # 退格
                out += b"\b"
                i += 1
                continue
            if ch < b"\x20" and ch not in (b"\t", b"\x1b"):
                # 其它控制字符，丢掉，避免污染文本日志
                i += 1
                continue
            self.pending_cr = False
            out += ch
            i += 1

        # 时间戳按“行”加：每个 \n 之后补一个时间戳
        text = bytes(out)
        lines = text.split(b"\n")
        # 最后一段可能不完整，留到下次
        self.carry = lines.pop() if lines else b""

        if lines:
            stamped = bytearray()
            for idx, ln in enumerate(lines):
                stamped += self._stamp() + ln + b"\n"
            self.logf.write(bytes(stamped))

    def flush_carry(self):
        if self.carry:
            self.logf.write(self._stamp() + self.carry + b"\n")
            self.carry = b""

    def close(self):
        self.flush_carry()
        self.logf.close()
        self.rawf.close()


def pump(fd, rec, deadline, keyplan=None, quiet=False):
    """读循环。keyplan 是 [(相对秒, 要发的bytes, 说明)] 列表。"""
    t0 = time.time()
    plan = list(keyplan) if keyplan else []
    sent = 0
    last_note = 0.0

    while True:
        now = time.time()
        if now >= deadline:
            break

        elapsed = now - t0
        while sent < len(plan) and elapsed >= plan[sent][0]:
            _t, payload, note = plan[sent]
            try:
                os.write(fd, payload)
            except OSError:
                pass
            if note and not quiet:
                sys.stderr.write("\n[%.1fs] >>> 发送 %s\n" % (elapsed, note))
                sys.stderr.flush()
            sent += 1

        r, _w, _x = select.select([fd], [], [], 0.25)
        if r:
            try:
                data = os.read(fd, CHUNK)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                raise
            if data:
                rec.feed(data)

        if not quiet and now - last_note > 5.0:
            last_note = now
            sys.stderr.write(
                "\r已抓取 %6d 字节  剩余 %3.0f 秒   " % (rec.bytes, deadline - now)
            )
            sys.stderr.flush()

    if not quiet:
        sys.stderr.write("\n")


KEYS = {
    "ESC": (b"\x1b", "Esc"),
    "TAB": (b"\x09", "Tab"),
    "CR": (b"\r", "回车"),
    "ENTER": (b"\r", "回车"),
    "SPACE": (b" ", "空格"),
    "BS": (b"\x7f", "退格"),
}


def _key_seq(key):
    """打断键序列。CM360 实测提示语是
        Hit Esc or Tab key to enter console mode or rescue linux: 0
    所以打断键是 **Esc / Tab**，不是回车。
    """
    if key == "both":
        return [b"\x1b", b"\x09"]
    if key == "esc":
        return [b"\x1b"]
    if key == "tab":
        return [b"\x09"]
    return [b"\r"]


def build_burst(burst_until=8.0, gap=0.15, key="both"):
    """生成 [0, burst_until) 区间内的连续打断键序列。"""
    seq = _key_seq(key)
    out = []
    t = 0.0
    i = 0
    while t < burst_until:
        out.append((t, seq[i % len(seq)], None))
        i += 1
        t += gap
    return out


def build_uboot_plan(burst_until=8.0, gap=0.15, key="both", cmd="printenv"):
    """开机瞬间连打打断键抢进 u-boot 提示符，然后执行一条命令。"""
    plan = build_burst(burst_until, gap, key)
    plan.append((burst_until + 0.5, b"\r", "回车确认提示符"))
    plan.append((burst_until + 1.2, b"\r", None))
    if cmd:
        plan.append((burst_until + 2.0, cmd.encode() + b"\r", cmd))
    plan.append((burst_until + 4.0, b"\r", None))
    return plan


def prepend_burst(plan, burst_until=8.0, gap=0.15, key="both"):
    """给一个自定义命令计划前面补上开机打断键序列。

    自动在 burst 结束与第一条命令之间留出 1 秒余量；
    若用户给的命令时间早于 burst_until，则提前收尾，避免把键打到命令输出里。
    """
    plan = sorted(plan, key=lambda x: x[0])
    first_cmd = min((t for t, _p, _n in plan), default=burst_until + 1.0)
    stop = min(burst_until, max(0.0, first_cmd - 1.0))
    out = build_burst(stop, gap, key)
    out.append((stop + 0.4, b"\r", "回车确认提示符"))
    out += plan
    return out


def parse_plan(spec):
    """把 '1.0:ESC,2:printenv,5:TAB' 解析成 [(相对秒, bytes, 说明)]。

    token 是 ESC/TAB/CR/SPACE/BS 之一时按按键处理；
    否则当作字面文本，自动补一个回车。
    """
    plan = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise ValueError("计划项缺少冒号：%r" % item)
        tstr, token = item.split(":", 1)
        token = token.strip()
        up = token.upper()
        if up in KEYS:
            payload, note = KEYS[up]
        else:
            payload, note = token.encode() + b"\r", token
        plan.append((float(tstr), payload, note))
    plan.sort(key=lambda x: x[0])
    return plan


# probe 模式要探查的命令（全部只读，不会写任何存储）
PROBE_CMDS = [
    "help",          # 命令总表 —— 决定阶段 1 走法的关键
    "version",       # u-boot 版本与编译配置
    "bdinfo",        # 板级信息 / 内存分布
    "help usb",      # 有没有 USB 子系统
    "help fatload",  # 能不能从 FAT 分区载入
    "help tftpboot", # 能不能走网络载入（bootcmd 里已有 ping）
    "help mmc",      # eMMC 访问能力
    "help bootm",    # 能不能直接 bootm 一个内核
]


def build_probe_plan(burst_until=8.0, key="both", start=None, gap=3.0):
    """打断 autoboot 后，逐条发送只读探查命令。"""
    start = burst_until + 2.0 if start is None else start
    plan = []
    t = start
    for c in PROBE_CMDS:
        plan.append((t, c.encode() + b"\r", c))
        t += gap
    return prepend_burst(plan, burst_until, key=key)


BAUDS = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
    230400: termios.B230400,
}


def main():
    ap = argparse.ArgumentParser(
        description="RTD1296 / CM360 串口抓取工具（纯标准库）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "mode",
        choices=["log", "uboot", "keys", "probe"],
        help="log=只读抓取；uboot=打断引导抓环境变量；keys=按自定义时序发按键；"
        "probe=打断引导后逐条探查 u-boot 命令能力（全只读）",
    )
    ap.add_argument("-d", "--dev", default="/dev/ttyUSB0", help="串口设备（默认 /dev/ttyUSB0）")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="波特率（默认 115200）")
    ap.add_argument("-t", "--time", type=float, default=120.0, help="总抓取秒数（默认 120）")
    ap.add_argument("-o", "--out", default=None, help="输出文件名前缀")
    ap.add_argument(
        "-k",
        "--interrupt-key",
        default="both",
        choices=["both", "esc", "tab", "enter"],
        help="uboot 模式的打断键（默认 both = Esc/Tab 交替）",
    )
    ap.add_argument("-c", "--cmd", default="printenv", help="uboot 模式打断后要执行的命令（默认 printenv）")
    ap.add_argument(
        "-p",
        "--plan",
        default=None,
        help="keys 模式的按键计划，如 '1:ESC,2:TAB,10:printenv,12:help'",
    )
    ap.add_argument(
        "--burst-until",
        type=float,
        default=None,
        metavar="SEC",
        help="keys 模式：前 SEC 秒自动交替连打打断键抢 u-boot 提示符（uboot 模式默认 8.0）",
    )
    args = ap.parse_args()

    if args.baud not in BAUDS:
        sys.exit("[错误] 不支持的波特率：%d，可选 %s" % (args.baud, sorted(BAUDS)))

    prefix = args.out or ("shot_%s" % datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))

    fd = open_serial(args.dev, BAUDS[args.baud], args.baud)
    rec = Recorder(prefix)

    sys.stderr.write("=" * 62 + "\n")
    sys.stderr.write("设备      : %s\n" % args.dev)
    sys.stderr.write("波特率    : %d 8N1 raw\n" % args.baud)
    sys.stderr.write("模式      : %s\n" % args.mode)
    sys.stderr.write("时长      : %.0f 秒\n" % args.time)
    sys.stderr.write("输出      : %s.log / %s.raw\n" % (prefix, prefix))
    sys.stderr.write("-" * 62 + "\n")

    if args.mode == "log":
        sys.stderr.write(">>> 现在给板子上电！只读抓取，不会发送任何按键。\n\n")
        plan = None
    elif args.mode == "uboot":
        sys.stderr.write(">>> 现在给板子上电！前 8 秒会交替连打 Esc / Tab 以打断 autoboot，\n")
        sys.stderr.write(">>> 随后自动发送 %s 读取 u-boot 环境变量。\n" % args.cmd)
        sys.stderr.write(">>> 本操作不做任何写入，请勿在提示符下手敲擦写命令。\n\n")
        plan = build_uboot_plan(key=args.interrupt_key, cmd=args.cmd)
    elif args.mode == "probe":
        sys.stderr.write(">>> 现在给板子上电！前 8 秒会交替连打 Esc / Tab 以打断 autoboot，\n")
        sys.stderr.write(">>> 随后逐条探查 u-boot 命令能力（全部是只读命令，不会有任何写入）。\n\n")
        plan = build_probe_plan(key=args.interrupt_key)
    else:
        if not args.plan:
            sys.exit("[错误] keys 模式必须用 -p/--plan 指定按键计划")
        try:
            plan = parse_plan(args.plan)
        except ValueError as e:
            sys.exit("[错误] %s" % e)
        if args.burst_until:
            plan = prepend_burst(plan, args.burst_until, key=args.interrupt_key)
        sys.stderr.write(">>> 现在给板子上电！按键计划：\n")
        for t, payload, note in plan:
            sys.stderr.write("      %6.1fs  %s\n" % (t, note or repr(payload)))
        sys.stderr.write("\n")

    deadline = time.time() + args.time
    try:
        pump(fd, rec, deadline, keyplan=plan)
    except KeyboardInterrupt:
        sys.stderr.write("\n[已手动中断]\n")
    finally:
        rec.close()
        try:
            os.close(fd)
        except OSError:
            pass

    sys.stderr.write(
        "\n完成：%d 字节 / %.1f 秒\n  %s\n  %s\n"
        % (rec.bytes, args.time, rec.logpath, rec.rawpath)
    )
    if rec.bytes == 0:
        sys.stderr.write(
            "\n[警告] 一个字节都没收到。检查：\n"
            "  1. 板子真的上电并启动了？\n"
            "  2. TTL 线序：板子 TX -> 模块 RX，板子 RX -> 模块 TX，GND 共地\n"
            "  3. TTL 电平选 3.3V（不是 5V）\n"
            "  4. screen 之类占用串口的程序是否已完全退出？\n"
        )


if __name__ == "__main__":
    main()
