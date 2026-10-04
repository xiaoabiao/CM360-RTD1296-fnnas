# fnOS 官方镜像解剖报告（路线 C 完整结论）

> 解剖对象：`fnnas-official-arm64-image_rockchip_1253.img.xz`
> 来源：`https://github.com/ophub/fnnas/releases/tag/fnnas_base_image`
> 本地缓存：`~/.cache/fnnas/`（镜像 + 解压产物 + 仓库源码）
> 方法：**全程只读**。源码走查 + ext4/btrfs 超级块解析 + `btrfs restore` 用户态导出 + `strings`/符号分析。**未挂载、未刷机、未接触任何硬件。**

---

## 零、一句话结论

**fnOS 对内核版本没有实质门槛。** 全套服务（75 个 fnOS 私有二进制）只依赖标准 glibc（≤2.34）与内核通用能力（btrfs/ext4/overlay/sysfs），**不检查内核版本号**。唯一的版本判断在一个**用户手动调用的可选脚本**里（网卡性能模式切换），不参与启动。
→ **路线 B（6.6.54 强上）的可行性从"赌"变成了"确定"**：把 fnOS 的 rootfs 配我们的 6.6.54 内核，机制上完全成立。

---

## 一、镜像硬数据（实测）

### 1.1 分区表：**GPT**，两分区

```
磁盘容量: 3.68 GiB (7716831 扇区)      ← 官方原版镜像就这么大，不是 ophub 重打的
GPT 表头 @LBA 1, 备份表头 @LBA 7716863
可用扇区 LBA 34 ~ 7716830

p1  BOOT    LBA 368640~890879    180.0~435.0 MiB    255 MiB
p2  rootfs  LBA 923648~7700479   451.0~3760.0 MiB   3309 MiB
```

**注意两点：**
- 这是**官方原版镜像**（只有 2 个分区、无 p3），不是 ophub 重打的版本。
- p1 前 **180 MiB 是空闲空洞**（给 u-boot/trust 用），p1 与 p2 之间还有 16 MiB 空隙。

⚠️ **和 ophub 源码推断的不同**：`renas` 用 MBR 表、`fnnas-install` 提到 p3 数据分区；**官方原版是 GPT + 两分区**。装到 CM360 时要按官方这套走，或按我们自己的布局重构。

### 1.2 p1 = **ext4**（不是 fat32）

```
魔数 0xef53     卷标 'BOOT'     最后挂载点 '/boot'
块大小 1024      inode 尺寸 256      255 MiB
特征 incompat=0x202  compat=0x38  ro=0x6b
构建时间 2026-04-21 10:58
```

→ 和 `renas` 里 `bootfs_type` 可选 fat32/ext4 对应，**rockchip 版用 ext4**。CM360 上可以自由选（u-boot 需支持对应文件系统）。

### 1.3 p2 = **btrfs**

```
魔数 _BHRfS_M     卷标 'rootfs'     3.23 GiB 单设备
sectorsize=4096  nodesize=16384
bytes_used=2.12 GB
compat_ro_flags=3  incompat_flags=881
btrfs check --readonly: no error found ✅（文件系统健康）
```

### 1.4 p1 文件清单（完整）

```
vmlinuz-6.18.18-trim          内核（真文件）
vmlinuz                       -> vmlinuz-6.18.18-trim（符号链接）
initrd.img-6.18.18-trim       initramfs（19.2 MB, zstd 压缩）
uInitrd-6.18.18-trim          u-boot 用的 initrd
uInitrd                       -> uInitrd-6.18.18-trim（符号链接）
config-6.18.18-trim           内核配置（10080 行）
System.map-6.18.18-trim       内核符号表
board.json                    板卡描述（LED 定义等）
dtb/rockchip/rk3566-onethingcloud-oec.dtb
extlinux/extlinux.conf        ★ 实际生效的启动配置
grub/                          GRUB EFI（arm64-efi/、fonts/、grub.cfg、grubenv）
efi/                           空目录
lost+found/
```

**没有 `fnEnv.txt`** —— 那是 ophub 加的东西，官方原版不用。

---

## 二、启动链（实测配置原文）

`extlinux/extlinux.conf` —— **这是完整启动配方**：

```
label fnOS
	kernel /vmlinuz-6.18.18-trim
	fdt /dtb/rockchip/rk3566-onethingcloud-oec.dtb
	append console=ttyS2,1500000 earlycon=uart8250,mmio32,0xfe660000
	       splash=verbose cgroup_enable=cpuset cgroup_memory=1
	       cgroup_enable=memory cma=256M
	       ubootpart=/dev/mmcblk0p1 root=/dev/mmcblk0p2 rw rootwait
```

**逐条解读（对 CM360 极有价值）：**

