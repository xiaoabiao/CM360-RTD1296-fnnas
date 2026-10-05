#!/bin/bash
# board.sh —— 通过串口代理操作板子
#
# 串口代理 serial_agent.py（PID 常驻）的工作方式：
#   * 我们从 session02.ctl 追加一行 → 代理读到后按 --gap 0.6s 的间隔投递给串口
#   * 板子的回显落在 session02.log
# 所以这里所有的 "发送" 都是往 .ctl 追加，"读取" 都是读 .log 的新增部分。
#
# 注意 gap 的存在不是多余的：u-boot 打印长 help 文本时来不及读 UART 接收
# FIFO（通常 16 字节），一次性灌多条命令会错位（实测 `help sata` 变成
# `hehelp sata`）。所以 send 多条时**必须**留间隔，本脚本按行发。
#
# 用法：
#   ./board.sh send "help"            发一条命令
#   ./board.sh multi  'cmd1' 'cmd2'   按顺序发多条（每条之间有间隔）
#   ./board.sh wait   'CM360_DS218>'  10    等日志里出现某字符串（从此刻算起）
#   ./board.sh tail   40              打印最近 40 行
#   ./board.sh mark                   记录当前日志位置（供 wait 使用）
#   ./board.sh new                    打印 mark 之后的新增日志
#   ./board.sh factory                在 RAM 里复刻原厂内核搬运，看它的封装格式
#   ./board.sh bootgo                 ★推荐：装载 + `booti k initrd:size fdt`（x0=DTB）
#   ./board.sh prep [uimage|raw]      只做装载（不启动），方便自己接着手敲
#   ./board.sh gok  [uimage|raw]      兜底：`go k`（不传 fdt，大概率静音）
#   ./board.sh goall all|k            go all / go k（go all 会启 audio，慎用）
#   ./board.sh verify                 用 tftpput 把 RAM 里的内容回传并比对 md5
#
# ⚠ 别用 `go all`：它会 "Start Audio Firmware ..."，音频 DSP 起来后 Realtek 的
#   电源管理会 gate 掉外设时钟，UART 直接哑掉（板子还活着但串口全无回显，
#   只能断电）。`go k` 安全但**不传 fdt**，所以优先用 `bootgo`。

set -uo pipefail

STAGE0="$EVIDENCE_DIR/stage0"
S2="$BOARD_DIR"
TFTPROOT="${TFTPROOT:-$ROOT/build/tftproot}"

CTL="$STAGE0/session02.ctl"
LOG="$STAGE0/session02.log"
MARKFILE="$OUT/.logmark"

die() { echo "ERROR: $*" >&2; exit 1; }

# 串口独占守卫（见 stage0/serial-guard.sh 顶部的血泪教训）
. "$TOOLS_DIR/serial/serial-guard.sh"

check_agent() {
	pgrep -f "serial_agent.py .*session02" >/dev/null || die "串口代理没在跑，先启动它"
	[ -f "$CTL" ] || die "控制文件不存在: $CTL"
	serial_guard || die "串口被别的进程占用在读（见上），先关掉再跑"
}

# 记下当前日志长度，之后 wait 只看这之后的内容
cmd_mark() {
	stat -c %s "$LOG" > "$MARKFILE" 2>/dev/null || echo 0 > "$MARKFILE"
	echo "log mark = $(cat "$MARKFILE")"
}

cmd_send() {
	check_agent
	local n
	n=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
	echo "$n" > "$MARKFILE"
	printf '%s\n' "$1" >> "$CTL"
	echo "-> $1"
}

cmd_multi() {
	check_agent
	echo $(stat -c %s "$LOG") > "$MARKFILE"
	for c in "$@"; do
		printf '%s\n' "$c" >> "$CTL"
		echo "-> $c"
		sleep 0.9
	done
}

