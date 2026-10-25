# 在 CM360（RTD1296）上"直接跑 UEFI ARM 安装镜像"——安装器侧事实报告

- 评估对象：CM360 / Realtek RTD1296（4×A53，2 GiB，8 GiB eMMC，2×SATA，内嵌 GMAC，UART0）
- 问题：用户想"像 PC 一样插 U 盘 → UEFI 安装器 → 装完能用"
- 评估时间：2026-10-22
- 方法：直接抓官方发布站/源码（Debian cdimage、deb.debian.org、sources.debian.org、Ubuntu cdimage、u-boot/grub 源码、torvalds/linux master、armbian/build、openwrt/openwrt）+ 本仓库已有实测报告
- 标记约定：**[已验证]** = 本轮抓到一手文件/清单/源码原文；**[推断]** = 由已验证事实外推，未在本板实测；**[未验证]** = 明确还没证据
- 本报告只写"安装器/引导器侧"事实，不改动仓库其它文件

---

## 0. 结论（先看这 6 条）

1. **Debian arm64 netinst 的 UEFI 引导链（已验证）**：`EFI/BOOT/BOOTAA64.EFI`（GRUB arm64-efi）→ 在全部设备上 `search --file --set=root /.disk/info` → `source ($root)/boot/grub/arm64-efi/grub.cfg` → `linux /install.a64/vmlinuz --- quiet` + `initrd /install.a64/initrd.gz`（图形版用 `/install.a64/gtk/initrd.gz`）。
2. **"不经过 UEFI、直接用 U-Boot `booti` 引导 ISO 里的 kernel+initrd" 是 Debian 官方支持的路径族**（arm64 安装器同时发布 `netboot/`、`hd-media/`、`u-boot/` 三套非 UEFI 形态）。但注意：**ISO 内的 `/install.a64/initrd.gz` 是 cdrom 变体**（自带 `cdrom-detect`），想"内核从 U 盘起、ISO 从盘上找"应当改用 **`hd-media/initrd.gz`**（其 udeb 集合含 isofs/ata/sata/mmc/usb-storage/iso-scan 一族）。**[hd-media 的部分为已验证；booti 实跑未验证]**
3. **Ubuntu arm64 是另一套东西（已验证结构）**：live-server ISO 走 `EFI/boot/bootaa64.efi` → `/boot/grub/grub.cfg` → `linux /casper/vmlinuz` + `initrd /casper/initrd`，随后进 live squashfs（`/casper/ubuntu-server-minimal*.squashfs` + `install-sources.yaml`），安装器是 live 环境里的 subiquity。没有 Debian 那种 `hd-media`"内核+initrd 脱离 ISO 也能装"的等价物。
4. **结论性判断：通用 arm64 安装器（Debian 6.12 / Ubuntu 主线内核）在 RTD1296 上"能进界面"都很难，"装完并启动"基本不可能。** 原因不是 UEFI，而是**驱动**：2026 年主线 `arch/arm64/boot/dts/realtek/` 仍只有 UART/GIC/timer/watchdog/reset/GPIO；`drivers/mmc/host/` 无 RTD eMMC；`drivers/net/ethernet/realtek/` 整族 `depends on PCI`（SoC 内嵌 GMAC 无驱动）；`drivers/ata/` 只有 `snps,dwc-ahci`（SATA 理论可蹭，但缺 DT 节点/时钟/PHY）；USB dwc3 胶水+PHY 在主线但无 DTS 节点。→ 安装器会停在"找不到磁盘 / 找不到网卡"。**[主线侧已验证；"卡住"为推断，但证据强度高]**
5. **UEFI 侧的前置条件本身是可解的、但与本板现状有差距**：U-Boot 的 EFI 支持只是 Kconfig 开关（`CONFIG_CMD_BOOTEFI` + `CONFIG_EFI_LOADER`，块设备映射还要 `CONFIG_BLK`+`CONFIG_PARTITIONS`）；GRUB arm64-efi 的 `linux` 命令**要求内核是带 EFI stub 的 PE/COFF Image**（源码原文：`plain image kernel not supported - rebuild with CONFIG_(U)EFI_STUB enabled`）。**新发现**：Armbian 2026 已有 `realtek-rtd129x` 家族，给同 SoC 的 BPI-W2 打出了 **mainline U-Boot v2026.10-rc5 + 17 个补丁，`ARCH_RTD129X select ARM64`**（64 位 U-Boot，EL3 起），eMMC/SD/SMP 都补齐了——但该 defconfig **没开 EFI_LOADER / BOOTEFI / NET**，需要自己改配置重编。**[Armbian 事实已验证；开 EFI 后可跑 GRUB 为推断]**
6. **最短路径**：**不要走"UEFI 安装器"这条路。** 要"装完能用"，走 ①`rootfs 镜像 + dd/解包`（本仓库已有实测链路，天级）或 ②`自定义内核 + 官方 d-i hd-media initrd + booti`（"真安装器体验"，周级）。"能启动安装器界面"与"能装完并启动"必须分开看（见 §0.2）。

### 0.1 一句话回答用户

> 在这块板子上，"插 U 盘跑 UEFI 安装器"卡住的不是 UEFI，而是**安装器内核里没有 eMMC / SATA / 网卡驱动**；即使 UEFI 固件完美、GRUB 菜单完美，Debian/Ubuntu 的通用 arm64 安装器也会在"选择安装介质/磁盘"这一步走不下去。想装 Debian 系，必须换成"自带 RTD1296 驱动的内核"去跑安装器（自定义内核 d-i），或者干脆走 rootfs 直刷。

### 0.2 "能启动安装器界面" ≠ "能装完并启动"

| 阶段 | 通用安装器 + 完美 UEFI（假设） | 自定义内核 + d-i initrd（推荐路径） | 说明 |
|---|---|---|---|
| 进入 GRUB 菜单 | 🟡 取决于能否有 arm64 UEFI 固件（当前没有，见 §2.4） | — （U-Boot `booti` 直起内核） | GRUB 还需要串口输入；U-Boot 的 EFI 不一定提供 `SIMPLE_TEXT_INPUT` [未验证] |
| 起 Linux 内核、进安装器 UI（串口） | 🟡 需 DTB 与主线内核匹配，否则只剩单核/无中断扩展 | ✅ 用 vendor 6.6 或 Armbian 6.18 内核 + 本板 DTB，串口 console 已实测可用 | 本板 UART0 115200 无输出问题（见 `docs/01-hardware-and-boot.md`） |
| 找到安装介质（ISO/网络） | 🟡 UEFI 下 GRUB 能读 ISO；但 ISO9660 由固件读还是内核读要分清 | ✅ hd-media initrd 会扫块设备找 ISO | ISO 需整盘 dd 或有 ESP/FAT 分区承载 [推断] |
| 识别磁盘（eMMC/SATA） | ❌ 通用内核无驱动 | ✅ 自定义内核有 | **硬阻塞点** |
| 识别网卡（apt 源） | ❌ 通用内核无 SoC GMAC 驱动 | ✅ 有（vendor/Armbian） | 硬阻塞点（除非离线源） |
| 装引导器（arm64 d-i 默认装 grub-efi-arm64 到 ESP） | ❌ 假定 UEFI 引导，与本板 U-Boot `booti` 链不符 | 🟡 需跳过/替代（`nobootloader` udeb 在 ISO 内，但能否用 preseed 跳过未验证） | 本板实际启动链是 p1 上的 `Image+DTB` + `booti`（`docs/08-flashing-approaches.md`） |
| 首次启动 | ❌ | 🟡 需手工保证 p1/p2 布局、fstab、console | 本仓库 dd 链已解决，d-i 装完则要接上 |

