#!/bin/bash
# make-lineflash-official.sh —— 用**厂商官方打包工具** rtd129x_img_gen 生成 Realtek
# USB MP Tool 线刷包（install.img）。
#
# 为什么要有这个脚本（与 tools/make-lineflash-package.py 的区别）
# ---------------------------------------------------------------
# 旧脚本是"按逆向出来的格式手写" config.txt / layout.txt / mbr.bin / fw_tbl.bin；
# 厂商工具对这几份元数据有自己的一套规则（分区扇区数会少算 16 扇区、fstype 只认
# squashfs/ext4、Layout_Type 是固定名字白名单……），手写的包虽然"能载入"，
# 但线刷时的行为没有保证。
#
# 现在按社区同款流程：**把固件文件放进一个工作目录 + 一个 JSON 描述分区，
# 由 rtd129x_img_gen 生成元数据，再 tar 打包**。元数据与厂商工具同源。
#
# 已知/已验证（2026-10-20）
# -------------------------
# * 用厂商 iStoreOS CM360 包（istore-r16974-cm360.install.img）反推的
#   emmc_8gb.json 重跑本工具，生成的 config.txt / mbr.bin / fw_tbl.bin 与厂商
#   包**逐字节相同**，layout.txt 仅生成时间戳不同；
# * 工具只支持 filesystem = squashfs / ext4（写其它值直接报
#   `unsupported fstype:...` 并退出）。本板 p2 是 btrfs，但该字段只进元数据、
#   工具不会格式化分区，所以这里标成 ext4（内容仍是 btrfs 镜像）；
# * 工具给每个分区算的扇区数 = 声明值 - 16 扇区（8 KiB）。本板 ext4/btrfs
#   内核会校验"设备尺寸 ≥ 文件系统尺寸"，所以打包前必须把镜像做成
#   **与 MBR 完全一致**的尺寸（p1=0x7FFF0 扇区，p2=0xDFC7F0 扇区）。
#   firmware/build-images.sh 生成的是"板子实机分区尺寸"（0x80000 / 0xDFC800），
#   必须**先收缩**成上面尺寸再打包（--shrink-to-mbr 是占位参数、尚未实现）。
# * Layout_Type 是固定白名单（FW_KERNEL / FW_P_UBOOT / FW_BL31 / PARTn / MBR0 …），
#   自定义名字（如旧脚本的 FW_LOWREGION）会被厂商工具**静默忽略** —— 所以线刷包
#   不能再靠一条 FW_LOWREGION 写低区；低区仍走 dd / TFTP / "only upgrade bootloader"。
# * 工具会自动追加 FW_FWTBL（写到低区 0x620000，原厂镜像区）。本板 u-boot 不读
#   该表，为不动低区数据，本脚本默认把这条从 layout.txt 里删掉（--keep-fwtbl 保留）。
#
# 用法（在 Linux / WSL 里跑，需要厂商的 rtd129x_img_gen 可执行文件）
# -------------------------------------------------------------------
#   ./tools/make-lineflash-official.sh \
#       --tool  /path/to/rtd129x_img_gen \
#       --p1    /root/cm360-build/images/p1.img \
#       --p2    /root/cm360-build/images/p2.img \
#       --out   /root/cm360-build/out \
#       --version 1.2.0302
#
#   --no-p2          只打 p1（快速验证元数据/载入用）。⚠️ 工具会顺带把 MBR 改成
#                    只剩 1 个分区 ⇒ 必须同时加 --keep-mbr（不写 MBR），否则会把
#                    板上的 p2 分区表抹掉。p1 尺寸也必须正好等于板上 p1 分区
#                    （0x80000 扇区），所以不要用收缩过的 p1（或先重建成实机尺寸）。
#   --keep-mbr       不写 MBR0（沿用板上现有分区表）
#   --shrink-to-mbr  ⚠️ 占位参数（**当前未实现**，脚本只做尺寸校验、不会收缩）。
#                    请直接提供按 MBR 扇区数生成的镜像：p1=0x7FFF0（268,427,264 B）、
#                    p2=0xDFC7F0（7,508,844,544 B）。build-images.sh 输出是实机尺寸
#                    （大 8 KiB），需先自行收缩，否则校验阶段会报"尺寸 > 分区"。
#                    p1 举例：e2fsck -fy p1.img && resize2fs p1.img 65534 && truncate -s 268427264 p1.img
#   --lowregion FILE 把整块 38 MiB 低区镜像（hwsetting/bootcode/u-boot/env/factory）
#                    作为 FW_KERNEL 载荷、offset 改成 0 一起刷进去 ⇒ 刷完 u-boot env
#                    自动恢复（解决"线刷后 read_env from factory failed"），也能从
#                    砖头状态直接救回。⚠️ 写低区期间断电有变砖风险（可再救）。
#                    低区镜像用 firmware/low-region-38MiB.img.gz 解压后的 img。
#   --factory-tar FILE 把**根相对成员 `env.txt`** 的 factory.tar 放进 omv/（用
#                    tools/make-factory-tar.py 从低区镜像生成；不给又带 --lowregion 时
#                    脚本会自动生成）。工具刷写最后一步会把它写回 eMMC 0x220000/0x420000，
#                    u-boot env 因此恢复。（不加这个，工具会写空白 factory.tar，把 env 清掉。）
#                    ⚠️ 不要直接把低区 0x220000 的原始 factory 区 blob（成员是
#                    tmp/factory/env.txt）传进来 —— 工具会套成
#                    tmp/factory/tmp/factory/env.txt，env 依旧读不到；脚本会自动纠正并告警。
#   --p2-split[=N]   ⚠️ 实验性、**已实测不可用**：把 p2 拆成 N（默认 4）个 PART 条目，
#                    想绕过单载荷 2 GiB 限制。但工具载入时把**所有** PART 载荷读进内存，
#                    总量不变 → 真机报 `GetLastError:8` + `load [PART2] data failed`。
#                    仅保留作证据/复现（见 docs/10 §16.3 ⑨）。要功能完整请用
#                    firmware/make-extra-features.sh 生成注入包，刷机后再板端安装。
#   --p2-split-count N  同 --p2-split，指定片数。
#   --full-p2        ★ 用**完整 p2 镜像**（7.0 GiB，不精简、不分片）出包，并跳过
#                    "< 2 GiB 单载荷" 检查。⚠️ 厂商 32 位工具载入必失败
#                    （GetLastError:8 / 0xC0000409），**只给支持大载荷的其它工具**测试用。
#                    产物 ≈7.8 GB，命名 `...-full-uboot-fullp2.img`。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