# wait <pattern> [timeout_sec]
cmd_wait() {
	local pat="$1" timeout="${2:-15}" start
	start=$(cat "$MARKFILE" 2>/dev/null || echo 0)
	local deadline=$(( SECONDS + timeout ))
	while [ $SECONDS -lt $deadline ]; do
		if tail -c +$(( start + 1 )) "$LOG" 2>/dev/null | grep -qF -- "$pat"; then
			echo "OK: 命中 '$pat'"
			return 0
		fi
		sleep 0.3
	done
	echo "TIMEOUT: 等 '$pat' 超时（${timeout}s）"
	echo "---- 这段时间的日志 ----"
	tail -c +$(( start + 1 )) "$LOG" 2>/dev/null | tail -30
	return 1
}

cmd_tail() {
	tail -n "${1:-40}" "$LOG"
}

# 同 cmd_wait，但模式按**正则**解释（要匹配 "A|B" 这种多选时用这个）
cmd_waitre() {
	local pat="$1" timeout="${2:-15}" start deadline
	start=$(cat "$MARKFILE" 2>/dev/null || echo 0)
	deadline=$(( SECONDS + timeout ))
	while [ $SECONDS -lt $deadline ]; do
		if tail -c +$(( start + 1 )) "$LOG" 2>/dev/null | grep -qaE -- "$pat"; then
			echo "OK: 命中 /$pat/"
			return 0
		fi
		sleep 0.3
	done
	echo "TIMEOUT: 等 /$pat/ 超时（${timeout}s）"
	echo "---- 这段时间的日志 ----"
	tail -c +$(( start + 1 )) "$LOG" 2>/dev/null | tail -30
	return 1
}

cmd_new() {
	local start
	start=$(cat "$MARKFILE" 2>/dev/null || echo 0)
	tail -c +$(( start + 1 )) "$LOG"
}

IMG="$OUT/Image"
# ★ 下面这三个都可用环境变量覆盖，以便引导别的产物（如 6.6 树编出来的）
#   6.6 走法：./board.sh boot66
DTB="${DTB:-$OUT/cm360.dtb}"
INITRD="${INITRD:-$OUT/initramfs.cpio.gz}"
IMG="${IMG:-$OUT/Image}"

# ★ clk_ignore_unused 已于 2026-10-04 晚【撤掉】—— 原因是正经修法已经落地：
#   DTS 里给 uart0 补了 clocks = <&ic RTD1295_ISO_CLK_EN_UR0>
#   （gate 在 ISO 控制器，不是 CRT，父时钟 osc27m = 27MHz），
#   8250_dw 会 clk_prepare_enable() 认领它，引用计数 > 0，
#   clk_disable_unused() 就不会再碰它。
#
#   留着它会掩盖问题：GMAC 的 etn/etn_sys/etn_250m 也在这条时钟总线上，
#   总闸一开，就算 DTS 写错了、驱动没认领成功，网卡照样"看起来能用"，
#   后面 eMMC/SD/SATA（要做 clk_set_rate，必须时钟树是活的）就没法排查了。
#
#   历史症状（留档，别再来一次）：
#     [1.415032] clk: Disabling unused clocks
#     [1.513068] clk_en_ur0: clk_regmap_gate_disable_unused   ← 日志到此为止
#   厂商 clk 驱动只把 clk_en_misc 标成 CLK_IS_CRITICAL，没标 clk_en_ur0；
#   而 uart0 又没有 clocks 属性 → 被判"无人使用" → gate 掉 → 串口时钟停 →
#   连 Ctrl-C 都不回显，只能物理断电。
BOOTARGS='console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'

