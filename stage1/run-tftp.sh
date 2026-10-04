#!/usr/bin/env bash
# ============================================================================
#  run-tftp.sh —— 以 root 绑定 69 端口启动 TFTP 服务，随后立即降权回你自己
# ============================================================================
#
# 为什么要提权：板子的 u-boot 不支持 tftpdstp（已实测），只能打标准 69 端口，
# 而普通用户绑不了 69。所以启动这一步需要 root。
#
# 为什么用 sudo 而不是改 sysctl：保持内核参数原样。代价是每次重启服务都要 sudo。
#
# 降权的好处：只有 bind() 那一瞬间需要特权。绑完立刻 setuid 回普通用户，于是
#   * 常驻进程本身不持有 root 权限（它在解析网络报文，不该是 root）
#   * tftpput 上传回来的备份文件直接归你所有，不用事后 chown
#   * 每个传输用的临时端口是 bind(port=0)，降权后照样能绑，功能不受影响
#
# 用法
# ----
#   sudo bash run-tftp.sh              # 启动（已在跑则先停后起）
#   bash run-tftp.sh --stop            # 停止（不需要 sudo：降权后进程本来就属于你）
#   bash run-tftp.sh --status          # 看状态
#   PORT=6970 bash run-tftp.sh         # 用高端口试跑（不需要 root，便于自检）
#   BIND=192.168.1.254 sudo -E bash run-tftp.sh    # 换绑定地址
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRV="$HERE/tftp_server.py"
ROOT_DIR="$HERE/tftproot"
# 运行期文件放在项目目录里，不放 /tmp —— 见下面 preflight_log 的注释
PIDFILE="$HERE/tftp.pid"
LOGFILE="$HERE/tftp.log"
BIND="${BIND:-192.168.1.254}"
PORT="${PORT:-69}"
DEV="${DEV:-enp2s0}"

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

# 非 root 时不该拿 SUDO_USER 去降权（也没权限降）
if [ "$IS_ROOT" -eq 1 ]; then
    TARGET_USER="${SUDO_USER:-root}"
else
    TARGET_USER="$(id -un)"
fi

die(){ echo "错误：$*" >&2; exit 1; }
say(){ echo "  $*"; }

# 只有绑 <1024 端口才需要 root；其余情况允许非特权运行，便于整条链路自检
need_root_for_port(){
    if [ "$IS_ROOT" -eq 0 ] && [ "$PORT" -lt 1024 ]; then
        die "端口 $PORT 需要 root：sudo bash $0
     （想以普通用户验证整条链路，可用高端口：PORT=6970 bash $0）"
    fi
}

# ---------------------------------------------------------------------------
# ★ 为什么日志不能放 /tmp
#
# 本脚本以 root 启动服务、日志文件归属普通用户。如果日志放 /tmp 就会撞内核的
# 安全策略。真实判定在 fs/namei.c（约 1290-1350 行），对本场景化简后是：
#
#   目录有粘滞位(S_ISVTX) 且 目录"其他人可写"(dir_mode & 0002)
#     且 文件既不属于 目录属主、也不属于 当前调用者的 fsuid
#     → O_CREAT 打开被拒，返回 EACCES
#
# /tmp 是 1777（粘滞位 + 其他人可写），目录属主 root，而日志文件属主是普通用户
# → 三者两两不等 → root 也被拒。这就是那句莫名其妙的
#   `bash: /tmp/xxx.log: 权限不够`
#
# 注意别记错：这**不是** protected_regular=2 造成的。只要目录是"粘滞 + 其他人可写"，
# protected_regular=1 时同样会拒；=2 那条额外分支管的是"组可写"的粘滞目录。
# 策略的用意是防止别人往 /tmp 预埋文件，诱导 root 去追加写。
#
# 两种规避方式：① 文件属主留成 root（等于目录属主，放行）；② 换出粘滞目录。
# 这里选 ②：放到项目目录（非粘滞、非全局可写），附带好处是日志归你所有、
# tail/清空都不用再 sudo。
# ---------------------------------------------------------------------------
preflight_log(){
    local dir; dir="$(dirname "$LOGFILE")"
    mkdir -p "$dir"
    # 用同样方式试开一次，失败就直说原因，别让用户对着"权限不够"猜
    if ! { : >> "$LOGFILE"; } 2>/dev/null; then
        local dperm duname svtx
        dperm=$(stat -c '%a' "$dir" 2>/dev/null)
        duname=$(stat -c '%U' "$dir" 2>/dev/null)
        svtx=$(stat -c '%t' "$dir" 2>/dev/null)
        echo "  无法写入日志文件：$LOGFILE" >&2
        echo "  目录 $dir 权限=$dperm 属主=$duname 粘滞位=$svtx" >&2
        if [ "$svtx" != "0" ] && [ $(( 0$dperm & 2 )) -ne 0 ]; then
            echo "  → 这是内核粘滞目录保护拦的（audit 事件名 sticky_create）：" >&2
            echo "    目录有粘滞位且其他人可写，而日志文件既不属于目录属主($duname)，" >&2
            echo "    也不属于当前调用者 —— 于是 O_CREAT 被拒。root 同样被拒。" >&2
            echo "    把 LOGFILE 换到非粘滞目录即可；或让日志文件属主与目录属主一致。" >&2
        fi
        die "日志不可写"
    fi
}

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--status" ]; then
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "运行中：pid=$PID"
            ps -o pid,user,args -p "$PID" | sed 's/^/  /'
            ss -lunp 2>/dev/null | grep -E ":$PORT[[:space:]]" | sed 's/^/  /' || true
        else
            echo "pidfile 存在但进程 $PID 已不在"
        fi
    else
        echo "未运行（没有 $PIDFILE）"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# --stop（不需要 root：服务降权后本来就属于目标用户，pidfile 也可由本人删除）
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--stop" ]; then
    if [ -f "$PIDFILE" ]; then
        python3 "$SRV" --root "$ROOT_DIR" --stop --pidfile "$PIDFILE" || true
    else
        # pidfile 丢了也要能兜底停掉（扫一下谁占着这个端口）
        STOPPED=0
        for p in $(ss -lunp 2>/dev/null | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u || true); do
            if grep -qa tftp_server "/proc/$p/cmdline" 2>/dev/null; then
                if kill "$p" 2>/dev/null; then echo "  已停止 pid $p"; STOPPED=1
                else echo "  pid $p 杀不掉（可能属于其他用户，需要 sudo）" >&2; fi
            fi
        done
        [ "$STOPPED" -eq 0 ] && echo "  没有找到在跑的实例"
    fi
    rm -f "$PIDFILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
