#!/bin/bash
# =============================================================================
# tools/led_probe.sh — CM360 HDD LED 只读探测脚本
# -----------------------------------------------------------------------------
# 目的：在【不改板子状态】的前提下，采集 CM360(RTD1296) 硬盘指示灯相关的一切证据：
#   1) LED class / gpio sysfs / debugfs gpio / DTB 节点现状
#   2) iso pinctrl 的 pins / functions / pinmux-pins / pinconf（含 pin21、pin26 归属）
#   3) ISO GPIO 寄存器（DIR/DATO/DATI）与候选脚 bit21/bit26 解码
#   4) ISO 中断块 / PWM 寄存器只读快照（辅助判断风扇 pwm_0 占用）
#   5) dmesg / board.json / led-set 服务状态
#
# 本脚本【只读】：只做 ls/cat/readlink/devmem 读/ dmesg 读取；
#   不 export GPIO、不写 devmem、不改 sysfs、不动服务。
#
# 用法（板子上，root）：
#   MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' python tools/brd.py push tools/led_probe.sh /tmp/led_probe.sh
#   export PYTHONIOENCODING=utf-8
#   python tools/brd.py sudo 'bash /tmp/led_probe.sh'
#
# 背景结论（见 docs/reports/cm360-led-gpio-re.md）：
#   厂商 DTB sata@9803F000 的 blink-gpios = iso GPIO26 / ISO GPIO21（2 盘位指示灯）。
#   ISO GPIO 寄存器块 = 0x98007100（DIR 0x0 / DATO 0x4 / DATI 0x8 / IE 0xC / DP 0x10，bank1 @ +0x18）。
#   注意：0x98007000 是它旁边的“中断块”，不要把 DIR 读错（旧笔记曾在此处误读）。
# =============================================================================
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

ISO_GPIO_BASE_ADDR=0x98007100     # 6.6 gpio-rtd: resource0 = GPIO 寄存器块
ISO_IRQ_BASE_ADDR=0x98007000      # 6.6 gpio-rtd: resource1 = 中断寄存器块
PIN_BAY0=26                        # blink-gpios[0] -> sata-port@0（暂定 HDD1）
PIN_BAY1=21                        # blink-gpios[1] -> sata-port@1（暂定 HDD2，⚠ 与风扇 pwm_0 抢脚）

hr()  { printf '%s\n' "------------------------------------------------------------------------"; }
sec() { echo; hr; echo "## $*"; hr; }
note(){ printf '   %s\n' "$*"; }

# ------------------------------ 只读寄存器读 ------------------------------
read_reg() {
    local addr="$1" v
    if command -v devmem >/dev/null 2>&1; then
        v=$(devmem "$addr" 2>/dev/null) && { echo "$v"; return; }
    fi
    if command -v busybox >/dev/null 2>&1; then
        v=$(busybox devmem "$addr" 2>/dev/null) && { echo "$v"; return; }
    fi
    echo "N/A"
}

# 读寄存器并按位解码（$2=位号）
reg_bit() {
    local addr="$1" bit="$2" v n
    v=$(read_reg "$addr")
    case "$v" in
    ''|N/A) echo "$v"; return ;;
    esac
    n=$(( v >> bit & 1 ))
    echo "$v  (bit$bit=$n)"
}

dump_bits() { # $1=addr $2=bits...  一次读出、逐位打印
    local addr="$1" v b out=""
    shift
    v=$(read_reg "$addr")
    for b in "$@"; do
        if [ "$v" = "N/A" ] || [ -z "$v" ]; then out="${out} bit$b=N/A"; else
            out="${out} bit$b=$(( v >> b & 1 ))"; fi
    done
    echo "$v  [$out ]"
}

# ------------------------------ 0) 基本环境 ------------------------------
sec "0) 基本环境"
echo "date        : $(date -Is 2>/dev/null || date)"
echo "uname       : $(uname -a)"
echo "cmdline     : $(cat /proc/cmdline 2>/dev/null)"
echo "model       : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo N/A)"
echo "compatible  : $(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | tr '\0' ' ' || echo N/A)"
echo "uid/root    : $(id -u 2>/dev/null)  (需要 0 才能读 debugfs /dev/mem)"
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    note "⚠ 当前不是 root：后面 debugfs 与 devmem 段会失败，请用 sudo 重跑。"
fi