### 0.3 硬阻塞清单（不解决就"装不完"）

1. **主线内核没有 RTD1296 的 eMMC / SATA(完整) / 内嵌 GMAC 驱动**（§3，已验证到 2026 主线 master）。
2. **Debian/Ubuntu 安装器内核不可"插驱动"**：d-i 用的是自己编译的 `kernel-image-*-arm64-di`（trixie 为 **6.12.107+deb13-arm64-di**，见 §1.4 证据），模块集里只有主线驱动，没有 RTD129x 可加载模块。
3. **arm64 安装器默认假定 UEFI 引导器**（`grub-efi-arm64` + `partman-efi`），而本板实际是 U-Boot `booti` + p1 分区；`bootefi` 在本板当前 U-Boot（2015.07 魔改）里不存在。
4. **本板 DTB 只存在于 vendor 树**（`rtd1296-cm360.dtb`），主线 DTS 里没有 CM360 板级节点（只有 DS418/BPI-W4 之类极简板）。

---

## 1. Debian arm64 官方安装镜像结构

### 1.1 当前 stable / trixie 的 netinst

**[已验证]** 发布物：

- `debian-13.7.0-arm64-netinst.iso`，701 MB，2026-09-12
  <https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/>
- ISO 内文件清单（Debian 会发布 `.list.gz`，但**只列 pool 里的包**，不含引导文件；Ubuntu 那边反而列全量，见 §1.3）
  <https://cdimage.debian.org/debian-cd/current/arm64/list-cd/debian-13.7.0-arm64-netinst.list.gz>

**[已验证] ISO 内的引导文件路径与 GRUB 配置**（一手证据：`debian-cd` 的 arm64 制盘脚本 + d-i 发布的 `debian-cd_info.tar.gz` 实包）：

- 脚本 `debian-cd/tools/boot/trixie/boot-arm64`，关键行：
  - `INSTALLDIR="install.a64"`
  - `cp -lf cdrom/vmlinuz $CDDIR/$INSTALLDIR/`、`cp -lf cdrom/initrd.gz $CDDIR/$INSTALLDIR/`、`extra_image gtk/initrd.gz .../gtk/initrd.gz`
  - EFI 部分：`mcopy ... boot$N/grub/efi.img '::efi/*' $CDDIR/EFI`，`mv boot$N/grub/* $CDDIR/boot/grub/`，`mkfs.msdos ... $CDDIR/boot/grub/efi.img`，`xorriso -e boot/grub/efi.img -no-emul-boot` 且 `-append_partition 2 0xef`
  - `sed -i "s|%install%|$INSTALLDIR|g" $CDDIR/boot/grub/grub.cfg`
  <https://sources.debian.org/src/debian-cd/3.2.3/tools/boot/trixie/boot-arm64/>
- 实际 `grub.cfg`（来自 <https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/cdrom/debian-cd_info.tar.gz>，本轮已下载解包）：

  ```grub
  menuentry 'Install' {
      linux    /%install%/vmlinuz --- quiet
      initrd   /%install%/initrd.gz
  }
  menuentry 'Graphical install' {
      linux    /%install%/vmlinuz --- quiet
      initrd   /%install%/gtk/initrd.gz
  }
  ...（另有 expert / rescue / automated / speech synthesis 等子菜单）
  ```

  经 `%install% → install.a64` 替换后，最终路径是 **`/install.a64/vmlinuz` + `/install.a64/initrd.gz`**（图形版 initrd 为 `/install.a64/gtk/initrd.gz`）。
- EFI 启动介质内容（同一 tar 内的 `grub/efi.img`，FAT 根目录 8.3 项实测为 `BOOTAA64EFI`、`GRUBAA64EFI`）→ 即 **`EFI/BOOT/BOOTAA64.EFI`**（加 `GRUBAA64.EFI` 备用名）。
- `efi.img` 内嵌 GRUB 前缀配置（二进制原文）：

  ```
  search --file --set=root /.disk/info
  set prefix=($root)/boot/grub
  source $prefix/arm64-efi/grub.cfg
  ```

  → GRUB 靠 `/.disk/info` 反查 ISO 根，再 source `/boot/grub/arm64-efi/grub.cfg`（即上面那份菜单）。

**完整 UEFI 引导链（已验证）**：

```
UEFI 固件（BlockIo 读 U 盘/光驱；SimpleFileSystem 读 FAT ESP）
  └─ EFI/BOOT/BOOTAA64.EFI            (GRUB arm64-efi, PE/COFF)
       └─ search --file /.disk/info → root = ISO 根
       └─ source /boot/grub/arm64-efi/grub.cfg
            └─ linux  /install.a64/vmlinuz --- quiet
            └─ initrd /install.a64/initrd.gz
                 └─ GRUB 走 EFI stub 交接（要求内核有 EFI stub，见 §2.2）
                      └─ debian-installer（串口/图形前端）
```

### 1.2 不经 UEFI：Debian 官方给了三条非 UEFI 路径

**[已验证]** arm64 安装器镜像目录里同时存在（<https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/>）：

| 目录 | 内容（实测文件） | 用途 |
|---|---|---|
| `cdrom/` | `vmlinuz`(36M)、`initrd.gz`(25M)、`debian-cd_info.tar.gz`、`gtk/` | 做 netinst/bd ISO；initrd 内含 `cdrom-detect`，**默认找你 dd 过的 ISO 介质** |
| `hd-media/` | `vmlinuz`、`initrd.gz`(27M)、`hd-media.tar.gz`、`SD-card-images/`、`tiny/` | **"内核从 U 盘/硬盘起，ISO 从盘上找"**；MANIFEST 原文：`hd-media/initrd.gz -- Initrd for use on USB memory sticks` |
| `netboot/` | `netboot.tar.gz`、`mini.iso`、`debian-installer/`（PXE 目录） | TFTP/PXE（U-Boot 也能用） |
| `u-boot/` | 14 个板级 SD 镜像：`a64-olinuxino`、`pine64_plus`、`rock64-rk3328`、`rockpro64-rk3399`、`firefly-rk3399` … | 给"有 U-Boot 的板子"的即用镜像——**没有 RTD1296/CM360** |

**`hd-media` 的 udeb 集合（已验证，说明它就是"从盘上找 ISO"的变体）**

