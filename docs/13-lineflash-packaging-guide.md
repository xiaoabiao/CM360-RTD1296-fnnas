# CM360（RTD1296）fnOS 线刷包打包说明

> 交接文档。照着做就能在**任意一台 Linux / WSL** 上把线刷包（`install-*.img`）重新打出来。
> 背景与逆向细节见 [`10-vendor-usb-mp-tool-package.md`](10-vendor-usb-mp-tool-package.md)；本文只讲"怎么出包、怎么验"。
>
> 最后更新：2026-10-26（含 `--full-p2` 完整包与 `factory.tar` 自动纠正）

---

## 0. 产出的三种包，先选一种

| 产物 | 命名 | 体积 | 用途 | 状态 |
|---|---|---|---|---|
| **精简包（推荐/实测可引导）** | `install-cm360-fnos-<版本>-full-uboot-f2.img` | ≈2.4 GB | 一次刷入：低区(u-boot+env) + MBR + p1 + **2 GiB 精简 p2** + factory.tar | ✅ 真机实测刷完自动进 fnOS |
| **完整 p2 大包** | `install-cm360-fnos-<版本>-full-uboot-fullp2.img` | ≈7.8 GB | 同上但 p2 为**完整 7.0 GiB**，仅供"支持大载荷的刷机工具"试验 | ⚠️ 能写入；旧 32 位厂商工具载入会 OOM |
| p1-only | `install-cm360-fnos-<版本>-boot-sysonly.img` | ≈0.3 GB | 只刷 p1（调试元数据用） | ⚠️ 不建议用于整机刷写 |

为什么两种：厂商 `rtumdfsample.exe` 是 32 位进程，载入时把 layout 里**所有 PART 载荷一次性读进内存**，单包总量 ≲2.3 GB（超了报 `GetLastError:8` / 崩 `0xC0000409`）。
所以默认出**精简包**；完整 p2 只在"换用其它工具"时作为试验包。

---

## 1. 环境准备

```bash
# Linux 或 WSL2（推荐 WSL，命令里用 wsl -u root 执行）
sudo apt update
sudo apt install -y python3 btrfs-progs rsync e2fsprogs tar coreutils
```

要求：

- **root**（要 loop 挂载镜像、生成精简镜像）；
- 磁盘空闲 **≥ 16 GB**（完整 p2 7.5 GB + 成品包 7.8 GB + 精简 p2 2 GB）；
- ⚠️ **临时/输出目录必须放在 Linux 文件系统**（如 `/root/cm360-build/out`），不要放 `/mnt/c/...`：
  脚本对 p1/p2 用硬链接避免重复拷贝，跨盘会退化成复制 7.5 GB；成品再从 Linux 拷到 Windows 交付目录。

仓库位置（本机示例）：

```bash
REPO=/mnt/c/Users/xiaoa/CM360-RTD1296-fnnas      # Windows 上就是 C:\Users\xiaoa\CM360-RTD1296-fnnas
WORK=/root/cm360-build                            # Linux 侧工作目录（脚本、镜像、产物都放这）
mkdir -p $WORK/images $WORK/out
```

---

## 2. 输入文件清单（缺一不可）

| 文件 | 放哪 | 大小 | md5（本机实测，可用于对照） | 来源 |
|---|---|---|---|---|
| `rtd129x_img_gen` | `$WORK/` 或任意路径 | 850,856 B | `700154c366659bc43d2ec465121ebd7a` | 厂商 `rtd129x_img_tools-linux_x86_64.tar.gz`（静态 x86-64） |
| `p1.img` | `$WORK/images/` | **268,427,264 B**（0x7FFF0 扇区） | `983a08b8a0e84f6bbaf7f0053807ad3a` | `firmware/build-images.sh p1`（或仓库提供的 p1 资产，**注意用 `--shrink-to-mbr`**） |
| `p2.img`（完整） | `$WORK/images/` | **7,508,844,544 B**（0xDFC7F0 扇区） | `3d072974d4e7c59c023f3af6c296f3e3` | `firmware/build-images.sh p2 <官方镜像.gz>` + `--shrink-to-mbr` |
| `p2slim.img`（精简） | `$WORK/images/` | **2,097,152,000 B**（2000 MiB） | `761d2ccf152dbcbc1f2198d07d41c9fd` | `firmware/slim-p2.sh --src p2.img --out p2slim.img` |
| `low-region.img` | `$WORK/` | **39,845,888 B** | `22dc832126b42cd1b2f77e305e13c76b` | `firmware/low-region-38MiB.img.gz`（md5 `b2b4b61b26212e8b05e6afbf0a94a723`）解压 |
| `factory.tar`（根相对） | `$WORK/` | **133,120 B** | `328a1be402f19e8041280e7302a61ce9` | `tools/make-factory-tar.py` 自动生成（见 §3.3） |

