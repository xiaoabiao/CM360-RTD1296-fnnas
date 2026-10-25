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
| 包内**必须有名为 `omv` 的条目**，否则厂商工具拒绝读取 | ✅ 实测（2026-10-09，见 §14） |
| 厂商工具能正确**读取**本仓库生成的包 | ✅ 实测（补上 `omv/` 后工具正常载入，无报错） |
| 用厂商工具刷本板、且包含 u-boot | ✅ **实测通过（2026-10-22）**：`...-full-uboot-f2.img` 一次刷入低区+MBR+p1+p2，断电重启自动进 fnOS（§16.1） |
| 线刷包里放**完整 7.0 GiB p2** | ❌ **不可行**：工具 32 位、载入时全载荷进内存，单包总量 ≲2.3 GB；改用精简 p2 + 板端注入功能包（§16.1 / §16.3 ⑨） |

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
| **E. USB MP Tool 线刷** | **Windows + 驱动 + `SW5` + 本文包格式** | ✅ **实测通过（2026-10-22）**：`...-full-uboot-f2.img` 刷完自动进 fnOS（§16）；仅限精简 p2（32 位内存上限，§16.3 ⑨） | ✅ 实测（低区伪装成 `FW_KERNEL`，§16.3 ⑦） | ✅ |

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

---

## 11. 线刷包的两种形态（含 / 不含引导链）

关键区分：**包能不能救砖，只取决于它写不写低区。**

| 形态 | 生成命令 | 写入内容 | 能救砖？ | 会不会清配置 |
|---|---|---|---|---|
| **系统包**（默认） | `make-lineflash-package.py` | MBR + p1 + p2 | ❌ | ✔ 会（p2 被覆盖） |
| **救援包** | `... --with-lowregion --no-p2` | 低区 38 MiB + MBR + p1 | ✅ | ❌ 不会（不碰 p2） |
| **全量包** | `... --with-lowregion` | 低区 + MBR + p1 + p2 | ✅ | ✔ 会 |

命令 `--with-lowregion` 把**整块 38 MiB 低区**作为一条 `FW_LOWREGION` 编入包：

```c
#define FW_LOWREGION " target=0 offset=0 size=2600000 type=bin name=low-region.img "
```

这与 `dd` 写低区的效果**完全等价**（低区镜像第 0 字节起就含 MBR）。

### 11.1 为什么是"整块"，而不是拆成五条？

原计划是把 hwsetting / bootcode / FSBL / BL31 / u-boot **各写成一条**，
更贴近厂商 `layout.txt` 的风格。但实测低区数据分布后**否决了这个做法**：

```
各段起点（已知）：
  MBR       0x0
  hwsetting 0x20000
  bootcode  0x20E00
  u-boot    0x7F300
  TEE/BL32  0xB0600
  BL31      0x12C400
  env(生效)  0x220000
  env(旧副本) 0x420000
```

- 从 `0x20E00` 扫到 `0x220886`，**没有任何一段 ≥64 KiB 的空白**；
  各段是**紧挨着连续排布**的 → **无法靠空白可靠切分出各段边界**；
- 低区**远不止引导链**：`0x620000` 之后到末尾有约 **2400 万字节非零数据**，
  是大块 ARM64 代码，且内部含 `gzip`（`0x15AF4D8`）、`cpio`（`0x1CBD810`）、
  `DTB`（`FDT` 魔数 `0x2490000`）、`xz`（`0x1D3C108`）——
  这是**原厂固件按裸偏移留在低区的镜像区**（正是厂商 `layout.txt` 那套架构）。

→ 结论：**整块写入**才是安全且信息完整的做法；硬拆只会引入猜测。
仍保留 `--lowregion-split`（实验性）用于满足"工具只认白名单条目名"的可能性，
其六段文件与 `layout.txt` 条目会一并生成，但**默认不推荐**。

### 11.2 其它安全开关

| 开关 | 作用 |
|---|---|
| `--no-fw-tbl` | 不把 `fw_tbl.bin` 放进包（本板引导链不使用该表；若担心工具按其内固定偏移写入，可加此开关） |
| `--bootcode-y` | 在 `config.txt` 里启用 `bootcode=y`（测试工具**原生引导链刷写路径**） |
| `--dry-run` | 只生成元数据并自检，不写 tar（秒级，用于验证格式） |

### 11.3 仍未验证（不变）

包**格式**已完全自洽且可自检，但**厂商工具是否接受**——尤其是**自定义条目名**
（`FW_LOWREGION` / `HWSETTING` / `UBOOT` …）——**必须在 Windows 上用 `SW5`
进下载模式实测**。建议顺序：

1. 先 `--no-p2`（约 300 MB）小包试工具是否接受元数据；
2. 再 `--with-lowregion --no-p2` 救援包，验证低区条目是否被写入；
3. 最后才用全量包。

> **★ 2026-10-20 更正（重要）**：第 2 步的假设已被证伪 —— 厂商工具的
> `Layout_Type` 是**固定名字白名单**（逐名字 `strstr` 匹配），自定义的
> `FW_LOWREGION` 会被**静默忽略**，救援包根本不会写低区。低区恢复只能走
> `dd` / TFTP / 工具自带的 `bootloader.tar`（`only upgrade bootloader`）通道。
> 详见 **§16.3**，线刷包生成也已改为直接调用厂商 `rtd129x_img_gen`（§16）。

---

## 12. 大包（原厂 1.5 GB）补充证据：`part` 语义与 MBR 链

原厂包的 `layout.txt` 比 iStoreOS 小包完整得多，揭示了两个关键机制（均为实测读出）：

### 12.1 `part` 的真实语义 = 「建这个大小的分区 + 写入文件内容（内容可远小于分区）」

| 分区 | 声明大小 | 随包文件实际大小 | 说明 |
|---|---|---|---|
| `system`（/system, ext4） | 1,288,413,696 | `system.bin` **1,288,413,696** | 内容与分区**等大** |
| `data`（/data, ext4） | 4,521,344,000 | `data.bin` 89,473,024 | 内容远小于分区 |
| `etc`（etc, ext4） | 41,943,040 | `etc.bin` **512** | 近乎空（首启再初始化） |
| `rootfs`（/, squashfs） | 100,663,296 | `squashfs1.img` 33,329,152 | 镜像小于分区 |

