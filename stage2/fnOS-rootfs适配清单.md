# fnOS rootfs 适配清单（CM360 / RTD1296 / Linux 6.6.54）

> 生成于 2026-10-05。所有结论来自 fnOS 官方 rockchip 镜像（`fnnas-official-arm64-image_rockchip_1253.img.xz`）
> 的**只读解剖**：p2 (btrfs rootfs, 3309 MiB) 的 `btrfs restore` 副本 + p1 (ext4 BOOT, 255 MiB) 的 debugfs 清单。
> **没有任何写操作发生在原镜像上。**

## 0. 总体策略：哪些能在本机做，哪些必须在板上做

本机是普通用户且 `sudo` 需要密码 → **无法挂载 btrfs 做写入**（btrfs 不支持非特权 userns 挂载）。
因此适配动作分两类：

- **本机可做**：分析、准备要投放的文件（内核/dtb/initramfs）、编制清理脚本。
- **必须板上做**（以 root 挂载 eMMC 分区后）：实际删除 / 改写 rootfs 内容。

推荐执行路径见 §8。

---

## 1. 内核模块目录 —— 全部删除

我方 6.6.54 把关键驱动**全部内置**（`.config` 里 2875 个 `=y`：
btrfs / ext4 / overlay / md / ahci_rtk / rtkemmc / gmac5 / netfilter / nfsd / fuse / zram / xfs …）。
并且构建树**从未 `make modules`**（`.ko` 产出数为 0）。
→ **rootfs 里不需要任何外部内核模块**，这几个目录全部可删：

| 路径 | 体积 | 处置 | 理由 |
|---|---|---|---|
| `usr/lib/modules/6.18.18-trim/` | 140 M | **删** | 6.18.18 模块，vermagic 与 6.6.54 不匹配，加载必失败 |
| `usr/lib/modules/6.1.0-39-arm64/` | 295 M | **删** | Debian 原生内核模块，fnOS 并未使用 |
| `usr/src/linux-headers-6.18.18-trim/` | — | **删** | 内核头（供 DKMS 编译），6.6.54 不需要 |
| `usr/trim/modules/6.18.18-trim/` | ~2 M | **删** | fnOS 自带的 Realtek 网卡模块（r8101/8125/8126/8127/8152/8168/8169），**6.18.18 版**；CM360 用内置 `r8169soc`(gmac5) |

> 省出约 **440 MB**，同时消除"模块加载失败"这一整类故障面。

## 2. `etc/modules-load.d/` —— 3 删 1 留

| 文件 | 内容 | 处置 | 理由 |
|---|---|---|---|
| `trim-rk_vcodec.conf` | `rga3` `rknpu` `rk_vcodec` | **删** | Rockchip 专有 VPU/NPU，CM360 无此类硬件 |
| `trim-zfs.conf` | `zfs` | **删** | 我方内核无 ZFS；ZFS 模块在 `6.18.18-trim/updates/trim/zfs/`，随 §1 一起删 |
| `trim-fullconenat-nft.conf` | `nft_fullcone` | **删** | `nft_fullcone.ko` 来自 `updates/trim/fullconenat-nft/`，是 6.18.18 私有模块；删除后 fnOS 的 NAT 退回内核 `nft` 原生 masquerade（我方已内置 `NFT_NAT`/`NFT_MASQ`） |
| `20-zram-generator.conf` | `zram` | **保留** ✅ | 我方已 `ZRAM=y` `ZSMALLOC=y`，这个能真正生效 |

## 3. 设备标识 `etc/device_info/` —— 待评估（建议改写）

| 文件 | 现值 | 读取方 |
|---|---|---|
| `boot_board` | `onethingcloud-oec` | `usr/trim/bin/liveupdate` |
| `boot_brand` | `rockchip` | `liveupdate` |
| `boot_family` | `rk35xx` | `liveupdate` |
| `boot_mode` | `uboot` | — |
| `edition` | `Mainland-PE` | — |
| `platform` | `arm` | — |

- **读取方**：`liveupdate`（在线升级）、`share_service`、`resmon_service`、`avahi_service`（`grep -l device_info` 得到）。
- **处置建议**：改写为 CM360 实际值，例如
  `boot_brand=realtek` / `boot_family=rtd129x` / `boot_board=rtd1296-cm360` / `platform=arm`。
  目的：避免 `liveupdate` 把设备判成"未知/异常机型"而触发误动作。
- **但**：`liveupdate` 内部逻辑是二进制，未反汇编，**无法保证**改完它就不动。→ 见 §7 风险表。

## 4. 内核版本记录 `var/tmp/kernel_version_output`

当前内容：
```
kernel_version='6.18.18-trim'
platform_name='rockchip'
```
- **没有**脚本/配置直接引用该路径（已 `grep -r` 全 rootfs）；疑为安装期产物或供二进制以拼接路径方式读取。
- **处置**：改写为 `kernel_version='6.6.54-gbe79582cba58-dirty'` / `platform_name='realtek'`，或直接删除（观察）。

## 5. 平台专属钩子 —— **无需改动**（重要，别乱动）

