#!/bin/bash
# 00-catch-uboot.sh —— 抓住 Realtek bootcode 的 console 窗口
#
# 背景（见 README 4.5 + 阶段0 printenv 实录）：
#   板上 bootdelay=0，所以 "Hit Esc or Tab key to enter console mode" 那个
#   倒计时根本没有。必须让 Tab/Esc 在 bootcode 轮询 UART 的那一刻**已经躺在
#   接收 FIFO 里**。做法：上电前后持续、不间断地敲 Esc/Tab，直到日志里冒出
#   成功标记为止。
#
#   敲中之后 bootcode 的流程是：
#     Hit Esc or Tab ... -> Press Tab Key -> LOAD RESCUE/GOLD FW TABLE（签名失败）
#     -> Enter console mode, disable watchdog ... -> CM360_DS218>
#
# 为什么只敲 ESC、不敲 TAB（★ 实测踩到的坑）：
#   把四次上电的 bootcode 流程并排比一下：
#
#     Press Esc Key  -> Enter console mode, disable watchdog ... -> CM360_DS218>  ★秒出
#     Press Tab Key  -> Start Boot Setup ...
#                       ---------------LOAD  RESCUE  FW  TABLE ---------------
#                       [ERR] rtk_plat_parse_fwdesc:Signature() error!
#                       ---------------LOAD  GOLD  FW  TABLE ---------------
#                       [ERR] rtk_plat_parse_fwdesc:Signature() error!
#                       Enter console mode, disable watchdog ...
#                       <全静音：连 Ctrl-C/CR 都不回显，只能断电>
#
#   也就是说 **Tab 会走 "rescue linux" 分支**（去加载 RESCUE/GOLD FW TABLE），
#   那条路要么慢到 110 秒才出提示符，要么直接把板子搞哑（多半又是把音频 DSP
#   拉起来了，UART 时钟被 gate —— 见 board.sh 里 `go all` 那一节的同类现象）。
#   ESC 走的是干净路径，秒进 console。所以 KEYS 默认只用 esc。
#
# 为什么连打溢出到提示符之后也是安全的：
#   * Esc 会被 u-boot 当转义首字节吞掉，不留痕迹。
#   * （Tab 即使漏进去也只是触发补全，空行上 next_char 为空，补全不动作。）
#
# 三个已踩过的坑，都在这里堵掉了：
#   1. 提示符字符串会被连打吞掉 —— 所以成功标记用 'Enter console mode'
#      而不是 'CM360_DS218>'；抓中后再用 Ctrl-C + CR 把提示符逼出来。
#   2. "失手检测"不能只看 'DiskStation login:'：连打会让 getty 一分钟不登录就
#      超时重打一次登录提示，那个字符串会**在起点后 11 字节**就出现，误判。
#      必须先在本次窗口里看到过 'FSBL'/'U-Boot 2015.07'（真的重启过）才算。
#   3. 一切检测都只看"起点之后"的增量。
#
# 退出码：0 抓到提示符  2 抓到上电但没进 console  3 窗口内没有上电
#
# 用法：./00-catch-uboot.sh [守候窗口秒数，0=不限]   默认 1800
#       KEYS=esc（默认）或 "esc tab"
set -uo pipefail

S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
S2=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage2
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"

# 串口独占守卫：别的进程（如手动 screen）也在 read() 同一个 tty 时，
# 两个读者会瓜分字节流 -> 这里 sniffer 会大面积漏字节、永远抓不到 'Enter console mode'。
# 详见 stage0/serial-guard.sh 顶部。
. "$S0/serial-guard.sh"
serial_guard || { echo "!! 串口被别的进程占用在读（见上），先关掉再抓。" >&2; exit 4; }

OUT="$S2/out/catch-uboot.txt"
ROLL="$S2/out/catch-uboot.roll"
WINDOW=${1:-1800}
# ★ BURST 默认从 15 秒降到 3 秒。
#   原因（实测踩到的坑）：serial_agent 的 `@burst:N keys` 是**一次性把未来 N 秒
#   的按键全部排进发送队列**（_enqueue_burst 里 `t += 0.15`），脚本这边**没法撤回**。
#   BURST=15 意味着最多有 100 个 0x1b 卡在队列里；等 'Enter console mode' 一出现，
#   脚本虽然立刻停止再排队，但那 100 个 ESC 还会照发 —— 于是提示符刚打出来就被
#   自己的 ESC 洪水淹没，板子要啃好几分钟才肯回一条干净的提示符。
#   BURST=3 时残留最多 20 个 ESC，基本无害。宁可多循环几轮，也别一次灌太狠。
BURST=${BURST:-3}
KEYS=${KEYS:-esc}

