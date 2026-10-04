#!/bin/bash
# verify-gmac.sh —— 在 6.6 的 initramfs shell 里做 GMAC 终局验证
#
# 前置：board.sh boot66 已经把 6.6 内核起起来、掉到 / # shell。
# 本脚本往串口控制文件里按序灌命令（每条之间留够间隔，serial_agent 的 gap=0.6s，
# 一次灌多行会错位），然后把新增日志打印出来。
#
# 验证顺序（由弱到强）：
#   1) ip link                    —— 看 eth0 存不存在、MAC 是不是全 00
#   2) ip addr show eth0          —— 看地址/状态
#   3) ip link set eth0 up        —— 拉起，看 carrier
#   4) udhcpc -i eth0 …           —— 真去 DHCP 要地址（最硬的证据）
#   5) 静态 IP + ping 宿主机       —— 就算没有 DHCP 服务器，也要证明能收发
set -uo pipefail

S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"

MARK=$(stat -c %s "$LOG")
echo "log mark = $MARK"

send() { printf '%s\n' "$1" >> "$CTL"; echo "-> $1"; sleep "${2:-1.5}"; }

send '' 1
send 'echo ===GMAC-1-ip-link===' 1
send 'ip link' 2
send 'echo ===GMAC-2-dmesg===' 1
send "dmesg | grep -iE 'r8169|eth0|gmac'" 2.5
send 'echo ===GMAC-3-addr===' 1
send 'ip addr show eth0' 2
send 'echo ===GMAC-4-up===' 1
send 'ip link set eth0 up' 2
send 'ip link show eth0' 2
send 'echo ===GMAC-5-dhcp===' 1
# -n 要不到就退出、-q 拿到租约后安静、-t 重试次数、-T 每次超时秒数
send 'udhcpc -i eth0 -q -n -t 4 -T 3' 16
send 'echo ===GMAC-6-addr-after-dhcp===' 1
send 'ip addr show eth0' 2
send 'echo ===GMAC-7-ping-host===' 1
# 兜底：没 DHCP 服务器就自己配一个同网段静态 IP，ping 宿主机的 TFTP 服务器
send 'ip addr add 192.168.1.100/24 dev eth0 2>/dev/null; ip route add default via 192.168.1.254 2>/dev/null; ip addr show eth0' 2
send 'ping -c 3 -W 2 192.168.1.254' 12
send 'echo ===GMAC-DONE===' 1

echo
echo "======== 新增串口输出 ========"
tail -c +$((MARK + 1)) "$LOG" | tr -d '\000'