> **现成输入（推荐）**：`C:\Users\xiaoa\CM360-lineflash\images\` 里已经备好 `p1.img`、`p2.img`（完整 7.0 GiB）、
> `p2slim.img`、`low-region.img`、`rtd129x_img_gen`（md5 见上表）。在 WSL 里直接引用：
>
> ```bash
> IMG=/mnt/c/Users/xiaoa/CM360-lineflash/images
> --tool $IMG/rtd129x_img_gen --p1 $IMG/p1.img --p2 $IMG/p2slim.img --lowregion $IMG/low-region.img
> ```
>
> 只是出精简包的话，`p2.img`（7.5 GB）不是必需的，只要 `p2slim.img`。

脚本/元数据（都在仓库里，不用另备）：

```
tools/make-lineflash-official.sh        主打包脚本
tools/make-factory-tar.py               从低区镜像抽 env → factory.tar
tools/lineflash/emmc_8gb_cm360.json     分区布局描述（给 rtd129x_img_gen）
tools/lineflash/dummy-kernel.bin        2 B 占位（不带低区时才用）
tools/lineflash/cm360-mbr-2part.bin     标准 2 分区 MBR（--p2-split 时用）
firmware/slim-p2.sh                     完整 p2 → 2 GiB 精简 p2
firmware/make-extra-features.sh         生成"功能注入包"（可选）
firmware/install-extra-features.sh      板端安装功能注入包（可选）
```

30 秒自检：

```bash
md5sum $WORK/rtd129x_img_gen $WORK/images/p1.img $WORK/images/p2.img \
       $WORK/images/p2slim.img $WORK/low-region.img
stat -c '%s %n' $WORK/images/*.img $WORK/low-region.img
```

尺寸对不上就别打了 —— 十有八九是 p1/p2 用了"板子实机尺寸"（`0x80000` / `0xDFC800`）而不是 MBR 尺寸
（本脚本 `.json` 里声明的是 MBR 尺寸 − 16 扇区，即 p1 必须是 `0x7FFF0` 扇区、p2 必须是 `0xDFC7F0` 扇区）。

> ⚠️ `--shrink-to-mbr` 目前是**占位参数（未实现）**，脚本不会替你收缩，只在第 3 步校验并报错。
> 请用**预先做好的正确尺寸镜像**（交付目录 / 仓库里已有），或自己收缩：
>
> ```bash
> # p1（ext4，256 MiB → 0x7FFF0 扇区 = 268,427,264 B = 65,534 个 4K 块）
> cp p1-256MiB.img p1.img
> e2fsck -fy p1.img && resize2fs p1.img 65534 && truncate -s 268427264 p1.img
> # p2（btrfs，7,508,852,736 → 7,508,844,544 B，收缩方法见 docs/10 §13）
> ```

---

## 3. 打包步骤 A：精简包（默认，实测可引导）

### 3.1 p1（内核 + DTB）

```bash
cd $REPO
sudo ./firmware/build-images.sh p1            # 输出 firmware/images/p1-256MiB.img
```

注意 `build-images.sh` 输出的是**实机分区尺寸**（256 MiB = `0x80000` 扇区），而线刷包要求 MBR 尺寸
`0x7FFF0` 扇区（268,427,264 B，少 8 KiB）。用交付目录里现成的 `p1.img` 最省事；自己生成的话按 §2 收缩。

### 3.2 完整 p2 → 精简 p2

```bash
sudo ./firmware/slim-p2.sh \
  --src /root/cm360-build/images/p2.img \
  --out /root/cm360-build/images/p2slim.img \
  --size-mib 2000
```

- `--size-mib` **必须 < 2048**（工具 32 位上限），默认 2000；
- 脚本自检：镜像 < 2 GiB、`btrfs check` 通过、首启可 `resize max`；
- 精简掉的内容：`/usr/lib/firmware`、`/usr/share/AAVMF`、`/usr/lib/gcc`、`/usr/include`、`/usr/src`、
  `/usr/share/doc`、`/usr/share/man`、多余 locale（只留 en*/zh_CN*/zh_TW*）、`pocketsphinx`、`vim`、`qt5`、
  `proj`、`i18n`、apt 列表/缓存、`libLLVM-*`、`libgallium-*`；共约 1.65 GB。
  需要用这些功能时再打功能注入包（§5）。

