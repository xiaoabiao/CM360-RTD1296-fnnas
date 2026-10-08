# CM360 刷机包（fnOS 1.2.0302 + 自编译内核 6.6.54）

把这条链**一次刷回**所需要的东西，以及四条互不依赖的刷入路线。
目标是：板子哪怕变成砖，也能靠这份包恢复成"现在这台可用状态"。

---

## 零、先看这里：按场景选路线（**能不动低区就不动低区**）

这个包是**灾难恢复**用的，不是日常工具。真正的原则只有一条：
**低区是全板唯一的"砖区"，能用别的方式解决就绝不碰它。**

| 场景 | 推荐做法 | 为什么这是最简最安全 | 需要什么 |
|---|---|---|---|
| **日常换内核 / 调 DTS**（90% 的情况） | 在系统里把 p1 的两个文件覆盖掉：`mount /dev/mmcblk0p1 /mnt/p1` → `cp Image-6.6.uimage rtd1296-cm360.dtb /mnt/p1/`，**改之前先把旧的存成 `.bak`** | 完全不碰低区；写错了 u-boot 里三条 `ext4load … .bak` + `bootm` 就能回退 | 只要能 SSH |
| **重装系统层**（fnOS 换版本 / 系统起不来但 u-boot 正常） | 官方 arm 镜像 + `tools/upgrade/` 的三个脚本（复制→适配→切换），切换 = 子卷改名，回滚 = 改回来 | 零低区风险；旧系统整份留着，随时一键回滚 | 系统能起来（或 u-boot 能引导 p1 的内核） |
| **整机重装**（内核 + rootfs 一起，低区仍是好的） | u-boot + TFTP/U 盘：只写 **p1 + p2**，写完 `mmc read` 回读比对 | 在 u-boot 这个可控环境里做，仍然不碰低区 | 串口 + TFTP 或 U 盘 |
| **真砖了**（低区坏、u-boot 都起不来） | 串口 ROM Monitor，**只补最小集合**：hwsetting 3 KB + bootcode 515 KB + FSBL 72 KB + BL31 25 KB + u-boot 604 KB ≈ **1.2 MB** | 这条路我们实测走通过；1.2 MB 走 YMODEM 是分钟级，而整块 38 MiB 低区走串口要好几个小时，不现实 | 串口 + `tools/recovery/` |
| 全盘刷（本包 L0+L1+L2 一次写完） | 只在"换了板子/换了 eMMC"时才需要 | — | 最慢、风险最高，属于最后手段 |

### 明确不要做的三件事

1. **不要把自造数据写进低区** —— 2026-10-05 那次变砖，就是因为把前 1 MiB 清了、又往 LBA 2048 塞了个自造裸内核。
2. **不要在低区中途断电**：低区写入期间断电 = 需要串口救砖（虽然能救，但麻烦）。
3. **不要为了"图省事"每次都整盘刷**：日常迭代走 p1；系统层走子卷脚本。
   （`saveenv` 本身是正当操作 —— 我们的 `bootcmd`/`bootargs` 就是这么固化的 —— 手工往低区 dd 才是危险动作。）

### 一句话结论

> **日常**：只覆盖 p1 的两个文件 + 留 `.bak`。
> **换系统**：官方镜像 + 子卷脚本（改名切换，改名回滚）。
> **整机**：u-boot 写 p1+p2，不碰低区。
> **砖了**：串口补 1.2 MB 最小集合。
> 本包的 L0 低区镜像只在"真正需要还原整条链"时才用。

---

## 一、要刷的东西 = 三层

| 层 | 内容 | 位置 | 大小 | 来源 |
|---|---|---|---|---|
| **L0 低区** | hwsetting + bootcode + FSBL + BL31 + u-boot + u-boot env | LBA `0` ~ `77824` | 38 MiB | **必须是本板实测可用的低区 dump**（见下） |
| **L1 内核** | `Image-6.6.uimage` + `rtd1296-cm360.dtb` | `mmcblk0p1` @ LBA `77824` | 256 MiB 分区 | `artifacts/kernel-6.6.54/` |
| **L2 rootfs** | fnOS 1.2.0302 根文件系统（btrfs 子卷 `root`） | `mmcblk0p2` @ LBA `602112` | 6.99 GiB 分区 | 见下 |

