#!/usr/bin/env python3
"""brd.py —— 板子 SSH 助手（fnOS 已开 ssh）

凭据不写进本文件（仓库是公开的 Gitea），从 ~/.brd_cred 读：
    第 1 行 用户名   第 2 行 密码   第 3 行 IP(可省,默认 192.168.1.173)   第 4 行 端口(可省,默认 22)

用法:
    ./brd.py run  'uname -a'                 # 跑一条命令，回显 stdout+stderr
    ./brd.py sudo 'lsblk'                    # 用 sudo 跑（自动喂密码，走 stdin）
    ./brd.py put  <本地> <远端>               # scp 上传（走同一个连接）
    ./brd.py get  <远端> <本地>               # scp 下载
    ./brd.py push <本地> <远端> [总字节]       # 走 ssh 的 `cat > 远端` 流式上传（大文件更快，带进度）
    ./brd.py sh                              # 交互式（尽量别用，交给脚本）
"""
import os
import shlex
import sys

import paramiko

CRED = os.path.expanduser("~/.brd_cred")


def load_cred():
    lines = [l.rstrip("\n") for l in open(CRED, encoding="utf-8")]
    user = lines[0]
    pw = lines[1]
    host = lines[2] if len(lines) > 2 and lines[2].strip() else "192.168.1.173"
    port = int(lines[3]) if len(lines) > 3 and lines[3].strip() else 22
    return user, pw, host, port


def connect():
    user, pw, host, port = load_cred()
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        hostname=host,
        port=port,
        username=user,
        password=pw,
        look_for_keys=False,
        allow_agent=False,
        timeout=15,
        banner_timeout=20,
        auth_timeout=20,
    )
    return c, user, pw, host, port


def run(c, cmd, timeout=None, sudo=False, pw=None):
    """timeout=None 表示不设通道读超时。
    ★ 踩过的坑：默认 120s 会在 `btrfs send|receive` 这类长任务上抛 PipeTimeout，
      客户端断开；远端脚本虽然往往还活着，但它的 stdout 已失效，后续 echo 会
      撞 EPIPE/SIGPIPE 提前死掉（set -e）。所以长任务必须 timeout=None。"""
    if sudo:
        # ★ 必须整体包进 bash -c，否则 `;` / `&&` 会逃出 sudo 的作用范围
        # -S 从 stdin 读密码；-p '' 不回显提示
        cmd = "sudo -S -p '' /bin/bash -c " + shlex.quote(cmd)
    stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout, get_pty=False)
    if sudo:
        stdin.write(pw + "\n")
        stdin.flush()
    out = stdout.read()
    err = stderr.read()
    rc = stdout.channel.recv_exit_status()
    return rc, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    mode = sys.argv[1]
    c, user, pw, host, port = connect()

    if mode in ("run", "sudo"):
        cmd = " ".join(sys.argv[2:])
        rc, out, err = run(c, cmd, sudo=(mode == "sudo"), pw=pw)
        sys.stdout.write(out)
        if err.strip():
            sys.stderr.write(err)
        c.close()
        return rc

    if mode == "put":
        sftp = c.open_sftp()
        sftp.put(sys.argv[2], sys.argv[3], confirm=True)
        print(f"put ok: {sys.argv[2]} -> {sys.argv[3]}")
        c.close()
        return 0

    if mode == "get":
        sftp = c.open_sftp()
        sftp.get(sys.argv[2], sys.argv[3])
        print(f"get ok: {sys.argv[2]} -> {sys.argv[3]}")
        c.close()
        return 0

    if mode in ("push", "pushcmd"):
        # pushcmd: 把本地文件流喂给远端任意命令（默认 cat > 远端路径）
        #   ./brd.py pushcmd 'dd of=/dev/mmcblk0 bs=512 seek=2048 conv=notrunc' out/p1.img
        # 好处：256MB 的镜像不必先在板子上落盘。
        local = sys.argv[2]
        cmd = sys.argv[3] if mode == "pushcmd" else f"cat > {sys.argv[3]}"
        total = int(sys.argv[4]) if len(sys.argv) > 4 else os.path.getsize(local)
        stdin, stdout, stderr = c.exec_command(cmd, timeout=None)
        sent = 0
        tty = sys.stderr.isatty()
        with open(local, "rb") as f:
            while True:
                buf = f.read(4 << 20)
                if not buf:
                    break
                stdin.write(buf)
                sent += len(buf)
                if tty:
                    pct = sent * 100 // max(total, 1)
                    sys.stderr.write(f"\r  {sent/1048576:8.1f} / {total/1048576:.1f} MiB  {pct:3d}%")
                    sys.stderr.flush()
        stdin.flush()
        stdin.channel.shutdown_write()
        rc = stdout.channel.recv_exit_status()
        if tty:
            sys.stderr.write("\n")
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        if out.strip():
            sys.stdout.write(out)
        if err.strip():
            sys.stderr.write(err)
        c.close()
        return rc

    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