这三者都按 `/proc/device-tree/compatible` 的**最后一项**做匹配：

```
etc/kernel/postinst.d/10-sync-dtb              同步 dtb 到 /boot/dtb/<vendor>
etc/kernel/postinst.d/15-update-ukernel-ver     改写 extlinux.conf 的 kernel= 行
etc/initramfs/post-update.d/zz-update-uinitrd   生成 uInitrd
        ↓ 共同逻辑
case "$(strings /proc/device-tree/compatible | tail -n1)" in
   allwinner,*|amlogic,*|rockchip,*)  ...干活... ;;
   *)  exit 0 ;;                 ← CM360 (realtek) 走这里，全部静默跳过
esac
```

- CM360 的 compatible 是 **realtek** → 三个钩子全部 `exit 0`，**不会篡改引导配置**。
- ★ **反面警告**：**不要**为了"让这些钩子工作"而往 DTS 里塞 `rockchip,...` 之类的假 compatible ——
  那会让 `10-sync-dtb` / `15-update-ukernel-ver` 真的去改 `/boot/extlinux/extlinux.conf`，
  把我们的引导配置覆盖成它们的。**保持 realtek，让钩子跳过，才是对的。**

## 6. 引导文件在 **p1**，不在 rootfs 里

- rootfs 里的 `/boot` 是**挂载点（空目录）**；真正的引导内容在 **p1（ext4，卷标 BOOT，255 MiB）**。
- p1 内容（已解剖）：`extlinux/extlinux.conf` + `vmlinuz-6.18.18-trim` + `uInitrd-6.18.18-trim`
  + `dtb/rockchip/rk3566-onethingcloud-oec.dtb`。
- CM360 **不使用 extlinux**（我们的 u-boot 直接 `bootm`）→ p1 的引导内容整体替换为我们自己的三件套：
  `Image-6.6.uimage` + `rtd1296-cm360.dtb` + `initramfs.cpio.gz`。
- ⚠️ 若后续要让 fnOS 的 OTA 机制认得引导，再回头考虑是否保留 extlinux 外壳（当前阶段不需要）。

## 7. 风险点

| 项 | 风险 | 建议处置 |
|---|---|---|
| `apt-daily-upgrade.timer` | apt 定时升级可能装入新内核包并覆盖引导 | **mask**（`systemctl mask apt-daily-upgrade.timer apt-daily-upgrade.service`） |
| `usr/trim/bin/liveupdate` | 读 `device_info` + 内核版本；可能判定设备异常，或触发内核/系统更新 | 先**观察**，如异常则 mask 对应单元 |
| `usr/trim/bin/resize-rootfs.sh` | 首次启动可能对 rootfs 做扩容 | 确认行为；若 eMMC 分区已给足空间则无碍 |
| `usr/trim/bin/nic_performance_mode.sh` | 内含 `check_kernel_supported()`，但**无 systemd 引用、不参与启动** | 忽略 |

## 8. 执行路径建议

| 路径 | 做法 | 评价 |
|---|---|---|
| **A（推荐）** | 把 `p2.btrfs` dd 到 eMMC 的 rootfs 分区 → 用我们的 initramfs 起 shell → 以 root 挂载后执行清理脚本 | 最贴近最终形态，属主/xattr/ACL 零损耗 |
| B | 本机 `btrfs restore` 副本 → 本机清理（属主会丢）→ `tar --owner=0` 打包 → 板上以 root 解包 | 多一道工序，属主要靠 tar 重建 |
| C | 纯板上运维：首次进 fnOS 后手动清理 | 依赖 fnOS 能起来，风险最高 |

## 9. 附：本次内核侧已补齐的能力（对应第 1 层的 `.config`）

`04-build-66.sh` 第二批叠加（依据均为上表里的**真实文件**，非猜测）：

- `NFSD` `NFSD_V4` `NFSD_V3_ACL`（NFSv3 随 `NFSD=y` 自动编入，6.6 无 `NFSD_V3` 符号）
- `NETFILTER_NETLINK` `NF_TABLES*` `NFT_*`（nftables 全套）
- `BRIDGE` `VETH` `MACVLAN` `VLAN_8021Q` `BRIDGE_NETFILTER` `NF_CONNTRACK` `NF_NAT`
  `NETFILTER_XTABLES` `IP_NF_IPTABLES` `IP_NF_{FILTER,NAT,MANGLE}` `IP6_NF_IPTABLES`
  `NETFILTER_XT_TARGET_{MASQUERADE,CHECKSUM,LOG}` `NETFILTER_XT_MARK` `NETFILTER_XT_NAT`
  `NETFILTER_XT_MATCH_{CONNTRACK,ADDRTYPE,IPVS}` `NET_SCH_INGRESS`
- `IPV6` `VXLAN`
- `FUSE_FS` `ZRAM` `ZSMALLOC`
- `XFS_FS` `EXFAT_FS` `NTFS3_FS` `NTFS3_FS_POSIX_ACL` `F2FS_FS` `CIFS`
- `BLK_DEV_DM` `DM_MIRROR` `DM_ZERO`
