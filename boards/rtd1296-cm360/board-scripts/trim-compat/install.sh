#!/bin/bash
# install.sh —— CM360 上 fnOS 私有内核 ABI 的用户态兼容层（安装 / 卸载 / 打包注入）
#
# 背景（详见 docs/reports/fnos-acl-compat-layer.md 与 fnos-trashbin-re.md）：
#   fnOS 1.2.x 用户态依赖厂商内核私有接口，自编译 6.6.54 没有它们，导致：
#     - 面板「文件」上传必失败（file.checkUpload 返回 errno 9）
#     - SMB/WebDAV/FTP 共享文件夹建不出来
#     - FTP 共享目录进不去（/fs 是私有 trimafs）
#     - 面板删除一直转圈、回收站不可用、trim_trashbind 无限重启
#   本目录的兼容层在用户态补齐：魔数 faccessat、system.trim_acl xattr、
#   魔数 unlinkat（回收站/删除）、/fs（普通目录 + bind mount）。
#
# 用法：
#   sudo ./install.sh                    # 板端安装：编译（无 gcc 用预编译 .so）+ 配置 + 重启服务
#   sudo ./install.sh --log              # 同上，额外写调试日志 /tmp/trimcompat.log
#   sudo ./install.sh --uninstall        # 完整卸载（恢复 trim_trashbind / 移除 drop-in 等）
#   ./install.sh --stage <rootfs>        # 【刷机镜像构建用】把兼容层注入一个**未启动的 rootfs 目录**
#                                        #   不执行 systemctl、不需要 gcc（用预编译 aarch64 .so）
#
# 适用服务：trim_main / trim_upload / filestor_service / trim_http_cgi /
#           share_service / trim_trashbind（rootfs 里存在才装）
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX=/usr/local/lib
LIB="$PREFIX/libtrimcompat.so"
BUNDLE="$PREFIX/trim-compat"          # 板上留一份源码+安装脚本，便于升级后重装
# 适用服务：凡是链接 fnOS 私有库（libtrimacl/libnperm/libnfile/libquota）或用魔数
# 接口的 fnOS 服务都要覆盖。除了上传/共享主链路，**trim_app_center 也必须覆盖**：
# 应用中心给应用「推荐存储空间权限」时会用 trimacl_get_file/trimacl_set_file 写 ACL，
# 不覆盖时面板报 “Request failed, please try again later”(HTTP 500)。
SERVICES=(trim_main trim_upload filestor_service trim_http_cgi share_service \
          trim_app_center trim_trashbind \
          finder_service imagesrv eventlogger_service sysinfo_service \
          sysrestore_service backup_service dlcenter multiple-downloads \
          trim-sharelink trim_open_gateway)
LOG=${TRIMCOMPAT_LOG:-/tmp/trimcompat.log}
USE_LOG=0
ACTION=install
STAGE_ROOTFS=""

die() { echo "!! $*" >&2; exit 1; }

for arg in "$@"; do
	case "$arg" in
	--uninstall) ACTION=uninstall ;;
	--log) USE_LOG=1 ;;
	--stage) ACTION=stage ;;
	-h|--help) sed -n '2,28p' "$0"; exit 0 ;;
	*)
		if [ "$ACTION" = stage ] && [ -z "$STAGE_ROOTFS" ]; then
			STAGE_ROOTFS="$arg"
		else
			die "unknown arg: $arg"
		fi
		;;
	esac
done

# 把源码/脚本/预编译 .so 留一份到 <prefix>/trim-compat（$1 = 目标前缀，如 / 或 rootfs）
install_bundle() {
	local dst="$1/usr/local/lib/trim-compat"
	# 如果是从目标里自己的副本在跑（升级后重装），跳过自拷贝
	if [ -d "$dst" ] && [ "$(cd "$HERE" 2>/dev/null && pwd -P)" = "$(cd "$dst" 2>/dev/null && pwd -P)" ]; then
		return 0
	fi
	install -d -m 0755 "$dst" || return 1
	for f in install.sh trimcompat.c trash-ref.c trim-access-test.c \
	         cm360-fake-fs.sh cm360-fake-fs.service README.md; do
		[ -f "$HERE/$f" ] || continue
		install -m 0644 "$HERE/$f" "$dst/$f"
	done
	[ -f "$HERE/install.sh" ] && chmod 0755 "$dst/install.sh"
	[ -f "$HERE/cm360-fake-fs.sh" ] && chmod 0755 "$dst/cm360-fake-fs.sh"
	[ -f "$HERE/libtrimcompat.so.aarch64" ] && \
		install -m 0644 "$HERE/libtrimcompat.so.aarch64" "$dst/libtrimcompat.so.aarch64"
	return 0
}

