#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
极简 TFTP 服务器 —— 为 CM360（RTD1296）移植准备，纯标准库。

为什么自己写而不是用 dnsmasq/tftpd：
  1. 完整日志（每次传输的对端、文件名、方向、字节数、耗时、块大小都记下来）
  2. 同时支持读（RRQ，给 u-boot 的 `tftp` 下载内核）和写（WRQ，给 `tftpput` 反向备份）
  3. 支持 RFC 2348 blksize 协商 —— 512 字节的默认块太小，协商到 1468 能把灌内核时间砍到 1/3
  4. 没有额外依赖

用法（需要 root 才能绑 69 端口）
--------------------------------
  sudo python3 tftp_server.py --bind 192.168.1.254 --root ./tftproot --writable
  sudo python3 tftp_server.py --bind 192.168.1.254 --root ./tftproot --writable \
       --log tftp.log --daemon

关闭： CTRL-C，或 `--stop`（读 pidfile 后 kill）

安全性
------
  * 只服务 --root 目录内的文件，拒绝含 `..` 或绝对路径的请求
  * 默认不允许写入，必须显式 --writable（备份时才开）
  * 建议用 --bind 绑到直连板子的那块网卡地址，避免在 WiFi 侧暴露
"""

import argparse
import errno
import os
import socket
import struct
import sys
import threading
import time

OP_RRQ = 1
OP_WRQ = 2
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5
OP_OACK = 6

DEFAULT_BLKSIZE = 512
MAX_BLKSIZE = 65464
RETRIES = 5
TRANSFER_TIMEOUT = 3.0

_lock = threading.Lock()
_logfh = None


def log(msg):
    line = "%s  %s" % (time.strftime("%H:%M:%S"), msg)
    with _lock:
        print(line, flush=True)
        if _logfh is not None:
            _logfh.write(line + "\n")
            _logfh.flush()


def parse_request(pkt):
    """解析 RRQ/WRQ：op | filename | 0 | mode | 0 | (opt | 0 | val | 0)*"""
    if len(pkt) < 4:
        return None
    parts = pkt[2:].split(b"\x00")
    if len(parts) < 2:
        return None
    filename = parts[0].decode("utf-8", "replace")
    mode = parts[1].decode("ascii", "replace").lower()
    opts = {}
    rest = parts[2:]
    for i in range(0, len(rest) - 1, 2):
        k = rest[i].decode("ascii", "replace").lower()
        v = rest[i + 1].decode("ascii", "replace")
        if k:
            opts[k] = v
    return filename, mode, opts


def resolve_path(root, filename):
    """把请求的文件名安全地映射到 root 下的绝对路径。不合法返回 None。"""
    name = filename.replace("\\", "/").lstrip("/")
    if not name or name.startswith("../") or "/../" in name or name == "..":
        return None
    # 去掉可能的前导 "./"
    while name.startswith("./"):
        name = name[2:]
    if name.startswith("../") or name == "..":
        return None
    path = os.path.realpath(os.path.join(root, name))
    root_real = os.path.realpath(root)
    if path != root_real and not path.startswith(root_real + os.sep):
        return None
    return path


def negotiate(opts):
    """按客户端请求协商选项，返回 (options_to_oack, blksize)。"""
    oack = {}
    blksize = DEFAULT_BLKSIZE
    if "blksize" in opts:
        try:
            want = int(opts["blksize"])
        except ValueError:
            want = DEFAULT_BLKSIZE
        blksize = max(8, min(MAX_BLKSIZE, want))
        oack["blksize"] = str(blksize)
    if "timeout" in opts:
        try:
            t = max(1, min(255, int(opts["timeout"])))
        except ValueError:
            t = 3
        oack["timeout"] = str(t)
    return oack, blksize


def put_tsize(oack, value):
    """把 tsize 放进 OACK —— 但值为 0 时故意省略。

    RFC 2349 允许 tsize=0（空文件），但 curl 会直接判定
    "invalid tsize value in OACK packet" 并以 exit 71 失败
    （curl 内部把 0 当作"未设置"的哨兵值）。省略该选项是合法的：
    客户端只是拿不到文件大小，传输照常。空文件是很现实的场景
    ——比如某次备份产出 0 字节，你正想把它抓下来看看。
    """
    try:
        v = int(value)
    except (TypeError, ValueError):
        return
    if v > 0:
        oack["tsize"] = str(v)


def send_error(sock, peer, code, msg):
    sock.sendto(struct.pack("!HH", OP_ERROR, code) + msg.encode() + b"\x00", peer)


def drop_privileges(username):
    """把当前进程降权到指定用户。

    用途：只有绑 69 端口需要 root。绑定完成之后就没必要继续持有特权了——
    一个会解析网络报文的进程以 root 常驻是不划算的。降权还有个附带好处：
    tftpput 上传回来的备份文件直接归该用户所有，不用事后 chown。

    注意：每个传输线程用的临时端口都是 bind(port=0) 动态端口，
    降权后依然能绑，所以降权不影响 TFTP 的工作方式。
    """
    import pwd
    import grp

    pw = pwd.getpwnam(username)
    groups = [g.gr_gid for g in grp.getgrall() if pw.pw_name in g.gr_mem]
    groups.append(pw.pw_gid)
    os.setgroups(groups)
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)
    # 二次确认：此时进程应已无法恢复 root
    if os.getuid() != pw.pw_uid or os.geteuid() != pw.pw_uid:
        raise RuntimeError("降权失败，仍在 uid=%d" % os.getuid())


class TftpServer:
    def __init__(self, bind, port, root, writable, setuid=None):
        self.bind = bind
        self.port = port
        self.root = root
        self.writable = writable
        self.setuid = setuid
        self.n = 0

    def serve_forever(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.bind, self.port))
        log("TFTP 服务器已启动：%s:%d  根目录=%s  可写=%s  降权到=%s"
            % (self.bind, self.port, self.root,
               "是" if self.writable else "否", self.setuid or "不降权"))
        # 端口已经绑上了，特权到此为止
        if self.setuid:
            try:
                drop_privileges(self.setuid)
            except Exception as e:
                log("降权失败（%s）—— 拒绝继续以 root 常驻，退出" % e)
                raise SystemExit(1)
            log("已降权：uid=%d gid=%d" % (os.getuid(), os.getgid()))
        while True:
            try:
                pkt, peer = s.recvfrom(70000)
            except OSError as e:
                if e.errno == errno.EINTR:
                    continue
                raise
            if len(pkt) < 2:
                continue
            op = struct.unpack("!H", pkt[:2])[0]
            if op not in (OP_RRQ, OP_WRQ):
                continue
            self.n += 1
            t = threading.Thread(target=self.handle, args=(pkt, peer, op), daemon=True)
            t.start()

    def handle(self, pkt, peer, op):
        """每个传输用一个新的临时端口作为 TID（符合 RFC 1350）。"""
        req = parse_request(pkt)
        if not req:
            return
        filename, mode, opts = req
        path = resolve_path(self.root, filename)
        if path is None:
            log("拒绝非法路径请求：%r（来自 %s）" % (filename, peer[0]))
            tmp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            send_error(tmp, peer, 2, "Access violation")
            tmp.close()
            return

        if op == OP_RRQ:
            self.do_read(path, filename, mode, opts, peer)
        else:
            self.do_write(path, filename, mode, opts, peer)

    def do_read(self, path, filename, mode, opts, peer):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((self.bind, 0))
        sock.settimeout(TRANSFER_TIMEOUT)
        try:
            if not os.path.isfile(path):
                log("RRQ 失败（文件不存在）：%s  来自 %s" % (filename, peer[0]))
                send_error(sock, peer, 1, "File not found")
                return
            oack, blksize = negotiate(opts)
            size = os.path.getsize(path)
            if "tsize" in opts:
                put_tsize(oack, size)

            log("RRQ <- %s:%d  请求 %s (%d 字节, mode=%s)  协商: %s"
                % (peer[0], peer[1], filename, size, mode,
                   ", ".join("%s=%s" % kv for kv in sorted(oack.items())) or "无"))

            t0 = time.time()
            fd = open(path, "rb")
            try:
                # 构造第一个待发包
                if oack:
                    blob = b"".join(k.encode() + b"\x00" + v.encode() + b"\x00"
                                    for k, v in oack.items())
                    cur = struct.pack("!H", OP_OACK) + blob
                    expect = 0
                    is_oack = True
                    blk = 0
                    payload_len = 0
                else:
                    blk = 1
                    chunk = fd.read(blksize)
                    cur = struct.pack("!HH", OP_DATA, blk) + chunk
                    expect = 1
                    is_oack = False
                    payload_len = len(chunk)

                blocks_sent = 0
                tries = 0
                while True:
                    sock.sendto(cur, peer)
                    got = self._wait_ack(sock, peer)
                    if got is None:
                        log("RRQ 超时，放弃：%s（已发 %d 块）" % (filename, blocks_sent))
                        return
                    if got != expect:
                        tries += 1
                        if tries > RETRIES:
                            log("RRQ 重传过多，放弃：%s" % filename)
                            return
                        continue                       # 重发当前包
                    tries = 0
                    if is_oack:
                        # OACK 被确认 → 开始发第 1 块数据
                        is_oack = False
                        blk = 1
                        chunk = fd.read(blksize)
                        payload_len = len(chunk)
                        cur = struct.pack("!HH", OP_DATA, blk) + chunk
                        expect = 1
                        blocks_sent = 1
                        continue
                    if payload_len < blksize:
                        break                          # 最后一块（含整块倍数时的空块）
                    blk = (blk + 1) & 0xFFFF
                    chunk = fd.read(blksize)
                    payload_len = len(chunk)
                    cur = struct.pack("!HH", OP_DATA, blk) + chunk
                    expect = blk
                    blocks_sent += 1
            finally:
                fd.close()
            dt = time.time() - t0
            log("RRQ -> %s:%d  完成 %s  共 %d 块 / %d 字节  用时 %.2fs (%.1f KB/s)  [TID=%d]"
                % (peer[0], peer[1], filename, blocks_sent, size, dt,
                   size / 1024.0 / max(dt, 1e-6), sock.getsockname()[1]))
        finally:
            sock.close()

    @staticmethod
    def _wait_ack(sock, peer):
        """等一个来自 peer 的 ACK，返回块号；超时/出错返回 None。"""
        for _ in range(RETRIES):
            try:
                r, p = sock.recvfrom(70000)
            except socket.timeout:
                continue
            except OSError:
                return None
            if p[0] != peer[0] or p[1] != peer[1]:
                continue                               # 别的会话，忽略
            if len(r) < 2:
                continue
            op = struct.unpack("!H", r[:2])[0]
            if op == OP_ACK and len(r) >= 4:
                return struct.unpack("!H", r[2:4])[0]
            if op == OP_ERROR:
                log("RRQ 对端报错：%s" % r[4:].decode("utf-8", "replace"))
                return None
        return None

    def do_write(self, path, filename, mode, opts, peer):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((self.bind, 0))
        sock.settimeout(TRANSFER_TIMEOUT)
        try:
            if not self.writable:
                log("WRQ 被拒（未开 --writable）：%s  来自 %s" % (filename, peer[0]))
                send_error(sock, peer, 2, "Access violation")
                return
            oack, blksize = negotiate(opts)
            if "tsize" in opts:
                put_tsize(oack, opts["tsize"])
            log("WRQ <- %s:%d  上传 %s (mode=%s)  协商: %s"
                % (peer[0], peer[1], filename, mode,
                   ", ".join("%s=%s" % kv for kv in sorted(oack.items())) or "无"))
            t0 = time.time()

            if oack:
                blob = b"".join(k.encode() + b"\x00" + v.encode() + b"\x00"
                                for k, v in oack.items())
                reply = struct.pack("!H", OP_OACK) + blob
            else:
                reply = struct.pack("!HH", OP_ACK, 0)

            expect = 1
            total = 0
            blocks = 0
            final_ack = None
            # 先写临时文件，收齐了再改名。这样"目标文件存在"就等于"备份完整"——
            # 传输中断只会留下一个显式的 xxx.part-*，而不会留下一个
            # 看起来正常、实际短了几百 KB 的假备份。
            #
            # ★ 临时名必须带本次传输的唯一标识（线程号）：
            #   u-boot 的 tftp/tftpput 会把同一个请求重发一次（实测每条约 +1 次），
            #   服务器为每个请求各起一个线程。若两个线程写同一个 .part 路径，
            #   就会同时 truncate + 交叉写 —— 这次因为两份数据恰好相同才没暴露。
            #   带上线程号后，两条流各写各的临时文件，各自 rename，
            #   最终文件必定是某一个完整传输的结果。
            tmp_path = "%s.part-%d" % (path, threading.get_ident())
            # buffering=0：每块写完立刻落盘。否则最后一块会滞留在 Python 缓冲区里，
            # 传输"结束"后外部立刻去拷这个文件，拿到的是残缺的备份。
            fd = open(tmp_path, "wb", buffering=0)
            ok = False
            try:
                while True:
                    got = self._wait_data(sock, peer, reply)
                    if got is None:
                        log("WRQ 超时，放弃：%s（已收 %d 字节，残片留在 %s）"
                            % (filename, total, tmp_path))
                        return
                    blk = struct.unpack("!H", got[2:4])[0]
                    if blk == ((expect - 1) & 0xFFFF):
                        # 重复块：重发上一个 ACK，等对端继续
                        reply = struct.pack("!HH", OP_ACK, blk)
                        continue
                    if blk != expect:
                        log("WRQ 块号乱序（期望 %d，收到 %d），中止（残片留在 %s）"
                            % (expect, blk, tmp_path))
                        send_error(sock, peer, 0, "Bad block number")
                        return
                    payload = got[4:]
                    fd.write(payload)
                    total += len(payload)
                    blocks += 1
                    reply = struct.pack("!HH", OP_ACK, blk)
                    expect = (expect + 1) & 0xFFFF
                    if len(payload) < blksize:
                        final_ack = reply          # 最后一块：记下 ACK，稍后单独发
                        break
                # 顺序很重要：先把数据刷到磁盘，再发最终 ACK。
                # 对外界而言，"收到最终 ACK"就等价于"文件已经完整可读"。
                fd.flush()
                os.fsync(fd.fileno())
                fd.close()
                os.replace(tmp_path, path)
                ok = True
            finally:
                if not ok:
                    try:
                        fd.close()
                    except Exception:
                        pass

            dt = time.time() - t0
            log("WRQ -> %s:%d  完成 %s  共 %d 块 / %d 字节  用时 %.2fs (%.1f KB/s)  已存 %s  [TID=%d]"
                % (peer[0], peer[1], filename, blocks, total, dt,
                   total / 1024.0 / max(dt, 1e-6), path, sock.getsockname()[1]))

            # 最终 ACK 必须真发出去（对端 tftpput 会等它，等不到就报失败）。
            # 发完再短暂徘徊：万一 ACK 丢了、对端重传最后一块，还能再确认一次。
            if final_ack is not None:
                self._dally(sock, peer, final_ack)
        finally:
            sock.close()

    @staticmethod
    def _dally(sock, peer, ack):
        """收尾徘徊：反复发最终 ACK，对端若重传最后一块则继续陪，最长 3 秒。"""
        ack_blk = struct.unpack("!H", ack[2:4])[0]
        sock.settimeout(0.8)
        deadline = time.time() + 3.0
        while time.time() < deadline:
            try:
                sock.sendto(ack, peer)
            except OSError:
                return                     # 对端已关闭（ICMP 端口不可达），收工
            try:
                r, p = sock.recvfrom(70000)
            except socket.timeout:
                return
            except OSError:
                return
            if p[0] != peer[0] or p[1] != peer[1] or len(r) < 4:
                continue
            if struct.unpack("!H", r[:2])[0] == OP_DATA:
                if struct.unpack("!H", r[2:4])[0] == ack_blk:
                    deadline = time.time() + 1.0     # 还在重传，再陪一会儿

    @staticmethod
    def _wait_data(sock, peer, reply):
        """发 reply（若非 None）后等一个来自 peer 的 DATA。"""
        for _ in range(RETRIES):
            if reply is not None:
                sock.sendto(reply, peer)
            try:
                r, p = sock.recvfrom(70000)
            except socket.timeout:
                continue
            except OSError:
                return None
            if p[0] != peer[0] or p[1] != peer[1]:
                continue
            if len(r) < 4:
                continue
            op = struct.unpack("!H", r[:2])[0]
            if op == OP_DATA:
                return r
            if op == OP_ERROR:
                log("WRQ 对端报错：%s" % r[4:].decode("utf-8", "replace"))
                return None
        return None


def main():
    global _logfh
    ap = argparse.ArgumentParser(description="极简 TFTP 服务器（纯标准库）")
    ap.add_argument("--bind", default="0.0.0.0", help="监听地址（建议绑直连板子的网卡 IP）")
    ap.add_argument("--port", type=int, default=69, help="监听端口（TFTP 标准是 69）")
    ap.add_argument("--root", required=True, help="服务根目录")
    ap.add_argument("--writable", action="store_true", help="允许 WRQ（tftpput 备份用）")
    ap.add_argument("--setuid", default=None,
                    help="绑定端口后降权到该用户（典型用法：root 绑 69，再降权回本人）")
    ap.add_argument("--log", default=None, help="同时写日志文件")
    ap.add_argument("--pidfile", default=None, help="写 pid 文件（配合 --stop）")
    ap.add_argument("--stop", action="store_true", help="按 pidfile 停掉已在跑的实例")
    args = ap.parse_args()

    if args.stop:
        if not args.pidfile or not os.path.exists(args.pidfile):
            sys.exit("[错误] 需要 --pidfile 且文件存在")
        pid = int(open(args.pidfile).read().strip())
        try:
            os.kill(pid, 15)
        except OSError as e:
            print("发送 TERM 失败（可能已经退出）：%s" % e)
            if os.path.exists(args.pidfile):
                os.unlink(args.pidfile)
            return
        # 等它真的退出，最多 5 秒
        for _ in range(50):
            time.sleep(0.1)
            try:
                os.kill(pid, 0)
            except OSError:
                print("已停止 pid %d" % pid)
                break
        else:
            print("pid %d 没在 5 秒内退出，可能需要 kill -9" % pid)
        if os.path.exists(args.pidfile):
            os.unlink(args.pidfile)
        return

    # 提前校验降权目标用户存在，避免绑完端口才发现用户名写错
    if args.setuid:
        import pwd
        try:
            pwd.getpwnam(args.setuid)
        except KeyError:
            sys.exit("[错误] --setuid 指定的用户不存在：%s" % args.setuid)

    root = os.path.realpath(args.root)
    if not os.path.isdir(root):
        sys.exit("[错误] 根目录不存在：%s" % root)
    if args.log:
        _logfh = open(args.log, "a", buffering=1)
    if args.pidfile:
        with open(args.pidfile, "w") as f:
            f.write(str(os.getpid()))

    srv = TftpServer(args.bind, args.port, root, args.writable, args.setuid)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("收到中断，退出（共处理 %d 次请求）" % srv.n)


if __name__ == "__main__":
    main()