<https://sources.debian.org/src/debian-installer/20260628/build/pkg-lists/hd-media/arm64.cfg>：

```
fat-modules / ext4-modules / isofs-modules / udf-modules
ata-modules / sata-modules / mmc-modules / usb-modules / usb-storage-modules
scsi-core-modules / scsi-modules
cdrom-core-modules      # "So it can find cdroms ..."
md-modules / lvm2-udeb  # "We want to be able to find the iso in a LVM logical volume too"
```

→ **`iso-scan` + `usb-storage` + `isofs` 都在**，所以"booti 起内核 → 在 U 盘上找到 netinst ISO → 继续安装"在机制上成立。**[机制已验证；本板实跑未验证]**

**Debian 官方文档明确写了 U-Boot 非 UEFI 启动方式**（arm64 安装手册 §5.1.4.1 TFTP-booting in U-Boot）：

- `tftpboot` 分别加载 kernel / dtb / initrd；
- uImage 用 `bootm ${kernel} ${ramdisk} ${fdt}`，原生 Image 用 `bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}`；
- 我们的 U-Boot 只有 `booti`，语义等价：`booti <kernel> <initrd>:<size> <fdt>`，且文档同一节明确"先加载 kernel 和 dtb、最后加载 initrd，因为 `filesize` 记录的是最后一个文件"。
  <https://www.debian.org/releases/trixie/arm64/ch05s01.en.html>

> 注意：`booti` 需要内核与 DTB 分别给地址。ISO 里的 `install.a64/vmlinuz` 是 **Debian 自己的 6.12 内核**（见 §1.4），它拿到我们的 vendor DTB 后能否起得来，见 §3 结论（能起、但外设全无）。

### 1.3 Ubuntu server arm64 对比（26.04.1 LTS）

**[已验证]** 发布物与 ISO 内文件清单（Ubuntu 官方直接发布 `.list`）：

- <https://cdimage.ubuntu.com/releases/26.04.1/release/> → `ubuntu-26.04.1-live-server-arm64.iso`（2.9 GB）
- 文件清单 <https://cdimage.ubuntu.com/releases/26.04.1/release/ubuntu-26.04.1-live-server-arm64.list>，实测关键行：

```
/EFI/boot/bootaa64.efi
/EFI/boot/grubaa64.efi
/EFI/boot/mmaa64.efi
/boot/grub/grub.cfg
/casper/vmlinuz
/casper/initrd
/casper/install-sources.yaml
/casper/ubuntu-server-minimal.squashfs
/casper/ubuntu-server-minimal.installer.squashfs
...
```

**引导链（结构已验证，菜单内容未逐字节取）**：UEFI → `EFI/boot/bootaa64.efi`（GRUB）→ `/boot/grub/grub.cfg` → `linux /casper/vmlinuz` + `initrd /casper/initrd` → casper 挂 squashfs → live 环境里的 subiquity 安装器。

**与 Debian 的关键差别**：

| 维度 | Debian trixie netinst | Ubuntu 26.04 live-server |
|---|---|---|
| 安装器形态 | debian-installer（udeb/anna，串口可用） | live squashfs + subiquity（假定有本地 console/网络） |
| 内核/initrd 路径 | `/install.a64/vmlinuz`、`/install.a64/initrd.gz` | `/casper/vmlinuz`、`/casper/initrd` |
| 非 UEFI 启动支持 | 官方发布 `hd-media`/`netboot`/`u-boot` 三套 | 只有 `netboot` tarball（163 MB）；**没有 hd-media 等价物** |
| `booti` 直起可行性 | 官方路径族内（hd-media） | 需自己传 casper 参数，且 casper 依赖 ISO9660 上的 `/casper` 目录与 squashfs —— 更脆 **[推断]** |
| 用户诉求适配度 | 较好（串口安装器、preseed） | 较差（需要 live 环境可交互、通常要网络） |

### 1.4 顺带确认：安装器内核版本与 d-i 组件

**[已验证]** netinst 池内 udeb 名（从 `.list` 解包得到）：

```
kernel-image 相关：mmc-modules-6.12.107+deb13-arm64-di、sata-modules-6.12.107+deb13-arm64-di、
nic-modules-6.12.107+deb13-arm64-di、usb-storage-modules-6.12.107+deb13-arm64-di、
ata-modules-...、isofs/udf/fat/ext4 等（均为 6.12.107+deb13-arm64-di）
grub-installer_1.212_arm64.udeb、partman-efi_110_arm64.udeb、nobootloader_1.73_all.udeb、
flash-kernel-installer_3.109_arm64.udeb、efi-reader、efibootmgr
```

→ **Debian 安装器用的就是 Debian 的 6.12 主线内核**（`6.12.107+deb13`），模块集只覆盖主线已有驱动；**没有 RTD129x 的 d-i 模块可加载**（主线根本没有这些驱动，§3）。`nobootloader` udeb 存在，是"跳过装引导器"的官方钩子（能否在本板用 preseed 顺畅跳过：**[未验证]**）。

---

## 2. UEFI 引导 ARM 安装镜像的真实前置条件

### 2.1 固件侧（U-Boot 视角，官方文档原文）

**[已验证]** <https://raw.githubusercontent.com/u-boot/u-boot/master/doc/develop/uefi/uefi.rst>：

- 打开 UEFI：`CONFIG_CMD_BOOTEFI=y` + `CONFIG_EFI_LOADER=y`（"UEFI support can be activated for ARM and x86"）
- 块设备映射（`EFI_BLOCK_IO_PROTOCOL` → 分区 → `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`）需要：`CONFIG_BLK=y` + `CONFIG_PARTITIONS=y`
- 启动 UEFI 应用：`bootefi <image addr> [fdt addr]`；文档给的例子正是"从 mmc 分区 `load` 出 `efi/debian/grubaa64.efi`，再 `bootefi ${kernel_addr_r} ${fdt_addr_r}`"
- 设计目标对标 **EBBR 2.1.0**
- 运行期变量：U-Boot 文档明确"cannot be set at runtime"，要用 `efidebug` 预置；配合本板 `CONFIG_ENV_IS_NOWHERE`（Armbian defconfig 实见，§2.4）→ **EFI 变量不持久**

**要装得起 arm64 Linux 安装器，固件必须提供的服务（对照 UEFI/EBBR 清单）**：

