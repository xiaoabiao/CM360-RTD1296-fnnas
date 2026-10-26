#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CM360 盘位指示灯守护进程（HDD1 / HDD2）

硬件坐标
--------
    iso GPIO 26 = HDD1 灯 = SATA port0 = ata1
    iso GPIO 21 = HDD2 灯 = SATA port1 = ata2
（坐标来自原厂 DTB boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dts
  sata@9803F000 节点的 blink-gpios，详见 docs/02-kernel-and-dts.md）

为什么不用内核自带的 disk-activity trigger
------------------------------------------
内核的 ledtrig_disk_activity() 只在 libata 完成一条命令时闪 BLINK_DELAY=30ms：
  * 空闲时全灭（用户预期是"盘在位就常亮"）；
  * 两颗盘共用一个全局 trigger，无法分辨是哪块盘在动；
  * 30ms 的闪烁在机械盘持续 IO 时反而看不出规律。
本守护按 ATA 端口分别读 /proc/diskstats，做"在位常亮 + 有 IO 快闪 + 无盘灭"。

用法
----
    cm360-hdd-led.py            # 前台（systemd 里用）
    cm360-hdd-led.py --once     # 只刷一轮（调试）
"""

import glob
import os
import sys
import time

SYS_LEDS = "/sys/class/leds"

POLL = 0.1          # 轮询间隔（秒）
BLINK_HZ = 6.0      # 闪烁频率
HOLD = 0.35         # 最后一次 IO 之后继续保持闪烁的时长（秒）

# (LED label, 统计口径对应的 ATA 端口)
LEDS = [
    ("hdd1", "ata1"),
    ("hdd2", "ata2"),
]


def find_disk(ata):
    """返回挂在这个 ATA 端口上的块设备名（如 sdc），没有盘返回 None。"""
    for path in glob.glob("/sys/block/sd*/device"):
        if "/%s/" % ata in os.path.realpath(path):
            return os.path.basename(os.path.dirname(path))
    return None


def disk_ios(dev):
    """返回该设备的累计 IO 次数（读完成 + 写完成），读失败返回 None。"""
    try:
        with open("/proc/diskstats") as f:
            for line in f:
                p = line.split()
                # 格式：major minor name reads ... writes ...
                if len(p) > 7 and p[2] == dev:
                    return int(p[3]) + int(p[7])
    except OSError:
        pass
    return None


class Led(object):
    def __init__(self, label, ata):
        self.label = label
        self.ata = ata
        self.dir = os.path.join(SYS_LEDS, label)
        self.dev = None
        self.last_ios = None
        self.active_until = 0.0
        self.brightness = None
        self.available = os.path.isdir(self.dir)

    def set_brightness(self, value):
        if not self.available or value == self.brightness:
            return
        try:
            with open(os.path.join(self.dir, "brightness"), "w") as f:
                f.write("%d" % value)
            self.brightness = value
        except OSError:
            self.available = False

    def set_trigger_none(self):
        try:
            with open(os.path.join(self.dir, "trigger"), "w") as f:
                f.write("none")
        except OSError:
            pass

    def refresh(self, now):
        if not self.available:
            return
        dev = find_disk(self.ata)
        if dev != self.dev:
            self.dev = dev
            self.last_ios = None
            self.active_until = 0.0
            if dev is None:
                self.set_brightness(0)
                return
        if dev is None:
            return

        ios = disk_ios(dev)
        if ios is not None:
            if self.last_ios is not None and ios > self.last_ios:
                self.active_until = now + HOLD
            self.last_ios = ios

        if now < self.active_until:
            # 有 IO：按相位闪烁
            phase = int(now * BLINK_HZ) & 1
            self.set_brightness(0 if phase else 1)
        else:
            # 无 IO：盘在位常亮
            self.set_brightness(1)


def run_once(leds):
    now = time.monotonic()
    for led in leds:
        led.refresh(now)


def main(argv):
    leds = [Led(label, ata) for label, ata in LEDS]
    available = [led for led in leds if led.available]
    if not available:
        sys.stderr.write("cm360-hdd-led: /sys/class/leds 下没有 hdd1/hdd2，"
                         "请确认内核 DTB 里有 leds 节点\n")
        return 1

    if "--once" in argv:
        for led in available:
            led.set_trigger_none()
        run_once(available)
        for led in available:
            sys.stdout.write("%s: dev=%s brightness=%s\n"
                             % (led.label, led.dev, led.brightness))
        return 0

    # 常驻：接管 trigger（DTS 里的 disk-activity 只是没有本守护时的兜底）
    for led in available:
        led.set_trigger_none()

    try:
        while True:
            run_once(available)
            time.sleep(POLL)
    except KeyboardInterrupt:
        pass
    finally:
        for led in available:
            led.set_brightness(0)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
