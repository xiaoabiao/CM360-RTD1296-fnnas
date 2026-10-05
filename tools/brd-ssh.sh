#!/bin/bash
# brd-ssh.sh —— 上板助手（替代 brd.py）
#
# 为什么不用 brd.py 了
# -------------------
# brd.py 依赖 paramiko，但本机只有 python3.14，而 paramiko 装在
# ~/.local/lib/python3.13/site-packages（没有 3.13 解释器）→ import 直接失败。
# 本脚本改用系统 ssh 客户端，凭据仍从 ~/.brd_cred 读（格式与 brd.py 一致）：
#     第 1 行 用户名   第 2 行 密码   第 3 行 IP(默认 192.168.1.164)   第 4 行 端口(默认 22)
# 密码通过 SSH_ASKPASS 注入，不出现在进程命令行里。
#
# ★ 2026-10-05 救砖后板子 MAC 变了（BPI-W2 u-boot 默认 ethaddr=00:10:20:30:40:50），
#   DHCP 租约因此从 192.168.1.173 变成 192.168.1.164，凭据文件里已同步更新。
#
# 用法：
#   ./brd-ssh.sh run  'uname -a'          # 普通命令
#   ./brd-ssh.sh sudo 'lsblk'             # sudo 执行（自动喂密码）
#   ./brd-ssh.sh shell                    # 交互式登录
set -uo pipefail

CRED="${BRD_CRED:-$HOME/.brd_cred}"
[ -r "$CRED" ] || { echo "!! 读不到凭据 $CRED" >&2; exit 1; }

USERB=$(sed -n 1p "$CRED")
PW=$(sed -n 2p "$CRED")
HOST=$(sed -n 3p "$CRED"); [ -n "$HOST" ] || HOST=192.168.1.164
PORT=$(sed -n 4p "$CRED"); [ -n "$PORT" ] || PORT=22

ASKPASS=$(mktemp /tmp/.brdask.XXXXXX)
printf '#!/bin/sh\ncat %s\n' "$ASKPASS.pw" > "$ASKPASS"
chmod 700 "$ASKPASS"
printf '%s' "$PW" > "$ASKPASS.pw"
chmod 600 "$ASKPASS.pw"
cleanup() { rm -f "$ASKPASS" "$ASKPASS.pw"; }
trap cleanup EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o LogLevel=ERROR -p "$PORT")
# 先探测密钥是否真的被板子接受（本机虽有 id_ed25519，但板子 home 目录不存在、
# 装不进 authorized_keys，所以不能假设密钥可用）；不行就回退到密码 + askpass。
USE_ASKPASS=1
if [ -r "$HOME/.ssh/id_ed25519" ] && \
   ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 \
       "$USERB@$HOST" true >/dev/null 2>&1; then
	SSH_OPTS+=(-o BatchMode=yes)
	USE_ASKPASS=0
else
	SSH_OPTS+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password
	           -o NumberOfPasswordPrompts=1)
fi

do_ssh() {
	if [ "$USE_ASKPASS" = 1 ]; then
		env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
			setsid -w ssh "${SSH_OPTS[@]}" "$USERB@$HOST" "$@"
	else
		ssh "${SSH_OPTS[@]}" "$USERB@$HOST" "$@"
	fi
}

case "${1:-}" in
	run)  shift; do_ssh "$*" ;;
	sudo)
		shift
		# ★ 复盘踩过的坑：sudo -S -p '' 必须整体包进 bash -c，否则 ; / && 逃出 sudo
		do_ssh "sudo -S -p '' /bin/bash -c $(printf '%q' "$*")" <<<"$PW"
		;;
	put)
		shift
		# scp 用 -P 而不是 -p
		SCP_OPTS=(); for o in "${SSH_OPTS[@]}"; do
			case "$o" in -p) SCP_OPTS+=(-P) ;; *) SCP_OPTS+=("$o") ;; esac
		done
		if [ "$USE_ASKPASS" = 1 ]; then
			env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
				setsid -w scp "${SCP_OPTS[@]}" "$1" "$USERB@$HOST:$2"
		else
			scp "${SCP_OPTS[@]}" "$1" "$USERB@$HOST:$2"
		fi
		;;
	get)
		shift
		SCP_OPTS=(); for o in "${SSH_OPTS[@]}"; do
			case "$o" in -p) SCP_OPTS+=(-P) ;; *) SCP_OPTS+=("$o") ;; esac
		done
		if [ "$USE_ASKPASS" = 1 ]; then
			env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
				setsid -w scp "${SCP_OPTS[@]}" "$USERB@$HOST:$1" "$2"
		else
			scp "${SCP_OPTS[@]}" "$USERB@$HOST:$1" "$2"
		fi
		;;
	shell) shift; do_ssh -t ;;
	*) sed -n '1,20p' "$0"; exit 1 ;;
esac
