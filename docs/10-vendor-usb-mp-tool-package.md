# 厂商线刷包结构分析：Realtek USB MP Tool / CM360

本文分析**厂商原始线刷包**的内部结构，目的是回答一个具体问题：

> 能不能用厂商的 Windows 线刷工具（Realtek USB MP Tool），把 **u-boot 和系统打进同一个包**、一次性刷进去？

**结论先给**：包格式**已经彻底解开**，技术上"一个包连引导链一起刷"是可行的；
但**本机无法端到端验证**（需要 Windows + 物理按键 SW5 + 真实 USB 下载模式），
所以**对外发布的刷机流程仍然以已验证的 `dd` 方案为准**（见 `docs/08-flashing-approaches.md`）。
**未验证的部分在本文中一律标注为"未验证"。**

---

## 0. 状态一览（哪些是实测，哪些只是读资料）

| 结论 | 证据强度 |
|---|---|
| 包是 **POSIX tar**，含 19 个成员 | ✅ 实测（`tar tvf`） |
| `layout.txt` 是**绝对字节偏移表**，与 `mbr.bin`、`emmc.Image` 等**逐项自洽** | ✅ 实测（三方交叉核对，见 §3） |
| `fw_tbl.bin` 魔数 = `VERONA__`，结构 = 0x20 头 + 分区块 + 记录块（每记录 64 B） | ✅ 实测（逆出并与 `layout.txt` 逐条吻合） |
| 记录里的校验字段就是**完整 SHA-256(载荷)**（偏移 `0x1A`，共 32 B） | ✅ 实测（5 条记录逐条以原文件重算命中） |
| 头部校验 `u32@0x08 == sum(bytes[0x0C:]) & 0xFFFFFFFF` | ✅ 实测（`fw_tbl.bin` 与 `gold_fw_tbl.bin` 两张表均命中） |
| **因此 `fw_tbl.bin` 可以自己生成**（工具：`tools/make-lineflash-package.py`） | ✅ 实测（生成后回读自检通过） |
| 本板 u-boot **内嵌同一套固件表代码**（同魔数、同错误串） | ✅ 实测（低区 `0x80FA0`） |
| 厂商 `bootloader.tar` **不适用于本板**（三段落一个字节都不匹配） | ✅ 实测（逐段 md5 比对） |
| 用厂商工具刷本板、且包含 u-boot | ❌ **未验证**（需 Windows + SW5，无法在本机复现） |

---

## 1. 资料来源与提取

厂商线刷资料放在仓库外（体积大，不入库）：

```
/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/线刷固件/
├── istore-r16974-cm360.install.img   139,888,640 B  iStoreOS r16974（CM360 版）
├── install移动遥控.img             1,538,836,480 B  厂商原厂包（移动遥控版）
└── （教程 PDF：Windows USB MP Tool 刷机步骤）
```

只取元数据（几 KB），不整包解压：

```bash
W=/run/media/xiaoabiao/1877ec11-c65c-4b5e-a220-344ffae7ba61/cm360-fw
tar xf 线刷固件/istore-r16974-cm360.install.img -C "$W" \
    layout.txt config.txt fw_tbl.bin gold_fw_tbl.bin mbr.bin etc.bin rtd-129x.dtb
tar xf 线刷固件/istore-r16974-cm360.install.img -C "$W" omv/bootloader.tar
tar xf "$W/omv/bootloader.tar" -C "$W/bl"
```

---

## 2. 教程要点：怎么进 USB 下载模式

> 这一节是**唯一能解释"为什么线刷需要按按键"**的部分，也是本板之前一直没走通线刷的原因。

1. **按住板上电源插座旁的 `SW5` 键不放**，然后插 **Type-C 线**（**不要接 DC 电源**），保持约 3 秒；
2. 电脑出现 `USB REDIRECTION` → 安装驱动 → 设备变成 **`Realtek generic USB Device`**（即进入 SoC 的 USB 下载模式）；
3. 打开 `usb mp tool`（`rtumdfsample.exe`）：
   - `flash type` 选 **EMMC**
   - `DDR Type` 选 **`4DDR4_2GB`**
   - `open` 选择 `install*.img`（就是上文那个 tar 包）
   - 点小绿人开始刷 → 到 100%