| 项 | 值 | 对我们的含义 |
|---|---|---|
| `root=` | `/dev/mmcblk0p2` | **设备路径而非 UUID**；且**没有 `rootfstype=`、没有 `rootflags=`** → 内核必须**内置** btrfs（`=y`），且默认压缩设置来自 fstab |
| `fdt` | 平台相对路径 | dtb 放 `/dtb/<platform>/`；**我们换成 `rtd1296-cm360.dtb` 即可** |
| `console` | `ttyS2,1500000` | Rockchip 串口。**CM360 要改 `ttyS0`** |
| `cma=256M` | CMA 保留 | RTD1296 上按需调整 |
| `ubootpart=` | fnOS 私有参数 | 可能需要处理（见 §五） |
| `cgroup_*` | cgroup v1 兼容 | 照抄 |

`grub/grub.cfg` 走的是 `/dev/md127`（RAID 根），**说明这是给"多盘 NAS"准备的备用引导**，单盘场景用 extlinux。**CM360 用我们的 u-boot 直接 `bootm`，两条都可以不理会。**

---

## 三、内核分析（`config-6.18.18-trim` 实测）

### 3.1 编译参数
```
CONFIG_CC_VERSION_TEXT="aarch64-linux-gnu-gcc (Debian 12.2.0-14) 12.2.0"
Linux/arm64 6.18.18-trim
CONFIG_LOCALVERSION=""          ← ★ "-trim" 不在 LOCALVERSION 里
CONFIG_MODVERSIONS is not set   ← ★ 模块不校验符号版本
CONFIG_MODULE_SIG is not set    ← ★ 无签名强制
CONFIG_RANDOMIZE_BASE=y
CONFIG_CMDLINE=""               ← 无内置 cmdline，全靠 extlinux 传
```

**`-trim` 的含义搞清楚了**：`LOCALVERSION` 是空的，所以 `-trim` 是**编译时通过 `make LOCALVERSION=-trim` 之外的机制加进去的**（Debian 打包的 `linux-image` 用 `KERNELRELEASE` 后缀）。这只是个**命名标记**，不影响任何加载逻辑。

### 3.2 文件系统与关键能力（全部内置）
```
CONFIG_BTRFS_FS=y            ← ★ 内置，root 能挂的根因
CONFIG_BTRFS_FS_POSIX_ACL=y  ← ★ FilesACL（fnOS 的核心卖点）
CONFIG_EXT4_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_F2FS_FS=y / CONFIG_XFS_FS=m / CONFIG_SQUASHFS=y / CONFIG_TMPFS=y
CONFIG_ZSTD_COMMON/COMPRESS/DECOMPRESS=y / CONFIG_CRYPTO_ZSTD=y
```

### 3.3 initramfs = **纯标准 Debian initramfs**
解包后：`init` + `conf/` + `etc/` + `scripts/` + `usr/`，**716 个内核模块**（`usr/lib/modules/6.18.18-trim/`）。
- `scripts/local-premount/btrfs` ← btrfs 挂载钩子
- `scripts/local-block/mdadm` ← RAID
- **没有任何 fnOS 私有脚本、没有任何版本校验逻辑**

模块 vermagic 实测：
```
6.18.18-trim SMP preempt mod_unload aarch64
```

---

## 四、fnOS 用户态分析（最关键的部分）

### 4.1 fnOS 核心 = `/usr/trim/`（753 MB 量级）

```
usr/trim/
├── bin/        75 个服务二进制
├── config/     网关/授权配置
├── etc/        版本文件（version = 1.1.31）、密钥
├── lib/        共享库
├── modules/6.18.18-trim/  ← 自带网卡驱动
├── nginx/      Web 服务
├── share/      共享目录
└── www/        Web UI
```

**fnOS 版本：`1.1.31`**

### 4.2 ★ 核心问题：fnOS 检查内核版本吗？

我做了针对性搜索：

| 搜索项 | 结果 |
|---|---|
| 全库 grep `6.18.18` / `6.12.41` 硬编码 | **0 命中** |
| systemd 单元里引用内核版本 | **0 命中** |
| `trim` 二进制依赖库 | 仅 `libc.so.6` / `libstdc++.so.6` / `libcrypto.so.3` / `libm.so.6` / `libgcc_s.so.1` / `libppjson.so` |
| `trim` 的 glibc 要求 | **GLIBC_2.17 / 2.32 / 2.33 / 2.34**（任何现代发行版都满足） |

### 4.3 唯一的版本判断：一个**可选脚本**

`usr/trim/bin/nic_performance_mode.sh`：

```bash
check_kernel_supported() {
    if [[ "${KERNEL_VERSION}" != 6.18* ]]; then
        echo "error: unsupported kernel version ${KERNEL_VERSION}, only 6.18* is supported"
        return "${RET_KERNEL_UNSUPPORTED}"
    fi
}
```