# 完整引导
cmd_boot() {
	[ -f "$IMG" ] || die "缺少 $IMG"
	[ -f "$DTB" ] || die "缺少 $DTB"
	[ -f "$INITRD" ] || die "缺少 $INITRD"
	[ -f "$TFTPROOT/Image" ] || die "TFTP 根目录里没有 Image，先跑 03-deploy.sh"

	check_agent
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"

	echo "==== 1) 进 u-boot 提示符 ===="
	printf '\n' >> "$CTL"; sleep 1.5
	printf '\n' >> "$CTL"; sleep 1.5

	echo "==== 2) 网络 ===="
	for c in \
		'setenv ipaddr 192.168.1.100' \
		'setenv serverip 192.168.1.254' \
		'setenv netmask 255.255.255.0' \
		'ping 192.168.1.254' ; do
		printf '%s\n' "$c" >> "$CTL"; echo "-> $c"; sleep 1.2
	done
	cmd_wait 'is alive' 8 || true

	echo "==== 3) 加载内核 ===="
	for c in \
		'tftp 0x03000000 Image' \
		'tftp 0x01f00000 cm360.dtb' \
		'tftp 0x08000000 initramfs.cpio.gz' ; do
		printf '%s\n' "$c" >> "$CTL"; echo "-> $c"; sleep 4
	done

	echo "==== 4) 设置 bootargs ===="
	printf "setenv bootargs '%s'\n" "$BOOTARGS" >> "$CTL"
	echo "-> setenv bootargs '...'"
	sleep 1.5

	echo "==== 5) 启动 ===="
	printf 'booti 0x03000000 0x08000000 0x01f00000\n' >> "$CTL"
	echo "-> booti 0x03000000 0x08000000 0x01f00000"
	echo
	echo "（下面盯日志，最多等 90 秒）"
	cmd_wait 'Run /init as init process' 90 || true
}

# 用 tftpput 把内核加载后的 RAM 内容回传，和宿主机上的 Image 比 md5# 这是 stage1 就验证过的手法：u-boot 没有 crc32 命令，只能这样证明字节一致。
cmd_verify() {
	[ -f "$IMG" ] || die "缺少 $IMG"
	local size md5local hexsize
	size=$(stat -c %s "$IMG")
	hexsize=$(printf '0x%x' "$size")
	md5local=$(md5sum "$IMG" | cut -d' ' -f1)
	echo "宿主机 Image: $size 字节, md5=$md5local"

	check_agent
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"

	printf 'tftp 0x03000000 Image\n' >> "$CTL"; sleep 4
	printf 'tftpput 0x03000000 %s rb_Image\n' "$hexsize" >> "$CTL"
	echo "-> tftp 0x03000000 Image; tftpput 0x03000000 $hexsize rb_Image"
	cmd_wait 'Bytes transferred' 30 || true

	# 代理是降权到 xiaoabiao 跑的，回传文件落在 tftproot（可写）
	sleep 1
	if [ -f "$TFTPROOT/rb_Image" ]; then
		local n
		n=$(stat -c %s "$TFTPROOT/rb_Image")
		echo "回传大小: $n 字节"
		if [ "$n" != "$size" ]; then
			echo "✗ 大小不符（期望 $size）"
		else
			local md5rb
			md5rb=$(md5sum "$TFTPROOT/rb_Image" | cut -d' ' -f1)
			echo "回传 md5: $md5rb"
			[ "$md5rb" = "$md5local" ] && echo "✓ md5 一致 —— 内核在 RAM 里是完整的" \
			                            || echo "✗ md5 不一致"
		fi
	else
		echo "✗ 没收到 rb_Image，检查 TFTP 服务是否开着（run-tftp.sh）"
	fi
}

# ---------------------------------------------------------------------------
# go all 路径
#
# 实测结论（见 README「为什么不能用 booti」）：
#   板上 `booti` 一定会报 `Wrong Image Format for do_booti command`。
#   这是 Realtek u-boot 的固有行为，Armbian 论坛上同款 RTD1296（TerraMaster
#   F4-210）是一模一样的报错。可用路径是 Realtek 私有的 `go all`：
#   它按 ${kernel_loadaddr}/${fdt_loadaddr}/${rootfs_loadaddr} 这几个
#   环境变量去内存里取镜像，绕开标准 bootm/booti 的格式检查。
# `bootr` 别用 —— 那玩意会去加载原厂内核，不是你刚 tftp 进去的。
# ---------------------------------------------------------------------------