need_root_for_port
[ -f "$SRV" ] || die "找不到 $SRV"
id "$TARGET_USER" >/dev/null 2>&1 || die "用户 $TARGET_USER 不存在"

# 只有 root 才谈得上"降权"
if [ "$IS_ROOT" -eq 1 ]; then
    SETUID_ARGS=(--setuid "$TARGET_USER")
    MODE_DESC="root 绑端口 → 降权到 $TARGET_USER"
else
    SETUID_ARGS=()
    MODE_DESC="非特权直跑（端口 >=1024，无需降权）"
fi

echo "==> 配置"
say "绑定地址   : $BIND:$PORT"
say "TFTP 根目录: $ROOT_DIR"
say "运行方式   : $MODE_DESC"
say "日志       : $LOGFILE"

# 1) 确认绑定地址确实配在网卡上（否则 bind 会失败）
if ! ip -4 addr show "$DEV" 2>/dev/null | grep -q "${BIND}/"; then
    die "$DEV 上没有 $BIND —— 先配地址：nmcli con mod netplan-$DEV ipv4.addresses $BIND/24 ipv4.method manual"
fi
say "网卡 $DEV 上已配置 $BIND ✓"

# 2) 根目录准备好（降权后要能在里面写备份，所以归属目标用户）
mkdir -p "$ROOT_DIR"
if [ "$IS_ROOT" -eq 1 ]; then
    chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$ROOT_DIR"
fi
say "根目录就绪 ✓"

# 3) 停掉旧实例
if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
        say "停掉旧实例 pid=$OLD ..."
        python3 "$SRV" --root "$ROOT_DIR" --stop --pidfile "$PIDFILE" >/dev/null 2>&1 || kill "$OLD" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$PIDFILE"
fi
# 兜底：还有别的进程占着 69 吗
if ss -lun 2>/dev/null | grep -qE ":${PORT}[[:space:]]"; then
    echo "  !! $PORT 端口仍被占用：" >&2
    ss -lunp 2>/dev/null | grep -E ":${PORT}[[:space:]]" >&2
    die "请先停掉占用者（dnsmasq / in.tftpd）"
fi

# 4) 拉起服务（新会话，脱离当前 shell，脚本退出后继续存活）
#    日志/pidfile 都在项目目录里（非粘滞、非全局可写），不会撞粘滞目录保护
preflight_log
if [ "$IS_ROOT" -eq 1 ]; then
    chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$LOGFILE" 2>/dev/null || true
fi

setsid python3 "$SRV" \
    --bind "$BIND" --port "$PORT" --root "$ROOT_DIR" --writable \
    "${SETUID_ARGS[@]}" --pidfile "$PIDFILE" --log "$LOGFILE" \
    < /dev/null >> "$LOGFILE" 2>&1 &

# 5) 验证：端口听上了吗？进程活着吗？（root 模式下还要确认降权成功）
echo "==> 验证"
OK=0
for _ in $(seq 1 30); do
    if ss -lun 2>/dev/null | grep -qE ":${PORT}[[:space:]]"; then OK=1; break; fi
    sleep 0.2
done
[ "$OK" -eq 1 ] || { echo "启动失败，日志末尾：" >&2; tail -20 "$LOGFILE" >&2; exit 1; }

PID=$(cat "$PIDFILE" 2>/dev/null || echo 0)
kill -0 "$PID" 2>/dev/null || die "进程 $PID 不在（看 $LOGFILE）"

ACTUAL_USER=$(ps -o user= -p "$PID" | tr -d ' ')
say "监听中 ✓  pid=$PID"
if [ "$IS_ROOT" -eq 1 ]; then
    say "进程属主: $ACTUAL_USER  （应为 $TARGET_USER —— 说明已成功降权）"
else
    say "进程属主: $ACTUAL_USER"
fi
ss -lunp 2>/dev/null | grep -E ":${PORT}[[:space:]]" | sed 's/^/    /'

if [ "$IS_ROOT" -eq 1 ] && [ "$ACTUAL_USER" != "$TARGET_USER" ]; then
    echo "  !! 警告：进程属主不是 $TARGET_USER，降权可能没生效" >&2
fi

echo
echo "================================================"
echo " TFTP 已就绪：$BIND:$PORT  （板子 serverip 指向它）"
echo "================================================"
echo "  换内核文件：直接覆盖 $ROOT_DIR/ 里的文件即可，不用重启服务"
echo "  重启服务  ：sudo bash $0"
echo "  停止服务  ：bash $0 --stop      （不用 sudo）"
echo "  看状态    ：bash $0 --status    （不用 sudo）"
echo "  看日志    ：tail -f $LOGFILE"
