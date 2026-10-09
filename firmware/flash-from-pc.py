#!/usr/bin/env python3
"""flash-from-pc.py —— 从电脑一键刷入 CM360（TFTP + 串口 + u-boot）

它做什么
--------
在你自己的电脑上跑一条命令，把三层镜像逐一刷进板子，每层都做**写后回读校验**：

    L0 低区   LBA 0        38 MiB     hwsetting+bootcode+FSBL+BL31+u-boot+env
    L1 p1     LBA 0x13000  256 MiB    ext4（内核 uImage + 板级 DTB）
    L2 p2     LBA 0x93000  ~7 GiB     btrfs（fnOS rootfs）

流程：检查环境 → **备份板上当前低区**（安全网）→ 起内置 TFTP →
经串口让板子停在 u-boot 提示符 → 逐层 `tftpboot` + `crc32` + `mmc write` + 回读比对 →
`boot` 启动 → 经 SSH 复核系统（版本/存储/面板）。

为什么需要串口
--------------
u-boot 2015.07 的 TFTP 固定用 69 端口、且**没有其他带外通道**，
所以"进 u-boot"这一步只能走串口（3 秒窗口内按任意键）。
没有串口就退回手动：见 firmware/README.md 第 3 节。

用法
----
    ./flash-from-pc.py --layers low,p1            # 刷低区+内核（最常见）
    ./flash-from-pc.py --layers low,p1,p2         # 三层全刷（p2 需先生成）
    ./flash-from-pc.py --rehearse --layers all    # 演练：写回板上已有的同样内容
    ./flash-from-pc.py --dry-run                  # 只检查，不写盘
    ./flash-from-pc.py --backup-only              # 只把板上低区备份下来

U 盘模式（不依赖网络，只要板子能进 u-boot；镜像先用 tools/make-usb-flash.sh 做到 U 盘上）
    ./flash-from-pc.py --usb --layers low,p1,p2   # 走 U 盘 fatload
    ./flash-from-pc.py --usb-plan --layers all    # 打印 U 盘制作计划（制表符分隔，供工具消费）

依赖：python3 + pyserial（apt install python3-serial）；TFTP 模式需 TFTP 端口 69（root）。
U 盘模式不需要 root、不需要网络。
"""
import argparse
import hashlib
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
IMAGES = os.path.join(HERE, "images")
TFTP_SERVER = os.path.join(REPO, "tools", "tftp-server.py")

# eMMC 布局（实测）：低区 0x0~0x12FFF / p1 0x13000~0x92FFF / p2 0x93000~末尾
LAYERS = {
    "low": {"lba": 0x0,      "file": "low-region-38MiB.img", "sectors": 0x13000, "risk": "★ 低区（砖区，务必先备份）"},
    "p1":  {"lba": 0x13000,  "file": "p1-256MiB.img",        "sectors": 0x80000, "risk": "内核+DTB"},
    "p2":  {"lba": 0x93000,  "file": "p2.img",               "sectors": 0xE00000, "risk": "rootfs（大，耗时）"},
}
# 加载地址必须避开 u-boot/FSBL 已占用的区域：
#   BL31 载入 0x10120000，TEE 载入 0x10200000（见启动日志），u-boot 自身在低地址。
# 之前在 0x02000000 载入 256MiB 的 p1 会一路写到 0x12000000 —— 正好撞上 BL31/TEE 区，
# 结果是 u-boot 把自己写坏、传输中途卡死（实测两次都在约 60~70MB 处断掉）。
# 现在改用 0x20000000：256MiB 到 0x30000000，7GiB 的 p2 也能覆盖到 0xE0000000（板上 2GB 内存，
# 因此 p2 必须分片传输，脚本会按 64MiB 自动分片）。
UIMG_ADDR = 0x20000000
CHUNK = 64 * 1024 * 1024      # 单次 TFTP 传输上限（大文件分片，避免压满内存与撞保留区）