| 服务 | 用途 | 本板可得性 |
|---|---|---|
| `EFI_LOADED_IMAGE` / `LoadImage`+`StartImage`（PE/COFF arm64） | 加载 `BOOTAA64.EFI` | U-Boot EFI_LOADER 提供 **[推断，配置后可]** |
| `EFI_BLOCK_IO_PROTOCOL` | 读 U 盘/ISO 上追加的 ESP 分区 | 需要 U-Boot 有 USB storage/MMC + `CONFIG_BLK` |
| `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`（FAT） | GRUB 读 `\EFI\boot\grubaa64.efi`、菜单、kernel、initrd | 需要 FAT 驱动 + BLK/PARTITIONS |
| `EFI_DEVICE_PATH` + `ConnectController` | 枚举设备、定位文件 | 同上 |
| `EFI_SIMPLE_TEXT_OUTPUT` | GRUB 菜单在串口出字 | U-Boot EFI 提供 console 输出 **[推断]** |
| `EFI_SIMPLE_TEXT_INPUT` / `_EX` | GRUB 菜单按键、`e` 编辑 cmdline | **风险点：纯串口板子未必有输入协议** **[未验证]** |
| `GetVariable`/`SetVariable`（NV） | GRUB 记 `Boot####`/`BootOrder`、`grub-installer` 注册启动项 | U-Boot 只有 `efidebug` 预置/易失 **[已验证文档]** |
| `GetMemoryMap` + `ExitBootServices` | 交棒给内核 | U-Boot EFI 提供 |
| DT 传递（EFI config table / `EFI_DT_FIXUP`） | arm64 内核必须拿到 DTB | U-Boot `bootefi <img> <fdt>` 显式给 |

### 2.2 GRUB arm64-efi 侧：**内核必须有 EFI stub**

**[已验证]** GRUB 的 arm64 `linux` 命令走的是通用 EFI loader（`grub-core/loader/efi/linux.c`），源码里读 Image 头并强制检查 PE 头：

```c
if ((lh->code0 & 0xffff) != GRUB_PE32_MAGIC)
  return grub_error (GRUB_ERR_NOT_IMPLEMENTED_YET,
    N_("plain image kernel not supported - rebuild with CONFIG_(U)EFI_STUB enabled"));
```

- 即：**GRUB 只接受 PE/COFF 格式、带 EFI stub 的内核 Image**；vendor 树里如果 `CONFIG_EFI` 关了，那它编出来的 `Image` 不能由 GRUB 加载（但 `booti` 照样能起）。要上 GRUB/UEFI，内核必须 `CONFIG_EFI=y`（arm64 上即 EFI stub + PE 头）。
- initrd 交接：GRUB 用 `LoadFile2` 协议（`CONFIG_EFI_LOAD_FILE2_INITRD` 一侧）或更新 `chosen/linux,initrd-*`；DT 由 GRUB 的 `grub_fdt_load`/`grub_fdt_install` 装配后随 EFI 配置表交给内核。
- 因此"UEFI 安装"这条链上，**GRUB 只是二传手**，真正的门槛在内核：①有 EFI stub；②能驱动这块板的控制器。

### 2.3 "装到本地磁盘"这一步对安装器内核的要求

d-i 的装盘流程需要的**内核能力**（与 UEFI 无关，纯驱动）：

1. **块设备**：能枚举 eMMC（`/dev/mmcblk*`）或 SATA（`/dev/sd*`）→ 需要对应 host 控制器驱动 + 时钟/复位/pinctrl/PHY。
2. **分区与文件系统**：GPT/MBR 解析、ext4/btrfs（rootfs）、FAT（ESP/p1）→ d-i 有 udeb，但底层块设备没有就无从谈起。
3. **安装介质读取**：ISO9660（`isofs`）或网络（GMAC/USB 网卡）。
4. **引导器安装**：arm64 d-i 默认 `grub-installer` → 写 ESP + `efibootmgr` 注册；本板实际用 U-Boot `booti`，所以这一步要么跳过（`nobootloader`），要么改成写 p1 的 `Image+DTB`。
5. **串口 console**：`console=ttyS0,115200` 或从 DT 的 `stdout-path` 继承；Debian 手册 §5.1.1 专门讲"检测不到时手改 cmdline 为 `console=ttyAMA0,115200n8`"。**[已验证文档]**；本板等价 `console=ttyS0,115200`（本仓库实测，见 `docs/01-hardware-and-boot.md`）。

### 2.4 本板现状：U-Boot 2015.07 没有 `bootefi`，但 2026 年有 64 位 U-Boot 移植

**[已验证，本仓库]**

- 现役 U-Boot：2015.07（BPI-W2 魔改），`help` 全表实测**无 `bootefi`**；有 `booti`/`fatload`/`usb start`/`tftp`/`mmc read`（`docs/reports/driver-inventory.md` §0 勘误补充二）。
- SPI flash 剩余仅 68 KB~772 KB 且已判定"必须不写 SPI"→ **刷大体积新 U-Boot 要动 eMMC 引导区，不是改 SPI**（`docs/reports/driver-inventory.md`）。

**[已验证，Armbian 上游]** 存在同 SoC 的现代 U-Boot 移植：

- 家族配置 <https://raw.githubusercontent.com/armbian/build/main/config/sources/families/realtek-rtd129x.conf>：
  - `BOOTBRANCH="tag:v2026.10-rc5"`、`BOOTPATCHDIR="v2026.10-rtd129x"`
  - `UBOOT_TARGET_MAP=";;u-boot.bin rtd129x-emmc-boot.bin"`，用 `packages/blobs/rtd129x/mkbootarea.py` 拼 eMMC boot area
  - "No ATF: U-Boot and Linux start at EL3/EL2 from the Realtek loader"
  - 内核走 mainline（current=6.18，edge=7.3）+ 29 个 RTD129x 补丁（见 §4.3）
- 板级 <https://raw.githubusercontent.com/armbian/build/main/config/boards/bananapiw2.csc>：`BOARDFAMILY="realtek-rtd129x"`、`BOOT_FDT_FILE="realtek/rtd1296-bananapi-w2.dtb"`、`KERNEL_TARGET="current,edge"`、`eth0=98016000.ethernet`、`eth1=98060000.ethernet`
- U-Boot 补丁先看**关键一条**：<https://raw.githubusercontent.com/armbian/build/main/patch/u-boot/v2026.10-rtd129x/0001-arm-add-Realtek-RTD129x-and-Banana-Pi-BPI-W2-minimal.patch>

  ```
  config ARCH_RTD129X
      bool "Realtek RTD1295/RTD1296 SoCs"
      select ARM64          ← U-Boot 本体是 64 位 aarch64
  ```

  但 `configs/bananapi-w2_defconfig` 只有 20 行：`CONFIG_ARM=y`、`ARCH_RTD129X`、`DEBUG_UART`、`CONFIG_ENV_IS_NOWHERE=y`、`# CONFIG_NET is not set`，**没有 `CONFIG_CMD_BOOTEFI` / `CONFIG_EFI_LOADER` / `CONFIG_BLK` / `CONFIG_PARTITIONS`**；后续补丁只加了 MMC（SD + eMMC）与 `CONFIG_EFI_PARTITION`（GPT，和 EFI 固件无关）。
  → **"这块板能跑 arm64 EFI 应用"是配置级工作（改 defconfig 重编 + 刷 eMMC boot area），不是驱动级移植；但当前 Armbian 产物并不含 UEFI 能力。** **[配置可行为推断；实机未验证]**

---

## 3. 主线内核能不能驱动这块板？（逐项核实，2026-10 master）