# 这三个值不是猜的 —— 是板上 `printenv` 实录（阶段0 / shot_uboot_01.log）：
#   kernel_loadaddr=0x03000000
#   fdt_loadaddr=0x01f00000
#   rootfs_loadaddr=0x02200000
# 注意 bootcmd 是：
#   run syno_bootargs; run rtk_spi_boot; run mod_fdt; ping $serverip; go all
# 也就是说 **原厂自己最后就是靠 `go all` 起的**，README 4.5 那个结论坐实了。
KVAR="${KVAR:-kernel_loadaddr}"
FVAR="${FVAR:-fdt_loadaddr}"
RVAR="${RVAR:-rootfs_loadaddr}"

# 默认地址（= 板上 env 的值）
KADDR="${KADDR:-0x03000000}"
FADDR="${FADDR:-0x01f00000}"
RADDR="${RADDR:-0x02200000}"

# 先探路：go 命令怎么用、加载地址变量叫什么、当前值是多少
cmd_probe() {
	check_agent
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	for c in 'help go' 'help bootr' 'printenv'; do
		printf '%s\n' "$c" >> "$CTL"
		echo "-> $c"
		sleep 3
	done
	sleep 2
	echo
	echo "======== 完整回显 ========"
	tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | tail -80
	echo
	echo "======== 只看关键行 ========"
	tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | \
		grep -iE "loadaddr|bootargs|^go |Usage|printenv|bootr" | head -40
}

# goall [all|k]  —— 用 Realtek 私有的 `go` 启动我们 tftp 进去的镜像
#
#   go all - start all firmware    （原厂 bootcmd 用的就是这个）
#   go k   - start kernel          （只起内核，不起 audio fw）
#
# 为什么不用 booti：见 README 4.5 / 上面那段注释。板上 `booti` 必报
# `Wrong Image Format for do_booti command`。
#
# 地址一律用 KADDR/FADDR/RADDR（默认就是板上 env 里的三个 loadaddr）。
# 还有个坑：mainline arm64 只认 DTB 的 /chosen/linux,initrd-start/end，
# 不认 bootargs 里的 initrd=，所以必须显式 `fdt chosen <start> <end>`。
cmd_goall() {
	[ -f "$IMG" ] || die "缺少 $IMG"
	[ -f "$INITRD" ] || die "缺少 $INITRD"
	check_agent

	local mode="${1:-all}"
	local isz iend
	isz=$(stat -c %s "$INITRD")
	iend=$(printf '0x%x' $(( RADDR + isz )))

	echo "⚠⚠ 注意：go all 会先启动 audio firmware，实测会把 UART 时钟 gate 掉，"
	echo "⚠⚠       板子随后串口全哑、只能断电。要引导请优先用 ./board.sh gok"
	sleep 5

	echo "$(stat -c %s "$LOG")" > "$MARKFILE"

	echo "==== 1) 加载三个镜像到 Realtek 约定的地址 ===="
	for spec in "Image:$KADDR" "cm360.dtb:$FADDR" "initramfs.cpio.gz:$RADDR"; do
		local f="${spec%%:*}" a="${spec##*:}"
		echo "$(stat -c %s "$LOG")" > "$MARKFILE"   # 每次 tftp 都要重设游标，否则会命中上一次的 Bytes transferred
		printf 'tftp %s %s\n' "$a" "$f" >> "$CTL"
		echo "-> tftp $a $f"
		cmd_wait 'Bytes transferred' 180 >/dev/null 2>&1 || echo "   （没看到 Bytes transferred，继续）"
	done

	echo "==== 2) 把 initrd 塞进 DTB 的 /chosen（mainline 只认这条路）===="
	printf 'fdt addr %s\n' "$FADDR" >> "$CTL"; sleep 1.2
	printf 'fdt resize\n'          >> "$CTL"; sleep 1.2
	printf 'fdt chosen %s %s\n' "$RADDR" "$iend" >> "$CTL"
	echo "-> fdt addr $FADDR; fdt resize; fdt chosen $RADDR $iend"
	sleep 2

	echo "==== 3) bootargs ===="
	printf "setenv bootargs '%s'\n" "$BOOTARGS" >> "$CTL"
	echo "-> setenv bootargs '$BOOTARGS'"
	sleep 2

	echo "==== 4) go $mode ===="
	printf 'go %s\n' "$mode" >> "$CTL"
	echo "-> go $mode"
	echo
	echo "（盯日志，最多等 120 秒；期望看到 'Booting Linux on physical CPU'）"
	cmd_wait 'Booting Linux' 120 || true
}

