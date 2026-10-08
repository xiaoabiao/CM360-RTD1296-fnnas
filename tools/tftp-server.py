#!/usr/bin/env python3
"""tftp-server.py —— 极简只读 TFTP 服务端（仅供 u-boot 取刷机镜像用）

为什么自己写一个
----------------
刷机时电脑上要有个 TFTP 服务给 u-boot 拉镜像，但：
  * 装 dnsmasq/tftpd-hpa 需要 root + 系统配置，还要改全局防火墙；
  * u-boot 会协商 `blksize`（一次传 1468 字节而不是 512），标准实现未必都支持；
  * 我们只需要"读"，不需要任何写能力。
所以这里用标准库实现一个**只读**（RRQ）服务端，绑定到指定地址的 69 端口之上的
非特权端口（默认 6969，避开需要 root 的 69），支持 blksize/timeout/tsize 协商。

用法
----
    python3 tftp-server.py --root ./images --bind 192.168.1.254 --port 6969
    # u-boot 侧：
    #   setenv serverip 192.168.1.254
    #   tftpboot 0x02000000 low-region-38MiB.img

安全
----
只允许读取 --root 目录下的常规文件，拒绝任何形式的路径穿越；
只实现 RRQ，WRQ 一律拒绝。
"""
import argparse
import os
import socket
import struct
import sys
import threading

OP_RRQ = 1
OP_WRQ = 2
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5
OP_OACK = 6

ERR_NOT_FOUND = 1
ERR_ACCESS = 2
ERR_ILLEGAL = 4


def log(msg):
    print(msg, flush=True)


def parse_request(pkt):
    """解析 RRQ/WRQ：文件名 \0 模式 \0 [选项 \0 值 \0 ...]"""
    parts = pkt[2:].split(b"\x00")
    if not parts:
        return None, None, {}
    filename = parts[0].decode("utf-8", "replace")
    mode = parts[1].decode("ascii", "replace") if len(parts) > 1 else "octet"
    opts = {}
    rest = parts[2:]
    for i in range(0, len(rest) - 1, 2):
        if rest[i]:
            opts[rest[i].decode("ascii", "replace").lower()] = rest[i + 1].decode("ascii", "replace")
    return filename, mode, opts


def safe_path(root, filename):
    """把请求的文件名解析到 root 内，拒绝路径穿越与目录。"""
    p = os.path.normpath(os.path.join(root, filename.lstrip("/")))
    if not p.startswith(os.path.abspath(root) + os.sep):
        return None
    if not os.path.isfile(p):
        return None
    return p


def serve_file(sock, addr, path, opts, stats):
    handle = opts.get("blksize")
    try:
        blksize = int(handle) if handle else 512
    except ValueError:
        blksize = 512
    blksize = max(8, min(blksize, 65464))

    size = os.path.getsize(path)
    oack = {}
    if "blksize" in opts:
        oack["blksize"] = str(blksize)
    if "tsize" in opts:
        oack["tsize"] = str(size)
    timeout = 3.0
    if "timeout" in opts:
        try:
            timeout = max(1, min(int(opts["timeout"]), 30))
        except ValueError:
            timeout = 3.0
    sock.settimeout(timeout)

    if oack:
        payload = b"".join(k.encode() + b"\x00" + v.encode() + b"\x00" for k, v in oack.items())
        sock.sendto(struct.pack("!HH", OP_OACK, 0) + payload, addr)
        try:
            data, _ = sock.recvfrom(1024)
        except socket.timeout:
            return
        if len(data) < 4 or struct.unpack("!H", data[:2])[0] != OP_ACK:
            return

    with open(path, "rb") as fh:
        block = 1
        sent_bytes = 0
        while True:
            chunk = fh.read(blksize)
            pkt = struct.pack("!HH", OP_DATA, block & 0xFFFF) + chunk
            for _ in range(5):  # 重传
                sock.sendto(pkt, addr)
                try:
                    data, _ = sock.recvfrom(1024)
                except socket.timeout:
                    continue
                if len(data) >= 4 and struct.unpack("!H", data[:2])[0] == OP_ACK \
                        and struct.unpack("!H", data[2:4])[0] == (block & 0xFFFF):
                    break
            else:
                log("    ! 对端无响应，放弃 %s" % os.path.basename(path))
                return
            sent_bytes += len(chunk)
            if len(chunk) < blksize:
                break
            block += 1
    stats["done"] += 1
    log("    ✔ 发送完成 %s（%d 字节）" % (os.path.basename(path), sent_bytes))


def handle_rrq(root, addr, pkt, stats):
    filename, _mode, opts = parse_request(pkt)
    path = safe_path(root, filename)
    if path is None:
        log("    ✗ 拒绝请求 %r（不存在或越权）" % filename)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.sendto(struct.pack("!HH", OP_ERROR, ERR_NOT_FOUND) + b"not found\x00", addr)
        s.close()
        return
    log("    → %s（来自 %s:%d）" % (filename, addr[0], addr[1]))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))  # 每次传输用一个新的临时端口（TFTP 规范）
    try:
        serve_file(sock, addr, path, opts, stats)
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser(description="只读 TFTP 服务端（给 u-boot 拉刷机镜像）")
    ap.add_argument("--root", default=".", help="要共享的目录")
    ap.add_argument("--bind", default="0.0.0.0", help="监听地址（建议填写朝向板子的那块网卡 IP）")
    ap.add_argument("--port", type=int, default=6969, help="监听端口（默认 6969，u-boot 里用 serverip:port 语法）")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print("目录不存在: %s" % root, file=sys.stderr)
        return 1

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    log("TFTP 只读服务已启动: %s:%d  根目录=%s" % (args.bind, args.port, root))
    log("（u-boot 侧用 tftpboot <addr> <文件名>；若用的不是 69 端口，需写成 serverip:port）")

    stats = {"done": 0}
    try:
        while True:
            pkt, addr = sock.recvfrom(4096)
            if len(pkt) < 4:
                continue
            op = struct.unpack("!H", pkt[:2])[0]
            if op == OP_RRQ:
                # 每个请求单独起线程，便于并发/重试
                threading.Thread(target=handle_rrq, args=(root, addr, pkt, stats), daemon=True).start()
            elif op == OP_WRQ:
                log("    ✗ 拒绝写请求（只读服务）")
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.sendto(struct.pack("!HH", OP_ERROR, ERR_ACCESS) + b"read-only server\x00", addr)
                s.close()
    except KeyboardInterrupt:
        log("\n已停止（共完成 %d 次传输）" % stats["done"])
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
