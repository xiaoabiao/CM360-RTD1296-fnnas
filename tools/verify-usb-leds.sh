#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# 新内核 + 新 DTB 启动后的验收脚本（只读，不做任何写入/测试性操作）
#
# 用法（在板子上以 root 运行）：  bash verify-usb-leds.sh
# 目的：一次性收集 USB、iso GPIO、LED、pinctrl 的现场状态，便于判定：
#   - USB 三个控制器是否 probe、Type-C/USB-A 插上设备是否枚举；
#   - iso GPIO 控制器是否出现、gpio-ranges 是否生效（pinctrl claim）；
#   - 盘位灯是否注册、默认 trigger 是否 disk-activity、当前 brightness；
#   - USB 时钟 clk_en_usb 是否真被打开。
# ═══════════════════════════════════════════════════════════════════════════
set -u
echo "╔══════════ 0. 内核与设备树 ══════════╗"
uname -a
echo
echo "--- /proc/device-tree 里的 usb / led / gpio 节点 ---"
find /proc/device-tree -maxdepth 4 \( -iname '*usb*' -o -iname '*led*' -o -iname '*gpio*' \) 2>/dev/null | sed 's|/proc/device-tree||' | sort
echo
echo "╔══════════ 1. USB 控制器 ══════════╗"
echo "--- dmesg 相关行 ---"
dmesg | grep -iE 'usb|dwc3|xhci|phy-rtk|rtk_usb' | tail -40
echo
echo "--- usb_manager / dwc3 / xhci 平台设备（probe 成功才会有 driver 链接）---"
for d in /sys/bus/platform/devices/*usb* /sys/bus/platform/devices/*dwc3*; do
	[ -e "$d" ] || continue
	printf '%-52s driver=%s\n' "$(basename "$d")" "$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
done
echo
echo "--- /sys/bus/usb/devices（枚举到的 USB 设备/集线器）---"
ls -l /sys/bus/usb/devices/ 2>/dev/null || echo "（空）"
echo
echo "--- lsusb ---"
lsusb 2>/dev/null || echo "（无 lsusb 或没有任何设备）"
echo
echo "--- clk_en_usb 是否打开（rate>0 才算真开了）---"
if [ -d /sys/kernel/debug/clk ]; then
	for c in /sys/kernel/debug/clk/*usb*/; do
		[ -e "$c/enable_count" ] || continue
		printf '%-40s rate=%s enable_count=%s\n' "$(basename "$c")" "$(cat "$c/clk_rate" 2>/dev/null)" "$(cat "$c/enable_count" 2>/dev/null)"
	done
else
	echo "（没有 debugfs clk 目录；先 mount -t debugfs none /sys/kernel/debug）"
fi
echo
echo "╔══════════ 2. GPIO 控制器 ══════════╗"
echo "--- /sys/class/gpio ---"
for g in /sys/class/gpio/gpiochip*; do
	[ -e "$g" ] || continue
	printf '%s label=%s base=%s ngpio=%s\n' "$(basename "$g")" "$(cat "$g/label" 2>/dev/null)" "$(cat "$g/base" 2>/dev/null)" "$(cat "$g/ngpio" 2>/dev/null)"
done
echo
echo "--- pinctrl pinmux-pins（重点看 pin 21/26 是否被 gpio-leds claim、function=gpio）---"
for f in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
	[ -e "$f" ] || continue
	echo "== $f"
	grep -E 'pin (21|26) ' "$f" 2>/dev/null
done
echo
echo "╔══════════ 3. 盘位指示灯 ══════════╗"
echo "--- /sys/class/leds ---"
ls -l /sys/class/leds/ 2>/dev/null || echo "（空 —— leds 节点没生效）"
echo
for led in /sys/class/leds/*/; do
	[ -e "$led" ] || continue
	echo "== $(basename "$led")"
	echo "   trigger: $(tr '\0' ' ' < "$led/trigger" 2>/dev/null)"
	echo "   brightness: $(cat "$led/brightness" 2>/dev/null)  max: $(cat "$led/max_brightness" 2>/dev/null)"
	grep -E '^[0-9]' "$led/trigger" 2>/dev/null | sed 's/^/   trig: /'
done
echo
echo "--- dmesg 里 leds-gpio 行 ---"
dmesg | grep -iE 'leds|gpio-leds|ledtrig' | tail -10
echo
echo "--- 盘位灯守护 cm360-hdd-led（在位常亮 + 有 IO 闪烁）---"
if systemctl is-active --quiet cm360-hdd-led.service 2>/dev/null; then
	echo "   service: active（$(systemctl show -p MainPID --value cm360-hdd-led.service)）"
	/usr/local/bin/cm360-hdd-led.py --once 2>/dev/null | sed 's/^/   /'
	echo -n "   1 秒内 brightness 采样(hdd1/hdd2):"
	for i in $(seq 1 5); do
		echo -n " $(cat /sys/class/leds/hdd1/brightness 2>/dev/null)/$(cat /sys/class/leds/hdd2/brightness 2>/dev/null)"
		sleep 0.2
	done
	echo "   ← 空闲时应全为 1；做 dd 读盘时应看到 0/1 交替"
else
	echo "   service: 未运行 —— 只有内核 disk-activity 兜底（有 IO 闪 30ms、空闲灭）"
	echo "   安装：bash boards/rtd1296-cm360/board-scripts/cm360-hdd-led/install.sh"
fi
echo
echo "╔══════════ 4. 块设备（盘位灯 trigger 依赖） ══════════╗"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | head -20
echo
echo "验收采集完毕。把以上输出整段贴回即可。"