# gok [uimage|raw]  —— 走 `go k`（只起内核，不碰 audio fw）+ 全套装载
#
# 为什么不用 `go all`：实测 `go all` 会先 "Start Audio Firmware ..."，
# 音频 DSP 一起来之后 Realtek 的电源管理会把外设时钟 gate 掉，UART 直接哑掉
# （现象：CPU 还活着、网口还是 1Gbps，但串口连回显都没有了，只能断电）。
# `go k` 只起内核，不启 audio，是安全的入口。
#
# 为什么可能要 uImage：`go all`/`go k` 内部调 do_booti -> genimg_get_format()，
# 而它只认 legacy uImage(0x27051956) 和 FIT，**裸 arm64 Image 一律 INVALID**。
# 实测原厂内核在内存里也是裸 Image（iminfo 会说 Unknown image format），
# 所以原厂 bootcmd 里的那句 `go all` 其实一直是失败的 —— DSM 是 bootcode
# 自己的 SPI 直载路径起来的，没经过 u-boot。这就是为什么我们得自己喂 uImage。
#
#   uimage（默认）：Image.uimage -> 载荷落在 0x03000000（64B 头 + 裸 Image）
#   raw           ：Image       -> 0x03000000（给"其实不走 do_booti"的兜底）
#
# ★ 落点算术（踩过一次坑，务必按这个来）：
#   legacy uImage 头是 **64 字节**，所以"载荷正好落在 KADDR"要求
#       UIADDR = KADDR - 64 = 0x03000000 - 0x40 = 0x02ffffc0
#   之前写成 0x02fff000，载荷实际落在 0x02fff040，而 uImage 头里
#   ih_load/ih_ep 仍然写着 0x03000000 —— 于是 0x03000000 上躺着的是
#   Image 内部偏移 0xFC0 处的 **nop 填充**。Realtek 版 booti 的流程是
#   "先判 raw Image，不是就当 gzip 解"，它到 0x03000000 一看是 nop，
#   就报 "Not raw Image, Starting Decompress Image.gz..." -> "Bad gzipped data"。
#   （iminfo 依然显示 Legacy image found / Checksum OK，所以光看 iminfo 发现不了。）
UIADDR="${UIADDR:-0x02ffffc0}"
IHEX=""    # initramfs 大小（hex），由 cmd_prep 填

