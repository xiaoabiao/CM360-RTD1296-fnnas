#!/bin/bash
# CM360 盘位指示灯守护安装脚本
#
# 板端（root 执行）：
#   bash install.sh             # 安装并启用（常驻 systemd 服务）
#   bash install.sh --uninstall  # 卸载（灯回到 DTB 默认的 disk-activity）
#   bash install.sh --test       # 只刷一轮并打印状态（调试）
#
# 构建机（对未启动的 rootfs 预装，不需要 root、不执行 systemctl）：
#   bash install.sh --stage <rootfs 目录>
#
# 依赖：板上 /sys/class/leds/hdd1、hdd2 已存在（内核 DTB 里的 gpio-leds 节点）。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN_REL=usr/local/bin/cm360-hdd-led.py
UNIT_REL=etc/systemd/system/cm360-hdd-led.service
WANTS_REL=etc/systemd/system/multi-user.target.wants/cm360-hdd-led.service
BIN=/usr/local/bin/cm360-hdd-led.py
UNIT=/etc/systemd/system/cm360-hdd-led.service

die() { echo "错误：$*" >&2; exit 1; }

# ---- 镜像构建：注入未启动的 rootfs（不跑 systemctl、不需 root）-----------
if [ "${1:-}" = "--stage" ]; then
    ROOT="${2:-}"
    [ -n "$ROOT" ] && [ -d "$ROOT" ] || die "用法：bash install.sh --stage <rootfs 目录>"
    install -D -m 0755 "$HERE/cm360-hdd-led.py" "$ROOT/$BIN_REL"
    install -D -m 0644 "$HERE/cm360-hdd-led.service" "$ROOT/$UNIT_REL"
    mkdir -p "$ROOT/$(dirname "$WANTS_REL")"
    ln -sfn "../cm360-hdd-led.service" "$ROOT/$WANTS_REL"
    echo "已注入：/$BIN_REL, /$UNIT_REL, /$(dirname "$WANTS_REL")/cm360-hdd-led.service → ../cm360-hdd-led.service"
    exit 0
fi

if [ "$(id -u)" != 0 ]; then
    echo "请用 root 执行（sudo -i / su -）" >&2
    exit 1
fi

case "${1:-}" in
--uninstall)
    systemctl disable --now cm360-hdd-led.service 2>/dev/null
    rm -f "$UNIT" "$BIN"
    systemctl daemon-reload
    echo "已卸载 cm360-hdd-led（灯的行为回到 DTB 默认的 disk-activity）"
    exit 0
    ;;
--test)
    install -d /usr/local/bin
    install -m 0755 "$HERE/cm360-hdd-led.py" "$BIN"
    "$BIN" --once
    exit $?
    ;;
esac

for l in hdd1 hdd2; do
    if [ ! -d "/sys/class/leds/$l" ]; then
        echo "缺少 /sys/class/leds/$l —— 当前内核/DTB 没有 leds 节点" >&2
        exit 1
    fi
done

install -d /usr/local/bin
install -m 0755 "$HERE/cm360-hdd-led.py" "$BIN"
install -m 0644 "$HERE/cm360-hdd-led.service" "$UNIT"
systemctl daemon-reload
systemctl enable --now cm360-hdd-led.service
sleep 1
systemctl --no-pager --lines=5 status cm360-hdd-led.service
echo
echo "安装完成：盘在位常亮，有 IO 闪烁（hdd1=ata1/port0, hdd2=ata2/port1）"