→ 所以：
- **文件 = 初始内容**（可以只是很小一段，其余由系统首启时创建/扩容）；
- **`size` = 要建多大分区**；
- 我们包里 `PART0 size=0x10000000`(=p1.img 实际大小 268,435,456，**两者相等**)、
  `PART1 size=0x1BF900000`(=p2.img 实际大小 7,508,852,736，**两者相等**) ——
  属于"内容与分区等大"的最干净情形（与 `system` 那行同构）。
- ⚠️ 厂商只用过 `filesystem=ext4` 与 `squashfs`，**我们 p2 声明的是 `btrfs`，未验证工具是否接受**。

### 12.2 MBR 不止一个：厂商用的是**扩展分区链**（`mbr_00` … `mbr_06`）

```
MBR0 offset=0            name=omv/mbr_00.bin
MBR1 offset=198c00000    name=omv/mbr_01.bin
MBR2 offset=199000000    name=omv/mbr_02.bin
MBR3 offset=19a000000    name=omv/mbr_03.bin
MBR4 offset=1b9400000    name=omv/mbr_04.bin
MBR5 offset=1bf800000    name=omv/mbr_05.bin
MBR6 offset=1c5800000    name=omv/mbr_06.bin
```

每个 MBR 落在**扩展分区里各逻辑分区的边界**上（原厂有 9 个分区：system/data/cache/
uboot/logo/backup/verify/rootfs/etc），即经典 MBR 扩展分区链。

**我们板子不需要这一套**：本板只有 **2 个主分区**（p1 @38 MiB、p2 @294 MiB），
单个 `MBR0` 就描述完了（已实测：我们的 `mbr.bin` 只有分区 1、2 两条，分区 3/4 为空）。

### 12.3 小包 `config.txt` 里没有 `fw = fwtbl` 行

大包 `layout.txt` 有 `FW_FWTBL " target=0 offset=620000 size=4f0 type= name=omv/fw_tbl.bin "`，
小包也有（`size=1f0`），但**两个包的 `config.txt` 都没有对应的 `fw =` 行** ——
说明固件表由 layout 描述、不走 `fw` 列表。这解释了为什么厂商包的 `fw_tbl.bin`
尺寸不同（小包 496 B / 大包 1,264 B，记录条数不同）。

→ 我们的包沿用"只由 layout 描述"的做法；若担心工具按固定偏移写它，
可用 `--no-fw-tbl` 完全不放该文件。

---

## 13. 线刷包瘦身：精简 p2 镜像（`--p2-compact`）

### 13.1 问题

dd 出来的 `p2.img` 是**整分区裸镜像**（7,508,852,736 B ≈ 6.99 GiB），
但其中 **67.5% 是空洞**（真实数据约 2.27 GiB）：

```
p2.img 表观 7.0G   真实占盘 2.3G   空洞 4.72 GiB (67.5%)
```

**tar 不保留稀疏性**，会把 7.5 GB 原样写进包 → 全量线刷包 7.32 GiB。
厂商包之所以小，正因为它**不装整分区镜像**（见 §12.1：`etc` 分区 6.875 GiB 只带 512 B）。

### 13.2 做法（与厂商同构）

```bash
sudo firmware/shrink-p2.sh                  # 复制 + 收缩 → firmware/images/p2-compact.img
python3 tools/make-lineflash-package.py --p2-compact --with-lowregion
```

| 环节 | 处理 |
|---|---|
| 收缩 | `btrfs filesystem resize <用量+25%+256MiB>`（在**副本**上；原 p2.img 不动） |
| 分区声明 | **仍按真实分区大小** `0x1BF900000`（7,508,852,736）——不是文件大小 |
| 首启扩容 | `cm360-firstboot.sh` 执行 `btrfs filesystem resize max /` 扩回满分区 |
| 校验 | 收缩后 `btrfs check --readonly` + 关键文件存在性检查 |

体积（按真实用量推算）：

| 方案 | 精简 p2 | 全量包 |
|---|---|---|
| 现状（整分区裸镜像） | 6.99 GiB | **7.32 GiB** |
| 默认（用量 +25% + 256 MiB） | 3.25 GiB | **≈3.57 GiB** |
| 保守（用量 +50% + 256 MiB） | 3.75 GiB | ≈4.07 GiB |

### 13.3 实施中修掉的两个真 bug

1. **分区声明大小取错**：原实现用 `os.path.getsize(p2)` 当分区大小。
   整分区镜像两者恰好相等所以没暴露；一旦换成精简镜像，就会把分区
   **声明成 3.25 GiB** —— 那会真的把分区改小。
   现改为**取 MBR 里的真实分区大小**（`mbr_p2["bytes"]`），并加断言拒绝
   "精简镜像反而大于分区"的情形。
2. **产物文件名冲突**：精简包与非精简包会生成同一个
   `install-…-full.img`，**互相覆盖**。现文件名带 `compact-` 区分。

### 13.4 仍未验证

- 工具是否接受**"随包文件小于声明的分区大小"**：厂商有强先例（§12.1），
  但对**承担 rootfs 角色、且为 btrfs** 的分区未验证；
- btrfs `resize max` 在板上的实际表现未实测（逻辑上幂等：已满则空操作）；
- 分区尾部可能残留旧文件系统数据，扩容后会被 btrfs 当作空闲空间覆盖
  （btrfs 超级块只在前 64 MiB 的三处，均被新文件系统覆盖，风险低但未实测）。

### 13.5 本机实测数据与安全闸门

用 `btrfs inspect-internal dump-super`（**不需要 root**）读到本机 `p2.img` 的权威用量：

```
label=rootfs   total_bytes=7,508,852,736   bytes_used=2,351,362,048 (2.190 GiB)
建议目标 = 2.190 × 1.25 + 256 MiB → 对齐 256 MiB → 3.000 GiB
预计全量线刷包 = 3.00 + p1 0.25 + 低区 0.037 + 内核 0.035 ≈ 3.32 GiB
```

稀疏复制也实测过：`cp --sparse=always` 一份 7.5 GB 的 p2.img 只花 **1.07 秒**、
**实占 2.24 GiB**（不是 7.5 GiB）—— 所以收缩过程的磁盘开销与脚本声明一致。

脚本与生成器里已有的闸门（均已实测触发）：