# prep [uimage|raw] —— 确保在提示符上 + 装载内核/dtb/initramfs + 写 /chosen
cmd_prep() {
	local mode="${1:-uimage}"
	[ -f "$DTB" ] || die "缺少 $DTB"
	[ -f "$INITRD" ] || die "缺少 $INITRD"
	check_agent

	local kernfile kaddr
	case "$mode" in
		uimage) kernfile="$UIMGFILE"; kaddr="$UIADDR" ;;
		raw)    kernfile="$RAWFILE";  kaddr="$KADDR"  ;;
		*) die "模式只能是 uimage 或 raw" ;;
	esac
	[ -f "$OUT/$kernfile" ] || die "缺少 $OUT/$kernfile"
	cp -f "$OUT/$kernfile" "$TFTPROOT/$kernfile"

	local isz iend
	isz=$(stat -c %s "$INITRD")
	iend=$(printf '0x%x' $(( RADDR + isz )))
	IHEX=$(printf '0x%x' "$isz")

	# ---------- 0) 确保在提示符上 ----------
	local prompt_ok=0 i
	for i in 1 2 3 4 5 6; do
		echo "$(stat -c %s "$LOG")" > "$MARKFILE"
		printf '@raw:03\n'   >> "$CTL"; sleep 1.2
		printf '@raw:0d0a\n' >> "$CTL"; sleep 1.5
		if tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | grep -q 'CM360_DS218>'; then
			prompt_ok=1; break
		fi
	done
	[ "$prompt_ok" = 1 ] || die "逼不出 u-boot 提示符（板子可能已经挂了，需要断电）"
	echo "== 0) 已在 CM360_DS218> 提示符上（第 $i 轮）"

	# ---------- 1) 内核 ----------
	echo "== 1) tftp $kernfile -> $kaddr"
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'tftp %s %s\n' "$kaddr" "$kernfile" >> "$CTL"
	cmd_wait 'Bytes transferred' 180 >/dev/null || die "内核 tftp 超时"
	printf 'iminfo %s\n' "$kaddr" >> "$CTL"
	echo "   （iminfo 说 'Legacy image found' 就说明 uImage 封装对了）"
	sleep 5
	if [ "$mode" = uimage ]; then
		# ★ 关键自检：0x03000000 上必须是 arm64 Image 头。
		#   头 8 字节 = 4d 5a 40 fa 27 3c 90 14（"MZ" + b primary_entry），
		#   u-boot 的 md 按 32 位小端显示 -> 头一个字就是 fa405a4d。
		#   如果这里是 1f2003d5（nop），说明 uImage 头没放对，载荷落在了
		#   0x02fff040 —— 那样 booti 一定会 "Not raw Image" 然后 gzip 失败。
		echo "   （自检 $KADDR 是不是 arm64 Image 头：期望 fa405a4d 273c... ）"
		echo "$(stat -c %s "$LOG")" > "$MARKFILE"
		printf 'md %s 4\n' "$KADDR" >> "$CTL"; sleep 3
		if tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | grep -qa 'fa405a4d'; then
			echo "   ✓ 载荷落点正确（$KADDR = arm64 Image 头）"
		else
			die "载荷落点错误：$KADDR 上没有 arm64 Image 头（检查 UIADDR，应为 KADDR-0x40 = 0x02ffffc0）"
		fi
	fi

	# ---------- 2) dtb + initramfs ----------
	for spec in "$(basename "$DTB"):$FADDR" "$(basename "$INITRD"):$RADDR"; do
		local f="${spec%%:*}" a="${spec##*:}"
		echo "== 2) tftp $f -> $a"
		echo "$(stat -c %s "$LOG")" > "$MARKFILE"
		printf 'tftp %s %s\n' "$a" "$f" >> "$CTL"
		cmd_wait 'Bytes transferred' 120 >/dev/null || echo "   （超时，继续）"
	done
	printf 'md %s 4\n' "$FADDR" >> "$CTL"; sleep 3

	# ---------- 3) DTB: initrd + bootargs ----------
	echo "== 3) 写 /chosen（initrd 走 DTB —— mainline 只认这条路）"
	printf 'fdt addr %s\n' "$FADDR"           >> "$CTL"; sleep 1.5
	printf 'fdt resize\n'                     >> "$CTL"; sleep 1.5
	printf 'fdt chosen %s %s\n' "$RADDR" "$iend" >> "$CTL"; sleep 2
	printf 'fdt set /chosen bootargs "%s"\n' "$BOOTARGS" >> "$CTL"; sleep 2
	printf "setenv bootargs '%s'\n" "$BOOTARGS" >> "$CTL"; sleep 1.5
	printf 'setenv fdt_high 0xffffffffffffffff\n'    >> "$CTL"; sleep 1.2
	printf 'setenv initrd_high 0xffffffffffffffff\n' >> "$CTL"; sleep 1.2
	printf 'fdt print /chosen\n'              >> "$CTL"; sleep 3
}