TOOL=""
JSON="$HERE/lineflash/emmc_8gb_cm360.json"
P1=""
P2=""
OUT=""
VER="1.2.0302"
NO_P2=0
KEEP_MBR=0
KEEP_FWTBL=0
SHRINK=0
LOWREGION=""
LOWREGION_END=$((0x2600000))      # 低区终点 = p1 起点（38 MiB）
FACTORY_TAR=""                    # 带 env.txt 的原厂 factory.tar（工具刷写最后会写它）
P2_SPLIT=0                        # 1 = 实验：p2 切成多片（真机实测载入失败，见 §16.3 ⑨）
P2_CHUNKS=4
FULL_P2=0                         # 1 = 完整 p2（不精简/不分片），跳过 2 GiB 检查，供大载荷工具测试

die() { echo "!! $*" >&2; exit 1; }
need() { [ -n "${1:-}" ] || die "缺参数：$2"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--tool) need "${2:-}" "$1"; TOOL="$2"; shift 2 ;;
	--json) need "${2:-}" "$1"; JSON="$2"; shift 2 ;;
	--p1)   need "${2:-}" "$1"; P1="$2"; shift 2 ;;
	--p2)   need "${2:-}" "$1"; P2="$2"; shift 2 ;;
	--out)  need "${2:-}" "$1"; OUT="$2"; shift 2 ;;
	--version) VER="$2"; shift 2 ;;
	--no-p2) NO_P2=1; shift ;;
	--keep-mbr) KEEP_MBR=1; shift ;;
	--keep-fwtbl) KEEP_FWTBL=1; shift ;;
	--shrink-to-mbr) SHRINK=1; shift ;;
	--lowregion) need "${2:-}" "$1"; LOWREGION="$2"; shift 2 ;;
	--factory-tar) need "${2:-}" "$1"; FACTORY_TAR="$2"; shift 2 ;;
	--p2-split) P2_SPLIT=1; shift ;;
	--p2-split-count) need "${2:-}" "$1"; P2_SPLIT=1; P2_CHUNKS="$2"; shift 2 ;;
	--full-p2) FULL_P2=1; shift ;;
	-h|--help) sed -n '2,74p' "$0"; exit 0 ;;
	*) die "未知参数：$1（--help 看用法）" ;;
	esac
done

need "$TOOL" "--tool"; need "$P1" "--p1"; need "$OUT" "--out"
[ -x "$TOOL" ] || die "工具不可执行：$TOOL"
[ -f "$JSON" ] || die "找不到 JSON：$JSON"
[ -f "$P1" ] || die "找不到 p1：$P1"
if [ "$NO_P2" = 0 ]; then need "$P2" "--p2"; [ -f "$P2" ] || die "找不到 p2：$P2"; fi
if [ "$FULL_P2" = 1 ] && [ "$NO_P2" = 1 ]; then die "--full-p2 与 --no-p2 互斥"; fi
if [ "$FULL_P2" = 1 ] && [ "$P2_SPLIT" = 1 ]; then die "--full-p2（整块）与 --p2-split（分片）互斥"; fi
mkdir -p "$OUT"
WORK="$(mktemp -d "$OUT/.stage-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "== 1/6 暂存固件文件 =="
# 同一文件系统时用硬链接，避免把 7 GB 的 p2 再复制一遍（工具只读载荷，不会改）
ln "$P1" "$WORK/p1.img" 2>/dev/null || cp "$P1" "$WORK/p1.img"
if [ "$NO_P2" = 0 ]; then
	# 分片模式也需要一个 p2.img 供工具生成元数据（硬链接，随后删除）
	ln "$P2" "$WORK/p2.img" 2>/dev/null || cp "$P2" "$WORK/p2.img"