| 闸门 | 行为 |
|---|---|
| 非 root 运行 | 明确报错退出（dry-run 除外 ✔ 免 root） |
| 源不是 btrfs | `dump-super` 预检直接拒绝 |
| 目标 < 真实用量 | 拒绝（会丢数据） |
| 目标 ≥ 当前大小 | 拒绝（btrfs 只能缩小，无需操作） |
| 空间不足 | 报出"需要/可用"两项再拒绝 |
| 收缩后关键文件缺失 | 拒绝并保留副本供排查 |
| 收缩后 `btrfs check` 报错 | 拒绝使用 |
| 精简镜像**不是** btrfs | 打包时拒绝 |
| 精简镜像超级块 `total_bytes` ≠ 文件大小 | 打包时拒绝（防截断半成品） |
| 精简镜像大于声明的分区 | 打包时拒绝 |

### 13.6 实测结果（真跑，非估算）

| 指标 | 实测值 |
|---|---|
| 原 `p2.img` | 7,508,852,736 B；实占 2.27 GiB；空洞 **67.5%** |
| btrfs `Used` | 2.19 GiB（超级块）/ 2.26 GiB（挂载后） |
| btrfs `Device allocated` | **4.04 GiB ← 真正的收缩硬下限** |
| `balance -dusage=50` | 4.039 → 4.086 GiB（**几乎无效**，别指望它） |
| 逐级下探（256 MiB 步长） | 4.25 → 4.00 → 3.75 → 3.50 → 3.25 → 3.00 → **2.75 GiB**；2560 MiB 失败 |
| 精简镜像 | 2,952,790,016 B（2.750 GiB），md5 `f226b9ce09466d54c21924434b1d725c` |
| **内容完整性** | 79,864 个文件 + 清单指纹 `4d5a45cb9fd318d5f5cc0fe9d1e7fe56` **与原镜像逐字一致** |
| `btrfs check --readonly` | 通过（无 error/corrupt） |
| 首启扩容（主机模拟验证） | 2,952,790,016 → `btrfs filesystem resize max` → **7,508,852,736 精确恢复** |
| 最终线刷包 | **3,299,020,800 B（3.072 GiB）**，md5 `433679645012e6eaae216fd671ad7d68` |
| 对比 | 7.316 GiB → **3.072 GiB（−58%）**；耗时 14 秒 |

包内三处关键声明（独立回读校验）：

```
layout.txt : PART1 " offset=12600000 size=1bf900000 … "   ← 1bf900000 = 7,508,852,736（真实分区）
config.txt : part = etc etc btrfs p2.img 7508852736        ← 分区大小
tar 内 p2.img 实际大小 = 2,952,790,016                       ← 随包内容（更小）
```

**两个踩坑记录（都已写进脚本注释）**

1. **收缩下限是 `Device allocated`（4.04 GiB）而不是 `Used`（2.26 GiB）**。
   按 `Used` 算目标会直接报 `ERROR: unable to resize: No space left on device`。
2. **但连续下探比单次收缩有效得多**：每次成功的 resize 都会让 btrfs 顺带搬迁/压实
   已分配块，于是逐级往下探能到 **2.75 GiB**（远低于最初看到的 4.04 GiB）。
   脚本已实现"自动下探"，无需人工试。

**仍未验证**：厂商 USB MP Tool 是否接受"随包文件小于声明分区大小"。
厂商有强先例（`etc` 分区 6.875 GiB 只带 512 B、`rootfs` 128 MiB 只带 97.9 MB），
但对**承担 rootfs 角色且为 btrfs** 的分区未实测 —— 需要 Windows + SW5 才能验。

> **后续（2026-10-22，结论已更新）**：2.75 GiB 的方案最终**不可用** ——
> 工具是 32 位进程，载入时把所有 PART 载荷整块读进内存，单载荷 ≥2 GiB 就 abort
> （§16.3 ⑤），所有载荷合计 ≳2.3 GB 更是 `GetLastError:8`（§16.3 ⑨）。
> 现行方案是 **2 GiB 精简 p2**（`firmware/slim-p2.sh`）+ 刷机后注入
> `cm360-extra-features.tar.gz` 补回功能（§16.1）；§13 的收缩算法仍可复用，
> 只是目标尺寸要压到 2 GiB 以内。

---

## 14. 厂商工具的项目标记：包内必须有 `omv`（2026-10-09 实测定案）

### 14.1 症状

把本仓库生成的线刷包丢给 Realtek USB MP Tool（`rtumdfsample.exe`）时，
点 `open` 立即弹 ERROR，工具目录 `log/error_log/*.txt` 里是：

```
===============debug log===================
Cannot get untartemp project filename (package 5 or omv or generic linux)!
Error - Read install image data failed !
```

同时工具工作目录会留下解包结果 `UnTarTmp/`，里面**正是我们包的成员**
（`config.txt` / `layout.txt` / `fw_tbl.bin` / `mbr.bin` / 各载荷）。
→ 说明 **tar 解包是成功的，缺的是工具要的"项目标记"**。

### 14.2 工具逻辑

`rtumdfsample.exe` 里能读到相邻的字符串：

```
\UnTarTmp
Cannot get untartemp project filename (package 5 or omv or generic linux)!
read UntarTemp file failed!!
ScanTargetName: %s, PartNumFileName: %s
```

即：解包到 `UnTarTmp` 后，工具要在里面找到**它认得的项目名条目**，
候选只有 `package 5` / `omv` / `generic linux` 三个。
厂商原包（`istore-r16974-cm360.install.img`）里恰好有 `omv/`（含 `omv/bootloader.tar`）；
本仓库早期的包是**平铺**的、没有任何子目录 → 命中不了 → 报错。

### 14.3 对照实验（同一套 `config.txt`/`layout.txt`，只改标记）

| 测试包 | 加的条目 | 工具反应 |
|---|---|---|
| 厂商原包（对照） | `omv/` | ✅ 正常载入 |
| A | 空目录 `omv/` | ✅ **正常载入** |
| B | `omv/` + `omv/bootloader.tar` | ✅ 正常载入 |
| C | 普通文件 `omv` | ✅ 正常载入 |
| D | 目录 `package 5/` | ❌ 同样报错 |
| E | 目录 `generic linux/` | ❌ 同样报错 |
| F | `omv/` + `bootloader.tar` + `install_a` + `gold_fw_tbl.bin` | ✅ 正常载入 |
| G | `omv/` + 厂商大包那套目标名（`uboot.bin`/`system.bin`/`mbr_00.bin`/…） | ✅ 正常载入 |