# bootgo —— ★★ 推荐入口，2026-10-04 实测跑通：套 legacy uImage + **`bootm`**
#
# 走过的三条弯路（按时间顺序），别再回去：
#   1) `booti <裸Image地址> ...`      -> "Wrong Image Format for do_booti command"
#      Realtek 的 do_booti 第一步 genimg_get_format() 只认 legacy uImage / FIT，
#      裸 arm64 Image 一律 INVALID。所以必须套一层 64 字节 legacy 头。
#   2) 套了 uImage 再用 `booti`        -> "Not raw Image, Starting Decompress Image.gz..."
#      Realtek 在 bootm_load_os 之后挂了个自家钩子，判"是不是 raw Image"，
#      判完说"不是"，转去当 gzip 解 -> "Bad gzipped data" -> "Decompress FAIL!!"。
#      ★ 关键：这个钩子判的**不是**目标地址上有没有合法 Image 头 ——
#        第一次尝试时 u-boot 已经把载荷 memmove 到 0x03000000 了（日志打的是
#        "Loading Kernel Image ... OK"），那里已经是合法头，它照样说"不是 raw"。
#        同一句话在 DS418J(U-Boot 2015.07 / Realtek QA Board) 上也有，是这版
#        u-boot 的通病，跟我们的镜像无关。**绕开它。**
#   3) 套了 uImage + `bootm`          -> ✅ 200 行日志一路跑到 initramfs shell
#
# 为什么 `go k` 也不行：它只给 do_booti 一个内核地址，images.ft_addr 为空，
# 于是 arm64 的 x0 = 0。head.S `mov x21, x0 // x21=FDT`，__primary_switched 再
# `str_l x21, __fdt_pointer`；x0=0 -> setup_machine_fdt() 直接失败。而 earlycon 要等
# parse_early_param() 才注册，它在 setup_machine_fdt **之后** —— 所以连
# "Error: invalid device tree blob" 都打不出来，表现就是**全静音死等**。
#
# `bootm <kernel> - <fdt>` 会把 ft_addr 交给内核（x0 = DTB），走原生路径。
# initrd 不吃 bootm 参数，改用 bootargs 的 `initrd=<addr>,<size>`（见下）。
cmd_bootgo() {
	cmd_prep uimage

	# initrd 只能走 bootargs。mainline arm64 的 early_initrd 认
	# `initrd=<addr>,<size>`；Färber 在 Zidoo X9S 上也确认
	# "I haven't succeeded loading an initrd via bootm/booti"。
	# DTB /chosen 里那份 linux,initrd-start/end 留着，两条互为兜底。
	printf "setenv bootargs '%s initrd=%s,%s'\n" "$BOOTARGS" "$RADDR" "$IHEX" >> "$CTL"
	sleep 2

	echo "== 4) bootm $UIADDR - $FADDR   （★ 不是 booti）"
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'bootm %s - %s\n' "$UIADDR" "$FADDR" >> "$CTL"
	echo
	echo "（盯日志，最多 120 秒；期望 'Run /init as init process'）"
	cmd_waitre 'Run /init as init process|Kernel panic|Decompress FAIL' 120 || true
	echo
	echo "======== bootm 之后的串口 ========"
	tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG"
}