### 3.3 factory.tar（u-boot env）—— 强烈建议让脚本自动生成

工具烧写**最后一步**会往 eMMC 0x220000 / 0x420000 写 factory 区（u-boot env 就在里面的 `tmp/factory/env.txt`）。
不给它 `omv/factory.tar` 时，它写**空白**版本 → 开机 `[ENV] read_env from factory failed` → 停 `BPI-W2>`。

⚠️ **最容易打错的一步**：输入 tar 的成员必须是**根相对 `env.txt`**（工具自己会加 `tmp/factory/` 前缀）。
别把低区 0x220000 的原始 factory blob（成员是 `tmp/factory/env.txt`）直接当 `--factory-tar`，
否则会被套成 `tmp/factory/tmp/factory/env.txt`，env 依旧读不到（本项目 2026-10-25 就踩过这个坑）。

现在**不需要手工准备**：只要带 `--lowregion`，脚本会自动用 `tools/make-factory-tar.py` 从低区镜像生成根相对
`factory.tar`；如果你显式传了 `--factory-tar` 且它是"嵌套"结构，脚本也会自动改写并告警。

手工生成（可选，用于核对）：

```bash
python3 tools/make-factory-tar.py firmware/low-region-38MiB.img.gz -o $WORK/factory.tar
# 期望输出：133120 B，md5 328a1be402f19e8041280e7302a61ce9，成员只有 env.txt
tar -tvf $WORK/factory.tar
```

### 3.4 出包

```bash
sudo bash tools/make-lineflash-official.sh \
  --tool   /root/cm360-build/rtd129x_img_gen \
  --p1     /root/cm360-build/images/p1.img \
  --p2     /root/cm360-build/images/p2slim.img \
  --lowregion /root/cm360-build/low-region.img \
  --factory-tar /root/cm360-build/factory.tar \
  --out    /root/cm360-build/out \
  --version 1.2.0302
```

产物：`/root/cm360-build/out/install-cm360-fnos-1.2.0302-full-uboot-f2.img`

> 命名规则：不带 `--full-p2`、带 `--lowregion` → `...-full-uboot.img`；
> 带 `--factory-tar` 且包内已有 factory.tar 时，交付时习惯把这一版叫 **f2**（低区 + factory.tar）。

脚本 6 个阶段会自动完成：
① 暂存（硬链接 p1/p2）→ ② 跑 `rtd129x_img_gen` 生成 `config.txt`/`layout.txt`/`mbr.bin`/`fw_tbl.bin`
→ ③ 三方校验（MBR ↔ 镜像 ↔ layout、单载荷 < 2 GiB、区间不重叠）
→ ④ 后处理（删 `FW_FWTBL`、替换 MBR 等）→ ⑤ 写 `README-lineflash.txt` + `omv/factory.tar`
→ ⑥ 打 tar 并打印 md5。

### 3.5 打包后自检（**必做，30 秒**）

