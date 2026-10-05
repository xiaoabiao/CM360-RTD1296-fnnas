#!/bin/bash
# 00-catch-uboot2.sh —— ★ 满线 ESC 洪流抓 u-boot console（v2）
#
# 为什么必须换掉 v1（00-catch-uboot.sh 的 @burst 连打）
# ------------------------------------------------------------------
# v1 用 serial_agent 的 `@burst:N esc`，而那个机制是**每 0.15 秒才发一个 0x1b**
#   （serial_agent.py:_enqueue_burst 里 `t += 0.15` 是硬编码的）。
#   占线率 = 87µs / 150ms ≈ **0.06%**。
#
# 而 Realtek bootcode 的判据是"打印 'Hit Esc or Tab key ...: 0' 之后 ~16ms 内，
# 在 UART 接收 FIFO(16B) 里看到 ESC"。两次实测并排：
#
#   成功（05:09）: [14525.614] Hit Esc ...    -> [14525.630] Press Esc Key      （16ms 内命中）
#   失败（05:51）: [16854.823] Hit Esc ...    -> [16854.844] Checking android recovery ← 没 Press Esc
#
# 0.06% 的占线率去碰 16ms 的窗口 = 抽奖。**这才是那次"上电了却没进 console"
# 的根因**，不是板子坏了、也不是脚本写错了。
#
# v2 改用代理新加的 `@flood`（见 serial_agent.py 文件头"@flood"一节）：
# 它把 0x1b 当**持续数据流**灌，把内核 tty 输出队列顶到常满，
# 线上占线率 ≈ **100%** —— 不管 bootcode 在哪一毫秒轮询 FIFO，里面都躺着 ESC。
#
# ★ 为什么不能另起一个进程直接写 tty：
#   本机 USB-TTL 是 CH340（ch341-uart, 1a86:7523），这条 tty **只允许一个进程
#   打开** —— 第二个 open 一律 EBUSY（O_RDONLY/O_WRONLY/O_RDWR/±O_NONBLOCK
#   六种组合全试过，连 `echo x > /dev/ttyUSB0` 都报"设备或资源忙"）。
#   所以洪流只能由持有 fd 的代理自己发。
#
# v1 还有第二个 bug（这次也踩到了）：失手判据写死成 'DiskStation login:'，但这台
# 设备主机名已被改成 Xiaoabiao，提示是 'Xiaoabiao login:' → 判不出失手，会一直
# 空转到窗口超时。v2 泛匹配 'login:'（在 rebooted 门槛之内）。
#
# 退出码：0 抓到 console   2 抓到上电但没进 console   3 窗口内没有上电
#
# 用法：./00-catch-uboot2.sh [守候窗口秒数]      默认 1800
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
S2="$BOARD_DIR"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
AGENTLOG=${AGENTLOG:-$EVIDENCE_DIR/stage0/agent3.out}

# 串口独占守卫：别的进程（如手动 screen）也在 read() 同一个 tty 时，
# 两个读者会瓜分字节流 -> sniffer 会大面积漏字节、永远抓不到 'Enter console mode'。
. "$TOOLS_DIR/serial/serial-guard.sh"
serial_guard || { echo "!! 串口被别的进程占用在读（见上），先关掉再抓。" >&2; exit 4; }

OUT="$OUT/catch-uboot.txt"
ROLL="$OUT/catch-uboot.roll"
WINDOW=${1:-1800}

mkdir -p "$OUT"
: > "$ROLL"
start=$(stat -c %s "$LOG")
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$ROLL"; }
newbytes() { tail -c +$((start + 1)) "$LOG" 2>/dev/null; }

# ---------- 0) 自检：代理必须已经加载 @flood 新代码 ----------
#
# ★ 为什么用"短时续订"而不是一次开 WINDOW 那么长：
#   洪流会把主机侧内核 tty 输出队列顶到常满。实测：洪流后往板子发 CR，响应
#   延迟 7.648s（不发洪流时基线只要 20~60ms），说明队列确实被顶到常满，
#   最坏能积压 ~88KB ≈ 7.6s 线上时间。如果一次性开 1800s，而脚本被硬杀
#   （SIGKILL 不触发 trap），板子就会被无休止地灌 ESC。改成每次只订 90 秒、
#   每 30 秒续一次，最坏情况也只残留 90 秒。
REARM=90
FLOODMS=${FLOODMS:-8}
amark=$(stat -c %s "$AGENTLOG" 2>/dev/null || echo 0)
printf '@flood:%s/%s esc\n' "$REARM" "$FLOODMS" >> "$CTL"
sleep 1.5
if ! tail -c +$((amark + 1)) "$AGENTLOG" 2>/dev/null | grep -qa '开始洪流'; then
	echo "!! 代理没有响应 @flood —— 它跑的还是旧代码（没有 @flood 指令）。" >&2
	echo "   请重启代理后再跑：" >&2
	echo "     pkill -f 'serial_agent.py .*session02'" >&2
	echo "     cd $EVIDENCE_DIR/stage0 && setsid nohup python3 serial_agent.py -d /dev/ttyUSB0 -b 115200 -o session02 --gap 0.6 --append >> $AGENTLOG 2>&1 &" >&2
	exit 4
