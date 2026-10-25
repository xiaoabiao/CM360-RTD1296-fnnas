#!/bin/bash
# cm360-fake-fs.sh —— 用「普通目录 + bind mount」模拟 fnOS 私有 trimafs 的 /fs 视图
#
# 背景（见 docs/reports/fnos-6.18-kernel-re/USERSPACE-trimafs.md）：
#   fnOS 的 FTP/WebDAV/NFS 共享通过 /fs/<uid>/<proto>/<share> 暴露，
#   条目是 share_service 用 symlink(2) 建的符号链接，指向真实路径 /volN/...。
#   正常情况下 /fs 是厂商私有 trimafs 伪文件系统（shmem 改造），自编译内核没有。
#   直接 mkdir /fs 只能让符号链接建出来，但 FTP 的 ChrootSet 是 /fs/<uid>/ftp，
#   绝对符号链接 /volN/... 在 chroot 里解析不到 → 列目录空、读写失败。
#
# 本脚本的处理：
#   1) 确保 /fs 存在（普通目录）；
#   2) 在每条协议根目录里把 /volN/<uid> 与 /volN/@team bind 进来，
#      于是 chroot 内的绝对符号链接 /volN/<uid>/... 能正确解析；
#   3) 以守护模式每 5 秒对账一次（新用户/新共享/新协议目录自动补挂载）。
#
# 用法：
#   cm360-fake-fs.sh once      # 只做一次（给 share_service 的 ExecStartPre 用）
#   cm360-fake-fs.sh daemon    # 循环对账（systemd 服务）
#   cm360-fake-fs.sh status    # 打印当前 /fs 与挂载
#
# 注意：只 bind 用户自己的子树和 @team，避免把同卷其它用户的目录暴露进 FTP chroot。
set -u

LOGTAG=cm360-fake-fs
log() { logger -t "$LOGTAG" -- "$*" 2>/dev/null || true; }

ensure_fs() {
	if [ ! -d /fs ]; then
		mkdir -p /fs || return 1
		chmod 755 /fs
		log "created /fs"
	fi
}

# 把 $src 挂到 $dst（不存在就建目录；已经是挂载点就跳过）
bind_one() {
	src=$1 dst=$2
	[ -d "$src" ] || return 0
	mkdir -p "$dst" 2>/dev/null || return 0
	if mountpoint -q "$dst" 2>/dev/null; then
		return 0
	fi
	mount --bind "$src" "$dst" 2>/dev/null && log "bind $src -> $dst"
}

reconcile() {
	ensure_fs || return 0
	# /fs/<uid>/<proto>  （uid 必须是数字；proto 由 share_service 创建：ftp/webdav/nfs/smb…）
	for d in /fs/[0-9]*/*; do
		[ -d "$d" ] || continue
		uid=$(basename "$(dirname "$d")")
		case "$uid" in ''|*[!0-9]*) continue ;; esac
		for vol in /vol[0-9]*; do
			[ -d "$vol" ] || continue
			vn=$(basename "$vol")
			# 绝对符号链接 /volN/<uid>/... 在 chroot 内会解析到 <chroot>/volN/<uid>/...
			bind_one "$vol/$uid" "$d/$vn/$uid"
			# 团队空间 /volN/@team/<share>/...
			bind_one "$vol/@team" "$d/$vn/@team"
			# 卷这一层只是给符号链接解析用的「跳板」：只给 x 不给 r，
			# 让 FTP 根目录里看不到整卷内容（名字仍会出现，进去会被拒绝）。
			if [ -d "$d/$vn" ] && ! mountpoint -q "$d/$vn" 2>/dev/null; then
				chmod 0111 "$d/$vn" 2>/dev/null || true
			fi
		done
	done
}

status() {
	echo "== /fs =="
	[ -d /fs ] && find /fs -maxdepth 3 -printf '%M %u %g %p -> %l\n' 2>/dev/null | head -40 || echo "missing"
	echo "== binds =="
	mount | grep -E ' on /fs/' | head -40
}

case "${1:-once}" in
once) reconcile ;;
daemon)
	ensure_fs
	while :; do reconcile; sleep 5; done
	;;
status) status ;;
*) echo "usage: $0 {once|daemon|status}" >&2; exit 2 ;;
esac