# 生成给某个服务用的 drop-in（$1=根目录前缀 $2=服务名）
write_override() {
	local root="$1" s="$2" d unit
	d="$root/etc/systemd/system/$s.service.d"
	install -d -m 0755 "$d" || return 1
	{
		echo "[Service]"
		echo "Environment=LD_PRELOAD=/usr/local/lib/libtrimcompat.so"
		[ "$USE_LOG" = 1 ] && echo "Environment=TRIMCOMPAT_LOG=$LOG"
		# share_service 启动前先保证 /fs 存在（否则建共享符号链接必失败）
		if [ "$s" = share_service ]; then
			echo "ExecStartPre=/usr/local/lib/cm360-fake-fs.sh once"
		fi
	} >"$d/override.conf"
}

# 服务在 rootfs 里是否存在（unit 可能位于三个路径之一）
unit_exists() {
	local root="$1" s="$2"
	[ -f "$root/etc/systemd/system/$s.service" ] || \
	[ -f "$root/lib/systemd/system/$s.service" ] || \
	[ -f "$root/usr/lib/systemd/system/$s.service" ]
}

# ── 模式 A：stage（给 firmware/build-images.sh 用，注入未启动的 rootfs 目录）──
if [ "$ACTION" = stage ]; then
	[ -n "$STAGE_ROOTFS" ] || die "用法: $0 --stage <rootfs目录>"
	ROOTFS="${STAGE_ROOTFS%/}"
	[ -d "$ROOTFS/etc" ] || die "--stage: $ROOTFS 不像一个 rootfs（缺 etc/）"
	command -v install >/dev/null 2>&1 || die "缺少 install 命令"
	[ -f "$HERE/libtrimcompat.so.aarch64" ] || die "缺 $HERE/libtrimcompat.so.aarch64（预编译 aarch64 .so）"

	echo "   [trim-compat] 注入 rootfs: $ROOTFS"
	install -d -m 0755 "$ROOTFS/usr/local/lib"
	# 1) 运行期 .so（预编译 aarch64，构建主机不需要 gcc/交叉工具链）
	install -m 0644 "$HERE/libtrimcompat.so.aarch64" "$ROOTFS$LIB"
	# 2) 源码/脚本留档（升级后可在板上重跑 install.sh）
	install_bundle "$ROOTFS" || die "install_bundle 失败"
	# 3) /fs 兼容（普通目录 + bind mount）
	install -m 0755 "$HERE/cm360-fake-fs.sh" "$ROOTFS/usr/local/lib/cm360-fake-fs.sh"
	install -d -m 0755 "$ROOTFS/etc/systemd/system"
	install -m 0644 "$HERE/cm360-fake-fs.service" "$ROOTFS/etc/systemd/system/cm360-fake-fs.service"
	install -d -m 0755 "$ROOTFS/etc/systemd/system/multi-user.target.wants"
	ln -sfn ../cm360-fake-fs.service \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/cm360-fake-fs.service"
	echo "     ✔ libtrimcompat.so + cm360-fake-fs.service（已 enable）"
	# 4) 给相关服务加 LD_PRELOAD drop-in
	local_n=0
	for s in "${SERVICES[@]}"; do
		unit_exists "$ROOTFS" "$s" || continue
		write_override "$ROOTFS" "$s" || die "写 $s drop-in 失败"
		local_n=$((local_n + 1))
		echo "     + $s"
	done
	echo "     ✔ $local_n 个服务 drop-in"
	# 5) trim_trashbind 不再需要：去掉开机 enable 的软链（unit 文件保留，便于 --uninstall 恢复）
	#    注意要兼容“断链”（wants 里的相对软链在 rootfs 未挂载时可能 -e 为假）
	for w in "$ROOTFS"/etc/systemd/system/*.wants/trim_trashbind.service; do
		if [ -e "$w" ] || [ -L "$w" ]; then
			rm -f "$w"
			echo "     - 关闭 trim_trashbind 开机自启"
		fi
	done
	# 6) 留一份注入清单，便于排查/核对
	{
		echo "# cm360 trim-compat staged rootfs manifest"
		echo "libtrimcompat.so:  usr/local/lib/libtrimcompat.so"
		echo "bundle:            usr/local/lib/trim-compat/"
		echo "fake-fs script:    usr/local/lib/cm360-fake-fs.sh"
		echo "fake-fs unit:      etc/systemd/system/cm360-fake-fs.service"
		echo "fake-fs enabled:   etc/systemd/system/multi-user.target.wants/cm360-fake-fs.service"
		for s in "${SERVICES[@]}"; do
			unit_exists "$ROOTFS" "$s" && \
				echo "drop-in:           etc/systemd/system/$s.service.d/override.conf"
		done
		echo "trim_trashbind:    disabled in image (no .wants symlink)"
	} >"$ROOTFS/usr/local/lib/trim-compat/MANIFEST.txt"
	echo "   [trim-compat] 完成（清单: /usr/local/lib/trim-compat/MANIFEST.txt）"
	exit 0
fi

# ── 模式 B：卸载（板端）──
if [ "$ACTION" = uninstall ]; then
	[ "$(id -u)" = 0 ] || die "需要 root（sudo）"
	# 先停 /fs 兼容服务并卸掉它建的 bind mount
	systemctl disable --now cm360-fake-fs 2>/dev/null || true
	for m in $(mount | awk '$3 ~ /^\/fs\// {print $3}'); do
		umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
	done
	rm -f /etc/systemd/system/cm360-fake-fs.service /usr/local/lib/cm360-fake-fs.sh
	rm -f /etc/systemd/system/multi-user.target.wants/cm360-fake-fs.service
	systemctl enable trim_trashbind >/dev/null 2>&1 || true
	for s in "${SERVICES[@]}"; do
		d=/etc/systemd/system/$s.service.d
		if [ -f "$d/override.conf" ] && grep -q libtrimcompat "$d/override.conf"; then
			rm -f "$d/override.conf"
			rmdir "$d" 2>/dev/null || true
			echo "  - 移除 $s 的兼容层配置"
		fi
	done
	systemctl daemon-reload
	for s in "${SERVICES[@]}"; do
		systemctl is-enabled "$s" >/dev/null 2>&1 && systemctl restart "$s" 2>/dev/null
	done
	rm -f "$LIB" /tmp/trimcompat.c
	rm -rf "$BUNDLE"
	echo "已卸载 libtrimcompat.so / cm360-fake-fs 并重启服务"
	exit 0
fi

# ── 模式 C：板端安装 ──
[ "$(id -u)" = 0 ] || die "需要 root（sudo）"

# ---- 1. 编译（板上有 gcc 时现场编译；否则用同目录预编译 .so）----
if command -v gcc >/dev/null 2>&1; then
	echo "== 编译 trimcompat.c + trash-ref.c =="
	gcc -shared -fPIC -O2 -Wall -Wl,--no-undefined -o "$LIB.tmp" \
		"$HERE/trimcompat.c" "$HERE/trash-ref.c" -ldl || {
		echo "!! 编译失败" >&2; exit 1; }
	# 自检：能被动态链接器加载（漏符号会在这一步直接暴露，而不是运行期崩服务）
	LD_PRELOAD="$LIB.tmp" /bin/true 2>/dev/null || {
		echo "!! $LIB.tmp 加载失败（未定义符号？）" >&2; exit 1; }
else
	echo "== 板上无 gcc，使用预编译 $HERE/libtrimcompat.so.aarch64 =="
	[ -f "$HERE/libtrimcompat.so.aarch64" ] || \
		die "既无 gcc 也无预编译 .so，请在开发机交叉编译后拷入"
	cp -f "$HERE/libtrimcompat.so.aarch64" "$LIB.tmp"
fi
install -m 0644 "$LIB.tmp" "$LIB"
rm -f "$LIB.tmp"
echo "   -> $LIB"
install_bundle "" || die "install_bundle 失败"
echo "   -> $BUNDLE（源码/脚本留档，升级后可重跑）"

# ---- 2. 安装「假 /fs」（trimafs 兼容：普通目录 + bind mount，修 FTP/WebDAV 共享视图）----
if [ -f "$HERE/cm360-fake-fs.sh" ] && [ -f "$HERE/cm360-fake-fs.service" ]; then
	install -m 0755 "$HERE/cm360-fake-fs.sh" /usr/local/lib/cm360-fake-fs.sh
	install -m 0644 "$HERE/cm360-fake-fs.service" /etc/systemd/system/cm360-fake-fs.service
	systemctl daemon-reload
	systemctl enable --now cm360-fake-fs >/dev/null 2>&1 || true
	echo "  + cm360-fake-fs.service（/fs 兼容层）"
fi

# ---- 3. 给相关服务加 LD_PRELOAD ----
mkdir -p /etc/systemd/system
for s in "${SERVICES[@]}"; do
	unit_exists "" "$s" || continue
	write_override "" "$s" || die "写 $s drop-in 失败"
	echo "  + $s"
done
systemctl daemon-reload

# ---- 4. 重启服务（按依赖顺序）----
systemctl restart cm360-fake-fs 2>/dev/null || true
for s in trim_main trim_upload filestor_service trim_http_cgi share_service; do
	systemctl is-enabled "$s" >/dev/null 2>&1 && systemctl restart "$s" && echo "  ↻ $s"
done
# 其余也要带上新 drop-in 的服务（应用中心 / 备份 / 下载等）
for s in "${SERVICES[@]}"; do
	case "$s" in
	trim_main|trim_upload|filestor_service|trim_http_cgi|share_service|trim_trashbind) continue ;;
	esac
	if systemctl is-enabled "$s" >/dev/null 2>&1; then
		systemctl restart "$s" 2>/dev/null && echo "  ↻ $s"
	fi
done
# trim_trashbind 是 Restart=always 的短命服务，重启一次即会带上环境变量；
# 但回收站现在由兼容层在用户态完成，它不再需要（它依赖的 /dev/trim-trashbin
# 字符设备只存在于厂商内核），停用它可以消掉每 5s 一次的失败重启日志。
systemctl restart trim_trashbind 2>/dev/null || true
if systemctl disable --now trim_trashbind >/dev/null 2>&1; then
	echo "  - trim_trashbind（回收站已由兼容层接管，服务停用）"
fi

sleep 2
echo
echo "== 自检 =="
TESTBIN=/tmp/trim-access-test
if command -v gcc >/dev/null 2>&1 && [ -f "$HERE/trim-access-test.c" ]; then
	gcc -O2 -o "$TESTBIN" "$HERE/trim-access-test.c" -L/usr/trim/lib -lnperm 2>/dev/null && \
		LD_LIBRARY_PATH=/usr/trim/lib LD_PRELOAD="$LIB" "$TESTBIN" 1000 /vol1
elif [ -x "$HERE/trim-access-test" ]; then
	LD_LIBRARY_PATH=/usr/trim/lib LD_PRELOAD="$LIB" "$HERE/trim-access-test" 1000 /vol1
fi
systemctl is-active --quiet trim_main && echo "  trim_main: active"
systemctl is-active --quiet share_service && echo "  share_service: active"
systemctl is-active --quiet cm360-fake-fs && echo "  cm360-fake-fs: active（/fs 兼容层）"
curl -s -o /dev/null -w "  面板 HTTP: %{http_code}\n" http://127.0.0.1:5666/ || true
echo
echo "安装完成。面板「文件」上传/删除、SMB 共享、FTP 共享目录都应恢复正常。"
echo "如需日志：加 --log 重装后 tail -f $LOG"