fi
say "★ 节流洪流已开（间隙 ${FLOODMS}ms ≈ $((1000 / FLOODMS)) 次/秒，每 30s 续订 ${REARM}s），窗口 ${WINDOW}s，日志起点字节 $start"
say ">>> 现在给板子断电，等 5 秒再上电（窗口内什么时候上都行）<<<"

# ---------- 1) 等 ----------
trap 'printf "@flood:0\n" >> "$CTL"; echo "[$(date +%H:%M:%S)] !! 被中断，已停洪流并退出" | tee -a "$ROLL"; exit 5' INT TERM
deadline=$(( SECONDS + WINDOW ))
next_arm=$(( SECONDS + 30 ))
found=0; missed=0; rebooted=0
while :; do
	[ $SECONDS -ge $deadline ] && break
	# 续订洪流（短时重开，见 0) 的说明）
	if [ $SECONDS -ge $next_arm ]; then
		printf '@flood:%s/%s esc\n' "$REARM" "$FLOODMS" >> "$CTL"
		next_arm=$(( SECONDS + 30 ))
	fi
	chunk=$(newbytes)
	# ① 先确认这次真的重启过（否则起点后 11 字节就能撞上 DSM 的 getty 提示，误判）
	if printf '%s' "$chunk" | grep -qa 'FSBL\|U-Boot 2015.07'; then
		rebooted=1
	fi
	# ② 成功标记：进 console 了（不用 'CM360_DS218>'，那个会被洪流吞掉）
	if printf '%s' "$chunk" | grep -qa 'Enter console mode'; then
		found=1
		break
	fi
	# ③ 失手：重启过、并且已经跑到登录提示（★ 泛匹配 login:，不写死主机名）
	if [ "$rebooted" = 1 ] && printf '%s' "$chunk" | grep -qa 'login:'; then
		missed=1
		break
	fi
	sleep 0.3
done
trap - INT TERM

# ---------- 2) 停洪流并排空 ----------
printf '@flood:0\n' >> "$CTL"
tail -c +$((start + 1)) "$LOG" > "$OUT" 2>/dev/null || true

if [ "$found" = 0 ]; then
	if [ "$missed" = 1 ]; then
		say "这次上电没进 console —— 板子自己启了原厂 DSM（节流洪流仍未命中）"
		exit 2
	fi
	say "窗口内没有上电动作（说明板子压根没上电）"
	exit 3
fi

say "★ 进 console 了（节流洪流命中）—— 已停洪流，等 tty 输出队列排空"
# ★ 节流洪流（~125 B/s）几乎不会在主机侧积压，这里主要是给 u-boot 一点时间。
sleep 2

# 提示符可能还埋在残留 ESC 里：Ctrl-C 打断当前行 + CR，反复直到看见提示符
mark=$(stat -c %s "$LOG")
prompt_ok=0
for i in 1 2 3 4 5 6 7 8 9 10; do
	printf '@raw:03\n'   >> "$CTL"; sleep 1.5
	printf '@raw:0d0a\n' >> "$CTL"; sleep 2.0
	if tail -c +$((mark + 1)) "$LOG" 2>/dev/null | grep -aq 'CM360_DS218>'; then
		prompt_ok=1
		break
	fi
done

if [ "$prompt_ok" = 1 ]; then
	say "提示符已确认（第 $i 轮）"
else
	say "!! 没逼出提示符 —— 后面自己看日志"
fi

say "抓现场信息（version / printenv）"
printf 'version\n'  >> "$CTL"; sleep 2.5
printf 'printenv\n' >> "$CTL"; sleep 4

tail -c +$((start + 1)) "$LOG" > "$OUT" 2>/dev/null || true
say "现场信息已存 $OUT"
echo "---- 关键行 ----"
grep -aE 'CM360_DS218>|bootdelay|bootcmd|serverip|tx_path|kernel_loadaddr|Enter console mode' "$OUT" | tail -20
exit 0
