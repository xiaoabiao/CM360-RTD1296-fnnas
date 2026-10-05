# 02 · 内核与设备树

## 1. 为什么用这棵树

**基线**：`github.com/XpressReal/linux` @ `be79582cb`（**6.6.54**，Realtek 全家桶 vendor 树）
+ 本仓库的**板级 DTS** + **补丁** + **内核配置叠加**。

选它的理由：这棵树已经把 RTD119x/129x/139x/13xx/16xx 的驱动都挪到 6.6 了
（CCF 时钟、pinctrl、gpio、eMMC/SD/SATA/GMAC 全在），
但 **129x 的板级 DTS 仍是上游极简骨架** —— 也就是「**驱动齐、DTS 空**」。
于是工作量从"移植几万行驱动"压成"写一份 DTS + 少量驱动修正 + 一份配置"。

对比：早期基于 6.12/6.18 主线的评估预估需移植约 **39,037 行**
（其中时钟 1,650 行、eMMC 10,828 行被认为最难）——这条路把它们全省了。

---

## 2. 补丁清单（`patches/`）

每个补丁对应一个**实测问题**，补丁头部都写了症状与证据。

| 补丁 | 解决的问题 |
|---|---|
| `0000-preexisting-driver-patches.patch` | `irq-realtek-mux.c` 的 `.data` 复制 bug；`phy-rtk-sata.c` 的 SATA 供电 |
| `0001-emmc-rtd1296.patch` | eMMC 时钟/驱动早期适配 |
| `0002-emmc-rtkemmc.patch` | ★ 移植 jjm2473 的 `rtkemmc.c`（17 文件）→ eMMC 一次点亮到 HS200 |
| `0003-smp-rtk-spin-table.patch` | ★ **SMP 四核**：从核释放寄存器必须用 `ioremap` + `writel_relaxed` |
| `0004-wdt-restart.patch` | ★ **修 `reboot`**：给 `rtd119x_wdt` 加 `.restart`，把看门狗当整机复位源 |

### 补丁 0003 的坑（很值钱）

ARM 官方 spin-table 规范说 `cpu-release-addr` 指向**内存**，主线按此用
`ioremap_cache()` + `writeq_relaxed()`（8 字节缓存写）。
但 RTD129x 把它接到了 `pinctrl@9801A000` 区间的**握手寄存器**（`0x9801aa44`）——
一次缓存的 8 字节突发写打到设备寄存器 → **总线挂死，且没有任何报错**。

```
症状：日志停在 "Mountpoint-cache hash table entries" 之后，
     本该出现的 "RCU Tasks: Setting shift to 0 ..." 不再打印
修法：ioremap() + writel_relaxed()（32 位），去掉 dcache 维护
```

### 补丁 0004 的坑（reboot 挂死）

`reboot` 后系统关得干净（systemd 打完 "All filesystems unmounted"），
然后**什么都不发生**：串口静默、网络消失。

根因是 arm64 在**没有任何 restart handler** 时走兜底分支：

```c
	do_kernel_restart(cmd);
	mdelay(1000);
	pr_emerg("Reboot failed -- System halted\n");
	while (1);
```

而这块板子**四方皆空**：

- CPU 用 `enable-method = "spin-table"`（**不是 PSCI**），设备树里也没有 `psci` 节点；
- 内核树里没有 Realtek 的 `rtk-rstctrl` / SoC restart 驱动；
- `rtd119x_wdt` 原本没有 `.restart` 回调；
- DTS 里 `&wdt` 还被显式关掉了。

修法是**两层**：补 `.restart`（设 1 s 超时 → 清计数 → 使能 → 不再喂狗，让硬件拉整机复位）
+ 把 `&wdt` 打开。看门狗核心只要 `ops->restart` 非空就注册 restart handler，
且**不检查 watchdog 是否 active**，所以没人打开 `/dev/watchdog` 也照样生效。

---

## 3. 内核配置叠加（`scripts/build-kernel.sh`）

基线是 arm64 defconfig，**下列每一项都是因为实测某个功能失败、反查出来的**。
全部 `=y` 而不是 `=m`：本树只跑 `make Image`，`.ko` 产出为 0；
板上也没有本内核的模块目录，`=m` 等于"编出来但装不上"。

| 分组 | 符号 | 不配的后果（实测症状） |
|---|---|---|
| 平台 | `ARCH_REALTEK` `ARCH_RTD129x` `COMMON_CLK_RTD1295` | DTB 编不出 / 平台驱动不上 |
| | `MMC_RTK_EMMC` `REALTEK_EMMC_LOCKAPI` | eMMC 认不到（旧驱动写的 pad 寄存器在 1296 上是 `deadbeef`） |
| | `MMC_RTK_SDMMC` `AHCI_RTK` `PHY_RTK_SATA` `R8169SOC` | SD / SATA / 网口不工作 |
| 存储 | `MD_RAID0` `MD_RAID1` `MD_RAID10` `MD_LINEAR` | `md: personality for level 1 is not loaded!` → **fnOS 建存储空间必失败** |
| | `DM_SNAPSHOT` `DM_THIN_PROVISIONING` `DM_RAID` `DM_CRYPT` `DM_CACHE` `DM_WRITECACHE` | LVM 精简置备/快照/加密空间不可用 |
| | `QFMT_V1` `QFMT_V2` | fnOS 的 `makefs_ext4_with_quota` 建卷失败 |
| | `CRYPTO_XTS` `CRYPTO_CBC` `CRYPTO_ESSIV` `CRYPTO_USER_API_*` | dm-crypt / LUKS |
| 网络 | `OPENVSWITCH`(+`_GRE`/`_VXLAN`/`_GENEVE`) | `modprobe openvswitch` not found → `ovs-vswitchd`/`ovsdb-server` 全挂 |
| 内存 | `ZRAM` `CRYPTO_LZ4` `CRYPTO_LZ4HC` `CRYPTO_LZO` `ZRAM_DEF_COMP_LZ4` | zram0 只提供 `lzo lzo-rle zstd`，fnOS 设 lz4 报 `Invalid argument` → **无 swap** |
| 文件系统 | `BTRFS_FS` `XFS_FS` `EXFAT_FS` `NTFS3_FS` `F2FS_FS` `CIFS` `NFSD` | 存储池/共享不可用 |
| 容器 | `OVERLAY_FS` `BRIDGE` `VETH` `VXLAN` `NF_TABLES` `NFT_*` `IP_NF_*` | docker / OVS 网络起不来 |