```bash
IMG=/root/cm360-build/out/install-cm360-fnos-1.2.0302-full-uboot-f2.img
tar -tvf $IMG | awk '{print $3, $6}'          # 期望 11 个成员，尺寸见下
```

期望结构（精简版）：

```
config.txt          489 B
layout.txt          596 B
mbr.bin             512 B
fw_tbl.bin          240 B
README-lineflash.txt
omv/                (目录)
omv/factory.tar     133,120 B ← 成员必须只有 env.txt
omv/README.txt
low-region.img      39,845,376 B
p1.img              268,427,264 B
p2.img              2,097,152,000 B
```

一条命令核对"包内 factory.tar 是不是根相对"：

```bash
python3 - "$IMG" <<'PY'
import io, sys, tarfile
t = tarfile.open(sys.argv[1], "r:")
d = t.extractfile("omv/factory.tar").read()
names = [m.name for m in tarfile.open(fileobj=io.BytesIO(d), mode="r:").getmembers()]
print(len(d), "B", names)
assert names == ["env.txt"], "factory.tar 成员不对：工具会套成 tmp/factory/tmp/factory/env.txt"
print("OK")
PY
```

再核对 layout / MBR：

```bash
tar -xOf $IMG layout.txt
tar -xOf $IMG config.txt
tar -xOf $IMG mbr.bin | xxd | sed -n '/01be/,+4p'
```

正确值（本板）：

```
layout：
  FW_KERNEL " target=3000000 offset=200 size=25ffe00 type=bin name=low-region.img "
  PART0 " offset=2600000 size=10000000 ... mount_dev=/dev/block/mmcblk0p1 ... name=p1.img "
  PART1 " offset=12600000 size=1bf900000 ... mount_dev=/dev/block/mmcblk0p2 ... name=p2.img "
  MBR0  " offset=0 size=200 name=mbr.bin "
MBR：
  p1: LBA 0x13000, count 0x7FFF0  (268,427,264 B)
  p2: LBA 0x93000, count 0xDFC7F0 (7,508,844,544 B)
```

---

## 4. 打包步骤 B：完整 p2 大包（给"支持大载荷"的工具）

只多一个开关 `--full-p2`（跳过"单载荷 < 2 GiB"检查），其余完全一样：

```bash
sudo bash tools/make-lineflash-official.sh \
  --tool   /root/cm360-build/rtd129x_img_gen \
  --p1     /root/cm360-build/images/p1.img \
  --p2     /root/cm360-build/images/p2.img \
  --lowregion /root/cm360-build/low-region.img \
  --full-p2 \
  --out    /root/cm360-build/out-fullp2 \
  --version 1.2.0302
```

- 产物：`install-cm360-fnos-1.2.0302-full-uboot-fullp2.img`，**7,817,267,200 B**
  （本机成品 md5 `f9e52e6e7dac548159623c590514058a`）；
- 不给 `--factory-tar` 时自动从低区生成（同上）；
- 包内 `p2.img` = **7,508,844,544 B**，与 MBR p2 分区**等大**（不需要首启 resize）；
- ⚠️ 厂商 32 位工具载入这个包会 `GetLastError:8`；这是**预期行为**，用于验证新工具；
- 拷贝 7.8 GB 到 Windows 交付目录大约 1 分钟。

---

## 5. 可选：功能注入包（精简 p2 补回功能）

```bash
# 主机端：从完整 p2 镜像里把精简掉的文件打成 tar.gz
sudo ./firmware/make-extra-features.sh /root/cm360-build/images/p2.img /tmp/extra
# 产物 /tmp/extra/cm360-extra-features.tar.gz ≈ 485 MB，28,190 个成员
# 本机成品 md5 f91c6c9ef0f6ec4fd18a44df761ad018

# 板端（刷完精简包、进系统后）：
sudo ./install-extra-features.sh        # tar -xzpf ... -C / + ldconfig，重启生效
```