方法：直接抓 `torvalds/linux` master 的 Makefile/Kconfig/DTS 原文（本轮 2026-10-22 抓取）。

### 3.1 逐项结论

| 子系统 | 主线状态 | 证据（原文/路径） | 对"通用安装器"的影响 |
|---|---|---|---|
| 平台 Kconfig | ✅ `ARCH_REALTEK` 存在 | `arch/arm64/Kconfig.platforms` | 内核能编、能起 |
| 板级 DTS | ❌ 只有 DS418 极简板 | `arch/arm64/boot/dts/realtek/` 列表仅 `rtd1293/1295/1296/1395/1501/1619/1861/1920` + `rtd1296-ds418.dts`；`rtd1296.dtsi` 只有 `cpus`/`timer`/`arm_pmu` | 无 CM360 节点 |
| CPU bring-up | ❌ 无 `enable-method`（无 psci/spin-table） | `rtd129x.dtsi` 全文 grep 无 `enable-method|psci|spin-table`；`rtd1296.dtsi` 只列 4 个 cpu 节点 | 只能单核跑（本仓库主线 6.17 实测亦为单核） |
| 时钟 CCF | ❌ 只有 27 MHz 固定晶振 | `rtd129x.dtsi`: `osc27M: osc { compatible="fixed-clock" }`；`drivers/clk/Makefile` grep `realtek` **无命中** | 所有外设缺时钟父节点 |
| 中断 | 🟡 GIC-400 有；**外设 IRQ 汇聚 mux 没有** | `rtd129x.dtsi` 有 `arm,gic-400`；vendor 用 `Realtek,rtk-irq-mux`（本仓库实测） | 网卡/SATA/eMMC 中断不通 |
| eMMC / SD | ❌ **无任何 rtk/rtd 宿主驱动** | `drivers/mmc/host/Makefile` 仅 `rtsx_pci_sdmmc`/`rtsx_usb_sdmmc`（PCI/USB 读卡器）+ `sdhci-of-dwcmshc`（Synopsys MSHC，非本 SoC） | **装不了盘（硬阻塞）** |
| SATA | 🟡 通用 `snps,dwc-ahci` 可蹭 | `drivers/ata/Makefile`: `obj-$(CONFIG_AHCI_DWC) += ahci_dwc.o`；`ahci_dwc.c` of_match = `snps,dwc-ahci`、`snps,spear-ahci` | 理论可 probe（需 DT 节点 + clocks/resets + SATA PHY；vendor 侧还有 `phy-rtk-sata` 私有 PHY）→ **未验证** |
| 内嵌 GMAC（RTL8168 兼容 SoC MAC） | ❌ 整族 `depends on PCI` | `drivers/net/ethernet/realtek/Kconfig`: `config NET_VENDOR_REALTEK ... depends on PCI`；`Makefile` 只有 `r8169`/`rtase`（都是 PCI/PCIe） | **装不了网卡（硬阻塞，除非 USB 网卡）** |
| USB3 dwc3 胶水 | 🟡 驱动在主线 | `drivers/usb/dwc3/Makefile`: `obj-$(CONFIG_USB_DWC3_RTK) += dwc3-rtk.o`；`dwc3-rtk.c` of_match=`realtek,rtd-dwc3` | 缺 DTS 节点、时钟、PHY 上电时序 |
| USB2/3 PHY | 🟡 驱动在主线 | `drivers/phy/realtek/Makefile`: `phy-rtk-usb2.o`/`phy-rtk-usb3.o`；`phy-rtk-usb3.c` of_match 含 **`realtek,rtd1295-usb3phy`** | 同上，缺 DTS/时钟 |
| PCIe | ❌ 无 host 控制器驱动 | `drivers/pci/controller/` 无 realtek | 不影响（原生 SATA 够用） |
| 看门狗/复位/GPIO | ✅/🟡 | `realtek,rtd1295-watchdog`、`snps,dw-low-reset`、`gpio-rtd.c` 支持 `realtek,rtd1295-{misc,iso}-gpio` | 与安装无关 |

本仓库既有实测报告与上述主线抓取一致，可交叉引用：
`docs/reports/driver-inventory.md` §2 总表、`docs/reports/peripherals-sata-gmac-emmc.md` §4/§9（主线 6.17/7.3 实测 eMMC/SATA/GMAC "一个都认不出"）。

### 3.2 结论：会卡在哪

**会。** 通用安装器（Debian d-i 6.12 / Ubuntu 26.04 内核）在这块板上：

- **第一阶段**：起内核 → 串口可能正常（UART/GIC/timer 都在主线），但只有单核、外设 IRQ mux 缺失；
- **第二阶段**：`cdrom-detect`/`iso-scan` 找安装介质 —— 若介质是 USB 盘且内核能枚举 USB（缺 PHY/时钟节点，**大概率枚举不到**）；
- **第三阶段**：`partman` 列磁盘 → **0 块盘**（eMMC 无驱动、SATA 无 DT/PHY、USB 无节点）→ 安装器只能落到"检测不到磁盘设备"的分支，装不下去；
- **即使**用某种方式给它一块盘（例如只接 SATA 且 `snps,dwc-ahci` 侥幸 probe），**装 base system 需要网络**（netinst 无网络即死），GMAC 无驱动 → 只能靠 USB 网卡，而 USB 也没起来。

→ **"即使 UEFI 完美工作，通用安装器也会卡在找不到磁盘/网卡"这个判断成立。** 且这不是"再等一版主线"的问题：主线对 RTD129x 的支持自 2019 至今只到"串口 shell"的量级（本仓库对照实测 4.9/6.17/7.3 三个版本）。

---

## 4. 替代方案对比

### 4.1 方案 a：自定义内核的 Debian 安装器（推荐度 ★★★☆）

两种做法：

**a-1（低成本，推荐先试）：官方 d-i initrd + 我们自己的内核（不走 UEFI）**

- 内核/DTB：用 vendor 6.6.54 的 `Image` + `rtd1296-cm360.dtb`（本仓库已有），或 Armbian 6.18 内核（§4.3，更现代）。
- initrd：直接取 d-i 的 **`hd-media/initrd.gz`**（27 MB，含 iso-scan/usb-storage/isofs/ata/sata/mmc 模块）。
- 介质：U 盘 p1(FAT) 放 `Image`、`cm360.dtb`、`initrd.gz`、`debian-13.7.0-arm64-netinst.iso`；U-Boot：`fatload` 三个文件 → `booti <k> <initrd>:<size> <dtb>`，`bootargs` 加 `console=ttyS0,115200`。
- d-i 起来后会用**我们的内核**做 `hw-detect`/`partman`，能看到 eMMC/SATA/GMAC → 能分区、能装 base system、能联网（若 GMAC 驱动在）。
- **剩余坑**：①d-i 的模块 udeb 与 6.6/6.18 内核版本不匹配（我们全内置驱动，通常不需要模块，但要确认 d-i 不强依赖某些模块）；②装引导器步骤要跳过（`nobootloader`/preseed），改由 dd 链写 p1；③内核 config 要满足 d-i 依赖（devtmpfs、tmpfs、ext4、isofs、loop、autofs4、efivarfs、GPT 等）——**这一条是主要调试量**。
- 工作量估计：**1–2 周**（含一次成功安装 + 首次启动）。
- 风险：中。风险点集中在"d-i 对我们的内核的隐含假设"和"跳过 grub-installer 后首启"。