# booti_try —— 留作对照：套 uImage + `booti`（必然撞上 "Not raw Image" 钩子）
cmd_booti_try() {
	cmd_prep uimage
	echo "== 4) booti $UIADDR $RADDR:$IHEX $FADDR"
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'booti %s %s:%s %s\n' "$UIADDR" "$RADDR" "$IHEX" "$FADDR" >> "$CTL"
	echo
	echo "（盯日志，最多 60 秒；预期会看到 Not raw Image / Decompress FAIL）"
	cmd_waitre 'Not raw Image|Run /init' 60 || true
	echo
	echo "======== booti 之后的串口 ========"
	tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG"
}

# gok —— 兜底：go k（不给 fdt，大概率静音，只用来对照）
cmd_gok() {
	cmd_prep "${1:-uimage}"
	echo "== 4) go k"
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'go k\n' >> "$CTL"
	echo
	echo "（盯日志，最多 120 秒）"
	cmd_wait 'Booting Linux' 120 || true
	echo
	echo "======== go k 之后的串口 ========"
	tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG"
}

# factory —— 在 RAM 里复刻一次原厂 bootcmd 的内核搬运，看它到底是什么封装
#
# 目的：原厂 bootcmd 是
#   run syno_bootargs; run rtk_spi_boot; run mod_fdt; ping $serverip; go all
# 其中 rtk_spi_boot 里内核那一步是
#   rtkspi read 0x100000 0x0b000000 0x2F0000; lzmadec 0x0b000000 $kernel_loadaddr 0x2F0000
# 也就是 "SPI -> 0x0b000000 -> lzma 解到 0x03000000"。我们把这两步单独跑一遍，
# 再用 iminfo/md 看 0x03000000 的头 —— 这就能回答两个关键问题：
#   1) 原厂内核在内存里是裸 arm64 Image，还是带 64 字节 legacy uImage 头？
#   2) 我们的 Image 该按哪种封装喂给 `go all`？
# 全程只碰 RAM，不写 flash。
cmd_factory() {
	check_agent
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	for c in \
		'rtkspi read 0x100000 0x0b000000 0x2F0000' \
		'lzmadec 0x0b000000 0x03000000 0x2F0000' \
		'iminfo 0x03000000' \
		'md 0x03000000 8' ; do
		printf '%s\n' "$c" >> "$CTL"
		echo "-> $c"
		sleep 6
	done
	sleep 2
	echo
	echo "======== 探针回显 ========"
	tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG"
}

# boot66 —— 引导 6.6 树（xpressreal-linux）编出来的产物
#
# 跟 bootgo 是同一条实证过的路（legacy uImage + `bootm`），只换文件名：
#   Image-6.6.uimage      套好 64 字节 legacy 头的 6.6 内核（04-build-66.sh 产出）
#   rtd1296-cm360.dtb     我们给这棵树写的板级 DTB
#   initramfs.cpio.gz     沿用 stage2 那份（cpio 与内核版本无关）
# 这三个文件要先跑 05-deploy-66.sh 放进 TFTP 根目录。
cmd_bootgo66() {
	DTB="$OUT/rtd1296-cm360.dtb" \
	INITRD="$OUT/initramfs.cpio.gz" \
	UIMGFILE="Image-6.6.uimage" \
	IMG="$OUT/Image-6.6" \
		cmd_bootgo
}

case "${1:-}" in
	send)   shift; cmd_send "$@" ;;
	multi)  shift; cmd_multi "$@" ;;
	wait)   shift; cmd_wait "$@" ;;
	tail)   shift; cmd_tail "$@" ;;
	mark)   cmd_mark ;;
	new)    cmd_new ;;
	boot)   cmd_boot ;;
	goall)  shift; cmd_goall "$@" ;;
	bootgo) cmd_bootgo ;;
	boot66) cmd_bootgo66 ;;
	booti_try|booti) cmd_booti_try ;;
	prep)   shift; cmd_prep "$@" ;;
	gok)    shift; cmd_gok "$@" ;;
	factory) cmd_factory ;;
	probe)  cmd_probe ;;
	verify) cmd_verify ;;
	*)
		sed -n '2,30p' "$0"
		exit 1
		;;
esac