注意 `make-extra-features.sh` 内部是先 `cd` 进镜像根再 tar —— `tar` 创建**不做通配符展开**，
不 `cd` 会漏掉 `libLLVM-*` / `libgallium-*`（约 248 MB）。

---

## 6. 一键脚本（把 §3 全流程串起来）

保存成 `build-lineflash.sh`，改最上面的变量即可：

```bash
#!/bin/bash
set -euo pipefail
REPO=/mnt/c/Users/xiaoa/CM360-RTD1296-fnnas
WORK=/root/cm360-build
VER=1.2.0302
FULL=${FULL:-0}                 # 1 = 完整 p2 大包；0 = 精简包（推荐）

mkdir -p $WORK/images $WORK/out
[ -f $WORK/low-region.img ] || gunzip -c $REPO/firmware/low-region-38MiB.img.gz > $WORK/low-region.img

# 0) 尺寸预检（必须是 MBR 尺寸；build-images.sh 直出的会大 8 KiB，先收缩）
chk() { [ "$(stat -c %s "$1")" = "$2" ] || { echo "!! $1 尺寸不是 $2 B（见文档 §2）"; exit 1; }; }
chk $WORK/images/p1.img 268427264

# 1) p2 → 精简（只在出精简包时）
if [ "$FULL" = 0 ]; then
  [ -f $WORK/images/p2slim.img ] || \
    sudo $REPO/firmware/slim-p2.sh --src $WORK/images/p2.img --out $WORK/images/p2slim.img --size-mib 2000
  chk $WORK/images/p2slim.img 2097152000
else
  chk $WORK/images/p2.img 7508844544
fi

# 2) 出包
P2=$([ "$FULL" = 1 ] && echo $WORK/images/p2.img || echo $WORK/images/p2slim.img)
EXTRA=""; [ "$FULL" = 1 ] && EXTRA="--full-p2"
sudo bash $REPO/tools/make-lineflash-official.sh \
  --tool $WORK/rtd129x_img_gen \
  --p1 $WORK/images/p1.img --p2 $P2 \
  --lowregion $WORK/low-region.img \
  --out $WORK/out --version $VER $EXTRA

# 3) 自检：成员数 + factory.tar 成员
IMG=$(ls -t $WORK/out/install-*.img | head -1)
echo "== $IMG"; ls -l "$IMG"; md5sum "$IMG"
tar -tf "$IMG"
python3 - "$IMG" <<'PY'
import io, sys, tarfile
t = tarfile.open(sys.argv[1], "r:")
d = t.extractfile("omv/factory.tar").read()
names = [m.name for m in tarfile.open(fileobj=io.BytesIO(d), mode="r:").getmembers()]
print("omv/factory.tar", len(d), "B", names)
assert names == ["env.txt"], "factory.tar 成员不对！"
print("SELF-CHECK OK")
PY
```

运行：

```bash
# 精简包（实测可引导）
FULL=0 sudo -E bash build-lineflash.sh

# 完整 p2 大包
FULL=1 sudo -E bash build-lineflash.sh
```

---

## 7. 必须知道的约束（踩过的坑，都是实测）