**影响范围（已查清）：**
- 这是**网卡性能模式切换工具**（`nic_performance_mode.sh true/false/status`），用来在"厂商驱动"与"主线驱动"之间切换；
- **没有 systemd 单元引用它**，**没有任何脚本自动调用它**，`usage` 里的示例就是全部调用点；
- 它在 `init_runtime()` 里按 `uname -r` 拼路径 `/usr/trim/modules/${KERNEL_VERSION}`；
- **失败只是让这个可选功能返回错误码，不影响系统启动。**

→ **这是唯一的"内核版本检查"，而且是可以无视的。**

### 4.4 系统信息接口是**只读展示**

`sysinfo_service`：
```cpp
OnGetKernelVersion(...)   // 处理 HTTP 请求
"kernel version '{} {}'"  // 格式化输出到 Web UI
"/sys/kernel/iommu_groups/"
```
调用 `uname()` **只为在 Web 界面显示版本号**。

### 4.5 硬件适配点（我们要处理的）

| 位置 | 内容 | 处理方式 |
|---|---|---|
| `usr/trim/modules/6.18.18-trim/` | Realtek 网卡驱动（r8126/r8168/r8101/r8152/r8125/r8127/r8169）| **路径带内核版本号**；CM360 用板载 GMAC，可删掉或换版本号目录 |
| `etc/modules-load.d/trim-rk_vcodec.conf` | `rga3` `rknpu` `rk_vcodec` | Rockchip 专有，加载失败但不致命（丢硬解） |
| `etc/modules-load.d/trim-zfs.conf` | `zfs` | 可选；失败不影响 |
| `etc/modprobe.d/trim_xe.conf` | Intel Xe GPU | 无关 |
| `triminit` 读 `/sys/class/block/mmcblk%d/device/cid` | **系统盘指纹（授权绑定用）** | ★ 标准 sysfs，我们的 rtkemmc 已提供 |
| `triminit` 写 `/sys/module/zfs/parameters/*` | ZFS 调优 | 无 ZFS 则跳过 |

### 4.6 systemd 服务（68 个单元，15 个 fnOS 私有）

```
trim_init.service   -> /usr/trim/bin/triminit    (oneshot)
trim_main.service   -> /usr/trim/bin/trim        (simple, Restart=always)
trim_nginx / trim_app_center / trim_license / trim_connect / trim_sac
trim_tfa / trim_diskpowerd / trim_file_monitor / trim_http_cgi
trim_raid_check / trim_sharelink / trim_trashbind / trim_upload
```
**全部是标准 systemd，无内核版本门槛、无私有模块依赖。**

---

## 五、对 CM360 移植的结论

### 5.1 之前担心的"fnOS 硬要求 6.12/6.18" —— **不成立**

那个印象来自 `fnnas-update -k 6.18.18` 的用法，但真相是：
- **`fnnas-update` 是 ophub 的工具**，不是 fnOS 的；
- fnOS **本体不检查内核版本**；
- 唯一检查的那个脚本，是可选的网卡调优工具。

### 5.2 路线 B（6.6.54 强上）**机制上完全可行**

**★ 内核配置改动清单（已和 CM360 现有 `.config` 逐项比对，实测）：**

| 配置项 | CM360 当前 | fnOS 要求 | 动作 |
|---|---|---|---|
| `CONFIG_BTRFS_FS` | `m` | **`y`** | **必改** —— 否则无 `rootfstype` 参数时挂不上根 |
| `CONFIG_ZSTD_COMPRESS` | `m` | `y` | **必改**（btrfs 压缩是内置功能，不能是模块） |
| `CONFIG_CRYPTO_ZSTD` | `m` | `y` | **必改**（同上） |
| `CONFIG_OVERLAY_FS` | `m` | 建议 `y` | 建议改（docker/podman 依赖） |
| `CONFIG_BLK_DEV_MD` | `m` | 建议 `y` | 建议改（存储池 RAID） |
| `CONFIG_MD_RAID456` | **未设** | 建议 `y` | 建议改 |
| `CONFIG_BTRFS_FS_POSIX_ACL` | `y` | `y` | ✅ 已满足 |
| `CONFIG_EXT4_FS` | `y` | `y` | ✅ 已满足 |
| `CONFIG_ZSTD_COMMON/DECOMPRESS` | `y` | `y` | ✅ 已满足 |
| `CONFIG_MODVERSIONS` | 未设 | 未设 | ✅ **恰好一致** —— 我们自编的模块能直接装进 fnOS |