**a-2（高成本，不推荐）：重编 d-i（kernel-image udeb + 重建 initrd）**

- 需要 `debian-installer` 构建环境（`build/config/arm64.cfg` + 自定义 kernel udeb + pkg-lists），把 vendor 内核打成 `kernel-image-6.6.54-*-di` udeb 再生成 initrd/ISO。
- 工作量：**数周**，且每次内核改动都要重来；收益与 a-1 几乎相同（a-1 只是"不换内核包"，实际效果一样）。
- 结论：**技术上可行，但没有必要**——a-1 用"外部内核 + 官方 initrd"就能达到同样效果。

### 4.2 方案 b：rootfs 镜像 + dd / 解包式安装（推荐度 ★★★★★，本仓库已实测）

- 本仓库已有完整链路（**已实测**）：`firmware/dd-flash.sh` 三层刷写（低区引导链 + p1 内核分区 + p2 rootfs），README 中标注 dd 套装"✅ 实测"。
  见 [08-flashing-approaches.md](../08-flashing-approaches.md)（路线 A：`dd` 直刷，2026-10-09 真实刷机）、[README.md](../../../README.md) §3。
- 代价：**1–3 天**（拿到目标发行版 rootfs 后重打包），无新驱动工作。
- 优点：完全复用已验证的启动链（U-Boot `booti` + p1 `Image+DTB` + p2 rootfs）。
- 缺点：不是"安装器体验"；换发行版要自己做 rootfs（Debian arm64 rootfs 可从 debootstrap/docker export 拿）。

### 4.3 方案 c：换一个"支持 RTD1296"的发行版（推荐度 ★★★，有新发现）

| 候选 | 结论 | 证据 |
|---|---|---|
| **Armbian（realtek-rtd129x 家族）** | 🟢 **存在**，但是 **community（.csc）级、绑定 BPI-W2 板**；内核 mainline 6.18/7.3 + 29 个 RTD129x 补丁（eMMC/SATA PHY/GMAC/irqchip/SMP/CLK/USB/Thermal/HDMI-in…），U-Boot 为 mainline v2026.10-rc5 + 17 补丁 | 家族：<https://raw.githubusercontent.com/armbian/build/main/config/sources/families/realtek-rtd129x.conf>；板：<https://raw.githubusercontent.com/armbian/build/main/config/boards/bananapiw2.csc>；内核补丁目录：<https://api.github.com/repos/armbian/build/contents/patch/kernel/archive/realtek-rtd129x-6.18>（29 个：`0007-mmc-host-add-the-Realtek-RTD129x-SD-host`、`0008-net-realtek-add-the-RTD129x-embedded-gigabit-MAC`、`0014-mmc-host-add-the-Realtek-RTD129x-eMMC-host`、`0020-phy-realtek-add-the-RTD1295-SATA-PHY`、`0022-dt-bindings-ata-ahci-platform-add-realtek-rtd1295-ahci`、`0005/0006 SMP` 等） |
| OpenWrt | ❌ 无 RTD129x target；`realtek` target 是 **MIPS 交换机 SoC**（rtl838x/839x/930x/931x/960x） | <https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/realtek/Makefile> |
| Debian/Ubuntu 官方 | ❌ 无 RTD1296 板级支持（Debian 的 `u-boot/` SD 镜像也不含它） | §1.2、§3 |
| ophub/fnnas（飞牛重打包） | ❌ 不支持 Realtek，无 RTD1296 镜像（但可拿其 rootfs + 自定义内核） | 本仓库 [ophub-fnnas-assessment.md](../ophub-fnnas-assessment.md) |

**Armbian 这条发现的意义（重要）**：
1. 它证明 **"2026 年可以有一个带 RTD1296 全套驱动的 mainline 6.18 内核"**——方案 a-1 的内核可以不必用老 vendor 6.6，而用这套补丁树（可维护、跟主线走）。
2. 它证明 **"这块 SoC 可以有 64 位 modern U-Boot"**——UEFI 的前提（§2.4）从"不可能"变成"配置工作量"。
3. 但它**只针对 BPI-W2**（`rtd1296-bananapi-w2.dtb`）；CM360 需要新写板级 DTS（或至少改 DTB 的 mmc/sata/eth/led/phy 节点），这是 **1–2 周**的移植工作量，且属社区支持级别（.csc），不保证稳定。

### 4.4 方案 d：x86 上交叉/QEMU 准备 rootfs，再上板（推荐度 ★★★★）

- 做法：x86 上 `debootstrap --arch=arm64`（或 `mmdebstrap` + qemu-user binfmt）产出 Debian/Ubuntu rootfs；安装内核用 vendor 6.6（或 Armbian 6.18）；然后用方案 b 的 dd 链写 eMMC。
- 代价：**1–3 天**（与 b 同量级，本质是 b 的"内容制作"步骤）。
- 优点：不需要板子在环、可反复迭代；缺点：`/etc/fstab`、`console`、`initramfs`（本板全内置可不要 initramfs）、首次启动的 `machine-id`/ssh host key 之类要处理（本仓库已有经验，见 `docs/05-storage-and-fnos.md`、`docs/07-fnos-upgrade.md`）。

### 4.5 方案对比表

| 方案 | 可行性 | 工作量（估） | 主要风险 | 是否"像 PC 一样装" |
|---|---|---|---|---|
| **原诉求：UEFI 直装 Debian/Ubuntu ISO** | ❌ 装不完 | —（前置就要 1–2 月做 U-Boot EFI，且装不了） | 无磁盘/网卡驱动；GRUB 需 EFI stub 内核；串口输入协议 | ✅ 体验最像，但**结果不可用** |
| a-1 自定义内核 + 官方 hd-media initrd（`booti`） | 🟡 高（机制齐备，未实跑） | 1–2 周 | d-i 对内核的隐含假设；引导器步骤要跳过；内核 config 适配 | 🟡 接近（串口安装器） |
| a-2 重编 d-i（自定义 kernel udeb） | 🟡 可行但没必要 | 数周 | 维护成本高 | 🟡 接近 |
| **b rootfs + dd/解包** | ✅ 已实测 | 1–3 天 | 非安装器体验；rootfs 内容要自己做 | ❌ |
| c 换发行版（Armbian rtd129x） | 🟡 有新发现但仅 BPI-W2 | 移植 CM360 DTS 1–2 周 | .csc 社区级；CM360 无现成 DTS；U-Boot 要另刷 | ❌（Armbian 也是镜像直刷） |
| d x86 交叉准备 rootfs | ✅ 高 | 1–3 天 | 首次启动细节（fstab/console/网络） | ❌ |
| **组合推荐：d（做 rootfs）+ b（dd 刷入）** | ✅ | **1–3 天** | 极小（复用已有实测链） | ❌ |
| **组合：a-1（安装器）+ b（首启引导）** | 🟡 | 1–2 周 | 中 | 🟡 |

