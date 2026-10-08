#!/bin/bash
# fnos-kernel-compat.sh —— 让 **fnOS 1.2.x** 在**自编译 Linux 6.6.54 内核**上正常工作（板端执行）
#
# 背景
# ----
# fnOS 1.2.x 的部分用户态是按它自带的 **6.18 内核**设计的，其中若干处依赖
# 厂商给内核打的私有补丁。自编译内核（本仓库的 6.6.54）没有这些补丁时，
# 会出现「存储空间创建失败 / 显示未挂载」「面板服务不开机自启」等现象：
#
#   ① mdadm 4.5 建阵列时传 --bitmap=lockless（6.7+ 内核特性）
#      → 建阵列必失败；且每次失败在内核留下 state=clear 的同名 md 设备，
#        导致后续重试永远报 File exists（面板只说"无法创建"）。
#      → 处理：mdadm 兼容层把 lockless 降级为等价的 internal。
#
#   ② fnOS 挂存储时传私有挂载选项 -o trimacl,prjquota
#      → 6.6 的 btrfs/ext4 不认识就直接拒绝挂载（日志：unrecognized mount option）
#        → 存储空间永远"未挂载"。
#      → 处理：**内核补丁** patches/0007（btrfs）、patches/0008（ext4）接受这些选项。
#        本脚本会做一次功能自检（见 --status）。
#
#   ③ fnOS 的 fast_resync_md_raid 依赖 lockless bitmap 的 md 接口
#      → 失败会让"创建存储空间"整个流程中止。
#      → 处理：对该工具做 no-op 兼容层（跳过全量同步，新阵列安全）。
#
#   ④ fnOS 的自定义文件系统类型 trimafs（-t trimafs 挂 /fs，其 ACL v2 用）
#      → 内核没有该类型，triminit 的初始化链会中断，导致 trim_* 服务开机不自启
#        （表现为：板子能 ping 通、但面板打不开）。
#      → 处理：装一个开机兜底单元，在 PostgreSQL 就绪后幂等地拉起这些服务。
#        该特性是**功能缺失**（细粒度 ACL 不生效），但存储/共享/面板均正常。
#
# 用法（板端 root）
#   ./fnos-kernel-compat.sh            # 安装全部兼容层
#   ./fnos-kernel-compat.sh --status   # 查看当前状态与内核补丁功能自检
#   ./fnos-kernel-compat.sh --remove   # 移除兼容层（恢复原文件）
#
# 前提：内核须用本仓库的补丁构建（scripts/build-kernel.sh 会自动 apply
#       patches/0007-*、patches/0008-*）。镜像必须打成 uImage 再部署，
#       直接拷裸 Image 会掉进 u-boot 提示符（u-boot 2015.07 只认 uImage/FIT）。
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
MDADM=/usr/trim/bin/mdadm
MDADM_REAL=/usr/trim/bin/mdadm.real
FAST=/usr/trim/bin/fast_resync_md_raid
FAST_REAL=/usr/trim/bin/fast_resync_md_raid.real
BOOT_UNIT=/etc/systemd/system/cm360-trim-boot.service
LOG=/var/log/mdadm-compat.log

need_root() { [ "$(id -u)" = 0 ] || { echo "请用 sudo 运行" >&2; exit 1; }; }

