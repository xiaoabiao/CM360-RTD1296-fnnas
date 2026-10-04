#!/bin/bash
# bootm-try.sh —— 用 `bootm`（而不是 Realtek 定制的 `booti`）启动内核
#
# 为什么要换 bootm（★ 这是从 openSUSE HCL:Zidoo X9S 页面抄来的实测配方）：
#   本机 u-boot 的 `booti` 是 Realtek 魔改过的，在 bootm_load_os 之后多挂了一步
#   自家判断：
#       XIP Kernel Image ... OK
#       Not raw Image, Starting Decompress Image.gz...
#       Error: Bad gzipped data
#       Decompress FAIL!!
#   同一台板子上 DS418J 也是同一句话（U-Boot 2015.07 / Board: Realtek QA Board），
#   说明是 Realtek 这版 u-boot 的通病，跟我们的镜像没关系。
#   而 `bootm` 走的是 u-boot 原生 legacy-uImage 路径，没有那个钩子。
#
# Zidoo X9S（同一家族，u-boot 2015.07）上跑通的原始配方：
#   tftp $kernel_loadaddr uImage
#   tftp $fdt_loadaddr  rtd1295-*.dtb
#   tftp $rootfs_loadaddr initrd.cpio.gz
#   fdt addr $fdt_loadaddr ; fdt resize
#   setenv bootargs "earlycon initrd=$rootfs_loadaddr,0x$filesize"
#   bootm $kernel_loadaddr - $fdt_loadaddr
#
#   页面原话：The uImage must use 0x00280000 as load address, or the Image
#   needs to be built with patched TEXT_OFFSET (default: 0x80000) to boot
#   successfully.  —— 所以 uImage 头里的 ih_load/ih_ep 是关键字，见 mk-uimage.py。
#
# 用法：./bootm-try.sh [uimage地址] [fdt地址] [initrd地址] [等待秒数]
#       ./bootm-try.sh 0x02ffffc0 0x01f00000 0x02200000 60
set -uo pipefail

S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
S2=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage2
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"

UIADDR=${1:-0x02ffffc0}
FADDR=${2:-0x01f00000}
RADDR=${3:-0x02200000}
WAIT=${4:-60}

ISIZE=$(stat -c %s "$S2/out/initramfs.cpio.gz")
IHEX=$(printf '0x%x' "$ISIZE")

# initrd 走 bootargs —— Färber 的实测结论：bootm/booti 都喂不进 initrd，
# 只有 `initrd=<addr>,<size>` 这条 bootargs 老路可靠（arm64 的 early_initrd）。
# 我们同时在 DTB /chosen 里也写了 linux,initrd-start/end，两条都摆上，互为兜底。
# clk_ignore_unused 已撤（2026-10-04 晚）：uart0 的 clocks 属性已补齐，
# 时钟由驱动认领，不再需要这颗总闸。详见 board.sh 顶上那段注释。
BOOTARGS="console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=$RADDR,$IHEX"

echo "== bootargs = $BOOTARGS"
echo "== bootm $UIADDR - $FADDR"

printf '@mark:bootm-try\n' >> "$CTL"
printf "setenv bootargs '%s'\n" "$BOOTARGS" >> "$CTL"
sleep 2
printf 'echo ARGS_NOW=$bootargs\n' >> "$CTL"
sleep 2

MARK=$(stat -c %s "$LOG")
printf 'bootm %s - %s\n' "$UIADDR" "$FADDR" >> "$CTL"

echo "== 已发出，盯 ${WAIT} 秒（期望 'Booting Linux on physical CPU'）"
for _i in $(seq 1 "$WAIT"); do
	sleep 1
	if tail -c +$((MARK + 1)) "$LOG" | grep -qaE \
		'Booting Linux|Kernel panic|Uncompressing Linux|Freeing unused|missing enable-method|Error: invalid'; then
		break
	fi
done

echo
echo "======== bootm 之后的串口 ========"
tail -c +$((MARK + 1)) "$LOG"