其余步骤：
1. **initramfs**：可直接用 fnOS 自带的那个（标准 Debian initramfs），**换掉里面的模块目录**即可；或继续用我们自己的 `initramfs.cpio.gz`（要含 btrfs 支持）。
2. **rootfs**：把 fnOS 的 btrfs 分区搬到 CM360 的 eMMC，或直接取官方镜像的 p2。
3. **引导**：我们的 u-boot 用 `bootm`，而 fnOS 的 extlinux 是给 `booti` + 标准 u-boot 用的。**两条路**：
   - a) 改造 u-boot 脚本：按 `extlinux.conf` 的参数手动拼 `bootm <uImage> <initrd> <fdt>`；
   - b) 把 `vmlinuz-6.6` 封成 uImage（`Image-6.6.uimage`），改 `extlinux.conf` 的 kernel 行指向它，并让 u-boot 用 `bootm` 而非 `booti`。
4. **cmdline 改造**：照抄但改正 —— `console=ttyS2,1500000` → **`ttyS0,115200`**；`fdt=/dtb/rockchip/rk3566-...dtb` → **`rtd1296-cm360.dtb`**；`root=/dev/mmcblk0p2` 保持（我们的 eMMC 也是 mmcblk0）；`cma=256M` 按内存调。
5. **可选清理**：删掉 `usr/trim/modules/6.18.18-trim/`（Realtek 网卡驱动，我们用 GMAC）、`etc/modules-load.d/trim-rk_vcodec.conf`（Rockchip 硬解）。

### 5.3 与路线 A（反向移植驱动到 6.12/6.18）的取舍

既然 fnOS 不挑内核，**路线 A 的"必须性"消失了**。它的价值只剩：
- 能直接用官方内核（含完整模块集、drivers、硬解支持）；
- 便于日后跟官方内核更新。

**但成本差距巨大**：路线 B 是几天（改 config + 换 rootfs + 调引导），路线 A 是数周（mmc 核心跨三个大版本迁移）。**建议先做 B，跑通了再考虑是否值得做 A。**

### 5.4 剩余风险（已查证 / 待实测）

1. ~~`ubootpart=` 参数~~ → **已查清**：rootfs（`grep -rl ubootpart usr/`）与 initramfs 里**均无任何引用**。说明它只被 **u-boot 脚本或内核 cmdline 解析层**读取（例如 u-boot 的 `distro_bootcmd` 用它定位 boot 分区）。**用户态不依赖它，对我们是透明的。**
2. **授权/激活** → **已查清，风险低于预期**：
   - 授权服务 `trim_license`（Go 二进制）连 `https://license.fnnas.com` / `https://member.fnnas.com`（测试环境 `license.test.teiron-inc.cn`）；
   - 硬件指纹读 `/proc/cpuinfo`（不是 eMMC CID，前面看到的 CID 是 `triminit` 用于别的用途）；
   - **`trim_license.service` 只有 `WantedBy=multi-user.target`，没有任何单元 `Requires` 它** → **不阻塞启动**；离线时只是 `Restart=always` 反复重试；
   - fnOS 有免费版，授权只影响增值功能（具体哪些功能需实测）。
3. **`/dev/md127`**：GRUB 配置里根是 RAID 设备 → fnOS 的**存储池**默认可能建 RAID/mdadm。我们 6.6.54 的 `.config` 里 CONFIG_MD/RAID/`MD_RAID456` 需确认为 `y` 或可加载。
4. **存储池格式**：fnOS 的 NAS 存储池用什么（btrfs subvol？mdadm+ext4？）—— 出厂镜像只有系统盘，**需实际建池一次才能确定**。
5. **`trim` 主服务的硬件假设**：75 个二进制里可能对特定 SoC 有探测（Rockchip rga/rknpu 已确认为软依赖），**需实测**。

### 5.5 关于预装模块的正确处理方式

fnOS 自带模块在 `usr/trim/modules/<kernel-version>/`，路径**硬编码内核版本号**：
- 我们的 6.6.54 用不到这套路径（脚本按 `uname -r` 拼 `6.6.54`，目录不存在 → 那个可选脚本报错退出，**无害**）；
- 若想让"网卡性能模式"功能可用，把目录重命名为 `6.6.54` 并放入我们的驱动即可，但**没必要**（我们用板载 GMAC）。

---

## 六、下一步建议

1. **（可在本机做）** 把 `usr/trim/bin/` 里的二进制逐个 `strings | grep -iE "uname|kernel|btrfs|/dev/"`，找 `ubootpart` 的读取点，确认没有隐藏门槛。
2. **（需要板子）** 在内核 tree 上改 config（`BTRFS_FS=y` 等），编出 6.6.54，用**现有 initramfs 流程**尝试挂载 fnOS 的 btrfs rootfs。
3. **（需要板子）** 引导链改造：先做能 `bootm` 起 6.6.54 内核 + 挂 btrfs 的实验，**不急于刷 eMMC**（走 TF 卡或 initramfs 里 pivot_root）。
4. **（阻塞项）** 授权/激活机制 —— 这是唯一可能"跑起来也用不了"的风险，建议尽早查清（或在社区问）。
