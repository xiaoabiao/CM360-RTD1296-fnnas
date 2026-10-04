#!/usr/bin/env bash
# 一次性修好串口权限：让 xiaoabiao 无需 sudo、无需重新登录就能读写 /dev/ttyUSB0
#
# 背景：/etc/group 里 dialout 已经有 xiaoabiao 了，但组信息只在【登录那一刻】
#       写进进程凭据。当前桌面会话是在 usermod 之前启动的，所以凭据里缺 gid 20。
#       重跑 usermod 没用，必须刷新凭据。
#
# 本脚本按"从好到兜底"的顺序尝试，任何一步成功即可：
#   1) setfacl 给设备节点加 ACL          —— 不依赖组成员关系，立刻生效
#   2) chmod 0666 兜底                    —— devtmpfs 不支持 ACL 时用
#   3) 装 udev 规则（TAG+=uaccess + MODE）—— 重插/重启后依然有效
#
# 用法：  sudo bash fix-serial-perm.sh
set -u

TARGET_USER="${SUDO_USER:-xiaoabiao}"
DEV="/dev/ttyUSB0"
RULE="/etc/udev/rules.d/99-ch340-serial-acl.rules"

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 sudo 运行：  sudo bash $0"
  exit 1
fi

echo "==================================================="
echo " 串口权限修复"
echo " 目标用户: $TARGET_USER    设备: $DEV"
echo "==================================================="
echo

# ---------- 0. 现状 ----------
echo "[0/4] 现状"
if [ -e "$DEV" ]; then
  stat -c '      %A %U:%G   %n' "$DEV"
  echo -n "      文件系统: "
  findmnt -no FSTYPE --target "$DEV" 2>/dev/null || echo "(未知)"
else
  echo "      !! $DEV 不存在 —— 请先插好 TTL 线"
fi
echo "      $(getent group dialout 2>/dev/null | sed 's/^/组: /')"
echo

# ---------- 1. 立刻生效 ----------
echo "[1/4] 立刻生效（二选一，先 ACL 后 chmod）"
IMMEDIATE_OK=0
if [ -e "$DEV" ]; then
  if setfacl -m "u:${TARGET_USER}:rw" "$DEV" 2>/dev/null; then
    if getfacl -p "$DEV" 2>/dev/null | grep -q "^user:${TARGET_USER}:rw-"; then
      echo "      ✓ ACL 已生效：user:${TARGET_USER}:rw-"
      IMMEDIATE_OK=1
    fi
  fi
  if [ "$IMMEDIATE_OK" -eq 0 ]; then
    echo "      · ACL 不可用（devtmpfs 大概率不支持），改用 chmod 0666"
    chmod 0666 "$DEV" && echo "      ✓ 已 chmod 0666（单用户机器上可接受）"
    IMMEDIATE_OK=1
  fi
else
  echo "      跳过"
fi
echo

# ---------- 2. 持久化：udev 规则 ----------
echo "[2/4] 装 udev 规则（重插 / 重启后自动生效）"
cat > "$RULE" <<EOF
# CH340 USB-TTL (1a86:7523)
# uaccess: 让当前登录会话的用户自动拿到 ACL（不依赖 dialout 组成员关系）
# MODE/GROUP: 双保险，即使 logind 没接管也能用
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", \\
  TAG+="uaccess", MODE="0660", GROUP="dialout"
EOF
echo "      已写入 $RULE"
if udevadm control --reload-rules 2>/dev/null; then
  echo "      已重载规则"
  udevadm trigger --action=add --subsystem-match=tty 2>/dev/null \
    && echo "      已重触发 tty 设备事件"
else
  echo "      !! udevadm 不可用，规则会在下次重插/重启时生效"
fi
echo

# ---------- 3. 验证 ----------
echo "[3/4] 验证：以 $TARGET_USER 身份 open $DEV"
VERIFY_OK=0
if sudo -u "$TARGET_USER" python3 - <<PY 2>/dev/null
import os, sys
try:
    fd = os.open("$DEV", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    os.close(fd)
except OSError as e:
    print("      失败 errno=%d" % e.errno); sys.exit(1)
PY
then
  echo "      ✓ 打开成功"
  VERIFY_OK=1
else
  echo "      !! 仍然打不开"
fi
echo

# ---------- 4. 结论 ----------
echo "[4/4] 结论"
if [ "$VERIFY_OK" -eq 1 ]; then
  echo "      ✅ 修好了。现在不需要 sudo，可以直接跑抓取/代理："
  echo "         cd $(cd "$(dirname "$0")" && pwd)"
  echo "         python3 serial_capture.py probe -t 45 -o shot_uboot_02"
  echo "         # 或让 Agent 常驻接管："
  echo "         python3 serial_agent.py -o session01"
else
  echo "      ❌ 没修好。剩下最可靠的一条路："
  echo "         注销桌面会话 → 重新登录（新会话自然带上 dialout 组）"
  echo "         若不想注销，也可以重启 WorkBuddy 桌面应用后再试。"
fi
echo
echo "      （若你其实希望 Agent 全程代劳，修好后跟我说一声即可）"
