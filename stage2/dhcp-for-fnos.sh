#!/bin/bash
# dhcp-for-fnos.sh —— 在开发机 enp2s0 上起一个 DHCP 服务器，好让 CM360 上的 fnOS 拿到 IP
#
# 为什么需要它：板子目前【直连】开发机（192.168.1.254/24），这个网段里没有任何 DHCP
#   服务器，所以 fnOS 启动后 eth0 虽然 link up，却拿不到地址，Web 界面也就访问不了。
#
# 为什么必须 sudo：DHCP 服务端固定用 UDP 67（特权端口），普通用户 bind 不了
#   （userns 也救不了 —— 网络资源属于初始 netns，权限按初始 user namespace 判）。
#
# 用法：  ./dhcp-for-fnos.sh          需要输入一次 sudo 密码
#        ./dhcp-for-fnos.sh stop      停掉
#
# 说明：本机已有一个 dnsmasq（PID 9035）在为 LXC 的 lxcbr0 服务，它用
#   --bind-interfaces --interface=lxcbr0 只绑 10.0.3.1:67，
#   我们这里只绑 enp2s0(192.168.1.254):67，两者地址不同，互不冲突。
set -uo pipefail

IF=enp2s0
PIDFILE=/tmp/dnsmasq-fnos.pid
LOGF=/tmp/dnsmasq-fnos.log
RANGE=192.168.1.150,192.168.1.200,12h
GW=192.168.1.254

case "${1:-start}" in
stop)
    sudo kill "$(cat $PIDFILE 2>/dev/null)" 2>/dev/null && echo "已停止" || echo "没有在跑"
    rm -f "$PIDFILE"
    exit 0
    ;;
esac

echo "== 在 $IF 上启动 DHCP（范围 $RANGE，网关 $GW）=="
sudo dnsmasq \
    -i "$IF" --bind-interfaces \
    --dhcp-range="$RANGE" \
    --dhcp-option=3,"$GW" \
    --dhcp-option=6,"$GW" \
    --dhcp-authoritative \
    --pid-file="$PIDFILE" \
    --log-dhcp --log-facility="$LOGF"

sleep 1
echo
echo "== 状态 =="
if [ -f "$PIDFILE" ]; then
    echo "  dnsmasq PID: $(cat "$PIDFILE")"
    ps -o pid,cmd -p "$(cat "$PIDFILE")" 2>/dev/null | tail -1
else
    echo "  !! 没起来，看上面报错"
fi
echo "  日志: $LOGF"
echo
echo "== 下一步 =="
echo "  1) 看板子是否来要地址： sudo tail -f $LOGF"
echo "  2) 若板子已经放弃 DHCP（ifupdown 失败后不重试），断电等 5 秒再上电即可 ——"
echo "     DHCP 服务器已经在跑，板子启动瞬间就能拿到地址。"
