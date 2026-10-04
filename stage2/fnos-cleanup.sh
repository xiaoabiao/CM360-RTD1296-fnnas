#!/bin/bash
# fnos-cleanup.sh —— 清理 CM360 上 fnOS rootfs 里的 Rockchip / 6.18.18 内核残留
#
# 依据：见同目录 fnOS-rootfs适配清单.md（结论全部来自官方镜像只读解剖）
#
# 用法：
#   ./fnos-cleanup.sh --dry-run /mnt/fnos-root     # 只看会做什么，不动任何文件（默认建议先跑这个）
#   ./fnos-cleanup.sh /mnt/fnos-root               # 实际执行
#
# 前提：以 root 运行，$1 是**已挂载**的 fnOS rootfs 挂载点（btrfs）。
# 安全网：动手前会先把所有待删路径记进 $ROOT/var/tmp/fnos-cleanup-removed.txt，
#         并打印出来；原始 p2.btrfs 镜像请另行妥善保存。

set -uo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
ROOT="${1:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "用法: $0 [--dry-run] <已挂载的 fnOS rootfs 路径>" >&2
    exit 2
fi
if [ "$(id -u)" != "0" ]; then
    echo "错误：需要 root（要改写 rootfs 属主/权限）" >&2
    exit 1
fi

LOG="$ROOT/var/tmp/fnos-cleanup-removed.txt"
KREL_OLD="6.18.18-trim"
KREL_NEW="$( (uname -r 2>/dev/null) || echo '6.6.54' )"

run() {                       # 打印 + （非 dry-run 时）执行
    echo "  \$ $*"
    [ "$DRY" = 1 ] || "$@"
}
note() { echo "  · $*"; }

echo "===== fnOS rootfs 清理 ====="
echo "  rootfs : $ROOT"
echo "  模式   : $( [ "$DRY" = 1 ] && echo 'DRY-RUN（不修改任何文件）' || echo '实际执行' )"
echo "  目标内内核版本: $KREL_NEW"
echo

echo "----- [1/6] 删除外来内核模块目录（我方内核全内置，不需任何外部模块）-----"
TOPDEL=(
  "usr/lib/modules/$KREL_OLD"
  "usr/lib/modules/6.1.0-39-arm64"
  "usr/src/linux-headers-$KREL_OLD"
  "usr/trim/modules/$KREL_OLD"
)
[ "$DRY" = 1 ] || : > "$LOG"
for p in "${TOPDEL[@]}"; do
    if [ -e "$ROOT/$p" ]; then
        note "存在: $p  ($(du -sh "$ROOT/$p" 2>/dev/null | cut -f1))"
        [ "$DRY" = 1 ] || echo "$p" >> "$LOG"
        run rm -rf "$ROOT/$p"
    else
        note "跳过（不存在）: $p"
    fi
done
echo

echo "----- [2/6] 删除引用不存在模块的 modules-load 配置 -----"
for f in trim-rk_vcodec.conf trim-zfs.conf trim-fullconenat-nft.conf; do
    t="$ROOT/etc/modules-load.d/$f"
    if [ -e "$t" ]; then
        note "删除: etc/modules-load.d/$f"
        [ "$DRY" = 1 ] || echo "etc/modules-load.d/$f" >> "$LOG"
        run rm -f "$t"
    fi
done
note "保留: etc/modules-load.d/20-zram-generator.conf（我方已内置 ZRAM=y，它有效）"
echo

echo "----- [3/6] 改写设备标识 etc/device_info/ -----"
set_dev() {                    # $1=文件  $2=新值
    t="$ROOT/etc/device_info/$1"
    [ -e "$t" ] || { note "跳过（不存在）: etc/device_info/$1"; return; }
    note "etc/device_info/$1 : $(cat "$t" 2>/dev/null) -> $2"
    if [ "$DRY" != 1 ]; then printf '%s\n' "$2" > "$t"; fi
}
set_dev boot_brand  realtek
set_dev boot_family rtd129x
set_dev boot_board  rtd1296-cm360
set_dev platform    arm
set_dev boot_mode   uboot
echo

echo "----- [4/6] 改写内核版本记录 var/tmp/kernel_version_output -----"
KVO="$ROOT/var/tmp/kernel_version_output"
if [ -e "$KVO" ]; then
    note "原内容: $(tr '\n' ' ' < "$KVO")"
    note "改为: kernel_version='$KREL_NEW'  platform_name='realtek'"
    if [ "$DRY" != 1 ]; then
        printf "kernel_version='%s'\nplatform_name='realtek'\n" "$KREL_NEW" > "$KVO"
    fi
else
    note "不存在，跳过"
fi
echo

echo "----- [5/6] 屏蔽可能覆盖引导的自动升级 -----"
if [ -d "$ROOT/etc/systemd/system" ]; then
    for u in apt-daily-upgrade.timer apt-daily-upgrade.service; do
        if [ -e "$ROOT/usr/lib/systemd/system/$u" ] || [ -e "$ROOT/etc/systemd/system/$u" ]; then
            note "mask: $u"
            run ln -sf /dev/null "$ROOT/etc/systemd/system/$u"
        fi
    done
else
    note "跳过（无 /etc/systemd/system）"
fi
echo

echo "----- [6/6] 提示：不要动的东西 -----"
note "etc/kernel/postinst.d/*、etc/initramfs/post-update.d/* —— 它们按 compatible 匹配"
note "  allwinner|amlogic|rockchip，CM360 是 realtek → 全部静默跳过，**保持原样**。"
note "  切勿往 DTS 里加假 rockchip compatible，否则它们会去改写 /boot/extlinux/extlinux.conf。"
note "/boot 是独立 p1(ext4) 分区的挂载点，引导文件不在此 rootfs 内。"
echo

if [ "$DRY" = 1 ]; then
    echo "===== DRY-RUN 结束，未修改任何文件 ====="
    echo "确认无误后去掉 --dry-run 再跑一次。"
else
    echo "===== 清理完成 ====="
    echo "被删除/改写的路径已记录到: $LOG"
    echo "建议随后执行: sync"
fi