4. ⚠️ 工具目录**不能放在中文路径**（尤其别放桌面）；路径要纯 ASCII。

**另有两处硬件信息（教程顺带提到）**：

- 板上有 **SPI flash**，可做双系统引导（SPI 引导群晖 / eMMC 引导本系统）；
- **开机时按住 `SW3`** 会从 eMMC 路径启动 —— 与 u-boot 里存在的 `rtkspi` 命令相互印证。

⚠️ 教程明确说明：**这个固件包不含 bootloader**，引导链要另外刷。
这与包内 `config.txt` 里 `# bootcode=y` 被**注释掉**完全一致（见 §3.2）。

---

## 3. 包结构逐个字段解读

### 3.1 小包（iStoreOS，139 MB tar）成员

| 文件 | 大小 | 作用 |
|---|---|---|
| `layout.txt` | 1,072 | ★ **绝对偏移表**（刷到哪里） |
| `mbr.bin` | 512 | ★ 分区表（MBR，`offset=0`） |
| `fw_tbl.bin` | 496 | ★ 固件表（`VERONA__`，引导链用它找内核） |
| `gold_fw_tbl.bin` | 288 | Gold（出厂备份）固件表 |
| `config.txt` | 672 | 包配置（见 §3.2） |
| `etc.bin` | 512 | p2 的 ext4 初始化内容（`RESET000` 头） |
| `rootfs.bin` | 97,911,772 | p1 内容（squashfs） |
| `emmc.Image` | 14,143,496 | 内核（uImage 形式） |
| `rtd-129x.dtb` | 48,443 | 板级 DTB |
| `bluecore.audio` / `rescue.audio` | 913,328 | 音频固件（DSP） |
| `rescue.Image` / `rescue.cpio.gz` / `rescue.dtb` / `rescue.emmc.dtb` | ~15 MB | 救援内核/根文件系统/DTB |
| `rescue.root.emmc.cpio.gz_pad.img` | 4,194,304 | 救援 rootfs（**已按 4 MiB 对齐补齐**） |
| `install_a` | 945,668 | 安装程序（包内脚本/二进制） |
| `omv/bootloader.tar` | 583,680 | ★ 引导链三段（见 §5） |

**大包（原厂 1.5 GB）** 的 `omv/` 目录里是**全套厂商目标名**，与我们 u-boot 的 fastboot 帮助里列出的目标名**完全对上**：

```
omv/emmc.uImage  omv/android.emmc.dtb  omv/bluecore.audio  omv/bootfile.image
omv/system.bin   omv/data.bin  omv/cache.bin  omv/backup.bin
omv/mbr_00.bin … omv/mbr_06.bin   omv/gold.*   omv/logo_p.bin
omv/uboot.bin    omv/uboot_p.bin  omv/verify_p.bin  omv/fw_tbl.bin
```

→ 说明 u-boot 的 fastboot/刷机目标名**沿用的是这套厂商命名**，不是自定义的。

### 3.2 `config.txt`（全文要点）

```ini
verify=y              # 校验
# bootcode=y          # ← 被注释掉：本包不刷引导链（刷机时刷 bootloader 要打开它）
install_dtb=y
reboot_delay=5
secure_boot=0
fw   = kernelDT    rtd-129x.dtb      0x2100000   # 名字 / 文件 / 加载到 RAM 的地址
fw   = linuxKernel emmc.Image        0x3000000
fw   = rescueDT    rescue.emmc.dtb   0x2140000
fw   = rescueRootFS rescue.root...   0x30000000
fw   = audioKernel bluecore.audio    0x1b00000
part = rootfs / squashfs rootfs.bin 134217728    # 分区：挂载点 / 文件系统 / 文件 / 大小
part = etc    etc  ext4  etc.bin    7381975040
```

### 3.3 `layout.txt`（★ 绝对偏移表，全文关键行）