| # | 约束 | 现象 | 处理 |
|---|---|---|---|
| 1 | `filesystem` 只认 `squashfs` / `ext4` | 写 `btrfs` → 工具报 `unsupported fstype:btrfs` 退出 | p2 是 btrfs 也只能写 `ext4`（该字段只进元数据，不格式化） |
| 2 | 工具给每个分区少算 **16 扇区（8 KiB）** | 镜像若按实机分区大小生成 → 挂载报 `bad geometry` | 镜像按 MBR 扇区数生成：p1 `0x7FFF0`、p2 `0xDFC7F0`；`--shrink-to-mbr` **未实现**，需自己收缩（§2） |
| 3 | 包内 tar 成员名**必须全 ASCII** | 工具解包中断 → `Cannot get untartemp project filename` | 说明文件用 `README-lineflash.txt`；脚本自带非 ASCII 检查 |
| 4 | 单载荷 **< 2 GiB** | `0xC0000409` / 载荷变大负数 | p2 用精简镜像（2000 MiB）；完整包用 `--full-p2` 显式放开 |
| 5 | 所有 PART 载荷合计 ≲2.3 GB（载入阶段全进内存） | `GetLastError:8`、`load [PART2] data failed` | 分片**不能**绕过（总量不变）；要么精简 p2，要么换工具 |
| 6 | `FW_KERNEL` 长度必须非零 | `LOST: kernel data length not found` | 不带低区时用 2 字节 `dummy-kernel.bin`；带 `--lowregion` 时天然满足 |
| 7 | layout 里 offset 不能为 **0** | `load layout fw [FW_KERNEL] failed` | 低区从 `0x200` 开始写（跳过 MBR 512 B） |
| 8 | `FW_KERNEL` 终点不能超过 p1 起点 | `firmwares overlaps normal partitions` | 低区镜像写到 `0x2600000` 为止（本仓库低区镜像正好 0x2600000 长，去掉前 512 B） |
| 9 | 工具最后一步重写 factory 区 | 刷完 env 丢失 → `read_env from factory failed` → 停 `BPI-W2>` | 包内放 `omv/factory.tar`（**成员根相对 `env.txt`**）；脚本已自动生成/自动纠正 |
| 10 | 旧工具不支持 >4 个 MBR 分区 | `not support MBR with over 4 partitions yet` | 本板 2 分区，无需处理；分片模式才需要换 MBR |
| 11 | 工具内部会追加 `FW_FWTBL`（写低区 0x620000） | 动到低区原厂固件表 | 脚本默认从 layout 删掉（`--keep-fwtbl` 可保留） |

---

## 8. 刷机与验收（交给刷机的人）

1. **工具**：Windows USB MP Tool（Realtek `rtumdfsample.exe`）。工具目录用纯 ASCII 路径；
   Win11 若报 Excel/OLE 依赖问题，见 `C:\Users\xiaoa\usbmp-work\README-win11-fix.md`。
2. **进下载模式**：按住主板上电源插座旁的 **SW5**，只插 Type-C 线（**不接 DC 电源**）约 3 秒，
   设备管理器出现 `Realtek generic USB Device`。
3. 工具里：`Flash type = EMMC`、`DDR Type = 4DDR4_2GB` → `open` 选包 → 点小绿人 → 到 100%。
   - **不要**勾"only upgrade bootloader"（会刷厂商 bootloader，与本板不匹配）；
   - `LK ENABLE=1` 保持默认（没有 `bootloader_lk.tar` 时会跳过 bootloader，正是我们要的）。
4. **验收（串口 115200）**：
   - 正常：`Hit Esc or Tab key...` 后自动进 fnOS（`Factory: ...` 之后不应出现
     `[ENV] read_env from factory failed`）；
   - 若出现 `read_env from factory failed` → 包内 `omv/factory.tar` 不对（见 §3.3 / §7-9）；
   - 若停在 `BPI-W2>` → 手工启动验证镜像是否写对：

     ```
     setenv bootargs 'earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 loglevel=7 root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root rootwait rw'
     setenv fdt_high 0xffffffffffffffff
     ext4load mmc 0:1 0x03000000 Image-6.6.uimage
     ext4load mmc 0:1 0x02100000 rtd1296-cm360.dtb
     bootm 0x03000000 - 0x02100000
     ```

     能启动 → 镜像没问题，只是 env/factory 恢复没对；
     报 `ext4load` 错 → p1 没写对（MBR/尺寸问题，见 §7-2）。
5. **精简包首启**：`cm360-firstboot.sh` 会自动 `btrfs filesystem resize max`，用 `df -h /` 确认 p2 撑到 ≈6.9 GB。
6. **低区一起刷**：本包 `FW_KERNEL` 已包含整块 38 MiB 低区（hwsetting/bootcode/u-boot/env/factory），
   可以从砖头状态直接救回；但写低区期间断电仍有变砖风险（可用 SW5 + 同一个包再救）。

---

## 9. 本机成品对照表（校验用）

