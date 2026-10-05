#!/bin/sh
# mdadm-lockless-compat.sh —— 修 "fnOS 1.2.x 建存储报错无法创建"（板端执行）
#
# 症状
# ----
# 面板里创建存储空间失败，只说"无法创建"；服务日志（journalctl -u trim_main）里是：
#   [MDADM ERROR] mdadm: Fail to create mdN when using
#                 /sys/module/md_mod/parameters/new_array, fallback to creation via node
#   [ERROR] md_create failed: /dev/mdN
#   [RETRY] Create storage retry times: N   （会重试 10 次，每次都失败）
#
# 真因（实测定位）
# ----------------
# fnOS 1.2.x 自带 mdadm 4.5，建阵列时显式传 `--bitmap=lockless`
# （v4.5 才有的"无锁写意图位图"，上游内核 6.7+ 才支持）。
# 本板内核是自编译的 6.6.54，**没有这个特性** → mdadm 打印
# "Experimental lockless bitmap, use at your own disk!" 后**静默失败**（退出码 1）。
# 两个后果：
#   1) 面板显示"无法创建"；
#   2) 每次失败会在内核里留下一个 state=clear 的同名 md 设备（md0/md1/...），
#      于是后续重试在写 new_array 时**必然**报 `File exists` → 永久失败。
#
# 修法
# ----
# 在 fnOS 调用 mdadm 的路径上加一层透明兼容层：把 `--bitmap=lockless` 换成
# 等价的 `--bitmap=internal`（写意图位图，任何内核都支持，重同步行为等价）。
# 原二进制保留为 mdadm.real，`--remove` 一键还原。
#
# 用法：  sudo sh mdadm-lockless-compat.sh           # 安装兼容层
#         sudo sh mdadm-lockless-compat.sh --remove  # 还原
#         sudo sh mdadm-lockless-compat.sh --status  # 查看当前状态
set -eu

REAL=/usr/trim/bin/mdadm.real
WRAP=/usr/trim/bin/mdadm
LOG=/var/log/mdadm-compat.log

clean_leftovers() {
	# 清掉失败重试遗留的 state=clear 空 md 设备，否则下次仍然 File exists
	for d in /sys/block/md*; do
		[ -d "$d" ] || continue
		i=$(basename "$d" | sed 's/md//')
		[ -x "$REAL" ] && "$REAL" --stop "/dev/md$i" >/dev/null 2>&1 || true
		rm -f "/dev/md$i"
	done
	echo "  已清理残留 md 设备"
}

case "${1:-}" in
--status)
	echo "当前 mdadm: $(head -1 "$WRAP" 2>/dev/null)"
	if grep -q "lockless -> internal" "$WRAP" 2>/dev/null; then
		echo "兼容层: 已安装"
	else
		echo "兼容层: 未安装"
	fi
	echo "残留 md 设备: $(ls -d /sys/block/md* 2>/dev/null | wc -l) 个"
	[ -f "$LOG" ] && tail -3 "$LOG"
	;;
--remove)
	if [ -x "$REAL" ]; then
		mv -f "$REAL" "$WRAP"
		echo "已还原原始 mdadm"
	fi
	clean_leftovers
	;;
"")
	if [ "$(id -u)" != 0 ]; then
		echo "请用 sudo 运行" >&2
		exit 1
	fi
	[ -x "$REAL" ] || mv "$WRAP" "$REAL"

	cat >"$WRAP" <<'EOF'
#!/bin/bash
# CM360 兼容层：fnOS 1.2.x 建存储时会传 --bitmap=lockless，
# 但本内核（Linux 6.6.54）不具备 lockless bitmap 支持（上游 6.7+ 才有），
# mdadm 4.5 遇到不支持会静默失败，面板只显示"无法创建"；
# 而每次失败还会在内核里留下 state=clear 的同名 md 设备，导致后续重试必然 File exists。
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
	chmod 755 "$WRAP"
	echo "==== 兼容层已安装 ===="
	echo "  $WRAP      （脚本，自动降级 lockless）"
	echo "  $REAL      （原 mdadm 4.5）"
	echo "  验证: $("$WRAP" --version 2>&1 | head -1)"
	clean_leftovers
	echo
	echo "现在去面板重试创建存储空间（只点一次）。"
	echo "若不放心，可用下面这条命令先验证（会在两块盘上建再销毁测试阵列）："
	echo "  sudo $WRAP --create /dev/md199 --metadata=1.2 --run --force --level=1 \\"
	echo "       --raid-devices=2 --bitmap=lockless /dev/sdb1 /dev/sda1"
	echo "  sudo $REAL --stop /dev/md199; sudo $REAL --zero-superblock /dev/sda1; sudo $REAL --zero-superblock /dev/sdb1"
	;;
*)
	echo "用法: $0 [--status|--remove]" >&2
	exit 1
	;;
esac