```c
#define BOOTTYPE " BOOTTYPE_COMPLETE "
#define FW_RESCUE_DT     " target=2140000 offset=630200  size=da9d   name=rescue.emmc.dtb "
#define FW_RESCUE_ROOTFS " target=30000000 offset=63de00 size=400000 name=rescue.root.emmc.cpio.gz_pad.img "
#define FW_AKERNEL       " target=1b00000 offset=a3de00  size=defb0  name=bluecore.audio "
#define FW_KERNEL_DT     " target=2100000 offset=b1ce00  size=bd3b   name=rtd-129x.dtb "
#define FW_KERNEL        " target=3000000 offset=b28c00  size=d7d008 name=emmc.Image "
#define FW_FWTBL         " target=0       offset=620000  size=1f0    name=fw_tbl.bin "
#define PART0 " offset=8000000  size=8000000   mount_point=/   mount_dev=/dev/block/mmcblk0p1 filesystem=squashfs name=rootfs.bin "
#define PART1 " offset=10000000 size=1b8000000 mount_point=etc mount_dev=/dev/block/mmcblk0p2 filesystem=ext4     name=etc.bin "
#define MBR0  " offset=0        size=200       name=mbr.bin "
```

`offset` = **eMMC 绝对字节偏移**（十六进制），`target` = **加载到内存的地址**（十六进制）。

**三方交叉核对（全部自洽，已实测）**：

| 项 | `layout.txt` offset | `layout.txt` size | 实际文件大小 | 核对 |
|---|---|---|---|---|
| `emmc.Image` | `0xb28c00` | `0xd7d008`(14,143,496) | 14,143,496 | ✅ |
| `rtd-129x.dtb` | `0xb1ce00` | `0xbd3b`(48,443) | 48,443 | ✅ |
| `bluecore.audio` | `0xa3de00` | `0xdefb0`(913,328) | 913,328 | ✅ |
| `fw_tbl.bin` | `0x620000` | `0x1f0`(496) | 496 | ✅ |
| `rescue.root…_pad` | `0x63de00` | `0x400000`(4 MiB) | 4,194,304 | ✅ |
| p1 (`rootfs.bin`) | `0x8000000`(128 MiB) | `0x8000000`(128 MiB) | 97,911,772 ≤ 128 MiB | ✅ |
| p2 | `0x10000000`(256 MiB) | `0x1b8000000` | — | ✅ |

`mbr.bin` 解析（512 B，签名 `55aa`）：

```
分区1  type=0x83  起始 LBA 0x40000(128 MiB)  262,128 扇区 = 128.0 MiB
分区2  type=0x83  起始 LBA 0x80000(256 MiB)  14,417,904 扇区 = 7040.0 MiB
```

→ 与 `PART0/PART1` 的 `offset` **完全一致** ✅

---

## 4. `fw_tbl.bin` 结构（已完全逆向，可自造）

```
0x00  "VERONA__"              magic（Realtek 对 RTD1296 的内部代号 Verona）
0x08  u32                     校验 = sum(bytes[0x0C:]) & 0xFFFFFFFF   ★已验证（两表命中）
0x0C  u32 = 2                 版本
0x10  u32 = 0                 ？
0x14  u32 = 512               扇区对齐
0x18  u32                     分区块字节数（fw_tbl=144 / gold=0）
0x1C  u32                     记录块字节数（fw_tbl=320=5×64 / gold=256=4×64）
0x20  分区块（每条 48 B，条数 = 0x18/48）
末尾  记录块（每条 64 B，条数 = 0x1C/64）
```

⚠️ 记录块**在文件末尾**（`0x20 + 分区块大小` 处开始），不是固定 `0xB0` ——
`gold_fw_tbl.bin` 只有 32 字节头（无分区块），记录就从 `0x20` 开始。

**固件记录（64 字节）**：

| 偏移 | 长度 | 含义 |
|---|---|---|
| `0x00` | 2 | 类型 `0x8002` 内核 / `0x8003` 救援DTB / `0x8004` 内核DTB / `0x8005` 救援rootfs / `0x8007` 音频内核 |
| `0x06` | 4 | `target`：加载到 RAM 的地址（LE u32） |
| `0x0A` | 4 | `offset`：eMMC 绝对字节偏移（LE u32） |
| `0x12` | 4 | `size`：载荷精确大小 |
| `0x16` | 4 | `size` 向上取整到 512（rec4：14,143,496 → 14,144,000 ✔） |
| `0x1A` | 32 | **SHA-256(载荷)** ★五条记录逐条以包内原文件重算命中 |
| `0x3A` | 6 | 零填充 |

