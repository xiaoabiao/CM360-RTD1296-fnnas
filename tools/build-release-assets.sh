#!/bin/bash
# build-release-assets.sh —— 一键生成"可下载即刷"的全部 Release 资产
#
# 这个脚本是**唯一真源**：GitHub Actions 只负责装依赖 + 调它 + 上传；
# 本地也能原样跑（便于验证），产物结构完全一致。
#
# 产物（按需生成，不含版权物）
# --------------------------
#   引导链 / u-boot
#     low-region-38MiB.img.gz            低区镜像（hwsetting+bootcode+FSBL+BL31+u-boot+env）
#   dd 刷入（板内直刷，已验证路线）
#     p1-256MiB.img.gz                   内核分区（ext4：uImage + 板级 DTB）
#     dd-set-cm360-<ver>.tar.gz          低区 + p1 + dd-flash.sh + 说明（解压即用）
#     p2.img.gz[.partNN]                 仅当提供 --p2/--fnos-image（版权物，需自行准备）
#   线刷（Windows USB MP Tool）
#     install-cm360-fnos-<ver>-slim-p2.img              ★ 低区+MBR+p1+精简 rootfs(2.0 GiB)+factory.tar
#     install-cm360-fnos-<ver>-full-p2.img              ★ 低区+MBR+p1+完整 rootfs(7.0 GiB)+factory.tar
#     install-cm360-fnos-<ver>-boot-sysonly.img        含低区+MBR+p1（不含 p2，救援/换内核用）
#     install-cm360-fnos-<ver>-boot-full.img           连 p2 一起刷（旧 python 打包器，仅工具链缺失时）
#     install-cm360-fnos-<ver>-boot-compact-full.img   精简 p2 版（旧 python 打包器）
#   校验与说明
#     MD5SUMS.txt / SHA256SUMS.txt / ASSETS.md
#   已刷机补救包（不是刷机必需：新镜像里已内置）
#     cm360-trim-compat-<ver>.tar.gz     fnOS 私有 ABI 用户态兼容层（上传/共享/回收站/FTP）
#
# 用法
# ----
#   ./build-release-assets.sh --p2 firmware/images/p2.img --out /mnt/out
#   ./build-release-assets.sh --fnos-image ~/downloads/fnos_arm_1.2.0302_xxx.img.gz
#   ./build-release-assets.sh --no-p2                 # 只出引导链 + p1 + 救援线刷包
#   ./build-release-assets.sh --dry-run
#
# 需要：sudo（p1/p2 构建要 loop 挂载）、btrfs-progs、e2fsprogs、rsync、gzip、tar、md5sum。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FW="$REPO/firmware"

# CI 里 sudo 免密；本地可用 SUDO="sudo -A" + SUDO_ASKPASS 免 tty 运行
SUDO="${SUDO:-sudo}"
OUT=""
VERSION="1.2.0302"
P2=""
FNOS_IMAGE=""
DO_P2=1
DO_COMPACT=1
DRYRUN=0
SPLIT_BYTES=$((1900 * 1024 * 1024))   # GitHub Release 单文件上限 2 GiB，留余量
WORK=""
LF_TOOL="${LF_TOOL:-$REPO/tools/lineflash/rtd129x_img_gen}"

log()  { echo "── $*"; }
say()  { echo "   $*"; }
die()  { echo "!! $*" >&2; exit 1; }
gi()   { awk "BEGIN{printf \"%.2f\", $1/1073741824}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--out) OUT="$2"; shift 2 ;;
	--version) VERSION="$2"; shift 2 ;;
	--p2) P2="$2"; DO_P2=1; shift 2 ;;
	--fnos-image) FNOS_IMAGE="$2"; DO_P2=1; shift 2 ;;
	--no-p2) DO_P2=0; shift ;;
	--no-compact) DO_COMPACT=0; shift ;;
	--work) WORK="$2"; shift 2 ;;
	--dry-run) DRYRUN=1; shift ;;
	-h|--help) sed -n '1,40p' "$0"; exit 0 ;;
	*) die "未知参数：$1" ;;
	esac
done

OUT="${OUT:-$REPO/dist/release}"
WORK="${WORK:-${TMPDIR:-/var/tmp}/cm360-release-work}"
[ "$DO_P2" = 1 ] || DO_COMPACT=0