mkdir -p "$S2/out"
: > "$ROLL"
start=$(stat -c %s "$LOG")
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$ROLL"; }
newbytes() { tail -c +$((start + 1)) "$LOG"; }

say "守候 u-boot 提示符：窗口 ${WINDOW}s，burst=${BURST}s，键=${KEYS}，日志起点字节 $start"
say ">>> 现在给板子断电再上电（窗口内什么时候上都行）<<<"

deadline=0
[ "$WINDOW" -gt 0 ] && deadline=$((SECONDS + WINDOW))
found=0
missed=0
rebooted=0
while :; do
	if [ "$deadline" -gt 0 ] && [ $SECONDS -ge $deadline ]; then
		break
	fi
	chunk=$(newbytes)
	if printf '%s' "$chunk" | grep -qa 'FSBL\|U-Boot 2015.07'; then
		rebooted=1
	fi
	# 成功标记：进 console 了（不要用 'CM360_DS218>'，那个会被连打吞掉）
	if printf '%s' "$chunk" | grep -qa 'Enter console mode'; then
		found=1
		break
	fi
	# 失手：确认这次真的重启过，并且已经跑到原厂 DSM 的登录提示
	# ★ 2026-10-04 修正：原来写死 'DiskStation login:'，但这台设备主机名已被
	#   用户改成 Xiaoabiao，登录提示是 'Xiaoabiao login:' → 判不出失手，脚本
	#   会一直空转到窗口超时。改成泛匹配 'login:'（已在 rebooted 门槛之内）。
	if [ "$rebooted" = 1 ] && printf '%s' "$chunk" | grep -qa 'login:'; then
		missed=1
		break
	fi
	printf '@burst:%s %s\n' "$BURST" "$KEYS" >> "$CTL"
	sleep "$(awk -v b="$BURST" 'BEGIN{printf "%.2f", b+0.3}')"
done

if [ "$found" = 0 ]; then
	tail -c +$((start + 1)) "$LOG" > "$OUT"
	if [ "$missed" = 1 ]; then
		say "这次上电没进 console —— 板子自己启了原厂 DSM（约 3.8% 的结构性空隙）"
		exit 2
	fi
	say "窗口内没有上电动作"
	exit 3
fi

say "进 console 了 —— 停止连打，等当前 burst 和队列排空"
sleep "$(awk -v b="$BURST" 'BEGIN{printf "%.1f", b+3}')"

# 提示符可能被连打吞掉：Ctrl-C 打断当前行 + CR，反复直到看见提示符
mark=$(stat -c %s "$LOG")
prompt_ok=0
for i in 1 2 3 4 5; do
	printf '@raw:03\n'   >> "$CTL"; sleep 1.2
	printf '@raw:0d0a\n' >> "$CTL"; sleep 1.5
	if tail -c +$((mark + 1)) "$LOG" | grep -q 'CM360_DS218>'; then
		prompt_ok=1
		break
	fi
done

if [ "$prompt_ok" = 1 ]; then
	say "提示符已确认（第 $i 轮）"
else
	say "!! 没逼出提示符 —— 后面自己看日志"
fi

say "抓现场信息"
printf 'version\n'       >> "$CTL"; sleep 2.5
printf 'printenv\n'      >> "$CTL"; sleep 4
printf 'help go\n'       >> "$CTL"; sleep 3
printf 'help booti\n'    >> "$CTL"; sleep 3
printf 'help iminfo\n'   >> "$CTL"; sleep 3

tail -c +$((start + 1)) "$LOG" > "$OUT"
say "现场信息已存 $OUT"
echo "---- 关键行 ----"
grep -aE 'CM360_DS218>|loadaddr|bootargs|bootcmd|bootdelay|^go |Wrong Image' "$OUT" | tail -50
exit 0
