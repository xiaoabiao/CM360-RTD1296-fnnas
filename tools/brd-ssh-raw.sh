#!/bin/bash
# brd-ssh-raw.sh —— 直连板子的"裸" ssh 封装
#
# 和 brd-ssh.sh 共用 ~/.brd_cred，但**不自动加 sudo**，而且支持把远端输出直接
# 接到本地管道/文件（brd-ssh.sh 的 sudo 模式要把密码喂给 stdin，没法当管道用）。
#
# 用法：
#   ./brd-ssh-raw.sh run 'uptime'                      # 执行命令（stdout 可重定向/入管道）
#   ./brd-ssh-raw.sh run 'sudo tar -C /path -czf - .' > backup.tgz
#   BRD_RSYNC_MODE=1 ./brd-ssh-raw.sh <rsync 传入的 ssh 参数>   # 供 rsync -e 使用
#
# rsync 用法示例（远端以 root 写盘需要远端有免密 sudo 规则）：
#   rsync -aHAX --rsync-path="sudo rsync" -e "$PWD/brd-ssh-raw.sh" \
#         src/ Xiaoabiao@192.168.1.173:/dest/
# 注意 BRD_RSYNC_MODE 需要在 rsync 环境里可见（export BRD_RSYNC_MODE=1）。
set -uo pipefail

CRED="${BRD_CRED:-$HOME/.brd_cred}"
[ -r "$CRED" ] || { echo "!! 读不到凭据 $CRED" >&2; exit 1; }
USERB=$(sed -n 1p "$CRED")
PW=$(sed -n 2p "$CRED")
HOST=$(sed -n 3p "$CRED"); [ -n "$HOST" ] || HOST=192.168.1.173
PORT=$(sed -n 4p "$CRED"); [ -n "$PORT" ] || PORT=22

ASKPASS=$(mktemp /tmp/.brdraw.XXXXXX)
printf '#!/bin/sh\ncat %s\n' "$ASKPASS.pw" >"$ASKPASS"
chmod 700 "$ASKPASS"
printf '%s' "$PW" >"$ASKPASS.pw"
chmod 600 "$ASKPASS.pw"
cleanup() { rm -f "$ASKPASS" "$ASKPASS.pw"; }
trap cleanup EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o LogLevel=ERROR
          -o PubkeyAuthentication=no -o PreferredAuthentications=password
          -o NumberOfPasswordPrompts=1 -p "$PORT")

# 是否有可用的密钥（有就走密钥，免密码注入）
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$USERB@$HOST" true >/dev/null 2>&1; then
	:
fi

if [ "${BRD_RSYNC_MODE:-0}" = 1 ]; then
	# rsync -e 模式：参数形如  <host> rsync --server ...
	# 把主机参数换成凭据里的 user@host，其余原样透传
	args=("$@")
	if [ ${#args[@]} -ge 2 ] && [ "${args[0]}" != "${args[0]#-}" ] ; then
		exec env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid -w \
			ssh "${SSH_OPTS[@]}" "$USERB@$HOST" "${args[@]}"
	fi
	if [ ${#args[@]} -ge 1 ]; then
		args[0]="$USERB@$HOST"
	fi
	exec env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid -w \
		ssh "${SSH_OPTS[@]}" "${args[@]}"
fi

case "${1:-}" in
run)
	shift
	exec env SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid -w \
		ssh "${SSH_OPTS[@]}" "$USERB@$HOST" "$*"
	;;
*)
	sed -n '1,20p' "$0"
	exit 1
	;;
esac