# ------------------------------ 1) LED class / gpio sysfs ------------------------------
sec "1) LED class 与 GPIO sysfs 现状"
echo "[1.1] /sys/class/leds/:"
if [ -d /sys/class/leds ]; then
    if [ -z "$(ls -A /sys/class/leds 2>/dev/null)" ]; then
        note "(空) —— 内核没有任何 LED class 设备；仅写 board.json 不会创建 LED。"
    else
        for d in /sys/class/leds/*/; do
            [ -e "$d" ] || continue
            echo "  - $(basename "$d")  trigger=[$(sed -ne 's/^.*\[\(.*\)\].*$/\1/p' "$d/trigger" 2>/dev/null)]  brightness=$(cat "$d/brightness" 2>/dev/null)  max=$(cat "$d/max_brightness" 2>/dev/null)"
        done
    fi
else
    note "/sys/class/leds 不存在"
fi

echo
echo "[1.2] /sys/class/gpio/（CONFIG_GPIO_SYSFS）:"
if [ -d /sys/class/gpio ]; then
    ls -la /sys/class/gpio/ 2>/dev/null
    for c in /sys/class/gpio/gpiochip*; do
        [ -e "$c" ] || continue
        echo "  chip $(basename "$c"): base=$(cat "$c/base" 2>/dev/null) ngpio=$(cat "$c/ngpio" 2>/dev/null) label=$(cat "$c/label" 2>/dev/null)"
    done
    note "↑ 应该看到两颗：misc(101线, label 9801b100.gpio) 与 iso(35线, label 形如 ...gpio@100)。"
    note "  只有 misc 说明运行中的 DTB 还没有 iso_gpio 节点（需要重新编译/刷 DTB）。"
else
    note "/sys/class/gpio 不存在（GPIO_SYSFS 未开）"
fi

# ------------------------------ 2) debugfs gpio ------------------------------
sec "2) /sys/kernel/debug/gpio"
if [ -r /sys/kernel/debug/gpio ]; then
    cat /sys/kernel/debug/gpio
else
    note "不可读（需要 root，或 debugfs 未挂载: mount -t debugfs none /sys/kernel/debug）"
fi

# ------------------------------ 3) pinctrl ------------------------------
sec "3) pinctrl 状态（iso 域, 9801a000.pinctrl-foo）"
PCTL=""
for d in /sys/kernel/debug/pinctrl/*/; do
    case "$d" in *pinctrl*) PCTL="$d"; break ;; esac
done
if [ -z "$PCTL" ]; then
    note "未找到 pinctrl debugfs 目录（root?）"
else
    echo "pinctrl dir: $PCTL"
    echo
    echo "[3.1] pins（只列候选）:"
    grep -E "pin ($PIN_BAY0|$PIN_BAY1|33|34) " "$PCTL/pins" 2>/dev/null || true
    echo
    echo "[3.2] function 0 (gpio) 的组里是否含 iso_gpio_21 / i2c_sda_6:"
    grep -A2 "function 0:" "$PCTL/pinmux-functions" 2>/dev/null | head -5
    echo
    echo "[3.3] pinmux-pins（候选脚被谁占用 / mux 是什么）:"
    grep -E "pin ($PIN_BAY0|$PIN_BAY1|33|34) " "$PCTL/pinmux-pins" 2>/dev/null || true
    echo
    echo "[3.4] pinconf-pins（候选脚上下拉/驱动强度）:"
    grep -E "pin ($PIN_BAY0|$PIN_BAY1) " "$PCTL/pinconf-pins" 2>/dev/null || true
    note "期望（方案生效前）：pin 21 由 980070d0.pwm(pwm_0) 占用；pin 26 (i2c_sda_6) 未占用。"
    note "期望（方案生效后）：pin 26/21 由 gpio-leds 申请，mux=gpio。"
fi

# ------------------------------ 4) ISO GPIO 寄存器 ------------------------------
sec "4) ISO GPIO 寄存器只读采样（GPIO 块基址 $ISO_GPIO_BASE_ADDR）"
echo "[4.1] bank0 DIR/DATO/DATI/IE/DP:"
for off in 0x0 0x4 0x8 0xc 0x10; do
    printf "  %s + 0x%-4s = %s\n" "$ISO_GPIO_BASE_ADDR" "$off" "$(read_reg "$(printf '0x%x' $(( ISO_GPIO_BASE_ADDR + off )))")"
done
echo "[4.2] bank0 DIR/DATO/DATI 的 bit21(pin21)、bit26(pin26) 解码:"
printf "  DIR0  0x%x: %s\n" $(( ISO_GPIO_BASE_ADDR + 0x0 ))  "$(dump_bits "$(printf '0x%x' $(( ISO_GPIO_BASE_ADDR + 0x0 )))"  $PIN_BAY1 $PIN_BAY0)"
printf "  DATO0 0x%x: %s\n" $(( ISO_GPIO_BASE_ADDR + 0x4 ))  "$(dump_bits "$(printf '0x%x' $(( ISO_GPIO_BASE_ADDR + 0x4 )))"  $PIN_BAY1 $PIN_BAY0)"
printf "  DATI0 0x%x: %s\n" $(( ISO_GPIO_BASE_ADDR + 0x8 ))  "$(dump_bits "$(printf '0x%x' $(( ISO_GPIO_BASE_ADDR + 0x8 )))"  $PIN_BAY1 $PIN_BAY0)"
echo "[4.3] bank1（iso pin32-34 所在）:"
for off in 0x18 0x1c 0x20 0x24 0x28; do
    printf "  %s + 0x%-4s = %s\n" "$ISO_GPIO_BASE_ADDR" "$off" "$(read_reg "$(printf '0x%x' $(( ISO_GPIO_BASE_ADDR + off )))")"