for c in gzip tar md5sum sha256sum awk split python3; do need "$c"; done
# 有 pigz 就用它（多核 gzip，CI 里 7.5 GiB 从 5 分钟降到 1 分钟内）
GZ="$(command -v pigz || command -v gzip)"
say_gz="gzip"; [ "${GZ##*/}" = pigz ] && say_gz="pigz（多核）"

log "计划"
say "产物目录   $OUT"
say "版本       $VERSION"
say "p2         $([ "$DO_P2" = 1 ] && echo '是' || echo '否（--no-p2）')$([ -n "$P2" ] && echo "  来源=$P2")$([ -n "$FNOS_IMAGE" ] && echo "  由官方镜像构建=$FNOS_IMAGE")"
say "精简 p2    $([ "$DO_COMPACT" = 1 ] && echo '是' || echo '否')"
say "分卷阈值   $((SPLIT_BYTES/1024/1024)) MiB"
say "压缩器     $GZ"
if [ -n "$FNOS_IMAGE" ] && [ ! -f "$FNOS_IMAGE" ] && [ "$DO_P2" = 1 ]; then
	say "官方镜像将下载：$FNOS_IMAGE"
fi
[ "$DRYRUN" = 1 ] && { log "dry-run：不做任何构建"; exit 0; }

mkdir -p "$OUT" "$WORK"
cd "$REPO"

# ── 1. 低区（引导链 / u-boot）：仓库里那份，解压 + 校验 md5 ──────────────
log "1/7 引导链（低区 / u-boot）"
LOW_GZ="$FW/low-region-38MiB.img.gz"
[ -f "$LOW_GZ" ] || die "缺 $LOW_GZ"
LOW="$WORK/low-region.img"
[ -f "$LOW" ] || gunzip -c "$LOW_GZ" >"$LOW"
LOW_MD5=$(md5sum "$LOW" | cut -d' ' -f1)
if [ -f "$FW/low-region-38MiB.img.md5" ]; then
	EXP=$(cut -d' ' -f1 "$FW/low-region-38MiB.img.md5")
	[ "$LOW_MD5" = "$EXP" ] || die "低区镜像 md5 不符：$LOW_MD5 != $EXP"
	say "md5 校验 ✅ $LOW_MD5"
fi
cp -f "$LOW_GZ" "$OUT/low-region-38MiB.img.gz"
(cd "$OUT" && md5sum low-region-38MiB.img.gz >low-region-38MiB.img.gz.md5)
say "low-region-38MiB.img.gz  $(stat -c %s "$OUT/low-region-38MiB.img.gz") 字节"

# ── 2. p1（内核 + DTB 的 ext4 分区）：现场构建（需要 sudo）─────────────
log "2/7 内核分区 p1"
P1_DIR="$WORK/p1out"; mkdir -p "$P1_DIR"
if [ -f "$P1_DIR/p1-256MiB.img" ]; then
	say "复用已有 $P1_DIR/p1-256MiB.img"
else
	$SUDO env OUT="$P1_DIR" WORK="$WORK/build" "$FW/build-images.sh" p1 \
		| sed 's/^/   /' || die "p1 构建失败（需要 sudo + e2fsprogs）"
fi
P1="$P1_DIR/p1-256MiB.img"
P1_MD5=$(md5sum "$P1" | cut -d' ' -f1)
say "p1  $(stat -c %s "$P1") 字节  md5 $P1_MD5"
"$GZ" -6 -c "$P1" >"$OUT/p1-256MiB.img.gz"
(cd "$OUT" && md5sum p1-256MiB.img.gz >p1-256MiB.img.gz.md5)
say "p1-256MiB.img.gz        $(stat -c %s "$OUT/p1-256MiB.img.gz") 字节"

# 线刷包要求 p1 尺寸**与 MBR 分区完全一致**（0x7FFF0 扇区 = 268,427,264 B），
# build-images.sh 产出的是实机尺寸 256 MiB（大 8 KiB）→ 这里做一份精确尺寸副本。
P1_MBR="$WORK/p1-mbr.img"
cp -f "$P1" "$P1_MBR"
e2fsck -fy "$P1_MBR" >/dev/null 2>&1 || true
resize2fs "$P1_MBR" 65534 >/dev/null 2>&1 || true
truncate -s 268427264 "$P1_MBR"
say "p1 线刷用（MBR 尺寸）  $(stat -c %s "$P1_MBR") 字节"