**结论**：只需一个名为 `omv` 的条目（**目录或普通文件都行**）；
`install_a`、`gold_fw_tbl.bin`、`bootloader.tar`、`omv/` 内的目标名**都不是必需的**。

### 14.4 落地

`tools/make-lineflash-package.py` 现在**默认在包尾加入空目录 `omv/`**
（可用 `--no-project-mark` 关闭），回读校验会打印目录列表以便确认：

```
[回读] tar 内 9 个文件：Image-6.6.uimage, README-线刷.txt, config.txt, fw_tbl.bin, ...
[回读] tar 内目录：omv
```

### 14.5 仍未验证的部分

- **实际刷写**（点绿人写 eMMC）尚未在真机跑过：需要 Windows + 按住 SW5 进下载模式。
- 读包阶段已验证通过；`layout.txt` 的绝对偏移、`fw_tbl.bin` 自检、MBR 条目均为本仓库生成且自洽。
- `FW_FWTBL` 条目厂商有、本仓库没有：读包阶段不影响（测试包 A 无此条也能载入），
  实际刷写是否需要待验证。本板 u-boot 的启动参数写在自己的 env 里（见 §11），不依赖该表。

---

## 15. 布局重叠缺陷：`FW_KERNEL` 会压进 p1（2026-10-10 修正）

### 15.1 症状与发现方式

给厂商工具把包补齐 `omv/` 之后，按"是否真能刷"逐项审计 layout 的绝对偏移，发现：

| 条目 | eMMC 字节范围 | 说明 |
|---|---|---|
| `MBR0` | 0 ~ 512 | ✔ |
| `FW_KERNEL_DT` | 11,652,608 ~ 11,661,436 | 落在低区内（本板不需要） |
| **`FW_KERNEL`** | **11,701,248 ~ 49,620,544** | ✗ **越过低区边界，压进 p1 开头 9.8 MB** |
| `PART0`（p1） | 39,845,888 ~ 308,281,344 | ← 与上一条重叠 |
| `PART1`（p2） | 308,281,344 ~ 7,817,134,080 | ✔ |

根因：这两个偏移是从厂商包**照抄**的（厂商 `FW_KERNEL offset=0xB28C00`），
但厂商板子的 p1 从 **128 MB**（`0x8000000`）开始，而我们这块板 p1 从 **38 MB** 开始；
内核 `Image-6.6.uimage` 有 **37,919,296 B ≈ 36.2 MiB**，**塞不进 38 MiB 的低区**，
于是写入范围必然越过 39,845,888 这条边界。

后果：若工具**先写 PART 再写 FW**，p1 开头 9.8 MB 会被内核覆盖 → 内核分区损坏 → 起不来。
（反过来若先 FW 后 PART，p1 会被随后完整覆盖，则无碍——顺序未知，所以必须消除重叠。）

### 15.2 修正

本板 u-boot 是从 **p1 的 ext4** 里读内核的（见 §11），低区**不需要**内核副本，
因此 `tools/make-lineflash-package.py` 现在**默认不生成** `FW_KERNEL` / `FW_KERNEL_DT`
（`config.txt` 的 `fw =` 行与 `layout.txt` 的 `FW_*` 条目都不写），
需要还原实验可用 `--vendor-fw-offsets`。

改完之后一个"只刷系统"的包写入范围只剩三条，且互不重叠：

```
MBR0     0 ~ 512
PART0    39,845,888 ~ 308,281,344          (p1，内核与 DTB 都在这个分区里)
PART1    308,281,344 ~ 7,817,134,080       (p2)
```

生成器在结束时会显式打印这条说明；`--with-lowregion` 时另有 `FW_LOWREGION`
（`offset=0 size=38 MiB`），它与 `MBR0` 内容一致、与 `PART0` 也不重叠。

### 15.3 教训

**从厂商包抄偏移量必须连同"厂商的分区表"一起抄**：
偏移是相对于厂商自己那套 MBR/分区的，搬到另一块分区表不同的板子上就会重叠。
本仓库的 `mbr.bin` 来自本板低区（`PART0 offset=0x2600000`），
与厂商的 `PART0 offset=0x8000000` 不同，所以凡是与分区相关的偏移都必须重算或去掉。

---

## 16. 2026-10-20：改用厂商官方打包工具 `rtd129x_img_gen` 生成元数据

### 16.1 结论

拿到了厂商的打包工具 **`rtd129x_img_gen`**（Linux x86_64 静态编译，1.2 MB 压缩包里
还有 `rtd129x_bootcode_gen` / `rtd129x_encode_hwsetting` / `rtd129x_decode_hwsetting`）。
它的用法就两个参数：

```bash
rtd129x_img_gen <LAYOUT>.json <WORKING_DIR>
```

跑完在 `WORKING_DIR` 里生成 `config.txt` / `layout.txt` / `mbr.bin` / `fw_tbl.bin`
（有 `gold` 条目时还有 `gold_fw_tbl.bin`），再把整个目录 tar 起来就是线刷包。

**实测复现**：拿厂商 iStoreOS CM360 包（`istore-r16974-cm360.install.img`，139 MB）
解包反推出它的 JSON，重跑一遍工具 → 生成的 `config.txt`、`mbr.bin`、`fw_tbl.bin`
与厂商原包**逐字节相同**，`layout.txt` 仅 `CREATE_DATE` / `CREATE_TIME` 两行不同。
⇒ 工具语义已对齐，可以放心用它重打我们自己的包。

本板线刷包已改由该工具生成：`tools/make-lineflash-official.sh` +
`tools/lineflash/emmc_8gb_cm360.json`。本次产物：