**分区条目（48 字节）**：

| 偏移 | 长度 | 含义 |
|---|---|---|
| `0x00` | 4 | 类型 = `2`（分区） |
| `0x04` | 4 | **大小 >> 16**（p1 `0x800`→128 MiB；p2 `0x1b800`→7,381,975,040 B ✔） |
| `0x0A` | 1 | 标志 = 1 |
| `0x0B` | 1 | 文件系统（2 = squashfs，4 = ext4） |
| `0x0C` | 1 | 分区号（1 / 2） |
| `0x10` | 16 | 名称（`/`、`etc`） |

**与 `layout.txt` 逐条吻合**（这就是引导链在 eMMC 上真正读的那张表）：

| 记录 | kind | target (RAM) | offset (eMMC) | 对应 |
|---|---|---|---|---|
| rec0 | `0x8003` | `0x02140000` | `0x00630200` | `FW_RESCUE_DT` |
| rec1 | `0x8005` | `0x30000000` | `0x0063DE00` | `FW_RESCUE_ROOTFS` |
| rec2 | `0x8007` | `0x01B00000` | `0x00A3DE00` | `FW_AKERNEL` |
| rec3 | `0x8004` | `0x02100000` | `0x00B1CE00` | `FW_KERNEL_DT` |
| rec4 | `0x8002` | `0x03000000` | `0x00B28C00` | `FW_KERNEL` |

**`gold_fw_tbl.bin`（Gold/出厂备份表，4 条）** 拿来交叉验证了同一结构：

| 记录 | kind | target | offset | size |
|---|---|---|---|---|
| rec0 | `0x8003` | `0x02140000` | `0x06000000` | 51,039 |
| rec1 | `0x8005` | `0x02200000` | `0x0600C800` | 10,266,020 |
| rec2 | `0x8007` | `0x01B00000` | `0x069D6E00` | 913,328 |
| rec3 | `0x8002` | `0x03000000` | `0x06AB5E00` | 9,835,232 |

→ 结构、字段位置、校验方式**与主表完全一致**，可确认逆向结论。

### 4.0 自动生成

`tools/make-lineflash-package.py` 会按上述格式生成 `fw_tbl.bin`（含校验与 SHA-256），
并在写下后**回读复算自检**。

### 4.1 我们板子的 u-boot 里有同一套代码（已实测）

在本板低区镜像（`dist/dd-set/low-region.img`，md5 `22dc832126b42cd1b2f77e305e13c76b`）中：

- `VERONA__` 出现在 **`0x80FA0`**，紧跟其后的全是**该代码的错误串**：

```
VERONA__
[ERR] %s:Signature(%s) error!\n
[ERR] %s:Read all fw tables error! (0x%x, 0x%x, 0x%x)\n
[ERR] %s:Checksum not match(0x%x != 0x%x)\n
[ERR] %s:No partition found!\n
**** Err…
```

**结论**：本板引导链与厂商**同族**，用的是同一个 `VERONA__` 固件表格式 —— 所以这个格式我们**有能力自己生成**。

⚠️ 但**低区里没有真实的表数据**：按 `kind=0x8002..0x8007` + 合理 `target/offset` 全盘扫描，**未找到任何一条真实记录**。
即本板低区目前只有**代码与字符串**，表数据或由刷机过程写入、或位于别处（未定位，标注为未验证）。

---

## 5. 厂商 bootloader 能否直接用于本板？（不能用）

`omv/bootloader.tar` 解出三段：

| 文件 | 大小 | md5 |
|---|---|---|
| `fsbl.bin` | 72,480 | `c86bc393b6dfa9f59480bef8d148d349` |
| `hw_setting.bin` | 3,200 | `eff2052999cbed110af938421920ae32` |
| `uboot.bin` | 498,400 | `a2b2ad52096b7ca45704f0392c56b891` |

**逐段在本板低区镜像里搜索（前 64 字节定位 + 整段 md5 比对）：三段一条都没命中。**

→ 厂商 bootloader 是**为另一种板型/引导链构建**的，**绝不能拿到本板上刷**。

本板实际布局（与厂商**完全不同**）：

