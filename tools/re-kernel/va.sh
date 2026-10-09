#!/bin/bash
# va.sh —— 对 fnOS vmlinuz-6.18.18-trim（arm64 裸 Image，未压缩）做地址定位与反汇编
#
# 标定（已实测验证）：
#   Image 文件偏移 0 ↔ 虚拟地址 _text = 0xffff800080000000
#   ∴ VA = file_offset + 0xffff800080000000
#   验证锚点：__start_rodata VA=0xffff800081170000 → 文件偏移 0x1170000，
#             该处读出 initcall_blacklist/setup_command_line 等真实 rodata 字符串
#   trim_acl_permission @ 0xffff800080480d80 反汇编出正常函数序言（paciasp/stp）
#
# 用法：
#   ./va.sh sym trim_acl_permission        # 查符号地址（后缀精确匹配）
#   ./va.sh symre 'trim_.*acl'             # 模糊查符号
#   ./va.sh disas trim_acl_permission 120  # 反汇编该符号起 120 条指令
#   ./va.sh disas-va 0xffff800080480d80 80 # 按地址反汇编
#   ./va.sh str trimafs                    # 找 NUL 结尾字符串的文件偏移与 VA
#   ./va.sh strany 'trim[a-z_]*'           # 正则找字符串
#   ./va.sh ptr 0xffff800081234567         # 找"谁指向这个地址"（8 字节 LE 指针）
#   ./va.sh hex 0xffff800081170000 256     # 看某地址的原始字节
set -euo pipefail
BASE=0xffff800080000000
# 素材目录：默认取脚本所在目录；可用 RE_DIR / RE_IMG / RE_MAP 覆盖
DIR="${RE_DIR:-/home/xiaoabiao/.cache/fnnas/re-6.18}"
IMG="${RE_IMG:-$DIR/vmlinuz-6.18.18-trim}"
MAP="${RE_MAP:-$DIR/System.map-6.18.18-trim}"
OBJDUMP=${OBJDUMP:-aarch64-linux-gnu-objdump}

va2off() { printf '%d' $(( $1 - BASE )); }
off2va() { printf '0x%x' $(( $1 + BASE )); }
slice() { dd if="$IMG" bs=1M iflag=skip_bytes,count_bytes skip="$1" count="$2" status=none; }

cmd="${1:-}"
case "$cmd" in
  sym)
    grep -E " $2\$" "$MAP" | head -20
    ;;
  symre)
    grep -E " [tTwW] $2\$" "$MAP" | head -80
    ;;
  disas)
    addr=$(grep -E " $2\$" "$MAP" | head -1 | awk '{print $1}')
    [ -n "$addr" ] || { echo "符号未找到: $2" >&2; exit 1; }
    exec "$0" disas-va "0x$addr" "${3:-60}"
    ;;
  disas-va)
    va=$2; off=$(va2off "$va"); cnt="${3:-60}"
    start=$(( off - 16 ))
    echo "== disas @ $va (file_off 0x$(printf '%x' "$off")) =="
    # 注意：objdump 读二进制需要可 seek 的输入，管道 (-) 会得到空输出，必须落临时文件
    tmp=$(mktemp /tmp/disas-XXXXXX.bin)
    slice "$start" $(( cnt * 4 + 32 )) > "$tmp"
    "$OBJDUMP" -D -b binary -m aarch64 --adjust-vma=$(( BASE + start )) "$tmp" 2>/dev/null \
      | grep -E '^[[:space:]]*ffff[0-9a-f]+:' | head -"$cnt"
    rm -f "$tmp"
    ;;
  str)
    grep -aboP "\Q$2\E\x00" "$IMG" | head -20 | while IFS=: read -r o _; do
      printf 'file_off=0x%x  VA=%s  %s\n' "$o" "$(off2va "$o")" "$2"
    done
    ;;
  strany)
    grep -aboP "$2" "$IMG" | head -40 | while IFS=: read -r o _; do
      printf 'file_off=0x%x  VA=%s\n' "$o" "$(off2va "$o")"
    done
    ;;
  ptr)
    needle=$(python3 -c "import sys,struct;sys.stdout.buffer.write(struct.pack('<Q',int(sys.argv[1],16)))" "$2")
    offs=$(grep -aboP --binary-files=text "$needle" "$IMG" | cut -d: -f1 | head -20)
    [ -n "$offs" ] || { echo "无指针指向 $2"; exit 0; }
    for o in $offs; do printf 'ptr_at file_off=0x%x  VA=%s\n' "$o" "$(off2va "$o")"; done
    ;;
  hex)
    off=$(va2off "$2"); slice "$off" "${3:-256}" | xxd
    ;;
  anchors)
    grep -E " (__start_rodata|__end_rodata|_etext|_sdata|_edata|__bss_start|_end|__init_begin|__init_end)$" "$MAP"
    ;;
  *)
    sed -n '2,26p' "$0"
    ;;
esac