```
install-cm360-fnos-1.2.0302-full.img        2,365,593,600 B
md5 23eef9790b9d391d1c2f6800467afd96
包内 9 个成员：config.txt / layout.txt / mbr.bin / fw_tbl.bin / README-lineflash.txt /
               omv/ / dummy-kernel.bin（2 B 占位，见 §16.3 ⑥）/ p1.img / p2.img
               ← 成员名必须全 ASCII，见 §16.3 ④
layout：FW_KERNEL(dummy 0x630200, 2 B) + MBR0 + PART0(p1 0x2600000, 0x10000000)
        + PART1(p2 0x12600000, 0x1BF900000)
p1.img = 268,427,264 B（0x7FFF0 扇区，与分区等大）
p2.img = 2,097,152,000 B（2000 MiB **精简镜像**，< 2 GiB，见 §16.3 ⑤；
                          分区仍按 0xDFC7F0 扇区≈7.0 GiB 建立，首启 resize max 撑满）

install-cm360-fnos-1.2.0302-full-uboot.img  2,405,437,440 B   ← 含低区（u-boot+env）
md5 9c0c2175571a6c879fd8d18ad8c54948
包内 10 个成员：上面的 9 个 + low-region.img（38 MiB，去掉前 512 B）
layout：FW_KERNEL(低区 0x200~0x2600000, 0x25FFE00) + MBR0 + PART0 + PART1

install-cm360-fnos-1.2.0302-full-uboot-f2.img  2,405,570,560 B   ← ★ 最终版（实测可自动引导）
md5 032d1f2d6b1e49c88cc80f429be9183f
包内 11 个成员：上面的 10 个 + omv/factory.tar（根相对成员 env.txt，见 §16.3 ⑧）
⇒ 一次刷写：低区(u-boot+env) → MBR → p1 → p2 → 最后 factory.tar（env 恢复）
⇒ 2026-10-22 实机验证：刷完断电重启**自动进 fnOS**，不再需要手动 bootm/saveenv
```

> 2026-10-22 实机验证记录：
> - 载入阶段：真机工具 open 各包均无 ERROR / 无 error_log；
> - 烧写阶段：`FW_KERNEL` 低区整块写入成功（日志 `start block: 1`，19×2MB）；
> - env 丢失根因 = 工具最后写空白 factory.tar（§16.3 ⑧），已用 `omv/factory.tar` 修好；
> - **最终包 `...-full-uboot-f2.img` 刷完可自动引导 fnOS**。
> - 更早的包（full / full-uboot）仅用于验证/对比，不要用于最终刷机。

**"功能完整"怎么办？——刷精简系统 + 注入功能包（2026-10-22 定案）。**
原厂完整 p2 是 7,508,844,544 B（≈7.0 GiB）。工具在**载入阶段会把所有 PART 载荷整块读进
内存**（32 位进程），单包 PART 总载荷超过 ≈2.3 GB 就报 `GetLastError:8`（内存不足）
—— 所以"p2 全量 + 一次刷完"这条路走不通；把 p2 拆成 PART1..PART4 也一样失败
（`--p2-split` 实验包 `...-full-uboot-split.img` 载入报 `load [PART2] data failed`，见 §16.3 ⑨）。
现在的做法是**先刷"引导 + 精简系统"，开机后再注入功能包**：

| 文件 | 大小 | 说明 |
|---|---|---|
| `extra/cm360-extra-features.tar.gz` | 485 MB（508,228,333 B；解开 1.53 GiB） | 从完整 p2 里剥出来的功能组件（`/usr/lib/firmware`、AAVMF、LLVM/gallium、Qt、gcc、文档、locale、apt 缓存等，28,190 个成员），md5 `f91c6c9ef0f6ec4fd18a44df761ad018` |
| `extra/install-extra-features.sh` | — | 板端执行：`tar -xzpf ... -C /` + `ldconfig`，需 root |
| `extra/make-extra-features.sh` | — | 主机端：挂载完整 p2 镜像，重新生成上面那个 tar.gz |