> 分区边界实测：p1 = LBA 77824（38 MiB），p2 = LBA 602112（294 MiB），
> 所以**低区就是 p1 之前那 38 MiB**，两者不重叠 —— 这一点是"分层刷入"能成立的前提。

## 二、低区里到底有什么（实测结论）

```
0x00000200  hwsetting            ← ROM 在 blk#0x100 读它
0x00020E00  bootcode             （FSBL 日志：FW Image fr 0x00020E00，size 0x7DC20）
0x000B0600  TEE / BL32           （FW Image fr 0x000B0600，size 0x7BDA0）
0x0012C400  BL31                 （FW Image fr 0x0012C400，size 0x62A0）
0x00002100  u-boot env/factory   （blk#0x2100，len 0x20A00）
其余         FSBL / FSBL_OS / u-boot（偏移未全部反推，因此低区一律整块 dump/写回）
```

### 关于 `hw_setting.bin`（重要发现）

它不是"分区表"，而是 **ROM 上电执行的硬件初始化脚本**：

- `+0x004..+0x010`：uboot/fsbl/tee/bl31 的**长度**（与 `vendor-firmware/*.bin` 逐一吻合）
- `+0x060` 起：**寄存器写入序列**，`0xFFFFFFFx` 是命令码（延时/结束），
  例如 `0x98007032`（iso 块）、`0x98007680`（看门狗）、`0x9801a308`（SCPU/SB2）

⇒ **它是全板最"不可替代"的文件**：DRAM/时钟/引脚的上电初始化都在里面，
  丢了它板子根本起不来。所以它必须在刷机包里，且**必须来自本板原厂包**。

### 关于板子上的 fwdesc

启动日志里 `rtk_plat_parse_fwdesc:Signature(...) error!` → 说明我们板子的
"厂商固件表"是无效的（我们当初是自己写低区），所以 u-boot 走的是
`boot manual mode` + `bootcmd` 手动引导 —— **这是正常的，不影响使用**。

## 三、四条刷入路线（任选，互不依赖）

### 路线 1：板子还能起来 → 从系统里 dd（最快）

```sh
# 在板子上（或通过 ssh）：
dd if=low-region-38MiB.img of=/dev/mmcblk0 bs=512 count=77824 conv=fsync
dd if=Image-6.6.uimage      of=/dev/mmcblk0p1
dd if=rtd1296-cm360.dtb     of=/mnt/p1/rtd1296-cm360.dtb     # p1 是 ext4，直接放文件
sync
```
> ⚠️ 运行中的内核不会读低区，所以这样写低区是安全的；但**写一半断电 = 砖**，
> 因此务必确认供电，并备好路线 4。

### 路线 2：进 u-boot → TFTP 刷（推荐，不需要拆机）

在主机跑一个 TFTP 服务（把本包内容放进去），然后串口进 u-boot：

```
BPI-W2> setenv serverip <主机IP>; setenv ipaddr <板子IP>; setenv autoload no
BPI-W2> tftpboot 0x02000000 cm360/low-region-38MiB.img
BPI-W2> mmc dev 0
BPI-W2> mmc write 0x02000000 0x0 0x13000         # 低区 38MiB = 77824 扇区
BPI-W2> tftpboot 0x02000000 cm360/p1-256MiB.img
BPI-W2> mmc write 0x02000000 0x13000 0x80000     # p1 256MiB = 524288 扇区
BPI-W2> tftpboot 0x02000000 cm360/p2-7GiB.img.part1
BPI-W2> mmc write 0x02000000 0x93000 0x400000    # p2 从 0x93000 开始，每片 2GiB
```
完整脚本见本目录 `flash-uboot.cmd`（含 U 盘路线与只换内核的路线 C）。

> ★ 这里必须用 **p1/p2 的裸镜像**：这块板的 u-boot 是 BPI-W2 2015.07，
> 有 `ext4load` 但**没有 `ext4write`**，没法把文件写进 ext4 分区，只能整块写扇区。

### 路线 3：进 u-boot → U 盘刷（无网络时）