done

sec "5) ISO 中断块只读采样（$ISO_IRQ_BASE_ADDR，勿与 GPIO 块混淆）"
for off in 0x0 0x4 0x8 0xc 0x10 0x14; do
    printf "  %s + 0x%-4s = %s\n" "$ISO_IRQ_BASE_ADDR" "$off" "$(read_reg "$(printf '0x%x' $(( ISO_IRQ_BASE_ADDR + off )))")"
done

# ------------------------------ 6) pinmux 原始寄存器 ------------------------------
sec "6) ISO pinctrl mux 寄存器只读采样（0x9801a000 块）"
note "pin26(i2c_sda_6) mux@0x14 bits3:2: 0=gpio 1=i2c6；pin21(iso_gpio_21) mux@0x1c bits1:0: 0=gpio 1=pwm_0"
printf "  0x9801a014 = %s   (pin26 mux)\n" "$(read_reg 0x9801a014)"
printf "  0x9801a01c = %s   (pin21 mux)\n" "$(read_reg 0x9801a01c)"
printf "  0x9801a008 = %s   (pin26 config/pull 区)\n" "$(read_reg 0x9801a008)"
printf "  0x9801a018 = %s   (pin21 config/pull 区)\n" "$(read_reg 0x9801a018)"
note "若要精确解码：pin26 mux=(v>>2)&3，pin21 mux=v&3。"

# ------------------------------ 7) PWM / fan 相关（辅助判断 iso21 归属） ------------------------------
sec "7) PWM 寄存器只读（判断风扇是否还在用 pwm_0/iso21）"
note "pwm@980070d0：全 1 = 某通道 enable；若 pwm_0 enable=1 且 pin21 mux=1，说明 iso21 当前是风扇 PWM。"
for a in 0x980070d0 0x980070d4 0x980070d8; do
    printf "  %s = %s\n" "$a" "$(read_reg "$a")"
done

# ------------------------------ 8) dmesg / board.json / 服务 ------------------------------
sec "8) dmesg / board.json / 服务状态"
echo "[8.1] dmesg（led/gpio/pinctrl/ahci 相关，最后 30 行）:"
dmesg 2>/dev/null | grep -iE "led|gpio-rtd|pinctrl|ahci|blink" | tail -30 || note "dmesg 不可读"
echo
echo "[8.2] /boot/board.json:"
if [ -f /boot/board.json ]; then
    echo "  存在，内容:"
    cat /boot/board.json
else
    note "不存在（led-set/set_gpio-init 会 exit 1）"
fi
echo
echo "[8.3] 服务状态:"
systemctl is-active led-set.service set_gpio-init.service 2>/dev/null | paste -sd' ' - || true
systemctl status led-set.service --no-pager -l 2>/dev/null | tail -6 || true

# ------------------------------ 9) 汇总提示 ------------------------------
sec "9) 汇总解读"
echo "  候选引脚: iso GPIO26(bay0/HDD1) / iso GPIO21(bay1/HDD2) —— 来自厂商 DTB blink-gpios。"
echo "  关键判读:"
echo "   - 若 [1.2] 只有一颗 gpiochip(misc)：DTB 没编进 iso_gpio 节点 → 需先刷 DTB。"
echo "   - 若 [4.2] DIR0 的 bit26/bit21 全为 0（输入）且 DATO 位为 0：引脚当前未输出，安全可测。"
echo "   - 若 [3.3] pin21 仍被 980070d0.pwm 占用：风扇 pwm_0 正在用 iso21，接线前需 lead 决策。"
echo "   - 若 [1.1] 出现 hdd1:green:disk：说明 gpio-leds 已生效，读 trigger 应为 disk-activity。"
echo
echo "  下一步（写操作，需 lead/USER 批准，见报告 §8）："
echo "   BASE=<iso chip base>; G=\$((BASE+26)); echo \$G > /sys/class/gpio/export; ... "
echo "   （一次只动一根、测完 direction=in + unexport；详见 docs/reports/cm360-led-gpio-re.md §8）"
hr
echo "只读探测完成（未做任何写操作）。"
