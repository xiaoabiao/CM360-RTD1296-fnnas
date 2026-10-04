#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest_flood.py —— @flood / pump_flood 的零风险自检（用 PTY，不碰真板子）

为什么要这个：
    @flood 是"抢 bootcode console 窗口"的最后一根救命稻草，如果它本身有 bug，
    代价是**又要用户跑一趟去断电上电**。所以在动真板子之前，先用 PTY 把
    两条路径都跑一遍：
      ① ctl 指令解析：@flood:N esc 是否真的置上 flood_until、@flood:0 是否停
      ② 写入路径：pump_flood() 是否真的在非阻塞下把 0x1b 持续灌出去
    本机 /dev/ttyUSB0 是 CH340，**只允许一个进程打开**，所以没法用真口做无害测试
    （真口只能被代理独占），PTY 是唯一安全的替身。

用法：python3 selftest_flood.py
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import serial_agent as SA  # noqa: E402


class StubRec:
    """只实现 Agent 用到的那点接口。"""
    logpath = "/dev/null.log"
    rawpath = "/dev/null.raw"

    def feed(self, data):
        pass


def drain(fd):
    """把 master 侧已到的东西全读走，返回字节数（顺便防止 PTY 缓冲写满卡死）。"""
    got = 0
    while True:
        try:
            b = os.read(fd, 65536)
        except BlockingIOError:
            break
        except OSError:
            break
        if not b:
            break
        got += len(b)
    return got


def main():
    master, slave = os.openpty()
    os.set_blocking(master, False)
    os.set_blocking(slave, False)

    ctl = os.path.join("/tmp", "selftest-flood.ctl")
    open(ctl, "w").close()

    agent = SA.Agent(slave, StubRec(), ctl, quiet=True, gap=0.6)

    fail = 0

    # ---------- ① ctl 指令解析（含间隙参数）----------
    with open(ctl, "a") as f:
        f.write("@flood:7/12 esc\n")
    if not agent.poll_ctl():
        print("FAIL: poll_ctl 返回 False"); fail += 1
    left = agent.flood_until - time.time()
    ok = 5.5 < left <= 7.1 and agent.flood_buf == b"\x1b" \
         and abs(agent.flood_interval - 0.012) < 1e-9
    print("① @flood:7/12 esc -> 剩余 %.2fs  缓冲 %s  间隙 %.0fms  %s"
          % (left, agent.flood_buf, agent.flood_interval * 1000, "OK" if ok else "FAIL"))
    if not ok:
        fail += 1

    with open(ctl, "a") as f:
        f.write("@flood:0\n")
    agent.poll_ctl()
    ok = agent.flood_until == 0.0
    print("② @flood:0        -> flood_until=%.1f  %s"
          % (agent.flood_until, "OK" if ok else "FAIL"))
    if not ok:
        fail += 1

    # ---------- ② 写入路径：节流节奏是否正确 ----------
    # 用 8ms 间隙跑 0.5s，期望收到 55~70 条 ESC（0.5/0.008 = 62）
    drain(master)
    agent.flood_buf = b"\x1b"
    agent.flood_interval = 0.008
    agent.flood_last = 0.0
    agent.flood_until = time.time() + 0.5
    total = 0
    bad = 0
    t0 = time.time()
    iters = 0
    while time.time() - t0 < 0.6:
        agent.pump_flood()
        iters += 1
        while True:
            try:
                b = os.read(master, 65536)
            except BlockingIOError:
                break
            if not b:
                break
            total += len(b)
            if b.count(b"\x1b") != len(b):
                bad += 1
        time.sleep(0.0005)
    rate = total / 0.5
    ok = 45 <= total <= 80 and bad == 0
    print("③ pump_flood 0.5s -> %d 条 ESC（期望 55~70，实测 %.0f 条/秒）非 ESC 块 %d  %s"
          % (total, rate, bad, "OK" if ok else "FAIL"))
    if not ok or bad:
        fail += 1

    # flood_until 过期后必须自动停手
    for _ in range(200):
        agent.pump_flood()
    after = drain(master)
    ok = after == 0
    print("④ 到时自动停手  -> 又收到 %d 字节  %s" % (after, "OK" if ok else "FAIL"))
    if not ok:
        fail += 1

    os.close(master)
    os.close(slave)
    try:
        os.unlink(ctl)
    except OSError:
        pass

    print()
    print("== 结论：%s ==" % ("全部通过" if fail == 0 else "%d 项失败" % fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