用法：先刷 `...-full-uboot-f2.img` → 开机进 fnOS → 把 `extra/` 传到板上
→ `sudo ./install-extra-features.sh` → 重启。之后 `df -h /` 应显示 p2 已被
首启 `btrfs filesystem resize max` 撑到 ≈6.9 GB，功能集与完整镜像一致。
（交付目录：`C:\Users\xiaoa\CM360-lineflash\extra\`；仓库内脚本：
[`firmware/make-extra-features.sh`](../firmware/make-extra-features.sh)、
[`firmware/install-extra-features.sh`](../firmware/install-extra-features.sh)。）

### 16.2 JSON 字段（实测语义）

| 字段 | 含义 |
|---|---|
| `size` | eMMC 总字节数（8 GB 片 = `0x1D2000000`） |
| `fw_table_offset` / `gold_table_offset` | 固件表 / gold 表写到 eMMC 的偏移（厂商默认 `0x620000` / `0x630000`，都在低区） |
| `fw_start` / `fw_align` | `fw[]` 里各文件的起始偏移与对齐（本板不用 fw 条目） |
| `gold_start` | gold（救援）镜像区起点 |
| `part_start` | **第一个分区**的字节偏移（本板 `0x2600000`） |
| `part_align` | 分区对齐（厂商 `0x2000`） |
| `fw[]` | `{type, target, file}`；`type` ∈ `RESCUE_DT`/`RESCUE_ROOTFS`/`AKERNEL`/`KERNEL_DT`/`KERNEL`，生成 `FW_*` 条目，按 `fw_start` 顺序排布 |
| `gold[]` | 同上，生成 `FW_GOLD_*` |
| `part[]` | `{name, mp, size, filetype, filesystem, file}`；`size` 为 `-1` 表示"剩余全部空间" |

### 16.3 九个必须知道的坑（全部实测）

**① `filesystem` 只认 `squashfs` / `ext4`。**
写别的（如 `btrfs`）工具直接报 `unsupported fstype:btrfs` 并退出。
本板 p2 是 btrfs，JSON 里只能写 `ext4`；该字段只进 `config.txt` / `layout.txt` /
`fw_tbl.bin` 的元数据，**工具不会格式化分区**，写进分区的仍是我们那份 btrfs 镜像，
所以标成 `ext4` 无害 —— 别看到 `filesystem=ext4` 就以为 p2 被格成 ext4 了。

**② 工具算的 MBR 扇区数 = 声明大小 / 512 − 16（每个分区都少 8 KiB）。**
本板内核/文件系统会校验"设备尺寸 ≥ 文件系统尺寸"，尺寸差 8 KiB 就会挂不上：
ext4 报 `bad geometry: block count ... exceeds size of device`，
btrfs 报 `device total_bytes ... smaller than ...`。
所以镜像必须按 **MBR 里的扇区数**生成：

```
p1 = 0x7FFF0 扇区 = 268,427,264 B   （ext4 65534 × 4 KiB）
p2 = 0xDFC7F0 扇区 = 7,508,844,544 B
```

`firmware/build-images.sh` 默认按**实机分区**生成（p1 `0x80000` / p2 `0xDFC800`），
直接喂给工具会大 8 KiB；本次做法：p2 用 `P2_BYTES=7508844544` 生成，
p1 用 `resize2fs 65534` + `truncate` 收缩。
（`make-lineflash-official.sh` 的 `--shrink-to-mbr` 只是占位参数、**尚未实现**，
脚本只做尺寸校验；完整打包流程见 [`13-lineflash-packaging-guide.md`](13-lineflash-packaging-guide.md)。）

**③ `Layout_Type` 是固定名字白名单，未知条目被静默忽略。**
`LoadFlashLayout` 是对着固定名字列表逐条 `strstr` 找行，白名单共 24 个
`FW_*`（`FW_KERNEL` / `FW_RESCUE_DT` / `FW_KERNEL_DT` / `FW_RESCUE_ROOTFS` /
`FW_KERNEL_ROOTFS` / `FW_NAS_RESCUE_*` / `FW_AKERNEL` / `FW_TEEKERNEL` /
`FW_BL31` / `FW_P_UBOOT` / `FW_DALOGO` / `FW_DILOGO` / `FW_CILOGO1` /
`FW_FWTBL` / `FW_CONFIG` / `FW_PROFILE` / `FW_GOLD_*` / `FW_EFUSE_*`）
加 `PART0…PART7` / `MBR0`。**自定义名字（旧脚本的 `FW_LOWREGION`）不会被处理**
⇒ §11 里"救援包会写低区"的说法不成立，线刷包写不了低区；低区恢复只能走
`dd` / TFTP / 工具自身的 `bootloader.tar`（`only upgrade bootloader`）通道。

另外工具会**自动追加**一条 `FW_FWTBL`（把 `fw_tbl.bin` 写到低区 `0x620000`，
即原厂镜像区）。本板 u-boot 用 env 引导、不读这张表，为了不动低区已有数据，
`tools/make-lineflash-official.sh` 默认把这条从 `layout.txt` 删掉
（`--keep-fwtbl` 可保留）。

**④ 包内 tar 成员名必须全部是 ASCII（2026-10-21 实机定案，这是"能载入"的最后一道坎）。**
工具的 `decompressTarget` → `tarlib` 解包是在 `setlocale(0,"")`（中文 Windows = GBK）
下解析 header 文件名的；遇到 **UTF-8 中文文件名**会**异常中断整个解包循环**：

```
# 实测现场（C:\w2_android_usb_download_tool\UnTarTmp）
config.txt  fw_tbl.bin  layout.txt  mbr.bin      ← 只有前 4 个 ASCII 成员
# 第 5 个成员是 README-线刷.txt（中文名）→ 解包在这里中断
# → omv/、p1.img、p2.img 都没解出来
# → 报 "Cannot get untartemp project filename (package 5 or omv or generic linux)!"
#   + "Error - Read install image data failed !"
```

修法：**成员名全部 ASCII**（`README-lineflash.txt`、`omv/README.txt`；文件内容仍可中文），
`tools/make-lineflash-official.sh` 已照此生成，并在打包后加了
"`tar -tf | grep 非 ASCII`" 的兜底检查。
（厂商原包所有成员名也都是 ASCII，这条与厂商一致。）

**⑤ 单个分区载荷必须 < 2 GiB（32 位文件大小溢出），否则载入到 100% 前崩溃。**
`ReadUnTarTempFile` 里 `getDataLen(file, (long*)&Real_Partition_Data_Size_Point[i])`
把载荷大小存进 **32 位有符号 long**；≥ 2³¹（2,147,483,648 B）时变负数，
后面的 `size / 0x3000000` 循环与 PartStruct 数组越界 → `terminate()` → `abort()`：

```
WER: 异常代码 0xC0000409（STATUS_STACK_BUFFER_OVERRUN/abort）
     错误偏移 0x00160371 → 对回 PDB = abort()（0x560349 + 0x28）