| 文件 | 大小 | md5 |
|---|---|---|
| `install-cm360-fnos-1.2.0302-full-uboot-f2.img`（精简 p2，实测可引导） | 2,405,570,560 | `032d1f2d6b1e49c88cc80f429be9183f` |
| `install-cm360-fnos-1.2.0302-full-uboot-fullp2.img`（完整 p2） | 7,817,267,200 | `f9e52e6e7dac548159623c590514058a` |
| `install-cm360-fnos-1.2.0302-full-uboot-split.img`（失败的 4 片实验包，勿用） | 7,817,267,200 | `38272f884f52b5480da6aa9eb22288d7` |
| `cm360-extra-features.tar.gz`（功能注入包） | 508,228,333 | `f91c6c9ef0f6ec4fd18a44df761ad018` |
| `factory.tar`（根相对 env.txt，`--factory-tar` 用） | 133,120 | `328a1be402f19e8041280e7302a61ce9` |
| `p1.img` | 268,427,264 | `983a08b8a0e84f6bbaf7f0053807ad3a` |
| `p2.img`（完整） | 7,508,844,544 | `3d072974d4e7c59c023f3af6c296f3e3` |
| `p2slim.img`（精简，2000 MiB） | 2,097,152,000 | `761d2ccf152dbcbc1f2198d07d41c9fd` |
| `low-region.img` | 39,845,888 | `22dc832126b42cd1b2f77e305e13c76b` |
| `rtd129x_img_gen` | 850,856 | `700154c366659bc43d2ec465121ebd7a` |

> 注意：md5 相同才代表是同一份文件。重新生成镜像（比如重新 `build-images.sh`）后 md5 会变，
> 属正常，但要自己记录新值；**packaging 脚本不依赖 md5，只校验尺寸/分区一致性**。

包内载荷已交叉核对（可用来确认"打进去的就是准备好的镜像"）：

| 包 | 包内成员 | md5 | 与输入一致 |
|---|---|---|---|
| f2（精简） | `p2.img` 2,097,152,000 B | `761d2ccf152dbcbc1f2198d07d41c9fd` | = `p2slim.img` ✅ |
| fullp2（完整） | `p1.img` 268,427,264 B | `983a08b8a0e84f6bbaf7f0053807ad3a` | = `p1.img` ✅ |
| fullp2（完整） | `p2.img` 7,508,844,544 B | `3d072974d4e7c59c023f3af6c296f3e3` | = `p2.img` ✅ |

---

## 10. 参考：JSON / MBR / layout

`tools/lineflash/emmc_8gb_cm360.json`：

```json
{
  "size": "0x1D2000000",
  "fw_table_offset": "0x620000",
  "gold_table_offset": "0x630000",
  "fw_start": "0x630200",
  "fw_align": "0x200",
  "gold_start": "0x6000000",
  "part_start": "0x2600000",
  "part_align": "0x2000",
  "fw": [ {"type": "KERNEL", "target": "0x3000000", "file": "dummy-kernel.bin"} ],
  "gold": [],
  "part": [
    {"name": "boot",   "mp": "/boot", "size": "0x10000000",  "filetype": "img", "filesystem": "ext4", "file": "p1.img"},
    {"name": "rootfs", "mp": "/",     "size": "0x1BF900000", "filetype": "img", "filesystem": "ext4", "file": "p2.img"}
  ]
}
```

带 `--lowregion` 时脚本会把 `fw` 改成一条 `{"type":"KERNEL","file":"low-region.img"}`、`fw_start` 改成 `0x200`，
低区正好写到 p1 起点（`0x2600000`）。

eMMC 布局（本板实测）：

```
0x0000000 ~ 0x25FFFFF   低区 38 MiB（hwsetting/bootcode/FSBL/BL31/u-boot/env/factory）
0x2600000 ~ 0x125FFFFF  p1 = 0x7FFF0 扇区（ext4：内核 Image-6.6.uimage + 板级 DTB）
0x12600000 ~ 末尾        p2 = 0xDFC7F0 扇区（btrfs subvol root，完整 7.0 GiB）
```