> ★ 符号名要先在 Kconfig 里确认：写错的名字 `scripts/config` 会**静默失败**
> （例如 NTFS 正确符号是 `NTFS3_FS`，不是 `NTFS3`）。
> `build-kernel.sh` 末尾会逐项复核并打印，别只看"我加了配置"。

---

## 4. 板级设备树（`boards/rtd1296-cm360/rtd1296-cm360.dts`）

DTS 里几乎每个节点都写了"为什么这么写"的注释和证据来源。几条要点：

### 原厂 DTB 是"圣旨"

原厂固件 DTB 的反编译文本留档在 `evidence/stage0/original-dtb.dts.txt`。
两个反复救命的经验：

1. **原厂 DTB 里"缺失的属性"是语义，不是遗漏** —— 它表示"用驱动默认值"，
   而默认值往往就是这台机器的正确硬件模式。
   实例：网口 gmac 原厂**没给** `output-mode` → 驱动默认内嵌 GPHY。
   我们"好心补上" `output-mode = <2>`（外置 PHY）→ 链路能协商、TX 能出、**RX 恒 0**。
2. **原厂双段 `reg` 的段序可能与主线驱动相反** ——
   写反的后果是寄存器全打空，读回全是 `0xdeadbeef`（Realtek SoC 上"地址不存在"的信号）。

### SATA 两个盘位是**分别**供电的

`hd_power_on_seq=2`、`ihd_num=2`（原厂 bootargs）说明两盘独立上电。
DTS 里每个 `sata-port@N` 都要给 `sata-gpios`，否则**盘不转**：

```dts
sata-port@0 { sata-gpios = <&misc_gpio 56 GPIO_ACTIVE_HIGH>; };
sata-port@1 { sata-gpios = <&misc_gpio 19 GPIO_ACTIVE_HIGH>; };
```

引脚号有个坑：**官方 Realtek 参考 dtsi 与这块板子的原厂 DTB 不一致** ——
官方说 port1 用 `iso_gpio 15`，原厂说用 `misc_gpio 19`。
判据：port0 两边都给 `misc_gpio 56`，而它**实测可用**；
既然原厂值在 port0 被证实正确，port1 就信原厂。
（原厂 DTB 里 `blink-gpios` 才用 `rtk_iso_gpio`，那是盘位指示灯，不是供电。）

### 看门狗地址

`&wdt` 在 `&iso`（`syscon@7000`，父总线 `rbus` 基址 `0x98000000`）下 `reg = <0x680>`，
⇒ 实际 `0x98007680`，与原厂 DTB 一致；运行时 sysfs 也印证：

```
/sys/class/watchdog/watchdog0 -> .../98000000.bus/98007000.syscon/98007680.watchdog/...
```

---

## <a name="为什么需要-modmeta"></a>5. 为什么换内核后必须跑 `deploy-modmeta.sh`

内核是**全内置**构建（`.ko` 产出为 0），所以板子上原本**没有 `/lib/modules/<版本>/`**。
于是 `modprobe <内置模块>` 一律失败：

```
modprobe: FATAL: Module zram not found in directory /lib/modules/6.6.54-...
```

而 fnOS 的多个脚本正是**靠 `modprobe` 的返回值判断模块可用性**的
（zramswap、ovs 等）。结果就是：模块明明已经编进内核，服务照样起不来。

`scripts/deploy-modmeta.sh` 把 `modules.builtin` / `modules.builtin.modinfo`
拷到板上，并在**板上**跑 `depmod`。

> ★ **实测教训**：只拷文本文件**不够** —— kmod 只认 `.bin` 索引，
> 必须在板上跑一次 `depmod` 才会生成 `modules.builtin.bin` 等。
> 只拷文本时 `modprobe` 依旧失败，白查一轮。

---

## 6. 构建产物

| 文件 | 说明 |
|---|---|
| `build/Image-6.6` | 裸 arm64 内核（u-boot 用 legacy uImage 壳，见 `make-uimage.py`） |
| `build/rtd1296-cm360.dtb` | 板级设备树 |
| `build/Image-6.6.uimage` | 套好壳的 uImage（load/entry = `0x03000000`） |

只改 DTS 时用 `DTB_ONLY=1 ./scripts/build-kernel.sh`（几秒钟）。
改 `.config` 相关（即 `build-kernel.sh` 里的配置叠加）时**不要**用这个开关。