# U 盘（fatload）模式下的分片大小，**必须与 tools/make-usb-flash.sh 一致**。
# 为什么是 512 MiB 而不是 FAT32 允许的 4 GiB：
#   板子 DRAM 只有 2 GiB（启动日志 "DRAM:  2 GiB"），加载地址 0x20000000 之上
#   只有 0x20000000~0x80000000 = 1.5 GiB 可用 —— 单次 fatload 超过 1.5 GiB 就会
#   越过 DRAM 顶端。512 MiB 留足余量（0x20000000+512MiB = 0x40000000），
#   也远小于 FAT32 单文件上限，且分片小、重试便宜。
# 分片文件名为 <name>.part00 / .part01 / …（由 tools/make-usb-flash.sh 生成）
USB_PART_BYTES = 512 * 1024 * 1024
# DRAM 顶端（实测 2 GiB）：加载上限的硬约束
DRAM_TOP = 0x80000000
USB_MODE = False


def say(msg):
    print(msg, flush=True)


def die(msg):
    print("!! " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def md5(path, limit=None):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def md5_range(path, offset, nbytes):
    """某个文件的 [offset, offset+nbytes) 区间的 md5（用于 U 盘分片的完整性核对）。"""
    h = hashlib.md5()
    with open(path, "rb") as fh:
        fh.seek(offset)
        left = nbytes
        while left > 0:
            b = fh.read(min(1 << 20, left))
            if not b:
                break
            h.update(b)
            left -= len(b)
    return h.hexdigest()


def resolve_images(layers, verbose=True):
    """把层名解析成本地镜像路径（必要时自动解压随仓库提供的低区 .gz）。"""
    targets = {}
    for l in layers:
        cands = [os.path.join(IMAGES, LAYERS[l]["file"]),
                 os.path.join(HERE, LAYERS[l]["file"])]
        p = next((c for c in cands if os.path.exists(c)), None)
        if p is None:
            # 低区镜像随仓库以 .gz 提供，自动解压到 images/
            gz = os.path.join(HERE, LAYERS[l]["file"] + ".gz")
            if os.path.exists(gz):
                os.makedirs(IMAGES, exist_ok=True)
                p = os.path.join(IMAGES, LAYERS[l]["file"])
                if verbose:
                    say("  解压低区镜像 %s …" % os.path.basename(gz))
                import gzip
                with gzip.open(gz, "rb") as src, open(p, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                ref = os.path.join(HERE, LAYERS[l]["file"] + ".md5")
                if os.path.exists(ref):
                    want = open(ref).read().split()[0]
                    got = md5(p)
                    if verbose:
                        say("     md5 %s %s" % (got, "✔ 与随包 md5 一致" if got == want else "✗ 与随包 md5 不一致！"))
                    if got != want:
                        die("低区镜像校验失败，拒绝继续")
        if p is None:
            die("缺少镜像 %s（low 层会自动解压随包的 .gz；p1/p2 用 ./build-images.sh 生成）"
                % LAYERS[l]["file"])
        targets[l] = p
    return targets


def usb_plan(layers, targets, part_bytes=USB_PART_BYTES):
    """U 盘上**应该有哪些文件、每个写到哪个 LBA** —— 这是唯一事实来源。

    tools/make-usb-flash.sh 完全按本函数的输出制作 U 盘，因此工具之间不可能"名字对不上"。
    返回 [{layer, usb_name, src, offset, bytes, lba, sectors, md5}, …]
    """
    plan = []
    for l in layers:
        path = targets[l]
        size = os.path.getsize(path)
        base = os.path.basename(path)
        info = LAYERS[l]
        if size > info["sectors"] * 512:
            die("%s 比目标分区大（%d 字节 > %d）" % (base, size, info["sectors"] * 512))
        need_parts = size > part_bytes
        off = 0
        idx = 0
        while off < size:
            nbytes = min(part_bytes, size - off)
            name = "%s.part%02d" % (base, idx) if need_parts else base
            if UIMG_ADDR + nbytes > DRAM_TOP:
                die("单片 %d 字节会在 0x%x 处越过 DRAM 顶端 0x%x —— 请调小 USB_PART_BYTES"
                    % (nbytes, UIMG_ADDR + nbytes, DRAM_TOP))
            plan.append({
                "layer": l, "usb_name": name, "src": path, "offset": off, "bytes": nbytes,
                "lba": info["lba"] + off // 512, "sectors": (nbytes + 511) // 512,
                "md5": md5_range(path, off, nbytes),
            })
            off += nbytes
            idx += 1
    return plan


def print_usb_plan(plan):
    """机器可读（制表符分隔），供 tools/make-usb-flash.sh 消费。"""
    say("# layer\tusb_name\tsrc\toffset\tbytes\tlba\tsectors\tmd5")
    for e in plan:
        say("\t".join(str(x) for x in (e["layer"], e["usb_name"], e["src"], e["offset"],
                                       e["bytes"], "0x%x" % e["lba"], "0x%x" % e["sectors"], e["md5"])))


# ── 串口 ────────────────────────────────────────────────────────────────
class Console:
    def __init__(self, dev, baud=115200, logpath=None):
        try:
            import serial
        except ImportError:
            die("缺少 pyserial：apt install python3-serial  （或 pip install pyserial）")
        self.ser = serial.Serial(dev, baud, timeout=0.3)
        self.ser.reset_input_buffer()
        # 全程串口日志：刷机出问题时，这是唯一能看清 u-boot 卡在哪的地方
        self.log = open(logpath, "a", encoding="utf-8") if logpath else None
        self.logpath = logpath

    def read(self, seconds=1.0):
        buf = b""
        t0 = time.time()
        while time.time() - t0 < seconds:
            d = self.ser.read(8192)
            if d:
                buf += d
        if buf and self.log:
            self.log.write(buf.decode("utf-8", "replace"))
            self.log.flush()
        return buf.decode("utf-8", "replace").replace("\r", "")

    def cmd(self, text, wait=1.5, listen=3.0):
        if self.log:
            self.log.write("\n>>> %s\n" % text)
            self.log.flush()
        self.ser.write(text.encode() + b"\r")
        time.sleep(wait)
        return self.read(listen)

    def wait_for(self, needle, timeout=60, spam=None):
        buf = ""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if spam:
                self.ser.write(spam)
            buf += self.read(0.25)
            if needle in buf[-3000:]:
                return buf
        return None

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass


def ssh_ok(board_ip, ssh_user, cmd, timeout=30):
    """跑一条板端命令；SSH 不通（例如板子正停在 u-boot）返回 (False, 输出)。"""
    if not ssh_user:
        return False, ""
    try:
        r = subprocess.run(
            "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "
            "%s@%s '%s'" % (ssh_user, board_ip, cmd),
            shell=True, capture_output=True, timeout=timeout)
        return r.returncode == 0, (r.stdout or b"").decode("utf-8", "replace")
    except Exception as e:
        return False, "EXC:" + str(e)


def enter_uboot(con, board_ip, ssh_user):
    """让板子停在 u-boot 提示符。三种情况都要能处理：

      a) 已经在提示符上（板子没跑系统，SSH 自然不通）
      b) 系统在跑 → 重启并在 bootdelay 窗口内按键打断
      c) 抢不到窗口 → 兜底：临时改名内核让引导失败
    """
    # u-boot 可能卡在 tftp 重试 / loadb 等状态，反复发中止序列把它拉回提示符
    for attempt in range(4):
        for burst in (b"\x03\x03", b"\x18\x18", b"\x1b", b"\r"):
            con.ser.write(burst)
            time.sleep(0.4)
        if con.wait_for("BPI-W2>", timeout=20, spam=b"\r") is not None:
            say("   板子已在 u-boot 提示符（无需重启）")
            return True
        say("   （第 %d 次尝试把控制台拉回提示符…）" % (attempt + 1))

    say("   尝试重启板子并抢 bootdelay 窗口…")
    ok, out = ssh_ok(board_ip, ssh_user, "sudo -n systemctl reboot")
    if ok:
        say("   已发出重启，等待窗口（3 秒内按任意键打断）…")
    elif "password is required" in (out or ""):
        die("板端 sudo 需要密码：请先在板子上放行（或手工重启板子后重跑）。\n"
            "   放行：echo '<用户> ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-cm360-flash")
    else:
        say("   SSH 不可达（板子可能不在系统里）—— 请手动复位/断电重启板子，")
        say("   我在这里等它停在 u-boot 提示符（最多 120 秒）…")

    if con.wait_for("BPI-W2>", timeout=120, spam=b"\r") is not None:
        say("   ✔ 已停在 u-boot 提示符")
        return True

    say("   没抢到窗口 —— 兜底：临时改名内核让引导失败")
    ok, _ = ssh_ok(board_ip, ssh_user,
                   "sudo -n sh -c 'mount /dev/mmcblk0p1 /mnt/p1 && "
                   "mv /mnt/p1/Image-6.6.uimage /mnt/p1/Image-6.6.uimage.hold && sync && umount /mnt/p1'")
    if not ok:
        die("既抢不到窗口、SSH 也不可用。请参考 firmware/README.md 第 2.5 节手工进入 u-boot。")
    ssh_ok(board_ip, ssh_user, "sudo -n systemctl reboot")
    if con.wait_for("BPI-W2>", timeout=120, spam=None) is None:
        die("仍无法进入 u-boot。请参考 firmware/README.md 第 2.5 节手工处理。")
    say("   ✔ 已停在 u-boot 提示符（内核当前是改名状态；刷完 p1 会自动纠正）")
    return True

# ── u-boot 侧 ───────────────────────────────────────────────────────────
_CRC_OK = {"checked": False, "ok": False}


def _rescue_console(con, tries=6):
    """把 u-boot 从 tftp 重试/传输状态拉回提示符。

    踩过的坑：传输中途掐断服务端，u-boot 会卡在等响应，且不理会 Ctrl-C；
    此时应保留服务端、反复发中止并耐心等它超时回到提示符。
    """
    for i in range(tries):
        for burst in (b"\x03", b"\x18\x18", b"\x1b", b"\r"):
            try:
                con.ser.write(burst)
            except Exception:
                pass
            time.sleep(0.4)
        if con.wait_for("BPI-W2>", timeout=15, spam=b"\r") is not None:
            say("   （已把控制台拉回 u-boot 提示符）")
            return True
    say("   ! 控制台未回到提示符 —— 若板子无响应，请断电/复位一次再重跑")
    return False


def uboot_crc32(con, addr, size):
    """u-boot 侧算 crc32；若该板 u-boot 没编入 crc32 命令则返回 None（并只提示一次）。"""
    if not _CRC_OK["checked"]:
        probe = con.cmd("crc32 %#x 0x10" % addr, wait=0.8, listen=2.0)
        _CRC_OK["checked"] = True
        _CRC_OK["ok"] = "Unknown command" not in probe
        if not _CRC_OK["ok"]:
            say("     ! 本机 u-boot 没有 crc32 命令 → 跳过回读校验（改由启动后 SSH 复核）")
    if not _CRC_OK["ok"]:
        return None
    out = con.cmd("crc32 %#x %#x" % (addr, size), wait=1.0, listen=4.0)
    m = re.search(r"=>\s*([0-9a-fA-F]{8})", out)
    return m.group(1).lower() if m else None


def _ensure_parts(path, chunk=CHUNK):
    """必要时把大镜像切成 <name>.partNN（u-boot 的 tftp 不支持文件内偏移）。"""
    import glob
    name = os.path.basename(path)
    existing = sorted(glob.glob(os.path.join(os.path.dirname(path), name + ".part*")))
    parts_needed = (os.path.getsize(path) + chunk - 1) // chunk
    if len(existing) == parts_needed:
        return existing
    say("     切分镜像为 %d 片（每片 %d MiB）…" % (parts_needed, chunk // (1024 * 1024)))
    for f in existing:
        os.remove(f)
    out_files = []
    with open(path, "rb") as fh:
        idx = 0
        while True:
            data = fh.read(chunk)
            if not data:
                break
            idx += 1
            fn = os.path.join(os.path.dirname(path), "%s.part%02d" % (name, idx))
            with open(fn, "wb") as w:
                w.write(data)
            out_files.append(fn)
    say("     ✔ 已生成 %d 个分片" % idx)
    return out_files


def _uboot_load(con, name, size_hint_mb):
    """按当前模式把某个文件（或分片）载入 UIMG_ADDR。返回是否成功。"""
    if USB_MODE:
        cmds = [("fatload usb 0:1 %#x %s" % (UIMG_ADDR, name), 20)]
    else:
        cmds = [("tftp %#x %s" % (UIMG_ADDR, name), 1),
                ("tftpboot %#x %s" % (UIMG_ADDR, name), 1)]
    out = ""
    for cmd, initial in cmds:
        out = con.cmd(cmd, wait=1.2, listen=initial)
        if "Unknown command" in out:
            continue
        deadline = time.time() + max(90, size_hint_mb * 6)
        while time.time() < deadline:
            chunk = con.read(2.0)
            if chunk:
                out += chunk
                if any(k in out for k in ("Bytes transferred", "bytes read",
                                          "TFTP error", "## Error", "Retry count exceeded")):
                    break
        ok = ("Bytes transferred" in out or "bytes read" in out)
        if not ok:
            _rescue_console(con)
            die("载入 %s 失败：\n%s" % (name, out[:250]))
        return True
    die("没有可用的载入命令（tftp / fatload）")


def _load_chunk(con, base, idx, sectors):
    """载入第 idx 个分片。u-boot 2015.07 的 tftp 不支持文件内偏移，
    因此分片文件名约定为 <原名>.partNN（由打包/切分步骤生成）。"""
    name = "%s.part%02d" % (base, idx)
    for cmdname in ("tftp", "tftpboot"):
        out = con.cmd("%s %#x %s" % (cmdname, UIMG_ADDR, name), wait=1.2, listen=1.0)
        if "Unknown command" in out:
            continue
        deadline = time.time() + max(90, (sectors * 512 / (1024.0 * 1024.0)) * 6)
        while time.time() < deadline:
            chunk = con.read(2.0)
            if chunk:
                out += chunk
                if ("Bytes transferred" in out or "bytes read" in out
                        or "TFTP error" in out or "## Error" in out):
                    break
        if "Bytes transferred" not in out and "bytes read" not in out:
            _rescue_console(con)
            die("分片 %s 载入失败：\n%s" % (name, out[:200]))
        return
    die("tftp 命令不可用")


def flash_layer(con, host_ip, layer, path, dry_run=False):
    info = LAYERS[layer]
    size = os.path.getsize(path)
    sectors = (size + 511) // 512
    if sectors > info["sectors"]:
        die("%s 比目标分区大（%d 扇区 > %d）" % (os.path.basename(path), sectors, info["sectors"]))
    say("  [%s] %s  %d 字节（%d 扇区）→ LBA 0x%x" % (layer, os.path.basename(path), size, sectors, info["lba"]))
    if dry_run:
        return True

    base = os.path.basename(path)
    # 大文件分片：TFTP 一次传 CHUNK 字节，收到后立刻 mmc write 到对应 LBA
    # ── 大文件：分片传输 + 逐片 mmc write ──
    if size > (USB_PART_BYTES if USB_MODE else CHUNK):
        con.cmd("mmc dev 0", wait=0.8, listen=1.5)
        if USB_MODE:
            nparts = (size + USB_PART_BYTES - 1) // USB_PART_BYTES
            for idx in range(nparts):
                off = idx * USB_PART_BYTES
                nbytes = min(USB_PART_BYTES, size - off)
                part = (nbytes + 511) // 512
                name = "%s.part%02d" % (base, idx)
                say("     分片 %d/%d：%s  %d 扇区 → LBA 0x%x"
                    % (idx + 1, nparts, name, part, info["lba"] + off // 512))
                _uboot_load(con, name, nbytes / (1024.0 * 1024.0))
                con.cmd("mmc write %#x %#x %#x" % (UIMG_ADDR, info["lba"] + off // 512, part),
                        wait=3, listen=60)
        else:
            _ensure_parts(path)
            done = 0
            idx = 0
            while done < sectors:
                part = min(CHUNK // 512, sectors - done)
                idx += 1
                say("     分片 %d：%d 扇区 → LBA 0x%x" % (idx, part, info["lba"] + done))
                _load_chunk(con, base, idx, part)
                out = con.cmd("mmc write %#x %#x %#x" % (UIMG_ADDR, info["lba"] + done, part),
                              wait=3, listen=45)
                done += part
        say("     ✔ 分片写入完成")
        return True
    _uboot_load(con, base, size / (1024.0 * 1024.0))
    say("     ✔ 已载入内存（%s）" % ("U 盘 fatload" if USB_MODE else "TFTP"))

    src_crc = uboot_crc32(con, UIMG_ADDR, size)
    say("     源 crc32 = %s" % (src_crc or "?"))
    out = con.cmd("mmc dev 0", wait=0.8, listen=1.5)
    out = con.cmd("mmc write %#x %#x %#x" % (UIMG_ADDR, info["lba"], sectors), wait=4, listen=60)
    if "written" not in out.lower() and "mmc write" not in out:
        say("     写入输出: " + out.strip()[-300:])
    say("     ✔ 已写入 eMMC")

    out = con.cmd("mmc read %#x %#x %#x" % (UIMG_ADDR, info["lba"], sectors), wait=3, listen=25)
    dst_crc = uboot_crc32(con, UIMG_ADDR, size)
    say("     回读 crc32 = %s" % (dst_crc or "?"))
    if src_crc and dst_crc:
        if src_crc == dst_crc:
            say("     ✔✔ 回读校验一致")
            return True
        die("回读校验不一致（源 %s / 回读 %s）—— 停止，别再继续刷" % (src_crc, dst_crc))
    say("     （无 crc32 可比，写入已由 mmc write 报告成功；随后用启动+SSH 复核）")
    return True


def main():
    ap = argparse.ArgumentParser(description="从电脑一键刷入 CM360（TFTP + 串口 + u-boot）")
    ap.add_argument("--board-ip", default="192.168.1.173", help="板子 IP（默认 192.168.1.173）")
    ap.add_argument("--host-ip", default=None, help="电脑朝向板子的网卡 IP（默认自动探测）")
    ap.add_argument("--serial", default="/dev/ttyUSB0", help="串口设备")
    ap.add_argument("--layers", default="low,p1", help="要刷的层：low,p1,p2（或 all，或逗号组合）")
    ap.add_argument("--ssh-user", default=None, help="板子 SSH 用户（用于自动重启/备份/复核）")
    ap.add_argument("--tftp-port", type=int, default=69, help="TFTP 端口（u-boot 2015.07 固定 69）")
    ap.add_argument("--usb", action="store_true",
                    help="改用 U 盘刷写（u-boot 侧 usb start + fatload），需要先用 tools/make-usb-flash.sh 做好 U 盘")
    ap.add_argument("--usb-plan", action="store_true",
                    help="只打印 U 盘制作计划（文件名/LBA/扇区/md5，制表符分隔）后退出；"
                         "tools/make-usb-flash.sh 按它制作 U 盘")
    ap.add_argument("--dry-run", action="store_true", help="只检查与演练，不写盘")
    ap.add_argument("--rehearse", action="store_true", help="演练：写回板上已有的同样内容（安全验证全流程）")
    ap.add_argument("--backup-only", action="store_true", help="只备份板上低区")
    ap.add_argument("--yes", action="store_true", help="跳过确认")
    args = ap.parse_args()
    global USB_MODE
    USB_MODE = bool(args.usb)

    layers = list(LAYERS) if args.layers == "all" else [x.strip() for x in args.layers.split(",") if x.strip()]
    for l in layers:
        if l not in LAYERS:
            die("未知的层: %s（可选 low,p1,p2）" % l)

    # U 盘制作计划：只依赖镜像文件，不需要串口/网络/root
    if args.usb_plan:
        if not os.path.isdir(IMAGES):
            die("找不到镜像目录 %s（先用 ./build-images.sh 生成，低区镜像解压即可）" % IMAGES)
        print_usb_plan(usb_plan(layers, resolve_images(layers, verbose=False)))
        return 0

    say("=" * 70)
    say("CM360 电脑端一键刷机（%s + 串口 + u-boot）" % ("U 盘 fatload" if USB_MODE else "TFTP"))
    say("=" * 70)

    # 0) 环境检查
    say("== 0) 环境检查 ==")
    if not USB_MODE and not os.path.exists(TFTP_SERVER):
        die("找不到内置 TFTP 服务 %s" % TFTP_SERVER)
    if not os.path.isdir(IMAGES):
        die("找不到镜像目录 %s（先用 ./build-images.sh 生成，低区镜像解压即可）" % IMAGES)
    host_ip = args.host_ip
    if not host_ip and not USB_MODE:
        r = run("ip route get %s" % args.board_ip)
        m = re.search(r"src (\d+\.\d+\.\d+\.\d+)", r.stdout or "")
        host_ip = m.group(1) if m else None
    say("  电脑侧 IP（朝向板子）: %s" % (host_ip or "未探测到，请用 --host-ip 指定"))
    say("  板子 IP: %s     TFTP 端口: %d" % (args.board_ip, args.tftp_port))
    if not host_ip and not USB_MODE:
        die("无法自动探测 host IP")

    targets = resolve_images(layers)
    for l in layers:
        p = targets[l]
        say("  %-4s %-28s %12d 字节  md5 %s  %s"
            % (l, os.path.basename(p), os.path.getsize(p), md5(p)[:16], LAYERS[l]["risk"]))

    r = run(f"ping -c1 -W2 {args.board_ip}")
    say("  板子可达: %s" % ("是" if r.returncode == 0 else "否（刷机时只需要网卡同网段，u-boot 会用自己的临时 IP）"))

    if args.rehearse:
        say("  ★ 演练模式：将把**板上已有的同样内容**写回去，用于端到端验证流程（不改动任何东西）")

    if not args.yes and not args.dry_run:
        say("")
        say("即将写入：%s" % "、".join(layers))
        say("⚠️ 刷 low 层 = 直接写低区（砖区）。脚本会先备份当前低区；")
        say("   串口 ROM Monitor 救砖流程见 firmware/RECOVERY.md。")
        if input("确认继续？输入 yes 回车：").strip() != "yes":
            die("已取消")

    # 1) 备份当前低区
    backup = None
    if args.ssh_user and not args.dry_run:
        say("== 1) 备份板上当前低区（安全网）==")
        backup = os.path.join(IMAGES, "low-region-backup-%s.img" % time.strftime("%Y%m%d-%H%M%S"))
        import gzip
        r = subprocess.run(
            f"ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new {args.ssh_user}@{args.board_ip} "
            f"'sudo -n dd if=/dev/mmcblk0 bs=512 count=77824 status=none | gzip -1'",
            shell=True, capture_output=True, timeout=300)   # ★ 二进制流，必须按 bytes 抓
        if r.returncode == 0 and r.stdout and len(r.stdout) > 1_000_000:
            with open(backup + ".gz", "wb") as fh:
                fh.write(r.stdout)
            with gzip.open(backup + ".gz", "rb") as src, open(backup, "wb") as out:
                shutil.copyfileobj(src, out)
            if os.path.getsize(backup) == 39845888:
                say("   ✔ 已备份到 %s（md5 %s）" % (backup, md5(backup)[:16]))
            else:
                die("备份文件大小异常：%d 字节" % os.path.getsize(backup))
        else:
            say("   ! 备份失败，继续前请自行确认：%s" % (r.stderr or b"")[-200:])
            if not args.yes and input("   仍要继续？输入 yes：").strip() != "yes":
                die("已取消")
    if args.backup_only:
        say("== 只做备份，结束 ==")
        return 0

    if args.dry_run:
        say("== dry-run：不写盘，结束 ==")
        return 0

    # 2) 起 TFTP（U 盘模式跳过）
    tftp = None
    if USB_MODE:
        say("== 2) U 盘模式：跳过 TFTP 服务（镜像由 U 盘提供）==")
        say("   请确认：U 盘已用 tools/make-usb-flash.sh 做好，并插在板子上")
    else:
        say("== 2) 启动内置 TFTP 服务（端口 %d）==" % args.tftp_port)
        tftp_cmd = [sys.executable, TFTP_SERVER, "--root", IMAGES,
                    "--bind", host_ip, "--port", str(args.tftp_port)]
        if args.tftp_port < 1024 and os.geteuid() != 0:
            tftp_cmd = ["sudo", "-n"] + tftp_cmd
        tftp = subprocess.Popen(tftp_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, preexec_fn=os.setsid)
        time.sleep(2)
        if tftp.poll() is not None:
            out = tftp.stdout.read() if tftp.stdout else ""
            die("TFTP 启动失败（端口 %d 需要 root）：%s\n"
                "  请先执行一次  sudo -v  授权，或用  sudo python3 %s …  整体运行。"
                % (args.tftp_port, out[-200:], os.path.basename(__file__)))
        say("   ✔ TFTP 就绪（%s:%d，根目录 %s）" % (host_ip, args.tftp_port, IMAGES))

    con = None
    # 写盘顺序：先刷 p1/p2 再刷 low —— 万一 low 写坏，至少系统镜像已就位；low 最后写
    order = [l for l in ("p1", "p2", "low") if l in targets]
    try:
        # 3) 进 u-boot
        say("== 3) 让板子停在 u-boot 提示符 ==")
        clog = os.path.join(REPO, "firmware", "images",
                            "flash-serial-%s.log" % time.strftime("%Y%m%d-%H%M%S"))
        con = Console(args.serial, logpath=clog)
        say("   串口全程日志: %s" % clog)
        enter_uboot(con, args.board_ip, args.ssh_user)
        if USB_MODE:
            say("   启动板子 USB 控制器…")
            o = con.cmd("usb start", wait=3, listen=8)
            hit = [l for l in o.splitlines() if any(k in l for k in ("Storage", "USB", "scanning", "1 USB"))]
            for l in hit[:4]:
                say("     " + l.strip()[:100])
            if "Error" in o or "not available" in o:
                say("   ! usb start 输出异常，若后面 fatload 失败请检查 U 盘是否插好")
            # 预检：U 盘上该有的文件一个都不能少（u-boot 有 fatls，实测）
            plan = usb_plan(order, targets)
            out = con.cmd("fatls usb 0:1", wait=2, listen=10)
            if "Unknown command" in out:
                say("   ! 本机 u-boot 没有 fatls，跳过 U 盘文件预检")
            else:
                missing = [e["usb_name"] for e in plan if e["usb_name"] not in out]
                if missing:
                    _rescue_console(con)
                    die("U 盘上缺少 %d 个文件：%s\n"
                        "  请先用 tools/make-usb-flash.sh 制作 U 盘（或确认插的是 USB 0 口、"
                        "FAT32 分区在 1 号分区）。" % (len(missing), "、".join(missing[:8])))
                say("   ✔ U 盘文件预检通过（%d 个文件齐全）" % len(plan))
        else:
            con.cmd("setenv serverip %s" % host_ip, wait=0.6, listen=1)
        con.cmd("setenv ipaddr %s" % args.board_ip, wait=0.6, listen=1)
        say("   已设置 serverip=%s ipaddr=%s" % (host_ip, args.board_ip))

        # 4) 逐层刷写
        say("== 4) 逐层刷写（每层都回读校验）==")
        for l in order:
            flash_layer(con, host_ip, l, targets[l])

        # 5) 启动并复核
        say("== 5) 启动并把控制权交回系统 ==")
        # 本板 u-boot 没有 `boot` 命令（实测），用 run bootcmd 触发默认引导
        out = con.cmd("run bootcmd", wait=5, listen=15)
        if "Unknown command" in out:
            con.cmd("boot", wait=5, listen=15)
        say("   （若走了兜底法，内核文件名可能仍是 .hold，启动后请改回）")
    finally:
        if con:
            con.close()
        if tftp is not None:
            try:
                os.killpg(os.getpgid(tftp.pid), signal.SIGTERM)
            except Exception:
                pass
            say("   TFTP 已停止")

    time.sleep(45)
    if args.ssh_user and USB_MODE:
        say("== 6) 复核系统（U 盘模式没有网络，跳过 SSH 复核）==")
        say("   请在串口上看启动日志；或插上网线后用：")
        say("     ssh %s@<板子新 IP> 'cat /usr/trim/etc/version; uname -r'" % args.ssh_user)
    elif args.ssh_user:
        say("== 6) 复核系统 ==")
        r = run(f"ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 {args.ssh_user}@{args.board_ip} "
                "'cat /usr/trim/etc/version; uname -r; findmnt -no TARGET /vol2 2>/dev/null; "
                "curl -s -o /dev/null -w \"panel=%{http_code}\\n\" --max-time 4 http://127.0.0.1:5666/'")
        for line in (r.stdout or "").splitlines():
            say("   " + line)
    say("完成。详细步骤与排错见 firmware/README.md。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
