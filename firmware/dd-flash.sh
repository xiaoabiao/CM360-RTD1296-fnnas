#!/bin/bash
# dd-flash.sh —— 板端直刷（最小系统四件套的第 4 个文件）
#
# 为什么用它
# ----------
# 前面验证过的 u-boot + TFTP 路线是可靠的（低区与 p1 都已实测通过 ✔），
# 但 TFTP 实测只有 ~1.5 MB/s，7GiB 的 rootfs 要 ~78 分钟。
# 而在**运行中的系统**里直接 dd 写 eMMC，速度是几十 MB/s —— 全部三层约 5 分钟。
# 所以：能进系统时用 dd（快），进不去时才用 u-boot/TFTP 或串口 ROM Monitor（保底）。
#
# 用法（板端 root）
#   sudo ./dd-flash.sh                     # 刷全部三层（会清空 fnOS 配置！）
#   sudo ./dd-flash.sh --layers p1,p2      # 只刷指定层
#   sudo ./dd-flash.sh --check             # 只校验镜像与目标，不写
#   sudo ./dd-flash.sh --yes               # 跳过交互确认
#
# 目录约定：脚本同目录下放四个文件
#   low-region.img   (38 MiB)  hwsetting+bootcode+FSBL+BL31+u-boot+env  → /dev/mmcblk0 起始
#   p1.img           (256 MiB) ext4：内核 uImage + 板级 DTB             → /dev/mmcblk0p1
#   p2.img           (7 GiB)   btrfs：fnOS rootfs（子卷 root）          → /dev/mmcblk0p2
#   dd-flash.sh      (本脚本)
#
# ⚠️ 刷 p2 = 清空 fnOS 的账号/共享/设置（这是"重装系统"的定义）。
#    两块硬盘上的存储空间（RAID/LVM/btrfs）**不受影响**（脚本只按设备名写 eMMC 分区）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DEV=/dev/mmcblk0
P1=${DEV}p1
P2=${DEV}p2
LOW_SECTORS=77824          # 38 MiB
CONFIRM=1

LAYERS=low,p1,p2
for a in "$@"; do
	case "$a" in
	--check)  CONFIRM=0; CHECK_ONLY=1 ;;
	--yes)    CONFIRM=0 ;;
	--reboot) REBOOT=1 ;;
	--layers) shift; LAYERS="$1" ;;
	--layers=*) LAYERS="${a#--layers=}" ;;
	*) echo "未知参数: $a" >&2; exit 1 ;;
	esac
done
CHECK_ONLY=${CHECK_ONLY:-0}
REBOOT=${REBOOT:-0}
say() { echo "$@"; }

[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行" >&2; exit 1; }
[ -b "$DEV" ] || { echo "找不到 $DEV" >&2; exit 1; }

say "=============================================="
say "CM360 dd 直刷（最小系统四件套）"
say "=============================================="

# ── 1) 校验镜像 ──────────────────────────────────────────────────────────
say "== 1) 校验镜像 =="
declare -A FILES=( [low]="low-region.img" [p1]="p1.img" [p2]="p2.img" )
declare -A SKIP=(  [low]=$((LOW_SECTORS*512)) [p1]=$(blockdev --getsize64 "$P1" 2>/dev/null || echo 0) [p2]=$(blockdev --getsize64 "$P2" 2>/dev/null || echo 0) )
ok=1
for l in ${LAYERS//,/ }; do
	f="$HERE/${FILES[$l]}"
	if [ ! -f "$f" ]; then say "   ✗ 缺少 ${FILES[$l]}"; ok=0; continue; fi
	sz=$(stat -c %s "$f")
	tgt=${SKIP[$l]}
	verdict="ok"
	[ "$sz" -gt "$tgt" ] && verdict="太大（目标 $tgt 字节）"
	m="${FILES[$l]}.md5"
	md5line=""
	[ -f "$HERE/$m" ] && md5line="  md5(记录) $(cut -d' ' -f1 "$HERE/$m")"
	say "   $(printf '%-4s' "$l") ${FILES[$l]}  $sz 字节 → 目标 $tgt 字节  [$verdict]$md5line"
	[ "$sz" -gt "$tgt" ] && ok=0
done
[ "$ok" = 1 ] || { echo "镜像检查未通过，终止" >&2; exit 1; }
[ "$CHECK_ONLY" = 1 ] && { say "== --check：只校验，未写入 =="; exit 0; }

# ── 2) 确认 ──────────────────────────────────────────────────────────────
say ""
say "== 2) 即将写入 eMMC：$LAYERS =="
say "   低区写入 = 直接改 u-boot/bootcode（砖区）；p2 写入 = 清空 fnOS 配置。"
say "   硬盘上的存储空间不会被动。"
if [ "$CONFIRM" = 1 ]; then
	read -r -p "   确认继续？输入 yes 回车：" a
	[ "$a" = "yes" ] || { echo "已取消"; exit 1; }
fi

# ── 2.5) 覆盖正在运行的 rootfs 前，先停掉服务减少磁盘 I/O ────────────────
if [ "$CONFIRM" = 0 ] && echo "$LAYERS" | grep -q p2; then
	say ""
	say "== 2.5) 停掉 fnOS 服务（p2 正在被覆盖，避免运行中大量磁盘 I/O）=="
	sync
	for svc in trim_main trim_sac trim_nginx filestor_service trim_sharelink trim_diskpowerd \
	           docker containerd smbd nmbd; do
		systemctl is-active --quiet "$svc" 2>/dev/null && {
			systemctl stop "$svc" >/dev/null 2>&1 && say "   已停 $svc"
		}
	done
	say "   （内核与 dd 都在内存里，写入期间不需要 rootfs）"
fi

# ── 3) 写入 ──────────────────────────────────────────────────────────────
say ""
say "== 3) 写入 =="
write_layer() {
	local name="$1" src="$2" dst="$3" extra="$4"
	say "   [$name] dd → $dst"
	# shellcheck disable=SC2086
	if dd if="$src" of="$dst" bs=4M conv=fsync $extra status=progress; then
		say "        ✔ 完成"
	else
		say "        ✗ 写入失败"
		return 1
	fi
}
rc=0
for l in ${LAYERS//,/ }; do
	case "$l" in
	low) write_layer low "$HERE/low-region.img" "$DEV" "count=$LOW_SECTORS bs=512" || rc=1 ;;
	p1)  write_layer p1  "$HERE/p1.img"         "$P1"  "" || rc=1 ;;
	p2)  write_layer p2  "$HERE/p2.img"         "$P2"  "" || rc=1 ;;
	esac