---

## 5. 最短路径建议

### 5.1 如果用户坚持"插 U 盘 → UEFI 安装器 → 装完能用"

**最少要做的事（按依赖顺序）**：

1. **改出一个 64 位、带 EFI_LOADER 的 U-Boot**（Armbian `realtek-rtd129x` + `CONFIG_CMD_BOOTEFI=y`、`CONFIG_EFI_LOADER=y`、`CONFIG_BLK=y`、`CONFIG_PARTITIONS=y`，以及 USB/MMC 块设备驱动），按 `mkbootarea.py` 拼 eMMC boot area 刷入。→ **周级，且动引导链（有变砖风险，SPI 不可写、只能靠 eMMC 引导区/ROM 模式救）**。
2. **解决串口输入**：确认 U-Boot EFI 是否提供 `SIMPLE_TEXT_INPUT`（不确定），否则 GRUB 菜单无法交互（只能靠 0 秒超时自动引导）。→ **未验证，可能是隐性阻塞**。
3. **补 DTB**：U-Boot 传给 GRUB/内核的 DTB 必须是能用的（U-Boot control DT 或显式 `bootefi <img> <fdt>`），且内核侧 `CONFIG_EFI=y`（EFI stub）。
4. **换一个有 RTD1296 驱动的内核去跑安装器**（即方案 a-1 的内核工作）—— 因为 Debian 的安装器内核永远不会有这些驱动。
5. **跳过/替换 d-i 的引导器安装**，把首启交给 `booti` + p1（本仓库 dd 链）。

**硬阻塞（无论怎么努力都绕不开）**：
- ❌ **通用安装器内核里没有 eMMC/SATA/GMAC 驱动**（主线现状，且短期不会变）；
- ❌ **本板 DTB 在主线不存在**（CM360 板级节点只有 vendor 树有）；
- ❌ **没有 arm64 UEFI 固件可用**（现役 U-Boot 无 `bootefi`；Armbian 的 U-Boot 有 64 位基础但未开 EFI）；
- ⚠️ **SPI 不能写**，任何 U-Boot 升级都只能走 eMMC 引导区，失败即需要 ROM 模式救砖。

### 5.2 推荐路线（按用户目标分）

| 用户真实目标 | 推荐 | 预计时间 |
|---|---|---|
| "我就要一块能用的 Debian 系 NAS" | **方案 d + b**：x86 上 debootstrap 出 arm64 rootfs → 用本仓库 dd 链刷 eMMC | **1–3 天** |
| "我要 Debian 官方安装器那种体验（分区/装包/装引导器）" | **方案 a-1**：vendor(或 Armbian)内核 + d-i `hd-media/initrd.gz` + `booti` + preseed 跳过引导器 | **1–2 周** |
| "我要最新内核（6.18/7.3）" | 先做 **方案 c 的前置**：把 CM360 板级 DTS 移植进 Armbian rtd129x 补丁树，再回到 d/b | **1–2 周**（额外） |
| "我就是要 UEFI 安装器" | 不建议。若一定要做，先做 1（U-Boot EFI）+ 4（自定义内核），总计 **1–2 月**，且最终仍需跳过 d-i 引导器步骤 | 1–2 月 |

### 5.3 "能启动"与"能装完"的最终判断

- **能启动安装器界面**：在 a-1 路线上**高概率能做到**（内核+DTB+initrd 都是我们选的，串口 console 已验证）；在原 UEFI 路线上**低概率**（缺固件、缺输入协议、DTB 仍要自己解决）。
- **能装完并启动**：只有 a-1（配 preseed + 引导器替换）或 b/d 路线；**原 UEFI 路线不可能**，因为安装器内核没有磁盘/网卡驱动。

---

## 6. 未验证项 / 待实测清单（TODO）

1. **`booti` + d-i `hd-media/initrd.gz` 在 CM360 上实跑**：能否进入安装器 UI、能否 `iso-scan` 找到 U 盘上的 netinst ISO。→ 这是方案 a-1 的第一个验证点，**建议优先做**（成本：一次 U 盘启动，不需要刷机）。
2. **d-i 对内核 config 的最低要求清单**：逐项确认（devtmpfs/tmpfs/ext4/isofs/loop/autofs4/efivarfs/GPT/OVERLAY 等）；以及"全内置无模块"时 d-i 的 `hw-detect` 是否报错。
3. **跳过 `grub-installer` 的正确姿势**：`nobootloader` udeb 在 ISO 内（已验证存在），但 preseed 参数（`grub-installer/skip` 还是 `partman-efi` 相关）需实测。
4. **Armbian rtd129x 内核在 CM360 上起不起得来**：需要新写 `rtd1296-cm360.dts`（或从 vendor DTB 反推），并确认 eMMC/SATA/GMAC 节点与 vendor 硬件一致。
5. **Armbian U-Boot 开 EFI_LOADER 后能否跑 GRUB arm64-efi**：包括串口输入协议是否可用、`efidebug` 变量、内存映射。**未验证，属高风险实验**。
6. **vendor 6.6.54 内核是否 `CONFIG_EFI=y`**：决定它能否被 GRUB 加载（`booti` 不需要，GRUB 需要）。
7. **Ubuntu live-server 在 `booti` 下的可行性**：casper 参数（`casper/findiso`、`iso-scan`）是否 arm64 可用；目前判断"更脆"。

---

## 附录 A：证据复现命令（本报告用到的抓取）