| 区域 | 厂商偏移 | 本板偏移 |
|---|---|---|
| MBR | `0` | `0` ✅ 同 |
| hwsetting | （在 bootloader.tar 里，由 `bootcode=y` 写入） | `0x20000` |
| bootcode/FSBL | 同上 | `0x20E00` |
| TEE / BL32 | — | `0xB0600` |
| BL31 | — | `0x12C400` |
| **u-boot** | — | **`0x7F300`**（`U-Boot 2015.07`） |
| fw_tbl | `0x620000` | 未见真实表（见 §4.1） |
| u-boot env | — | `0x220000`（生效）/ `0x420000`（旧副本） |
| **p1** | `0x8000000`（128 MiB，squashfs） | `0x13000` 起（38 MiB，**256 MiB**，ext4） |
| **p2** | `0x10000000`（256 MiB，7,381,975,040 B） | `0x93000` 起（294 MiB，**7,508,852,736 B**） |

---

## 6. 那"一个包连 u-boot 一起刷"到底能不能做？

**形式上能**，依据：

1. `layout.txt` 里 `FW_*` 条目的格式是**通用的**
   （`target=<RAM地址> offset=<eMMC绝对字节> size=<长度> type=bin name=<文件>`），
   理论上把本板五段（hwsetting / bootcode / FSBL / BL31 / u-boot）**各写成一条**即可；
2. `config.txt` 里的 **`# bootcode=y`** 说明工具**原生具备刷 bootcode 的能力**，只是厂商包默认关掉了；
3. 本板引导链与厂商**同族**，`fw_tbl.bin` 格式一致（§4）。

**但仍有 3 个未验证点，任何一个都可能让这条路走不通**：

| # | 未验证点 | 影响 |
|---|---|---|
| 1 | 工具是否只认**白名单条目名**（`FW_KERNEL`/`PART0`/`MBR0`…），还是接受自定义 `#define` | 决定能否描述本板五段 |
| 2 | 只能 **Windows + 物理 `SW5`** 进下载模式，本机无法端到端复现 | 无法给出"实测通过" |
| 3 | **刷坏低区就是变砖**（要靠再次 `SW5` 救回） | 风险高于现有方案 |

✅ 原本的第 2 个未验证点（`fw_tbl.bin` 校验算法）**已解决**：
校验 = 头部字节求和、记录校验 = 完整 SHA-256，均可复算（§4），
已实现为 `tools/make-lineflash-package.py`，并生成过一份完整包自检通过。

**因此本项目的对外发布口径**：

> 线刷（USB MP Tool）路线**已解开格式并产出可自检的包**，作为**研究/救援备选**；
> **对外推荐并已验证的流程仍然是 `dd` 四件套**（`dist/dd-set/`）。

---

## 7. 全部路线现状对照

| 路线 | 依赖 | 实测状态 | 能否写低区 | 砖板能用 |
|---|---|---|---|---|
| **A. `dd` 直刷** | 已启动的 Linux + SSH/scp | ✅ **实测通过**（低区 3.7 s / p1 1.7 s / p2 146 s） | ✅ | ❌ |
| **B. u-boot + TFTP** | 能进 u-boot + 网线 | ✅ **实测通过**（p1 字节级校验一致） | ✅ | ❌ |
| **C. u-boot + U 盘 `fatload`** | 能进 u-boot + FAT32 U 盘 | ⚠️ 脚本就绪（`tools/make-usb-flash.sh` + `flash-from-pc.py --usb`），**未端到端实测** | ✅ | ❌ |
| **D. 串口 ROM Monitor** | 串口线 | ❌ 未验证 | ✅ | ✅（唯一） |
| **E. USB MP Tool 线刷** | **Windows + 驱动 + `SW5` + 本文包格式** | ⚠️ **格式已完全逆向、生成器已产出可自检的包；工具侧未实测** | ✅（推测） | ✅（推测） |

---

## 8. 复现本文分析（可照抄）