done
sync
[ "$rc" = 0 ] || { echo "有层写入失败，请勿重启前先排查" >&2; exit 1; }

# ── 4) 写后校验 ──────────────────────────────────────────────────────────
say ""
say "== 4) 写后回读校验 =="
say "   （注意：p2 覆盖的是正在运行的 rootfs，本进程的 /usr/bin 会随之失效，"
say "     因此 p2 的回读校验通常无法在此完成 —— 应在重启后的新系统里核对。"
say "     低区与 p1 不受影响，正常校验。）"
chk() { # name file dev bytes|empty
	local name="$1" file="$2" dev="$3" cnt="$4"
	local a b
	if [ -n "$cnt" ]; then
		a=$(dd if="$file" bs=512 count="$cnt" status=none | md5sum | cut -c1-32)
		b=$(dd if="$dev"  bs=512 count="$cnt" status=none | md5sum | cut -c1-32)
	else
		a=$(md5sum "$file" | cut -c1-32)
		b=$(dd if="$dev" bs=4M status=none | md5sum | cut -c1-32)
	fi
	if [ -z "$a" ] || [ -z "$b" ]; then
		say "   ✗ $name 校验无法完成（命令失败，可能是 rootfs 正在被覆盖）"
		return 1
	fi
	if [ "$a" = "$b" ]; then say "   ✔ $name 一致（$a）"; else say "   ✗ $name 不一致（$a vs $b）"; return 1; fi
}
for l in ${LAYERS//,/ }; do
	case "$l" in
	low) chk low "$HERE/low-region.img" "$DEV" "$LOW_SECTORS" || rc=1 ;;
	p1)  chk p1  "$HERE/p1.img"         "$P1"  "" || rc=1 ;;
	p2)  chk p2  "$HERE/p2.img"         "$P2"  "" || rc=1 ;;
	esac
done
[ "$rc" = 0 ] || { echo "回读校验不一致，请勿直接重启" >&2; exit 1; }

say ""
say "== 完成：三层写入并校验通过 =="
if [ "$REBOOT" = 1 ]; then
	say "   即将重启（dd 覆盖了正在运行的 rootfs，必须重启才能进入新系统）…"
	sync 2>/dev/null || true
	# 此时 /usr/bin 可能已失效，优先用内核级重启
	if [ -w /proc/sysrq-trigger ]; then
		say "   使用 SysRq 内核级重启（不依赖已失效的 /usr/bin）"
		echo b > /proc/sysrq-trigger
	fi
	sleep 3
	reboot 2>/dev/null || echo "   ！自动重启失败，请手动断电重启"
else
	say "   请执行： sudo reboot"
fi