# ── 3. p2（rootfs）：可选。三种来源：已有镜像 / 官方镜像 / 跳过 ──────────
log "3/7 rootfs p2"
P2_IMG=""
if [ "$DO_P2" = 1 ]; then
	if [ -n "$P2" ]; then
		[ -f "$P2" ] || die "找不到 --p2 指定的镜像：$P2"
		P2_IMG="$P2"
		say "用已有 p2：$P2_IMG"
	elif [ -n "$FNOS_IMAGE" ]; then
		SRC="$FNOS_IMAGE"
		if [ ! -f "$SRC" ]; then
			case "$SRC" in
			http*) say "下载官方镜像：$SRC"
			       curl -fL --retry 3 -o "$WORK/fnos-official.dl" "$SRC" || die "官方镜像下载失败" ;;
			*)     die "找不到官方镜像：$SRC" ;;
			esac
			# build-images.sh 靠扩展名决定要不要解压，而官方直链常带 query 参数或不带 .gz
			# → 一律按文件头魔数判断（1f 8b = gzip），避免把 .gz 当成裸整盘镜像去挂载
			SRC="$WORK/fnos-official.dl"
			if [ "$(head -c2 "$SRC" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
				mv -f "$SRC" "$WORK/fnos-official.img.gz"; SRC="$WORK/fnos-official.img.gz"
				say "   识别为 gzip 压缩镜像（$(stat -c %s "$SRC") 字节）"
			else
				mv -f "$SRC" "$WORK/fnos-official.img"; SRC="$WORK/fnos-official.img"
				say "   识别为未压缩整盘镜像（$(stat -c %s "$SRC") 字节）"
			fi
		fi
		say "从官方镜像构建 p2（约 10~20 分钟）：$SRC"
		$SUDO env OUT="$P1_DIR" WORK="$WORK/build" P2_BYTES=7508844544 "$FW/build-images.sh" p2 "$SRC" \
			| sed 's/^/   /' || die "p2 构建失败"
		P2_IMG="$P1_DIR/p2.img"
	else
		say "未提供 --p2 / --fnos-image：跳过 p2（只出引导链 + p1 + 救援线刷包）"
		DO_COMPACT=0
	fi
fi
if [ -n "$P2_IMG" ]; then
	P2_MD5=$(md5sum "$P2_IMG" | cut -d' ' -f1)
	say "p2  $(stat -c %s "$P2_IMG") 字节  md5 $P2_MD5"
fi

# ── 3b. 精简 p2（线刷包瘦身）：实测 6.99 GiB → 2.75 GiB ────────────────
P2_COMPACT=""
if [ -n "$P2_IMG" ] && [ "$DO_COMPACT" = 1 ]; then
	log "3b/7 精简 p2（供线刷包使用）"
	P2_COMPACT="$WORK/p2-compact.img"
	rm -f "$P2_COMPACT"
	if $SUDO "$FW/shrink-p2.sh" --src "$P2_IMG" --dst "$P2_COMPACT" 2>&1 | sed 's/^/   /'; then
		say "精简 p2 $(stat -c %s "$P2_COMPACT") 字节"
	else
		say "⚠️ 精简失败，退回整分区镜像打线刷包"
		P2_COMPACT=""
	fi
fi

# ── 4. dd 套装（低区 + p1 + 脚本 + 说明），解压即用 ─────────────────────
log "4/7 dd 刷入套装"
DDSET="$WORK/dd-set-$VERSION"; rm -rf "$DDSET"; mkdir -p "$DDSET"
cp "$LOW" "$DDSET/low-region.img";  md5sum "$DDSET/low-region.img" | sed 's# .*/# #' >"$DDSET/low-region.img.md5"
cp "$P1"  "$DDSET/p1.img";          md5sum "$DDSET/p1.img"         | sed 's# .*/# #' >"$DDSET/p1.img.md5"
cp -f "$FW/dd-flash.sh" "$DDSET/"; chmod +x "$DDSET/dd-flash.sh"
if [ -n "$P2_IMG" ]; then
	P2NOTE='> **p2 是独立资产**（体积大，不塞进这个 tar）：从 Releases 下载后放进本目录，即可三层一起刷：
>
>     # 下到的若是分卷（名字带 .part01/.part02…），先按序号合并；单文件则跳过这行
>     cat p2.img.gz.part* > p2.img.gz
>     gunzip -k p2.img.gz            # 得到 p2.img（约 7 GiB）
>
> 刷 p2 = 清空 fnOS 账号/共享/设置（这就是"重装系统"）；两块硬盘上的存储空间不受影响。'
else
	P2NOTE='> 本发布未包含 p2：请用 `firmware/build-images.sh p2 <官方 fnOS ARM 镜像>` 现场生成，
> 或从 Releases 下载 p2 资产，放到本目录后再刷。'
fi
cat >"$DDSET/README-刷机.md" <<EOF
# CM360 dd 刷机套装（fnOS $VERSION）

把本目录整个拷到板子上（板子需已能进系统），然后在板端执行：

    sudo ./dd-flash.sh --check      # 先只校验（镜像大小 / md5 / 目标设备）
    sudo ./dd-flash.sh              # 三层都刷：低区 + p1 + p2
    sudo ./dd-flash.sh --layers p1  # 只刷某一层（例如只换内核）

| 文件 | 是什么 | 目标 |
|---|---|---|
| low-region.img | 引导链：hwsetting + bootcode + FSBL + BL31 + **u-boot** + env | /dev/mmcblk0 起始 38 MiB |
| p1.img | 内核分区（ext4：Image-6.6.uimage + rtd1296-cm360.dtb） | /dev/mmcblk0p1 |
| p2.img | fnOS rootfs（btrfs，子卷 root） | /dev/mmcblk0p2 |

$P2NOTE

实测速度：低区 3.7 s / p1 1.7 s / p2 约 146 s。
EOF
( cd "$WORK" && tar -I "$GZ" -cf "$OUT/dd-set-cm360-$VERSION.tar.gz" "$(basename "$DDSET")" )
say "dd-set-cm360-$VERSION.tar.gz  $(stat -c %s "$OUT/dd-set-cm360-$VERSION.tar.gz") 字节（p2 单独分发）"

# ── 4b. trim-compat 独立资产（新镜像已内置；给“已经刷过旧镜像”的板子补救）──
log "4b/7 trim-compat 用户态兼容层（已刷机补救包）"
TCNAME="cm360-trim-compat-$VERSION"
TCDIR="$WORK/$TCNAME"
TCSRC="$REPO/boards/rtd1296-cm360/board-scripts/trim-compat"
[ -f "$TCSRC/install.sh" ] || die "缺 $TCSRC/install.sh"
[ -f "$TCSRC/libtrimcompat.so.aarch64" ] || die "缺预编译 $TCSRC/libtrimcompat.so.aarch64"
rm -rf "$TCDIR"; mkdir -p "$TCDIR"
cp -a "$TCSRC" "$TCDIR/trim-compat"
cat >"$TCDIR/README-安装.md" <<EOF
# CM360 fnOS 私有 ABI 用户态兼容层（$VERSION）

> **新刷机镜像（p2 / 线刷包）已经内置本兼容层，不需要单独安装这个包。**
> 本包用于：已经刷了旧镜像 / 官方 rootfs，并且出现下面症状的板子。

## 症状 → 本包修复

| 症状 | 根因 |
|---|---|
| 面板「文件」上传必失败，且 nginx 日志里没有 \`POST /upload\` | \`file.checkUpload\` 走厂商私有魔数 \`faccessat\`，stock 6.6.54 返回 EBADF |
| 共享文件夹建不出来，\`share_service\` 报 \`User N has no permission of ...\` | 同上 + \`system.trim_acl\` xattr 不被支持 |
| FTP 能登录但共享目录进不去/读写失败 | \`/fs\` 是厂商私有 trimafs 伪文件系统，自编译内核没有 |
| 面板删除一直转圈、回收站不可用、\`trim_trashbind\` 每 5 秒重启 | \`file.rm\` 走魔数 \`unlinkat\`，以及 \`/dev/trim-trashbin\` 只存在于厂商内核 |

## 安装（板端 root）

    tar xzf $TCNAME.tar.gz
    cd $TCNAME
    sudo ./trim-compat/install.sh          # 编译（无 gcc 用预编译 .so）+ 配置 + 重启相关服务
    # 卸载： sudo ./trim-compat/install.sh --uninstall

## 验证

    LD_LIBRARY_PATH=/usr/trim/lib \\
      LD_PRELOAD=/usr/local/lib/libtrimcompat.so \\
      /tmp/trim-access-test 1000 /vol1           # 应输出 = 0
    systemctl is-active trim_main share_service cm360-fake-fs
    # 面板：上传一个文件；删除一个文件 → 进回收站 → 还原

## 重新打包进镜像

本目录就是仓库 \`boards/rtd1296-cm360/board-scripts/trim-compat/\` 的完整副本；
\`firmware/build-images.sh\` 在生成 p2 时会自动 \`install.sh --stage\` 注入。
详见 \`docs/reports/fnos-acl-compat-layer.md\` 与 \`docs/reports/cm360-trim-compat-repair-report.md\`。
EOF
( cd "$WORK" && tar -I "$GZ" -cf "$OUT/$TCNAME.tar.gz" "$TCNAME" )
say "$TCNAME.tar.gz  $(stat -c %s "$OUT/$TCNAME.tar.gz") 字节"

# ── 5. 线刷包（Windows USB MP Tool / RTD-Flasher 格式）──────────────────
# 优先用**厂商官方工具链**（tools/lineflash/rtd129x_img_gen）：产物与手工发布的一致
# （低区当 FW_KERNEL 一起写、omv/factory.tar 恢复 u-boot env、MBR 对齐），
# 且两个包分别对应"精简 p2"和"完整 p2"。工具缺失时退回旧 python 打包器。
log "5/7 线刷包 install-*.img"
mkdir -p "$WORK/lineflash"
if [ -x "$LF_TOOL" ] && [ -n "$P2_IMG" ]; then
	say "用官方工具链：$LF_TOOL"
	if $SUDO "$FW/slim-p2.sh" --src "$P2_IMG" --out "$WORK/p2-slim.img" --size-mib 2000 2>&1 | sed 's/^/   /'; then
		say "精简 p2 $(stat -c %s "$WORK/p2-slim.img") 字节（< 2 GiB，厂商 32 位工具可载入）"
		bash "$REPO/tools/make-lineflash-official.sh" --tool "$LF_TOOL" --p1 "$P1_MBR" --p2 "$WORK/p2-slim.img" --lowregion "$LOW" --out "$WORK/lineflash/slim" --version "$VERSION" | sed 's/^/   /' || die "精简 p2 线刷包打包失败"
		mv -f "$WORK/lineflash/slim"/install-*.img "$OUT/install-cm360-fnos-$VERSION-slim-p2.img"
		bash "$REPO/tools/make-lineflash-official.sh" --tool "$LF_TOOL" --p1 "$P1_MBR" --p2 "$P2_IMG" --lowregion "$LOW" --full-p2 --out "$WORK/lineflash/full" --version "$VERSION" | sed 's/^/   /' || die "完整 p2 线刷包打包失败"
		mv -f "$WORK/lineflash/full"/install-*.img "$OUT/install-cm360-fnos-$VERSION-full-p2.img"
	else
		say "⚠️ 精简 p2 失败 → 退回旧 python 打包器"
		LF_TOOL=""
	fi
fi
if [ ! -x "${LF_TOOL:-/nonexistent}" ] || [ -z "$P2_IMG" ]; then
	LF_ARGS=(--out "$WORK/lineflash" --version "$VERSION"
	         --low "$LOW" --p1 "$P1"
	         --kernel "$REPO/artifacts/kernel-6.6.54/Image-6.6.uimage"
	         --dtb "$REPO/artifacts/kernel-6.6.54/rtd1296-cm360.dtb")
	python3 "$REPO/tools/make-lineflash-package.py" "${LF_ARGS[@]}" --with-lowregion --no-p2 | sed 's/^/   /'
	if [ -n "$P2_IMG" ]; then
		python3 "$REPO/tools/make-lineflash-package.py" "${LF_ARGS[@]}" --p2 "$P2_IMG" --with-lowregion | sed 's/^/   /'
		[ -n "$P2_COMPACT" ] && python3 "$REPO/tools/make-lineflash-package.py" "${LF_ARGS[@]}" --p2 "$P2_IMG" --p2-compact "$P2_COMPACT" --with-lowregion | sed 's/^/   /'
	fi
	for f in "$WORK/lineflash"/install-*.img; do
		[ -f "$f" ] || continue
		mv -f "$f" "$OUT/"
	done
fi
ls -la "$OUT"/install-*.img | awk '{printf "   %s  %.2f GiB\n",$9,$5/1073741824}'

# ── 6. p2 资产（体积大 → gzip + 必要时分卷）────────────────────────────
log "6/7 p2 资产（gzip + 分卷）"
split_asset() { # $1=文件
	local f="$1" name base
	name=$(basename "$f")
	if [ "$(stat -c %s "$f")" -le "$SPLIT_BYTES" ]; then return 0; fi
	base="$OUT/$name"
	rm -f "$base".part*
	split -b "$SPLIT_BYTES" -d --numeric-suffixes=1 --suffix-length=2 "$f" "$base.part"
	rm -f "$f"
	say "$name 超过 $((SPLIT_BYTES/1024/1024)) MiB → 分卷 $(ls "$OUT/$name".part* | wc -l) 个"
	say "   合并： cat $(basename "$base").part* > $(basename "$name")"
}
if [ -n "$P2_IMG" ]; then
	"$GZ" -6 -c "$P2_IMG" >"$OUT/p2.img.gz.tmp" && mv "$OUT/p2.img.gz.tmp" "$OUT/p2.img.gz"
	say "p2.img.gz  $(stat -c %s "$OUT/p2.img.gz") 字节"
	split_asset "$OUT/p2.img.gz"
fi
if [ -n "$P2_COMPACT" ]; then
	"$GZ" -6 -c "$P2_COMPACT" >"$OUT/p2-compact.img.gz.tmp" && mv "$OUT/p2-compact.img.gz.tmp" "$OUT/p2-compact.img.gz"
	say "p2-compact.img.gz  $(stat -c %s "$OUT/p2-compact.img.gz") 字节"
	split_asset "$OUT/p2-compact.img.gz"
fi
for f in "$OUT"/install-*.img; do [ -f "$f" ] && "$GZ" -6 -c "$f" >"$f.gz.tmp" && mv "$f.gz.tmp" "$f.gz" && rm -f "$f"; done
for f in "$OUT"/install-*.img.gz; do [ -f "$f" ] && split_asset "$f"; done
ls -la "$OUT" | awk 'NR>3{printf "   %12s  %s\n",$5,$9}'

# ── 7. 校验清单 + 资产说明（Release 正文）──────────────────────────────
if [ "${WORK#"$OUT"}" != "$WORK" ]; then
	say "⚠️ 中间目录在产物目录内（$WORK）—— 已改到 ${TMPDIR:-/var/tmp} 以免被当成资产上传"
	WORK="${TMPDIR:-/var/tmp}/cm360-release-work"
fi
log "7/7 校验清单与说明"
( cd "$OUT" && md5sum    $(find . -maxdepth 1 -type f ! -name 'MD5SUMS.txt' ! -name 'SHA256SUMS.txt' ! -name 'ASSETS.md' -printf '%f\n' | sort) >MD5SUMS.txt )
( cd "$OUT" && sha256sum $(find . -maxdepth 1 -type f ! -name 'MD5SUMS.txt' ! -name 'SHA256SUMS.txt' ! -name 'ASSETS.md' -printf '%f\n' | sort) >SHA256SUMS.txt )
python3 - "$OUT" "$VERSION" "$( [ -n "$P2_IMG" ] && echo yes || echo no )" >"$OUT/ASSETS.md" <<'PY'
import os, sys
out, ver, has_p2 = sys.argv[1], sys.argv[2], sys.argv[3] == "yes"
rows = [
    ("low-region-38MiB.img.gz", "**引导链（含 u-boot）**：hwsetting+bootcode+FSBL+BL31+u-boot+env，38 MiB",
     "dd 写 /dev/mmcblk0 起始；或线刷包已内置"),
    ("p1-256MiB.img.gz", "内核分区（ext4：Image-6.6.uimage + rtd1296-cm360.dtb，带 .bak 兜底）",
     "dd 写 /dev/mmcblk0p1"),
    (f"dd-set-cm360-{ver}.tar.gz", "dd 四件套：低区 + p1 + dd-flash.sh + 说明（解压即用）",
     "板内 `sudo ./dd-flash.sh`（**已验证路线**）"),
    (f"install-cm360-fnos-{ver}-boot-sysonly.img.gz*", "线刷包（**含引导链**，不含 p2）：低区 + MBR + p1",
     "Windows USB MP Tool（SW5 进下载模式）"),
    (f"cm360-trim-compat-{ver}.tar.gz",
     "fnOS 私有 ABI 用户态兼容层（上传/共享/回收站/FTP）。**新镜像已内置**；此包用于已刷旧镜像的补救",
     "板端解压后 `sudo ./trim-compat/install.sh`"),
]
if has_p2:
    rows += [
        ("p2.img.gz*", "fnOS rootfs 整分区镜像（btrfs，子卷 root）", "dd 写 /dev/mmcblk0p2"),
        ("p2-compact.img.gz*", "精简 rootfs（2.75 GiB，首启自动扩回分区大小）",
         "线刷包用；单独使用时需自行写入并扩容"),
        (f"install-cm360-fnos-{ver}-slim-p2.img.gz*",
         "**推荐**线刷包：低区 + MBR + p1 + **精简 rootfs（2.0 GiB）** + factory.tar（解压约 2.24 GiB，首启自动扩回 7 GiB）",
         "RTD-Flasher / 厂商 USB MP Tool（≈7 分钟）"),
        (f"install-cm360-fnos-{ver}-full-p2.img.gz*",
         "功能完整线刷包：低区 + MBR + p1 + **完整 rootfs（7.0 GiB）** + factory.tar（解压约 7.28 GiB）",
         "**只能**用 64 位 RTD-Flasher（厂商 32 位工具载入会崩）"),
        (f"install-cm360-fnos-{ver}-boot-full.img.gz*", "线刷包（含引导链 + p2）",
         "Windows USB MP Tool（**最省事**，连 u-boot 一起刷）"),
        (f"install-cm360-fnos-{ver}-boot-compact-full.img.gz*", "线刷包（含引导链 + 精简 p2，体积约 1/2.4）",
         "Windows USB MP Tool"),
    ]
print("# CM360 刷机镜像 v" + ver)
print()
print("fnOS **%s** + 自编译 **Linux 6.6.54**（含 fnOS 1.2 兼容补丁）。" % ver)
print()
print("> 文件名带 `*` 的可能是**分卷**（单一文件超过 GitHub 2 GiB 限制）——")
print("> 先按序号下载全部 `.partNN`，再 `cat 文件名.part* > 文件名` 合并即可。")
print()
print("## 资产清单")
print()
print("| 文件 | 是什么 | 怎么用 |")
print("|---|---|---|")
for name, what, how in rows:
    if os.path.exists(os.path.join(out, name)) or any(
            f.startswith(name.rstrip('*')) for f in os.listdir(out)):
        print(f"| `{name}` | {what} | {how} |")
print()
print("## 三条刷机路线")
print()
print("| 路线 | 需要 | 状态 |")
print("|---|---|---|")
print("| **dd（板内直刷）** | 板子能进系统 + `dd-set` 套装 | ✅ 端到端实测（低区 3.7s / p1 1.7s / p2 146s） |")
print("| u-boot（TFTP / U 盘） | 能进 u-boot（开机 3 秒窗口） | ✅ 实测通过 |")
print("| **Windows USB MP Tool（线刷）** | Windows + SW5 进 USB 下载模式 | ⚠️ 包格式逆向自厂商包，**工具接受度未实测** |")
print()
print("## 校验")
print()
print("```sh")
print("md5sum -c MD5SUMS.txt          # 或 sha256sum -c SHA256SUMS.txt")
print("```")
print()
print("## 不含什么")
print()
print("厂商版权物（原厂固件、fnOS 官方镜像、`kylin_usb_mp_tools`）**不随本发布分发**，")
print("请自行从官方渠道获取；p2 也可用 `firmware/build-images.sh p2 <官方镜像>` 现场生成。")
PY
log "完成"
say "产物目录：$OUT"
ls -la "$OUT" | awk 'NR>3{printf "   %12s  %s\n",$5,$9}'
say ""
say "Release 正文：$OUT/ASSETS.md"
say "上传（CI 里用 GITHUB_TOKEN，本地需 gh 登录）："
say "  gh release create v$VERSION $OUT/* --notes-file $OUT/ASSETS.md --title \"CM360 刷机镜像 v$VERSION\""
