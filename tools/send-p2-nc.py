#!/usr/bin/env python3
# send-p2-nc.py —— 把 p2.btrfs（fnOS rootfs 原始分区镜像）通过 TCP 直接推给板子
#
# 为什么不用 HTTP/tftp：
#   * tftp 是 UDP，3.3G 大文件不可靠
#   * initramfs 里 busybox 没有 dd，但有 nc；用 `nc > /dev/sda` 让 shell 重定向直接写块设备
#   * 不用特权端口（9 需 root），用 8899；板子侧命令 `nc 192.168.1.254 8899 > sda` 共 26 字符
#     —— 串口无流控，命令必须 < 32 字符
#
# 用法: ./send-p2-nc.py [端口] [源文件]
import socket, os, sys, time

BIND = "192.168.1.254"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
SRC  = sys.argv[2] if len(sys.argv) > 2 else die("用法: send-p2-nc.py <host> <要发送的文件> [端口]")

total = os.path.getsize(SRC)
print(f"[send] listening {BIND}:{PORT}", flush=True)
print(f"[send] source   {SRC}", flush=True)
print(f"[send] size     {total} bytes ({total/1048576:.1f} MiB)", flush=True)

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((BIND, PORT))
s.listen(1)
print("[send] 等待板子连接 ...", flush=True)

c, addr = s.accept()
print(f"[send] 已连接: {addr[0]}:{addr[1]}", flush=True)

sent = 0
t0 = time.time()
last_report = 0
try:
    with open(SRC, "rb") as f:
        while True:
            d = f.read(1 << 20)          # 1 MiB
            if not d:
                break
            c.sendall(d)
            sent += len(d)
            if sent - last_report >= (128 << 20):   # 每 128 MiB 报一次
                last_report = sent
                el = max(time.time() - t0, 1e-6)
                print(f"[send] {sent/1048576:8.1f} / {total/1048576:.1f} MiB  "
                      f"({100*sent/total:5.1f}%)  {sent/el/1048576:6.1f} MiB/s", flush=True)
finally:
    try:
        c.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    c.close()
    s.close()

el = time.time() - t0
print(f"[send] DONE  {sent} bytes  {el:.1f}s  {sent/max(el,1e-6)/1048576:.1f} MiB/s", flush=True)
print(f"[send] {'OK 全部发送' if sent == total else '!! 字节数不符，检查'} ", flush=True)