```bash
# 1) Debian arm64 netinst 发布物
curl -sSL https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/            # 见 debian-13.7.0-arm64-netinst.iso

# 2) ISO 内引导配置（12 MB，含 grub.cfg 与 efi.img）
curl -sSL -o cd_info.tar.gz \
  https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/cdrom/debian-cd_info.tar.gz
tar tzf cd_info.tar.gz | head            # grub/grub.cfg, grub/efi.img, grub/arm64-efi/*
tar xzOf cd_info.tar.gz ./grub/grub.cfg  # 可见 linux /%install%/vmlinuz --- quiet

# 3) efi.img 内的 EFI 程序名与 GRUB 前缀配置（FAT 8.3 + 纯文本搜串）
python - <<'EOF'
import tarfile,os
d=tarfile.open(os.path.expandvars(r"%TEMP%\cd_info.tar.gz")).extractfile('./grub/efi.img').read()
print(d.find(b'BOOTAA64'), d.find(b'GRUBAA64'))     # 8.3 目录项：BOOTAA64EFI / GRUBAA64EFI
i=d.find(b'search --file'); print(d[i:i+120])       # search --file --set=root /.disk/info ...
EOF

# 4) 安装器镜像目录 / hd-media udeb 集合
curl -sSL https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/
curl -sSL https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/MANIFEST | grep hd-media

# 5) ISO 内的包清单（含 d-i 内核版本 6.12.107+deb13-arm64-di）
curl -sSL https://cdimage.debian.org/debian-cd/current/arm64/list-cd/debian-13.7.0-arm64-netinst.list.gz \
  | python -c "import gzip,sys;print(gzip.decompress(sys.stdin.buffer.read()).decode())"

# 6) Ubuntu ISO 文件清单
curl -sSL https://cdimage.ubuntu.com/releases/26.04.1/release/ubuntu-26.04.1-live-server-arm64.list \
  | grep -E '^/(EFI|casper|boot/grub)'

# 7) 主线驱动覆盖
curl -sSL https://raw.githubusercontent.com/torvalds/linux/master/drivers/mmc/host/Makefile
curl -sSL https://raw.githubusercontent.com/torvalds/linux/master/drivers/ata/ahci_dwc.c | grep -A4 of_device_id
curl -sSL https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/Kconfig | head -10
curl -sSL https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/Makefile
curl -sSL https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/realtek/rtd129x.dtsi

# 8) Armbian rtd129x
curl -sSL https://raw.githubusercontent.com/armbian/build/main/config/sources/families/realtek-rtd129x.conf
curl -sSL https://raw.githubusercontent.com/armbian/build/main/config/boards/bananapiw2.csc
curl -sSL "https://api.github.com/repos/armbian/build/contents/patch/kernel/archive/realtek-rtd129x-6.18"
curl -sSL "https://api.github.com/repos/armbian/build/contents/patch/u-boot/v2026.10-rtd129x"
```

## 附录 B：外部引用汇总

| 主题 | URL |
|---|---|
| Debian arm64 netinst 发布目录（trixie 13.7.0，701M） | <https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/> |
| Debian ISO 包清单 | <https://cdimage.debian.org/debian-cd/current/arm64/list-cd/debian-13.7.0-arm64-netinst.list.gz> |
| debian-cd arm64 制盘脚本（`INSTALLDIR=install.a64`、EFI efi.img、`%install%` 替换） | <https://sources.debian.org/src/debian-cd/3.2.3/tools/boot/trixie/boot-arm64/> |
| d-i arm64 介质配置包（grub.cfg / efi.img 来源） | <https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/cdrom/debian-cd_info.tar.gz> |
| d-i arm64 镜像总目录（cdrom/hd-media/netboot/u-boot） | <https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/> |
| 安装器文件说明（hd-media="USB memory sticks"） | <https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/MANIFEST> |
| d-i hd-media arm64 udeb 集合（iso-scan/usb-storage/isofs…） | <https://sources.debian.org/src/debian-installer/20260628/build/pkg-lists/hd-media/arm64.cfg> |
| Debian 安装手册 arm64 §5.1（U-Boot/TFTP 非 UEFI 启动） | <https://www.debian.org/releases/trixie/arm64/ch05s01.en.html> |
| Debian 安装手册 arm64 §4.3（dd 到 U 盘 / hybrid ISO） | <https://www.debian.org/releases/trixie/arm64/ch04s03.en.html> |
| Ubuntu 26.04.1 发布页 | <https://cdimage.ubuntu.com/releases/26.04.1/release/> |
| Ubuntu arm64 live-server ISO 文件清单（EFI/casper 路径） | <https://cdimage.ubuntu.com/releases/26.04.1/release/ubuntu-26.04.1-live-server-arm64.list> |
| U-Boot UEFI 支持文档（EFI_LOADER/BLK/PARTITIONS、EBBR） | <https://raw.githubusercontent.com/u-boot/u-boot/master/doc/develop/uefi/uefi.rst> |
| GRUB arm64 EFI loader（要求 EFI stub 的 PE/COFF 内核） | <https://raw.githubusercontent.com/rhboot/grub2/master/grub-core/loader/efi/linux.c> |
| 主线 arm64 realtek DTS 目录 | <https://api.github.com/repos/torvalds/linux/contents/arch/arm64/boot/dts/realtek> |
| 主线 `rtd1296-ds418.dts`（唯一"可用"板） | <https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/realtek/rtd1296-ds418.dts> |
| 主线 `rtd129x.dtsi`（无 psci/mmc/sata/eth 节点） | <https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/realtek/rtd129x.dtsi> |
| 主线 mmc host Makefile（无 rtk/rtd） | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/mmc/host/Makefile> |
| 主线 `ahci_dwc.c`（`snps,dwc-ahci`） | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/ata/ahci_dwc.c> |
| 主线 realtek 网卡 Kconfig（`depends on PCI`） | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/ethernet/realtek/Kconfig> |
| 主线 dwc3（`dwc3-rtk`）/ USB PHY（`rtd1295-usb3phy`） | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/usb/dwc3/Makefile> |
| Armbian realtek-rtd129x 家族（mainline U-Boot 2026.10 + 内核 6.18/7.3） | <https://raw.githubusercontent.com/armbian/build/main/config/sources/families/realtek-rtd129x.conf> |
| Armbian BPI-W2 板级（RTD1296 同 SoC 参考） | <https://raw.githubusercontent.com/armbian/build/main/config/boards/bananapiw2.csc> |
| Armbian rtd129x 内核补丁（29 个，含 eMMC/GMAC/SATA-PHY/SMP） | <https://api.github.com/repos/armbian/build/contents/patch/kernel/archive/realtek-rtd129x-6.18> |
| Armbian rtd129x U-Boot 补丁（17 个，`ARCH_RTD129X select ARM64`） | <https://api.github.com/repos/armbian/build/contents/patch/u-boot/v2026.10-rtd129x> |
| OpenWrt realtek target（仅 MIPS 交换机 SoC） | <https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/realtek/Makefile> |

## 附录 C：本仓库内部交叉引用

| 内容 | 文件 |
|---|---|
| U-Boot 实测命令表（有 `booti`、无 `bootefi`）、SPI 不可写、内存加载地址 | [driver-inventory.md](../driver-inventory.md) |
| 主线 6.17/7.3 实测"eMMC/SATA/GMAC 一个都认不出"、三条证据 | [peripherals-sata-gmac-emmc.md](../peripherals-sata-gmac-emmc.md) |
| dd 三层刷写链路（已实测）、TFTP 路线、U 盘路线 | [08-flashing-approaches.md](../08-flashing-approaches.md) |
| 硬件与启动链（串口 115200、分区布局） | [01-hardware-and-boot.md](../01-hardware-and-boot.md) |
| 内核/DTB 构建 | [02-kernel-and-dts.md](../02-kernel-and-dts.md) |
| fnOS rootfs 与存储栈 | [05-storage-and-fnos.md](../05-storage-and-fnos.md) |
| ophub/fnnas 不适配 Realtek | [ophub-fnnas-assessment.md](../ophub-fnnas-assessment.md) |