```bash
python3 - <<'PY'
import struct, hashlib
# 1) 解析厂商 fw_tbl.bin（记录块在文件末尾，起点 = 0x20 + 分区块大小）
v=open('fw_tbl.bin','rb').read()
assert v[:8]==b'VERONA__'
assert struct.unpack_from('<I',v,8)[0] == sum(v[0x0C:]) & 0xFFFFFFFF      # 头部校验
ps=struct.unpack_from('<I',v,0x18)[0]; rs=struct.unpack_from('<I',v,0x1C)[0]
print('分区块 %d 字节(%d 条) 记录块 %d 字节(%d 条)'%(ps,ps//48,rs,rs//64))
for i in range(ps//48):
    e=v[0x20+i*48:0x20+(i+1)*48]
    print('  part 分区号=%d 名称=%r 大小=%d 字节'%(e[12],e[16:32].split(b'\0')[0],
          struct.unpack_from('<I',e,4)[0]*65536))
base=0x20+ps
for i in range(rs//64):
    r=v[base+i*64:base+i*64+64]
    print('  kind=%#06x target=%#010x offset=%#010x size=%d sha256=%s'%(
        struct.unpack_from('<H',r,0)[0],struct.unpack_from('<I',r,6)[0],
        struct.unpack_from('<I',r,10)[0],struct.unpack_from('<I',r,18)[0],r[0x1A:0x1A+32].hex()))

# 2) 解析 mbr.bin
d=open('mbr.bin','rb').read()
for i in range(4):
    e=d[0x1BE+i*16:0x1BE+i*16+16]; lba,sec=struct.unpack_from('<II',e,8)
    if lba: print('part%d type=%#04x lba=%d sec=%d'%(i+1,e[4],lba,sec))
PY
```

在本板低区里定位同族代码：

```bash
grep -abo 'VERONA__' dist/dd-set/low-region.img      # → 0x80FA0
```

---

## 9. 风险提示

- 刷 p2 **会清空 fnOS 配置**（账号/设置），但**硬盘上的存储空间不受影响**；
- 进 USB 下载模式必须**断开 DC 电源**、只靠 Type-C 供电，并按 `SW5`；
- 工具与固件路径**必须纯 ASCII**，中文路径会失败；
- `SW3` / `SW5` 是物理按键，误按可能把引导切到 SPI，表现为"怎么都不启动"；
- 厂商 bootloader **不可用于本板**（§5）。

---

## 10. 相关文件

| 文件 | 说明 |
|---|---|
| `docs/08-flashing-approaches.md` | 各刷入方式的依赖关系总览（推荐先读） |
| `tools/make-lineflash-package.py` | ★ **线刷包生成器**（本文格式的实现，含自检） |
| `firmware/dd-flash.sh` | 板侧 `dd` 刷入脚本（已验证） |
| `firmware/flash-from-pc.py` | 电脑侧一键刷入（TFTP / `--usb`） |
| `tools/make-usb-flash.sh` | 制作 FAT32 刷机 U 盘 |
| `dist/dd-set/` | 四件套：`low-region.img` + `p1.img` + `p2.img` + `dd-flash.sh` |
| `docs/incident-2026-10-05-emmc-recovery.md` | 低区恢复实战记录 |

### 已生成的线刷包（不入库，体积 7.28 GiB）

放在外置盘（根分区空间紧张，见下）：

```
/run/media/xiaoabiao/1877ec11-c65c-4b5e-a220-344ffae7ba61/cm360-lineflash/
├── install-cm360-fnos-1.2.0302.img      7,815,229,440 B
└── install-cm360-fnos-1.2.0302.img.md5  b6af465bdd5ee2731165452f526904b5
```

包内 9 个文件（tar 根目录）：`layout.txt` / `config.txt` / `mbr.bin` / `fw_tbl.bin` /
`README-线刷.txt` / `Image-6.6.uimage` / `rtd1296-cm360.dtb` / `p1.img` / `p2.img`。

重建命令：

```bash
python3 tools/make-lineflash-package.py                 # 完整包（含 p2）
python3 tools/make-lineflash-package.py --no-p2 --dry-run   # 只验证格式，秒级
```

> 注：本机根分区一度只剩 5.3 GB 可用；本次已清理 7 份重复低区备份、
> p1 分片与旧 release 包（释放 3.2 GB），并让 `dist/dd-set/` 与
> `firmware/images/` 的镜像改为**硬链接**共用数据。大体积产物一律放外置盘。