```

实测阈值（同一套元数据、只改 p2.img 大小）：

| p2.img 载荷 | 工具行为 |
|---|---|
| 2,000,000,000 B | ✅ 正常载入，日志 `ScanTargetName: PART1 ...` |
| 2,200,000,000 B | ❌ 0xC0000409 闪退（解包已完成，`UnTarTmp` 7.3 GB 齐全） |
| 7,508,844,544 B（完整 p2） | ❌ 同上 |

修法：**p2 用精简镜像**（< 2 GiB）。`part` 语义本来就允许"文件内容 < 分区大小"
（厂商原包 rootfs.bin 97 MB 写进 128 MiB 分区同理），分区仍按 7.5 GB 建立，
板上首启由 `cm360-firstboot.sh` 的 `btrfs filesystem resize max /` 扩回满分区。
构建脚本：`firmware/slim-p2.sh`（把完整 p2 重建为 2000 MiB，含精简清单与自检）。
本次精简掉的都是 NAS 用不到的东西：`/usr/lib/firmware`（本板驱动全内建）、
`/usr/lib/gcc`、`/usr/include`、`/usr/src`、文档/man、多余 locale、apt 缓存、
AAVMF/Qt/pocketsphinx/vim（GUI/VM 静态资源）、软件渲染 LLVM。

**⑥ 烧写阶段强制要求 `FW_KERNEL` 长度非零，否则弹 LOST 错误、根本不开刷。**
`ThreadProgramDevice`（0x00422A40）在真正写盘之前检查
`m_dev_info[i].FW_Kernel_Len`——它来自 `Layout_Type[0].length`，也就是
`layout.txt` 里 **`FW_KERNEL` 条目的 `size=`**：

```
if (FW_Kernel_Len != 0 || bOnly_upgrade_uboot || flashType == 1) { 正常烧写 }
else 弹框 "LOST: kernel data length not found maby forgeter open install image!"
```

我们的包为了"不碰低区、不压 p1"把 `FW_KERNEL` 去掉了 → 点绿人直接报这个 LOST。
修法：加一个 **2 字节占位** `dummy-kernel.bin` 作为 `FW_KERNEL`（`offset=0x630200`，
低区里紧挨固件表之后的原厂 fw 区），只写 2 字节，不碰 u-boot/env/p1；
`config.txt` 同时生成 `fw = linuxKernel dummy-kernel.bin 0x3000000`。
`tools/lineflash/emmc_8gb_cm360.json` 的 `fw[]` 已带这一条，
`tools/make-lineflash-official.sh` 会自动把 JSON 引用的 fw 文件拷进包并检查存在。

**⑦ 可以让线刷包把整块低区（u-boot/env/factory）一起写回去 —— 解决"刷完 env 丢"。**
2026-10-21 实机验证：这个工具**每次普通刷写都会重建 factory 区**
（eMMC 0x220000/0x420000 的 factory tar，里面是 `tmp/factory/env.txt`），
把 u-boot env 清掉 → 开机 `[ENV] read_env from factory failed` → 默认 env
→ 走 Realtek 默认引导流程 → 停在 `BPI-W2>` 控制台（系统本身是好的，手动 `bootm` 能进）。

利用工具"**`FW_KERNEL` 条目的文件会按 layout 的 offset 原样写入 eMMC**"这一点，
把整块 38 MiB 低区镜像伪装成 `FW_KERNEL` 载荷即可：

```
fw_start = 0x200                # 不能是 0！LoadFlashLayout 用 offset!=0 判断条目有效
FW_KERNEL " target=3000000 offset=200 size=25ffe00 type=bin name=low-region.img "
```

- 载荷 = `low-region.img` 去掉前 512 字节（跳过 MBR；MBR 由 `MBR0` 单独写）；
- 写入范围 `0x200 ~ 0x2600000`，终点正好等于 p1 起点，不触发工具
  `firmwares overlaps normal partitions` 校验（`fw_start + size <= part_start`）；
- 内容包含 hwsetting / bootcode / FSBL / u-boot / env / factory；
- ⚠️ 写低区期间断电有变砖风险（可用 SW5 + 同一个包再救）；
- 脚本开关：`--lowregion <low-region.img>`（产物名 `...-full-uboot.img`）。
- **只想恢复 env、不想动整块低区**：见 [`../firmware/env-restore/README.md`](../firmware/env-restore/README.md)
  （`setenv`+`saveenv` 一步修好；备有从仓库低区镜像切出的 factory 区 blob 可整块写回）。
- ⚠️ **只写低区还不够**：工具在烧写**最后一步**还会重写 factory 区（见 ⑧），
  会把刚写进去的 env 再盖掉 —— 必须同时用 `--factory-tar`。

**⑧ 工具最后一步会用 `omv/factory.tar` 重写 factory 区（env 就存在这里面）。**
实机烧写日志（`log/debug_log/*.txt` 末尾）固定出现：

```
enter , write factory icon[0]
full install - write blank factory.tar not include secure key
try to use blank factory.tar in mp tool
Source: ...\UnTarTmp\omv\factory.tar
...
factory address - starpage : 4352   → eMMC 0x220000
factory address - starpage : 8448   → eMMC 0x420000
```

- 包里没有 `omv/factory.tar` 时，它写一份**空白 factory.tar**（~12 KB，无 `env.txt`）
  → u-boot 开机 `[ENV] read_env from factory failed` → 默认 env → 停在 `BPI-W2>`；
- 包里给了 `omv/factory.tar` 时，它用我们的 tar 解包 → **再加 `tmp/factory/` 前缀重打包**
  → 写回 0x220000/0x420000。**关键：输入 tar 的成员要用"根相对路径"**：

  | 输入 `factory.tar` 成员 | 工具重打包后写进 eMMC 的成员 | u-boot 能否找到 env |
  |---|---|---|
  | `tmp/factory/env.txt` | `tmp/factory/tmp/factory/env.txt`（路径被套一层） | ❌ |
  | `env.txt` | `tmp/factory/env.txt` | ✅ |

  正确做法：`tools/make-factory-tar.py` 从低区镜像抽出 `tmp/factory/env.txt`，
  以根相对名 `env.txt` 打成 `factory.tar`，打包时 `--factory-tar factory.tar`。
  实测（2026-10-22）：`full-uboot + factory.tar` 刷完断电重启，**自动进 fnOS**。

**⑨ 所有 PART 载荷在载入阶段一次性进内存，单包总量 ≲2.3 GB（分片绕不过去）。**
工具是 32 位进程，`LoadFlashImage` 会在刷写前把 layout 里**每个 `PARTn` 的镜像整块
读进 RAM**（`Real_Partition_Data_Size_Point` 里累加）。实测阈值：

| 单包 PART 总载荷 | 结果 |
|---|---|
| p1 256 MB + p2 2,000,000,000 B（≈1.86 GiB） | 载入/刷写正常 |
| p1 256 MB + p2 2,200,000,000 B | 载入阶段进程 `abort()`，错误码 `0xC0000409` |
| p1 256 MB + p2 1.87 GB + 再拆 PART2/PART3 各 1.87 GB | `GetLastError:8`、`load [PART2] data failed` |
| p2 全量 7.0 GiB（单 PART） | 同上，载入直接失败 |

- 32 位地址空间 + 工具自身的解包/校验缓冲，实际可用上限约 **2.3 GB**；
  超额时报的往往是 `GetLastError:8`（内存不足）或 `PARTn data failed`，**不是包格式问题**；
- 想靠"同一包内把 p2 切成 PART1..PART4"绕过是**无效**的 —— 总量不变，照样超限
  （脚本的 `--p2-split` 仅留作实验记录，不要用于出包）；
- 可行的路线：
  1. **精简 p2（当前采用）**：p2 ≤ 2 GiB，一次刷完，再用 §16.1 的
     `extra/cm360-extra-features.tar.gz` 在板端补回功能组件；
  2. **多趟线刷（未实做）**：每趟单独一个包、每趟 PART 载荷 ≤ ≈2.2 GB
     （如 p1 一趟、p2 分段四趟），靠 MBR/layout 只写各自区段；
     但工具每趟都会重写 MBR 与 factory 区（⑧），需逐趟确认 env 不被覆盖；
  3. **换一个支持大载荷的工具（2026-10-23 提供包，2026-10-26 修正 factory.tar）**：
     `make-lineflash-official.sh --full-p2` 出**不精简、不分片**的完整包
     `install-cm360-fnos-1.2.0302-full-uboot-fullp2.img`（7,817,267,200 B，
     md5 `f9e52e6e7dac548159623c590514058a`）：layout PART1 整块 `0x1bf900000`
     （7,508,852,736），包内 `p2.img` = 7,508,844,544 B（= MBR 分区），
     `omv/factory.tar` 成员为根相对 `env.txt`（133,120 B）。
     旧厂商 32 位工具载入仍会 `GetLastError:8`，只用于验证新工具能否吃下大载荷。
     ⚠️ 首版曾误把 0x220000 原始 factory blob（成员 `tmp/factory/env.txt`）传进
     `--factory-tar`，工具再套一层前缀 → 刷完 `read_env from factory failed` → 掉到
     `BPI-W2>`；脚本现已能自动纠正这种输入并告警（见 §16.3 ⑧）。

### 16.4 本板 JSON

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
  "fw": [
    {"type": "KERNEL", "target": "0x3000000", "file": "dummy-kernel.bin"}
  ],
  "gold": [],
  "part": [
    {"name": "boot",   "mp": "/boot", "size": "0x10000000",  "filetype": "img", "filesystem": "ext4", "file": "p1.img"},
    {"name": "rootfs", "mp": "/",     "size": "0x1BF900000", "filetype": "img", "filesystem": "ext4", "file": "p2.img"}
  ]
}
```

`size` = 15,269,888 扇区（`/sys/block/mmcblk0/size` 实测值）；`part_start` 与
本板现有 MBR 一致（p1 从 38 MiB 开始）。`fw[]` 里那条 **`dummy-kernel.bin`（2 字节）**
不是真内核（本板内核在 p1 的 ext4 里，由 u-boot `ext4load` 读取），只是为了满足
烧写阶段的 `FW_Kernel_Len != 0` 检查（§16.3 ⑥）；它会被写到低区 `0x630200`，
**只写 2 字节**，不碰 u-boot / env / p1。

### 16.5 生成与校验

```bash
# Linux / WSL（工具不在仓库里，路径自己指定）
bash tools/make-lineflash-official.sh \
  --tool /path/to/rtd129x_img_gen \
  --p1   /root/cm360-build/images/p1.img \
  --p2   /root/cm360-build/images/p2.img \
  --out  /root/cm360-build/out \
  --version 1.2.0302
```

脚本会：暂存文件 → 跑 `rtd129x_img_gen` → 校验 **MBR 扇区数 == 镜像字节数**
（不匹配直接报错，避免刷完挂不上）→ 去掉 `FW_FWTBL` → 写 `README-线刷.txt` →
加 `omv/` 项目标记 → 打 tar → 打印 md5。

本包 `layout.txt` 最终只写三条互不重叠的条目：

```
MBR0     offset=0          size=0x200
PART0    offset=0x2600000  size=0x10000000   (p1: 内核 + DTB)
PART1    offset=0x12600000 size=0x1BF900000  (p2: fnOS rootfs, btrfs)
```

（`MBR0` 覆盖 0~512，`PART0` 从 38 MiB 开始，`PART1` 从 294 MiB 开始。）

### 16.6 已验证 / 仍未验证

- **★ 全流程已实机打通（2026-10-22）**：`...-full-uboot-f2.img`
  （2,405,570,560 B，md5 `032d1f2d6b1e49c88cc80f429be9183f`）用厂商工具载入 → 烧写 →
  断电重启，**自动进 fnOS**，无需再手动 `bootm` / `saveenv`。一次刷写覆盖
  低区(u-boot+env) + MBR + p1 + p2(精简) + factory.tar。
- **"p2 全量一次刷完"已实测不可行**：工具把全部 PART 载荷读进内存，单包 >≈2.3 GB
  即失败（§16.3 ⑨）；`--p2-split` 四段包同样 `[PART2] data failed`。
  功能完整性改由板端注入 `extra/cm360-extra-features.tar.gz` 达成（§16.1）。
- **待验证**：板上 `sudo ./install-extra-features.sh` 后的功能回归
  （firmware/AAVMF/LLVM 等是否齐全）、以及首启 `btrfs resize max` 后的 `df -h /`。
- **载入阶段：已用真机工具实测通过**（2026-10-21，Windows 11 + Excel 补丁版
  `rtumdfsample.exe`，自动化点 open）：sysonly 与 full（精简 p2）两个包均
  **无 ERROR、无 error_log**，`UnTarTmp` 解包完整，日志出现
  `FlashLayoutPath : ...\layout.txt`、`ScanTargetName: PART0/1 ...`，进程存活。
  走过这段之前踩过的坑：ASCII 成员名（§16.3 ④）、p2 < 2 GiB（§16.3 ⑤）。
- **烧写阶段：第一道门槛已修好、真机刷写仍待验证。**
  2026-10-21 真机点绿人时先弹了 `LOST: kernel data length not found ...` ——
  原因是 `FW_KERNEL` 长度为空（§16.3 ⑥）。已加 2 字节 `dummy-kernel.bin` 补齐；
  载入阶段重新回归通过。真正的 eMMC 写入（MBR + p1 + p2 + 2 字节 fw）尚未跑过，
  首次刷之前建议先 `dd` 备份低区
  （`firmware/dd-flash.sh` 或 `firmware/flash-from-pc.py --backup-only`）。
- **本地静态校验**：
  - `rtd-flash inspect`（Rust 复刻的厂商工具）能识别 `Omv` 项目布局、8 个成员、
    `layout.txt` 原文正确 —— 说明"解包 + 项目标记 + 元数据"这一层没问题；
  - 注意：该复刻器只解析带 `target=` 的 `FW_*` 条目，`PARTn` 在**原工具里走另一条
    解析路径**（按 `PARTn` 名字取 offset/size/mount_point/partname），所以
    inspect 的"分区匹配"一栏为空是**复刻器覆盖不全**，不是包的问题；
  - `tools/make-lineflash-official.sh` 自带 Python 三方校验：
    **MBR 扇区数 == 镜像字节数**、**layout PARTn 的 offset/size ↔ MBR 一致**、
    **各写入区互不重叠**、**单载荷 < 2 GiB**。本次 full/sysonly 全部通过。
- **包内没有 `omv/bootloader.tar`**：读包不需要（§14 已实测空 `omv/` 也能载入），
  但刷写阶段工具是否会从自己的 `Tempfile\bootloader.tar` 取引导链、
  是否顺带写低区，**仍未知**。第一次刷之前建议先 `dd` 备份低区
  （`firmware/dd-flash.sh` 或 `firmware/flash-from-pc.py --backup-only`）。
- **`rom/release/install-sysonly.img.gz` 是坏文件**（2026-10-20 发现）：
  只有 1,064,960 B，gzip 头声明原始 3,848,440,792 B，`gzip -t` 报
  `unexpected end of file`。拿它去线刷必然"载入固件就错误"，与元数据无关；
  本节的 full 包可替代它（重新生成即可）。