u-boot 支持 `usb start` + `fatload`：把本包放进 FAT32 U 盘，`fatload usb 0 …` 之后同上 `mmc write`。

### 路线 4：完全砖了 → 串口 ROM Monitor（保底，已验证）

见 `docs/04-recovery.md`。要点：
- ROM Monitor 用**稀疏 Ctrl+Q** 进（约 33 B/s，连续 ≥3 字节；洪流进不去）
- 流程 `h`（YMODEM 传 hwsetting）→ `s 98007058` / `01500000` → `d`（dvrboot，传 bootcode/FSBL）
  → `g` 跳转/烧写；每一步都校验长度和 CRC 再按 `g`
- 串口必须**独占**（手动开的 `screen` 会抢走板子的应答，导致 YMODEM 全废）

## 四、关于 `kylin_usb_mp_tools`（Realtek Kylin USB 量产工具）

- 它是 **Realtek Kylin（RTD129x 家族）的 USB 量产/线刷工具**：
  证据 —— SoC 内部代号就是 Kylin（内核启动打印 `Realtek Kylin RTD1296`），
  而且 ROM bootcode 的编译路径是 `/home2/ericwu/work/Kylin/romcode/src/bin`。
- 它走 **BootROM 的 USB 下载模式**，吃的是**厂商工程/打包产物**，
  典型包 = 各 FW 镜像 + hwsetting + 工程配置。
- **能不能刷我们这份低区**：内容上可以（`vendor-firmware/` 里的 5 个文件**本来就是
  从这块板子的原厂包取出的**），但缺**工程配置**，所以更稳的做法是用
  **路线 1/2/3**（我们自己能控制的 u-boot/dd），把 MP 工具留给"低区彻底没了"的场合。
- 结论：**MP 工具不是必需**；本包的四条路线能覆盖从"系统可用"到"完全变砖"的全部情况。

## 五、还需要板子在线时生成的两份东西

| 文件 | 怎么生成 | 为什么必须 |
|---|---|---|
| `low-region-38MiB.img` | `dd if=/dev/mmcblk0 bs=512 count=77824 of=low-region-38MiB.img`（38 MiB，可入 git） | 这是**本板实测可用**的低区（含我们换上的 BPI-W2 u-boot 与 env）；原厂那 5 个文件只能还原"原厂布局"，不能还原我们这套 |
| `p1-256MiB.img` | `dd if=/dev/mmcblk0p1 of=p1-256MiB.img`（256 MiB，gz 后约 40 MB） | 内核 + DTB。u-boot 不能往 ext4 写文件，所以必须整块镜像 |
| `p2-7GiB.img` | `dd if=/dev/mmcblk0p2 of=p2-7GiB.img`（约 7 GiB，gz 后约 2 GB；刷入前切成 ≤2 GiB 分片） | 系统层。也可改用官方 fnOS 镜像 + `tools/upgrade/` 适配脚本重装 |

两份都在仓库里放了生成脚本占位说明；生成后请连同 `MD5SUMS.txt` 一起入包。
**注意**：`.img` 体积大（低区 38 MiB 可入库；p2 约 2G+，建议放 Gitea/GitHub 的 Release 附件，不要进 git 历史）。

## 六、清单

| 路径 | 状态 |
|---|---|
| `bootchain-vendor/`（5 个原厂文件） | 已入库 → `../boards/rtd1296-cm360/vendor-firmware/` |
| `boot/Image-6.6.uimage`、`boot/rtd1296-cm360.dtb` | 已入库 → `../artifacts/kernel-6.6.54/` |
| `flash-uboot.cmd` | ✔ 本目录 |
| `flash-serial.md` | ✔ 见 `../docs/04-recovery.md` |
| `low-region-38MiB.img` | ⬜ 需板子在线生成 |
| `p2-rootfs.img.gz` | ⬜ 需板子在线生成（或用官方镜像 + 适配脚本） |
| `MD5SUMS.txt` | ⬜ 生成镜像后一并计算 |

---

**风险提示（务必先读）**：低区是全板最容易变砖的地方。
任何低区写入之前，**先 dump 一份并核对 md5**；写入时保证供电稳定；
并且确认串口 ROM Monitor 那条保底路线你已经能走通（`docs/04-recovery.md` 有完整实录）。