fi
echo "   p1 = $(stat -c %s "$WORK/p1.img") 字节 ($(( $(stat -c %s "$WORK/p1.img") / 512 )) 扇区)"
if [ "$NO_P2" = 0 ] && [ "$P2_SPLIT" = 0 ]; then
	echo "   p2 = $(stat -c %s "$WORK/p2.img") 字节 ($(( $(stat -c %s "$WORK/p2.img") / 512 )) 扇区)"
fi
if [ "$P2_SPLIT" = 1 ]; then
	# ★ p2 分片：完整 p2 镜像（可 >2 GiB）切成 N 个 <2 GiB 的分片，
	#   作为 PART1..PARTn 连续写入（工具按 PART 逐块写，每块都 <2 GiB 就不触发
	#   它 32 位文件大小的溢出）。分片按 8 KiB 对齐，保证不留空洞。
	python3 - "$P2" "$WORK" "$P2_CHUNKS" <<'PY'
import os, sys
src, work, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
total = os.path.getsize(src)
AL = 0x2000
base = (total // n) // AL * AL
sizes = [base] * (n - 1)
sizes.append(total - base * (n - 1))
assert all(0 < s < 2**31 for s in sizes), [hex(s) for s in sizes]
names = []
with open(src, 'rb') as f, open(os.path.join(work, 'chunks.txt'), 'w') as man:
    for i, sz in enumerate(sizes):
        name = f'p2{"abcdefgh"[i]}.img'
        names.append(name)
        with open(os.path.join(work, name), 'wb') as o:
            left = sz
            while left:
                buf = f.read(min(1 << 20, left))
                if not buf: raise SystemExit('short read')
                o.write(buf); left -= len(buf)
        man.write(f'{name} {sz:#x}\n')
print(f'   （--p2-split：p2 {total:,} B -> {n} 片：' + ', '.join(f'{s:,}' for s in sizes) + '）')
PY
	[ -f "$WORK/chunks.txt" ] || die "p2 分片失败"
fi

echo "== 2/6 运行官方 rtd129x_img_gen =="
if [ "$NO_P2" = 1 ]; then
	# JSON 里还留着 p2 → 工具会报 "can not open p2.img"；只打 p1 时去掉第 2 个分区
	python3 - "$JSON" "$WORK/package.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if len(d.get("part", [])) > 1:
    d["part"] = d["part"][:1]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
print("   （--no-p2：已从 JSON 去掉第 2 个分区）")
PY
elif [ "$P2_SPLIT" = 1 ]; then
	# 工具限制「MBR 最多 4 个分区」，不能在 JSON 里直接放 5 个 part。
	# 仍按 2 个分区生成（MBR 标准 p1/p2），随后在 4/6 步把 layout 的 PART1 一行
	# 改写成若干连续分片 PART1..PARTn。
	cp "$JSON" "$WORK/package.json"
else
	cp "$JSON" "$WORK/package.json"
fi
if [ -n "$LOWREGION" ]; then
	# ★ 整块低区（hwsetting/bootcode/u-boot/env/factory）伪装成 FW_KERNEL 载荷：
	#   工具会把 FW_KERNEL 指向的文件原样写到布局里的 offset，于是刷机时连
	#   u-boot + env 一起写回 —— 解决"线刷后 env 丢失、必须恢复"的问题。
	#   注意：offset 不能是 0（LoadFlashLayout 用 offset!=0 判断条目有效），
	#   所以从 0x200 开始写（跳过前 512 字节 MBR；MBR 由 MBR0 条目单独写）。
	[ -f "$LOWREGION" ] || die "找不到低区镜像：$LOWREGION"
	LSZ=$(stat -c %s "$LOWREGION")
	[ "$LSZ" -le "$LOWREGION_END" ] || die "低区镜像 $LSZ B 超过 p1 起点 $LOWREGION_END —— 会压到 p1"
	SKIP=512
	tail -c +$((SKIP + 1)) "$LOWREGION" > "$WORK/low-region.img"
	LSZ2=$(stat -c %s "$WORK/low-region.img")
	python3 - "$WORK/package.json" "$WORK/package.json" <<'PY'
import json, sys
# 注意：读当前 package.json（可能已被 --no-p2 / --p2-split 改过），只改 fw/fw_start
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["fw"] = [{"type": "KERNEL", "target": "0x3000000", "file": "low-region.img"}]
d["gold"] = []
# 低区从 0x200 写到 p1 起点 0x2600000：fw_start=0x200，FW 区终点正好 = p1 起点，
# 不触发工具的 "firmwares overlaps normal partitions" 校验。
d["fw_start"] = "0x200"
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
print(f"   （--lowregion：FW_KERNEL = 整块低区 {d['fw'][0]['file']}，fw_start=0x200，跳过 MBR）")
PY
	echo "   low-region = $LSZ 字节（去掉前 $SKIP 字节后 $LSZ2 字节，写入 0x200~0x$(printf '%x' $((SKIP + LSZ2)))）"
fi
# JSON 的 fw[] 里引用的文件也要在工作目录里（工具按当前目录找文件）
JSON_DIR="$(cd "$(dirname "$JSON")" && pwd)"
python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for e in d.get("fw",[])+d.get("gold",[]):
    f=e.get("file","")
    if f: print(f)' "$WORK/package.json" | while IFS= read -r f; do
	[ -n "$f" ] || continue
	[ -f "$WORK/$f" ] && continue          # --lowregion 已经放好
	[ -f "$JSON_DIR/$f" ] || die "JSON 引用的文件不存在：$JSON_DIR/$f"
	cp "$JSON_DIR/$f" "$WORK/$f"
done
( cd "$WORK" && "$TOOL" package.json . )
for f in config.txt layout.txt mbr.bin fw_tbl.bin; do
	[ -f "$WORK/$f" ] || die "工具没有生成 $f"
done
if [ -n "$LOWREGION" ]; then
	# 校验工具生成的 FW_KERNEL 条目：offset=0x200、终点正好到 p1 起点
	grep -qE 'FW_KERNEL " target=[0-9a-f]+ offset=200 size=[0-9a-f]+ type=bin name=low-region\.img' "$WORK/layout.txt" \
		|| die "FW_KERNEL 条目不符合预期（应为 offset=200 / name=low-region.img），请检查 rtd129x_img_gen 输出"
	echo "   ✔ FW_KERNEL 低区整块写入（offset=0x200，终点 = p1 起点 0x2600000）"
fi
if [ "$P2_SPLIT" = 1 ]; then
	# ★ 把工具生成的 PART1（单条、name=p2.img）改写成 N 条连续分片 PART1..PARTn，
	#   并把 config.txt 的 p2 part 行同步改成分片；删掉占位 p2.img。
	python3 - "$WORK" <<'PY'
import os, re, sys
work = sys.argv[1]
chunks = [ln.split() for ln in open(os.path.join(work, "chunks.txt"), encoding="utf-8") if ln.strip()]

lp = os.path.join(work, "layout.txt")
lt = open(lp, encoding="utf-8").read()
m = re.search(r'^#define PART1 "[^"]*"\s*$', lt, re.M)
if not m:
    sys.exit("!! layout.txt 里找不到 PART1 行")
line = m.group(0)
off = int(re.search(r'offset=([0-9a-fA-F]+)', line).group(1), 16)
new = []
cur = off
for i, (name, size) in enumerate(chunks):
    sz = int(size, 16)
    ln = re.sub(r'PART1', f'PART{i+1}', line, count=1)
    ln = re.sub(r'offset=[0-9a-fA-F]+', f'offset={cur:x}', ln, count=1)
    ln = re.sub(r'size=[0-9a-fA-F]+', f'size={sz:x}', ln, count=1)
    ln = re.sub(r'\sname=[^ "]+', f' name={name}', ln, count=1)
    new.append(ln)
    cur += sz
lt = lt.replace(line, "\n".join(new), 1)
open(lp, "w", encoding="utf-8").write(lt)

cp = os.path.join(work, "config.txt")
ct = open(cp, encoding="utf-8").read()
cm = re.search(r'^part = rootfs / ext4 p2\.img \d+\s*$', ct, re.M)
if cm:
    nc = "\n".join(f'part = rootfs / ext4 {n} {int(s,16)}' for n, s in chunks)
    ct = ct.replace(cm.group(0), nc, 1)
    open(cp, "w", encoding="utf-8").write(ct)

os.remove(os.path.join(work, "p2.img"))
print(f"   ✔ layout PART1 -> PART1..PART{len(chunks)}（{len(chunks)} 片连续写入，占位 p2.img 已删）")
PY
fi
if [ "$P2_SPLIT" = 1 ]; then
	# 分片模式下工具会生成"p1 + N 片"的 N+1 分区 MBR；换成标准 2 分区 MBR，
	# 让板上仍然只有 p1（内核 256 MiB）和 p2（rootfs 7.0 GiB）两个分区。
	MBRF="$HERE/lineflash/cm360-mbr-2part.bin"
	[ -f "$MBRF" ] || die "缺 MBR 模板：$MBRF"
	cp "$MBRF" "$WORK/mbr.bin"
	echo "   ✔ MBR 换成标准 2 分区表（p1 0x13000+0x7FFF0 / p2 0x93000+0xDFC7F0）"
fi
echo "   ✔ config.txt / layout.txt / mbr.bin / fw_tbl.bin"

echo "== 3/6 校验 MBR ↔ 镜像 ↔ layout 三方一致 =="
python3 - "$WORK" "$NO_P2" "$P2_SPLIT" "$FULL_P2" <<'PY'
import re, struct, sys, os
work, no_p2, split = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
allow_big = sys.argv[4] == "1"

# ---- MBR ----
mbr = open(os.path.join(work, "mbr.bin"), "rb").read()
parts = []
for i in range(4):
    off = 0x1BE + i * 16
    status, _, _, _, ptype, _, _, _, lba, cnt = struct.unpack_from("<BBBBBBBBII", mbr, off)
    if ptype:
        parts.append((i, lba, cnt))
print(f"   MBR 分区：{[(f'p{i}', f'LBA {lba:#x}', f'{cnt} 扇区', f'{cnt*512:,} B') for i, lba, cnt in parts]}")

# ---- layout PARTn ----
text = open(os.path.join(work, "layout.txt"), encoding="utf-8", errors="replace").read()
lay = {}
for m in re.finditer(r'PART(\d+)\s+"\s*offset=([0-9a-fA-F]+)\s+size=([0-9a-fA-F]+)', text):
    lay[int(m.group(1))] = (int(m.group(2), 16), int(m.group(3), 16))

def check_payload(name, want_size, partition_size):
    path = os.path.join(work, name)
    if not os.path.exists(path):
        sys.exit(f"!! 缺少载荷 {name}")
    size = os.path.getsize(path)
    if size >= 2**31:
        if allow_big:
            print(f"   ⚠️ {name} = {size:,} B ≥ 2 GiB —— 已按 --full-p2 跳过检查"
                  f"（厂商 32 位工具会崩，仅限支持大载荷的工具）")
        else:
            sys.exit(f"!! {name} = {size:,} B ≥ 2 GiB —— 厂商工具 32 位变量会溢出崩溃（0xC0000409）")
    if size == partition_size:
        print(f"   ✔ {name} == 分区（{size:,} B）")
    elif size < partition_size:
        print(f"   ✔ {name} 小于分区：{size:,} B < {partition_size:,} B（精简镜像，首启 resize max）")
    else:
        sys.exit(f"!! {name} 尺寸 {size:,} B > 分区 {partition_size:,} B")
    return size

if not parts:
    sys.exit("!! MBR 里没有分区")
# p1
if 0 not in lay:
    sys.exit("!! layout.txt 缺少 PART0")
off0, sz0 = lay[0]
if off0 != parts[0][1] * 512:
    sys.exit(f"!! PART0 offset={off0:#x} ≠ MBR p1 起始 {parts[0][1]*512:#x}")
if sz0 != parts[0][2] * 512 + 8192:
    sys.exit(f"!! PART0 声明 size={sz0:#x} ≠ MBR p1+16 扇区（{parts[0][2]*512+8192:#x}）")
check_payload("p1.img", sz0, parts[0][2] * 512)
print(f"   ✔ PART0 offset/size ↔ MBR p1（offset={off0:#x} size={sz0:#x}）")

if no_p2:
    print("   · --no-p2：不检查 p2")
elif split:
    # 分片：PART1..PARTn 必须从 MBR p2 起点开始、连续、总和 = p2 分区大小
    if len(parts) < 2:
        sys.exit("!! 分片模式需要 MBR 里有 p2")
    idxs = sorted(k for k in lay if k >= 1)
    if not idxs:
        sys.exit("!! layout.txt 缺少 PART1（分片）")
    start = parts[1][1] * 512
    total = parts[1][2] * 512
    cur = start
    acc = 0
    for k in idxs:
        off, sz = lay[k]
        if off != cur:
            sys.exit(f"!! PART{k} offset={off:#x} ≠ 期望 {cur:#x}（分片必须连续）")
        # 取布局行里真正的 " name="（避开 partname=）
        ln = next((l for l in text.splitlines() if re.match(rf'#define PART{k}\b', l)), "")
        m = re.search(r'\sname=([^ "]+)', ln)
        if not m:
            sys.exit(f"!! PART{k} 没有 name= 字段")
        name = m.group(1)
        check_payload(name, sz, total if len(idxs) == 1 else sz)
        cur += sz
        acc += sz
    if acc != total:
        sys.exit(f"!! 分片总和 {acc:#x} ≠ p2 分区大小 {total:#x}")
    print(f"   ✔ 分片写入 p2：{len(idxs)} 片，{start:#x} ~ {cur:#x}，总和 = p2 分区 {total:,} B")
else:
    off1, sz1 = lay[1]
    if off1 != parts[1][1] * 512:
        sys.exit(f"!! PART1 offset={off1:#x} ≠ MBR p2 起始 {parts[1][1]*512:#x}")
    if sz1 != parts[1][2] * 512 + 8192:
        sys.exit(f"!! PART1 声明 size={sz1:#x} ≠ MBR p2+16 扇区（{parts[1][2]*512+8192:#x}）")
    check_payload("p2.img", sz1, parts[1][2] * 512)
    print(f"   ✔ PART1 offset/size ↔ MBR p2（offset={off1:#x} size={sz1:#x}）")

# ---- 写入区互不重叠（layout 条目之间） ----
spans = [(lay[i][0], lay[i][0] + lay[i][1]) for i in sorted(lay)]
for a, b in zip(spans, spans[1:]):
    if a[1] > b[0]:
        sys.exit(f"!! 写入区重叠：{a[1]:#x} > {b[0]:#x}")
print("   ✔ layout 各写入区互不重叠")

# ---- FW_KERNEL：低区整块写入时不得压到 p1 ----
mm = re.search(r'FW_KERNEL " target=[0-9a-fA-F]+ offset=([0-9a-fA-F]+) size=([0-9a-fA-F]+)'
               r' type=bin name=low-region\.img', text)
if mm:
    koff, ksz = int(mm.group(1), 16), int(mm.group(2), 16)
    if koff != 0x200:
        sys.exit(f"!! FW_KERNEL 低区写入 offset 应为 0x200（offset=0 会被工具判为无效），实际 {koff:#x}")
    if koff + ksz > 0x2600000:
        sys.exit(f"!! FW_KERNEL 低区写入 {koff:#x}+{ksz:#x} 超过 p1 起点 0x2600000，会压坏 p1")
    print(f"   ✔ FW_KERNEL 低区整块写入：0x{koff:x} ~ 0x{koff+ksz:x}（<= p1 起点 0x2600000）")
PY

echo "== 4/6 元数据后处理 =="
if [ "$NO_P2" = 1 ] && [ "$KEEP_MBR" = 0 ]; then
	echo "   ⚠ --no-p2 但没有 --keep-mbr：生成的 MBR 只有 1 个分区，刷入会抹掉板上 p2 分区表！" >&2
	echo "     强烈建议改用：--no-p2 --keep-mbr" >&2
fi
if [ "$KEEP_FWTBL" = 0 ]; then
	# FW_FWTBL 会被写到低区 0x620000（原厂镜像区）；本板不用该表，删掉以免动低区
	sed -i '/FW_FWTBL /d' "$WORK/layout.txt" && echo "   ✔ 已去掉 FW_FWTBL（不动低区 0x620000；--keep-fwtbl 可保留）"
fi
if [ "$KEEP_MBR" = 0 ]; then
	echo "   ✔ 保留 MBR0（写工具生成的 2 分区表）"
else
	sed -i '/MBR0 /d' "$WORK/layout.txt"
	echo "   ✔ 已去掉 MBR0（--keep-mbr：沿用板上现有分区表）"
fi

echo "== 5/6 包内说明 =="
{
	echo "CM360 fnOS 线刷包（Realtek USB MP Tool）"
	echo "版本: $VER   生成: $(date '+%Y-%m-%d %H:%M:%S')"
	echo
	echo "包内 metadata 由厂商 rtd129x_img_gen 依据 tools/lineflash/emmc_8gb_cm360.json 生成。"
	echo
	echo "写入范围（layout.txt）："
	cat "$WORK/layout.txt" | sed 's/^/  /'
	echo
	echo "⚠️ 本包只写 MBR + p1 + p2，**不含低区引导链**。"
	echo "   - 板子必须已经能进 u-boot（或先用原厂工具刷回 bootloader）；"
	echo "   - 低区（hwsetting/bootcode/u-boot/env）请走 dd / TFTP 流程，见 firmware/README.md。"
	echo
	echo "⚠️ 厂商工具会把每个分区按 MBR 里的扇区数建立分区；本包 p1 镜像与分区等大"
	echo "   （0x7FFF0 扇区）。"
	if [ "$FULL_P2" = 1 ]; then
		echo "   p2 为**完整镜像**：$(stat -c %s "$WORK/p2.img") B，与分区（0xDFC7F0 扇区）等大，"
		echo "   **不精简、不分片**。⚠️ 本包是给「能处理大载荷的工具」测试用的；"
		echo "   厂商 32 位 rtumdfsample.exe 载入会内存不足（GetLastError:8）。"
	elif [ "$P2_SPLIT" = 1 ]; then
		echo "   p2 为**完整镜像（未精简）**，切成 $P2_CHUNKS 片、按 PART1..PART$P2_CHUNKS 连续写入"
		echo "   （每片 < 2 GiB，绕开工具 32 位文件大小限制；板上仍是 p1/p2 两个分区）。"
	else
		echo "   p2 为**精简镜像**（< 2 GiB，分区仍按 0xDFC7F0 扇区建立，"
		echo "   首启由 cm360-firstboot.sh 执行 btrfs resize max 撑满）。"
	fi
	echo
	if [ "$P2_SPLIT" = 1 ]; then
		echo "★ 单载荷仍必须 < 2 GiB：分片就是把 7.5 GB 的完整 p2 拆成多片来写。"
	else
		echo "⚠️ 厂商工具内部用 32 位变量存分区载荷：单个载荷 ≥ 2 GiB 会 abort"
		echo "   （0xC0000409），所有 PART 载荷合计 ≳2.3 GB 会载入失败（GetLastError:8）。"
		echo "   ⇒ p2 必须精简（slim-p2.sh）；功能完整靠刷机后注入："
		echo "     firmware/make-extra-features.sh + board 上 install-extra-features.sh"
		echo "   （--p2-split 分片**不能**绕过，实测 load [PART2] data failed，见 docs/10 §16.3 ⑨）"
	fi
	echo
	if [ -n "$LOWREGION" ]; then
		echo "★ 本包含低区（0~38 MiB）：hwsetting / bootcode / u-boot / env / factory"
		echo "   会一并用 FW_KERNEL(offset=0) 写回，所以："
		echo "   - 刷完 u-boot env 自动恢复，不需要再手动 saveenv；"
		echo "   - 可以从砖头状态（SW5/USB 下载模式）直接刷回；"
		echo "   - ⚠️ 写入低区期间断电仍有变砖风险（用 SW5 + 本包可再救）。"
	else
		echo "⚠️ 包内 dummy-kernel.bin 是 2 字节占位：厂商工具烧写前强制要求"
		echo "   FW_KERNEL 长度非零（否则弹 LOST: kernel data length not found）。"
		echo "   该条目只向低区 0x630200 的 fw 区写 2 字节，不碰 u-boot / env / p1。"
	fi
} > "$WORK/README-lineflash.txt"
mkdir -p "$WORK/omv"   # 厂商工具的项目标记（见 docs/10 §14）
# ★ 工具在"普通整机刷写"的最后一步会往 eMMC 0x220000/0x420000 写一份 factory.tar
#   （里面是 tmp/factory/env.txt，即 u-boot env）。默认它写"空白"版本 → env 被清空。
#   如果包内提供 omv/factory.tar，工具会用它（日志：try to use blank factory.tar in mp tool
#   → Source: UnTarTmp\omv\factory.tar）→ 刷完 env 自动恢复。
#   注意输入 tar 的成员必须**根相对**（env.txt），由工具自己加 tmp/factory/ 前缀。
if [ -z "$FACTORY_TAR" ] && [ -n "$LOWREGION" ]; then
	# 未显式给 --factory-tar：从低区镜像自动抽出 env 生成（省掉一个手工步骤）
	FACTORY_TAR="$WORK/auto-factory.tar"
	python3 "$REPO/tools/make-factory-tar.py" "$LOWREGION" -o "$FACTORY_TAR" >/dev/null \
		|| die "从低区镜像自动生成 factory.tar 失败（需要 python3）"
	echo "   · 未给 --factory-tar：已从低区镜像自动生成根相对 factory.tar"
fi
if [ -n "$FACTORY_TAR" ]; then
	[ -f "$FACTORY_TAR" ] || die "找不到 factory.tar：$FACTORY_TAR"
	cp "$FACTORY_TAR" "$WORK/omv/factory.tar"
	# ★ 安全检查：传入的若是低区 0x220000 的**原始 factory 区 blob**（成员 tmp/factory/env.txt），
	#   工具会在外面再套一层 → tmp/factory/tmp/factory/env.txt，u-boot 读不到 env。
	#   这里自动改写成根相对 env.txt。
	python3 - "$WORK/omv/factory.tar" <<'PY'
import io, sys, tarfile
p = sys.argv[1]
raw = open(p, "rb").read()
try:
    t = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
    names = [m.name for m in t.getmembers()]
except tarfile.TarError:
    sys.exit(f"!! {p} 不是 tar 文件")
if any(n == "env.txt" for n in names):
    print("   ✔ factory.tar 成员为根相对 env.txt（正确）")
elif any(n.startswith("tmp/factory/") for n in names):
    env = None
    for m in t.getmembers():
        if m.isfile() and m.name.endswith("env.txt"):
            env = t.extractfile(m).read()
            break
    if env is None:
        sys.exit("!! factory.tar 含 tmp/factory/ 但没有 env.txt")
    out = io.BytesIO()
    o = tarfile.open(fileobj=out, mode="w", format=tarfile.GNU_FORMAT)
    ti = tarfile.TarInfo("env.txt")
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(env), 0o644, 0, 0, 0
    o.addfile(ti, io.BytesIO(env))
    o.close()
    open(p, "wb").write(out.getvalue())
    print("   ⚠️ 传入的 factory.tar 成员是 tmp/factory/env.txt（原始 factory 区 blob），")
    print("      已自动改写为根相对 env.txt（否则工具会套成 tmp/factory/tmp/factory/env.txt）")
else:
    sys.exit("!! factory.tar 里没有 env.txt —— 用 tools/make-factory-tar.py 重新生成")
PY
	echo "   ✔ omv/factory.tar（$(stat -c %s "$WORK/omv/factory.tar") 字节，成员 env.txt）"
fi
# ★ 包内成员名必须**全部是 ASCII**（2026-10-21 实测）：
#   工具的 tar 解包（decompressTarget → tarlib）在 setlocale(0,"") 下按本地代码页
#   （GBK）处理 header 文件名，遇到 UTF-8 中文名会异常中断整个解包循环 ——
#   症状是 UnTarTmp 里只有前几个 ASCII 成员，omv/ 与载荷都没解出来，
#   于是报 "Cannot get untartemp project filename"。
#   所以这个说明文件用 ASCII 名，内容仍可中文（内容不参与解析）。
cat > "$WORK/omv/README.txt" <<'EOF'
omv 是 Realtek USB MP Tool 的项目标记：解包到 UnTarTmp 后，工具需要在里面找到
名为 package 5 / omv / generic linux 之一的条目，否则报
"Cannot get untartemp project filename" 并拒绝载入。本文件没有实际作用，
只是让 omv/ 目录在任何 tar 解析器里都可见（见 docs/10 §14）。
EOF
echo "   ✔ README-lineflash.txt + omv/ 项目标记"

echo "== 6/6 打 tar 包 =="
IMG="$OUT/install-cm360-fnos-$VER-full.img"
[ "$NO_P2" = 1 ] && IMG="$OUT/install-cm360-fnos-$VER-boot-sysonly.img"
if [ "$FULL_P2" = 1 ]; then
	IMG="$OUT/install-cm360-fnos-$VER-full-fullp2.img"
	[ -n "$LOWREGION" ] && IMG="$OUT/install-cm360-fnos-$VER-full-uboot-fullp2.img"
elif [ "$P2_SPLIT" = 1 ]; then
	IMG="$OUT/install-cm360-fnos-$VER-full-split.img"
	[ -n "$LOWREGION" ] && IMG="$OUT/install-cm360-fnos-$VER-full-uboot-split.img"
elif [ -n "$LOWREGION" ]; then
	IMG="$OUT/install-cm360-fnos-$VER-full-uboot.img"
fi
rm -f "$IMG"
# fw[]/gold[] 引用的文件也打包（dummy-kernel.bin 或 low-region.img）
FW_FILES=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(" ".join(e["file"] for e in d.get("fw",[])+d.get("gold",[]) if e.get("file")))' "$WORK/package.json")
if [ "$P2_SPLIT" = 1 ]; then
	CHUNK_FILES=$(awk '{print $1}' "$WORK/chunks.txt" | tr '\n' ' ')
	P2_PAYLOAD="$CHUNK_FILES"
else
	P2_PAYLOAD="$( [ "$NO_P2" = 0 ] && echo p2.img )"
fi
tar --format=gnu -C "$WORK" -cf "$IMG" \
	config.txt layout.txt mbr.bin fw_tbl.bin README-lineflash.txt omv \
	$FW_FILES p1.img $P2_PAYLOAD
sync
# 兜底检查：包内成员名不允许出现非 ASCII（否则厂商工具会解包中断）
if tar -tf "$IMG" | LC_ALL=C grep -q '[^ -~/]'; then
	die "包内存在非 ASCII 文件名，厂商工具会解包中断（见上面注释）"
fi
echo "   ✔ 包内成员名全部 ASCII"
echo "   ✔ $IMG"
echo "   $(stat -c %s "$IMG") 字节"
md5sum "$IMG"
if [ "$FULL_P2" = 1 ]; then
	echo
	echo "⚠️ 这是**完整 p2 的大包**（约 7.8 GB）：厂商 32 位 rtumdfsample.exe 载入会失败，"
	echo "   仅用于「其它支持大载荷的工具」实测；失败请改用精简 p2 的 ...-full-uboot-f2.img。"
fi
echo
echo "✔ 完成。用 Windows USB MP Tool：按住 SW5 插 Type-C（不接 DC）→ 出现"
echo "  Realtek generic USB Device → open 选本包 → Flash type=EMMC, DDR=4DDR4_2GB。"