# ── ① mdadm：lockless → internal ─────────────────────────────────────────
install_mdadm() {
	[ -x "$MDADM_REAL" ] || mv "$MDADM" "$MDADM_REAL"
	cat >"$MDADM" <<'EOF'
#!/bin/bash
# CM360 兼容层：fnOS 1.2.x 建存储时传 --bitmap=lockless，
# 但本内核（Linux 6.6.54）不具备 lockless bitmap 支持（上游 6.7+ 才有），
# mdadm 4.5 遇到不支持会静默失败（面板只显示"无法创建"），且失败会在内核里
# 留下 state=clear 的同名 md 设备，导致后续重试必然报 File exists。
# 这里把 lockless 降级为等价的 internal 写意图位图（任何内核都支持）。
# 原二进制在 /usr/trim/bin/mdadm.real，可一键还原。
REAL=/usr/trim/bin/mdadm.real
args=(); changed=0
while [ $# -gt 0 ]; do
  a="$1"; shift
  if [ "$a" = "--bitmap=lockless" ]; then
    a="--bitmap=internal"; changed=1
  elif [ "$a" = "--bitmap" ] && [ "${1:-}" = "lockless" ]; then
    a="--bitmap=internal"; shift; changed=1
  fi
  args+=("$a")
done
[ "$changed" = 1 ] && echo "$(date "+%F %T") lockless -> internal: ${args[*]}" >> /var/log/mdadm-compat.log
exec "$REAL" "${args[@]}"
EOF
	chmod 755 "$MDADM"
	# 清掉历史失败留下的空 md 设备
	for d in /sys/block/md*; do
		[ -d "$d" ] || continue
		i=$(basename "$d" | sed 's/md//')
		mknod "/dev/md$i" b 9 "$i" 2>/dev/null
		"$MDADM_REAL" --stop "/dev/md$i" >/dev/null 2>&1
		rm -f "/dev/md$i"
	done
	echo "  ✔ mdadm 兼容层（lockless → internal），并清理了残留 md 设备"
}

# ── ③ fast_resync_md_raid：跳过首次全量同步 ──────────────────────────────
install_fast() {
	[ -x "$FAST_REAL" ] || mv "$FAST" "$FAST_REAL"
	cat >"$FAST" <<'EOF'
#!/bin/bash
# CM360 兼容层：fnOS 建存储后调用本工具做"快速重同步"（原版会清盘头尾 8MB +
# mdadm --add，依赖较新内核的 md 接口）。原版失败会让创建流程整体中止。
# 兼容做法：把新建阵列的首次同步置为 idle —— 新阵列两个成员都是刚分区的空盘，
# 跳过全量同步是安全的；否则 931G 全量同步要 ~95 分钟，创建流程会超时。
MD="$1"
B=$(basename "${MD:-}")
SA="/sys/block/$B/md/sync_action"
if [ -n "$B" ] && [ -w "$SA" ]; then
  before=$(cat "$SA" 2>/dev/null)
  echo idle > "$SA" 2>/dev/null && \
    echo "$(date "+%F %T") fast_resync: $B 首次同步 $before -> idle" >> /var/log/mdadm-compat.log
fi
exit 0
EOF
	chmod 755 "$FAST"
	echo "  ✔ fast_resync_md_raid 兼容层（跳过首次全量同步）"
}

# ── ④ 开机兜底：保证 trim_* 服务被拉起 ───────────────────────────────────
install_boot() {
	cat >"$BOOT_UNIT" <<'EOF'
[Unit]
Description=CM360: ensure fnOS services start after PostgreSQL (6.6 kernel, no trimafs)
# 本内核没有 fnOS 的 trimafs 文件系统类型，triminit 的初始化链会在此处中断，
# 导致 trim_* 服务开机时不被拉起（表现：网络通、但面板打不开）。
# 这里做一次幂等的兜底启动。移除本单元即可恢复原行为。
After=postgresql.service network-online.target
Wants=postgresql.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "for s in trim_main trim_sac trim_nginx filestor_service trim_sharelink trim_diskpowerd; do systemctl is-active --quiet $s || systemctl start $s; done"
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now cm360-trim-boot.service >/dev/null 2>&1
	echo "  ✔ 开机兜底单元 cm360-trim-boot.service（已启用）"
}

# ── ② 内核补丁的功能自检 ────────────────────────────────────────────────
check_kernel() {
	echo "  内核: $(uname -r)"
	local ok=0
	# 找一个已挂载的 fnOS 存储卷做真实挂载测试（只读、临时目录、用完即卸）
	local lv
	lv=$(ls -1 /dev/mapper/trim_*-0 2>/dev/null | head -1)
	if [ -n "$lv" ]; then
		local t; t=$(mktemp -d)
		if mount -o ro,trimacl,prjquota "$lv" "$t" 2>/dev/null; then
			echo "  ✔ 内核接受 fnOS 私有挂载选项（trimacl/prjquota）—— 存储可自动挂载"
			umount "$t"; ok=1
		else
			echo "  ✗ 内核仍拒绝 trimacl/prjquota —— 请用含 patches/0007+0008 的内核"
			echo "     （构建：scripts/build-kernel.sh；部署前务必打包 uImage）"
		fi
		rmdir "$t" 2>/dev/null
	else
		echo "  ? 当前没有 trim_* 存储卷，跳过挂载自检"
	fi
	echo "  存储挂载情况:"
	findmnt -n -o TARGET,SOURCE,FSTYPE | grep -E "vol[0-9]" | sed 's/^/    /' || echo "    （无）"
	echo "  面板服务: $(systemctl is-active trim_nginx 2>/dev/null) / $(systemctl is-active trim_main 2>/dev/null)"
	[ "$ok" = 1 ] || true
}

case "${1:-}" in
--status)
	check_kernel
	echo "  mdadm 兼容层: $(grep -q 'lockless -> internal' "$MDADM" 2>/dev/null && echo 已装 || echo 未装)"
	echo "  fast_resync 兼容层: $(grep -q '首次同步' "$FAST" 2>/dev/null && echo 已装 || echo 未装)"
	echo "  开机兜底单元: $(systemctl is-enabled cm360-trim-boot.service 2>/dev/null || echo 未装)"
	echo "  最近兼容层日志:"; tail -3 "$LOG" 2>/dev/null | sed 's/^/    /'
	;;
--remove)
	[ -x "$MDADM_REAL" ] && mv -f "$MDADM_REAL" "$MDADM"
	[ -x "$FAST_REAL" ] && mv -f "$FAST_REAL" "$FAST"
	systemctl disable --now cm360-trim-boot.service >/dev/null 2>&1
	rm -f "$BOOT_UNIT"; systemctl daemon-reload
	echo "已移除全部兼容层"
	;;
"")
	need_root
	echo "==== 安装 fnOS 1.2.x on Linux 6.6.54 兼容层 ===="
	install_mdadm
	install_fast
	install_boot
	echo
	check_kernel
	echo
	echo "完成。存储空间现在应能在开机时自动挂载，面板也会自动启动。"
	;;
*)
	echo "用法: $0 [--status|--remove]" >&2; exit 1 ;;
esac