---

## 11. 出问题先看这里

| 现象 | 原因 | 处理 |
|---|---|---|
| 工具载入报 `Cannot get untartemp project filename` | 包内成员名含非 ASCII / 缺 `omv/` | 用脚本打包（自带检查）；确认包里有 `omv/` 目录 |
| 载入报 `LoadFlashLayout` / `load layout fw [FW_KERNEL] failed` | `FW_KERNEL` offset=0 或长度为 0 | 带 `--lowregion`（offset=0x200）；否则放 2 B `dummy-kernel.bin` |
| 载入报 `GetLastError:8` / 进程崩 `0xC0000409` | 单载荷 ≥2 GiB 或 PART 总量超内存 | 用精简 p2；完整 p2 换工具（`--full-p2` 出的包不是给旧工具的） |
| 点绿人弹 `LOST: kernel data length not found` | `FW_KERNEL` 长度 0 | 同上 |
| 刷完停在 `BPI-W2>`，日志 `read_env from factory failed` | factory.tar 成员路径错 / 没放 | 重新出包（脚本会自动生成根相对 factory.tar），或串口 `setenv`+`saveenv` 应急 |
| 刷完串口报 `bad CRC, using default environment` | 同上（env 丢了） | 同上 |
| 刷完内核起不来 / `ext4load` 失败 | p1 尺寸与 MBR 不符 | 镜像按 `0x7FFF0` 扇区生成，或加 `--shrink-to-mbr` |
| 挂载报 `bad geometry` | 镜像比分区大 8 KiB（未收缩） | 同上 |

---

## 附：文件命名规则（脚本自动决定）

| 条件 | 产物名 |
|---|---|
| 默认 + `--lowregion` | `install-cm360-fnos-<ver>-full-uboot.img` |
| 默认无 `--lowregion` | `install-cm360-fnos-<ver>-full.img` |
| `--full-p2` + `--lowregion` | `install-cm360-fnos-<ver>-full-uboot-fullp2.img` |
| `--no-p2` | `install-cm360-fnos-<ver>-boot-sysonly.img` |
| `--p2-split`（已废弃） | `install-cm360-fnos-<ver>-full-uboot-split.img` |

完整参数说明：`bash tools/make-lineflash-official.sh --help`。

---

## 附：2026-10-26 重建记录（镜像内置 trim-compat 兼容层）

仓库 `boards/rtd1296-cm360/board-scripts/trim-compat/` 的修复由
`firmware/build-images.sh` 的 `adapt()` 自动 `install.sh --stage` 注入，所以
**只要用当前工作区重建 p2，兼容层就跟着进镜像**，出包命令不变。本次实测：

| 产物 | 大小 | md5 |
|---|---|---|
| `p2.img`（完整，重建） | 7,508,844,544 B | `1bbeea11f65b91aaecdff217ead1ba1e` |
| `p2slim.img`（精简，重建） | 2,097,152,000 B | `262b7cd032e280f0a7d47869b92916d5` |
| `install-...-slim-p2.img`（★ 推荐） | 2,405,570,560 B | `475053e73e26c3ddb53767a1791a333e` |
| `install-...-full-p2.img`（完整 p2，厂商工具载入必失败） | 7,817,267,200 B | `49d8336d2843c7bdf91b2649e06c322f` |
| `cm360-trim-compat-1.2.0302.tar.gz`（旧镜像补救包） | 30,906 B | `866bdd87c5147e0e903300c5bcf75f54` |

重建后自检（`build-images.sh` 6/7 + 重新只读挂载精简镜像）确认存在：
`usr/local/lib/libtrimcompat.so`、`cm360-fake-fs.sh`、`cm360-fake-fs.service`（已 enable）、
`trim_main`/`share_service` 等 15 个 drop-in、`/usr/lib/modules/*/extra/{spl,zfs}.ko`、
`cm360-firstboot.sh`（首启 `depmod` + `btrfs resize max`）。
