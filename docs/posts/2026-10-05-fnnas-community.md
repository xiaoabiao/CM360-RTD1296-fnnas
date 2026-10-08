# 把 2017 年的 Realtek RTD1296 老 NAS 板刷上飞牛 fnOS 1.2.0302：自编译内核 + ZFS 可用 + 两次救砖

> 一句话：一块原厂方案是**群晖 DS218 同款**的 Realtek RTD1296 双盘位老板子，
> 现在跑着 **fnOS 1.2.0302**（内核是自己交叉编译的 Linux 6.6.54），
> ZFS 存储空间可用、面板正常，升级前还顺手把 eMMC 可用空间从 2.1G 折腾到 4.3G。
> 中间踩了两个内核 panic 和一堆坑，都记下来了，仓库在文末。

---

## 一、这块板子是什么

| 项目 | 情况 |
|---|---|
| 主板 | Xiaorui CM360（Realtek **RTD1296**，4×Cortex-A53，2GB RAM） |
| 存储 | 板载 8GB eMMC + 2 个 SATA 盘位（盘位供电靠 GPIO 控制） |
| 原厂方案 | 从原厂固件 DTB 名字 `ds218-cm360-1020.dtb` 可以看出，**是群晖 DS218 同款 Realtek 方案** |
| 启动链 | Mask ROM → bootcode（串口打印 `C1/C2/?/C3h`）→ hwsetting（eMMC `blk#0x100`）→ FSBL → BL31/TEE → u-boot → Linux |

这类"老电视盒/老 NAS"方案的最大特点是：**原厂固件早停更、内核老、DTS 闭源**，
但硬件本身并不弱（千兆网口、SATA、支持 HS200 的 eMMC）。所以我的做法是
**自己编内核 + 自己写设备树 + 把飞牛当用户空间跑上去**。

---

## 二、现在跑成什么样了

| 项目 | 状态 |
|---|---|
| 飞牛系统 | **1.2.0302**（官方 ARM 版整块替换 rootfs 升级上来的，原 1.1.31） |
| 内核 | **Linux 6.6.54** 自编译（`XpressReal/linux` @ `be79582cb`，全内置 + 6 个自研补丁） |
| 面板 | ✔ 正常（80/443 监听，网页登录正常） |
| ZFS | ✔ **可用**（OpenZFS 2.4.1 内核模块，建池/写读/销毁全验证） |
| 存储 | 双盘 RAID1 → LVM → ext4（`/vol1`），创建存储空间不再报错 |
| eMMC | 7G 分区（p1 内核/DTB + p2 btrfs），开启 zstd 压缩后**可用 4.3G** |
| 已知未完成 | 风扇软件调速、SoC 温度读数、SD 卡/USB3、几个与本板无关的服务 |

（不是所有功能都通——下面第六节我把没做成的也摊开讲。）

---

## 三、升级：为什么不能走官方 OTA，以及我们干了什么

飞牛的 ARM 版是**整盘镜像**，而这块板子：

1. 没有外网出口，OTA 拿不到包；
2. 面板是按伪装机型去拉更新的，也拿不到 ARM 通用镜像。

所以我的方案是 **整块替换 rootfs 子卷**：

```
eMMC 布局：
  mmcblk0p1  256M  ext4  内核 + DTB（u-boot 直接读）
  mmcblk0p2  7.0G  btrfs 内核 cmdline: rootflags=subvol=root
                          ├── 子卷 root            ← 当前系统
                          └── 子卷 root-1.1.31     ← 旧系统（回滚用，只改名不删）
```

关键认识是：**内核和 DTB 在 p1、由 u-boot 直接读，rootfs 里的 `/boot` 是空的**，
所以换 rootfs **不会换错内核**，只要把子卷改名成 `root` 就算"切换"，
回滚就是把名字改回去——**完全不用动 eMMC 低区，也不用 `saveenv`**。

### 升级流程（四个脚本，可重复执行）

```sh
board-copy-rootfs.sh     # 把官方镜像里的新 rootfs 增量复制到新子卷
board-adapt-newroot.sh   # 换 rootfs 前适配：fstab / 内核模块元数据 / modules-load.d
board-verify-newroot.sh  # 切换前预检：与镜像逐项比对 + chroot 起壳测试
board-switch-rootfs.sh   # 子卷改名切换 / 一键回滚
```

### 这里踩了三个大坑

**① eMMC 只有 7G，必须开压缩，而且不能用 `du` 判断**

新 rootfs 解压后 5.1G 逻辑内容、92906 个条目，而 p2 只有 7.0G（还躺着 2.5G 旧系统）。
btrfs `compress=zstd` 实测约 3:1。注意两个反直觉点：

- `du` **不反映压缩**（btrfs 的 `st_blocks` 是按未压缩算的），要看 `btrfs filesystem usage`；
- btrfs 的 `compress=` **只在"把文件系统挂上来"那一次生效**，对已挂载过的 fs 再 mount 一次
  会被静默忽略 → 持久生效要写在 **`/` 那一行 fstab** 上（实测 40MB 文本只占 1.4MB）。

**② `rsync` 默认的"大小+时间"比较不可信，差点让我升了个坏系统**

第一次切过去直接内核 panic：

```
/sbin/init: error while loading shared libraries: /lib/aarch64-linux-gnu/libaudit.so.1: invalid ELF header
```

真因是：之前一轮 rsync 被复位打断，**写坏了 14 个库文件，而它们的大小和时间戳与源完全一致**
→ 后续 rsync 全部跳过它们，最终比对还报"0 差异"。

**教训：复制和校验一律要带 `-c`（内容比较）**；预检里再加一条
`chroot <新rootfs> /usr/lib/systemd/systemd --version` 烟雾测试
（只测 `/bin/bash` 会漏——bash 不链接 libaudit，而 PID 1 链接）。

**③ 全内置内核也要装"模块元数据"**

我们的内核是"全内置"构建（没有 `.ko`），而飞牛大量脚本用 `modprobe` 探测模块可用性
（zram、openvswitch……）→ 明明编进内核了，服务照样起不来。
解决：把 `modules.builtin` / `modules.builtin.modinfo` 放进 `/usr/lib/modules/<版本>/`，
并**在板上**跑一次 `depmod`（kmod 只认索引，光拷文本没用）。

---

## 四、ZFS 型存储空间：得自己交叉编译内核模块

飞牛支持 ZFS 存储空间，但它的模块是给自带内核（6.18.x）编的，我们是 6.6.54，
所以得自己编一份 **OpenZFS 2.4.1**（版本要和板端用户态一致）。

四个坑（都写在 `scripts/build-zfs.sh` 里）：

1. `configure` 必须知道自己在交叉编译（`--host=aarch64-linux`），而它编探针程序要**带 libc 的交叉 gcc**，
   不能拿内核的 nolibc 工具链凑；
2. 必须导出 `ARCH` / `CROSS_COMPILE`，否则它编内核测试模块失败，误报
   "This kernel does not include the required loadable module support"（其实 `CONFIG_MODULES=y`）；
3. OpenZFS 2.4.1 的 **aarch64 NEON RAIDZ 内联汇编在新版 GCC 上编不过**
   （`invalid hard register usage between earlyclobber operand and input operand`），
   要摘掉 NEON 实现（功能不受影响，RAIDZ 走通用实现）；
4. 内核树要有 `Module.symvers`（外部模块编译需要），全内置构建可能没有 →
   先 `make modules_prepare` + `make modules` 生成。

装好后 `modprobe zfs` → `zpool create/list/destroy` + 写读全部通过，
面板里的「ZFS 型存储空间」就能用了。

---

## 五、两次内核 panic 与救砖（这段最值得存）

自编译内核最大的风险是**改坏了就起不来**。我遇到两次：

| 次数 | 现象 | 真因 |
|---|---|---|
| 第 1 次 | 升级后 PID 1 加载失败 → `Attempted to kill init` | 上面那个 rsync 写坏的 `libaudit.so.1` |
| 第 2 次 | 加风扇节点后 oops → panic | `rtk_fan` 驱动对缺失 `clocks`/`resets` **不做错误检查**，直接解引用 `ERR_PTR` |

**救回来的办法就两句话**：串口进 u-boot，然后

```
BPI-W2> ext4load mmc 0:1 0x03000000 Image-6.6.uimage.bak
BPI-W2> ext4load mmc 0:1 0x02100000 rtd1296-cm360.dtb.bak
BPI-W2> bootm 0x03000000 - 0x02100000
```

只改内存、不 `saveenv`，一次性启动那对**改动前留好的 `.bak` 内核/DTB**，
系统起来后再把修好的内核写回 p1。

> 🔑 由此得出的硬性习惯：**每次改内核/DTB 前，先在 p1 留一份 `.bak`**。
> 它比任何备份都管用——因为它就在启动路径上。

顺带把 `rtk_fan` 的两个真 bug 修了（都提交在仓库里）：
缺失 clk/reset 不检查导致 panic；以及**只调 `pwm_config()` 从不调 `pwm_enable()`**，
而新内核 PWM 框架对 disabled 通道会直接丢弃新状态 → 写什么转速都没反应。

---

## 六、压轴：让「存储空间」可用（本节是全文最硬的部分）

老 ARM 板跑新系统，最难的往往不是驱动，而是**用户态默认你的内核够新**。
fnOS 1.2.x 的存储栈就是典型：它在 6.6.54 上连踩三个坑，一个比一个隐蔽。

**坑 1：mdadm 4.5 的 `--bitmap=lockless`**（6.7+ 内核特性）
面板点"创建存储空间"，日志里只有一句
`mdadm: Fail to create mdN when using /sys/module/md_mod/parameters/new_array`，
面板只说"无法创建"。更坑的是：**每次失败都会在内核里留下一个 `state=clear` 的同名 md 设备**，
于是后续每次重试都必然 `File exists` —— 越试越坏，重试 10 次全灭。
→ 做法：在 `/usr/trim/bin/mdadm` 上加一层透明兼容层，把 `lockless` 降级为等价的 `internal`，
并清掉残留的空 md 设备。

**坑 2：fnOS 挂存储时带私有挂载选项 `-o trimacl,prjquota`**
这才是"存储建好一半、面板显示未挂载"的真凶：
```
BTRFS error (device dm-0): unrecognized mount option 'trimacl'
ext4: Unknown parameter 'trimacl'
```
`trimacl` 是 fnOS 自己的 ACL v2 扩展（`prjquota` 是 ext4 的习惯写法），
**vanilla 内核不认识就直接拒绝挂载**。
→ 做法：**给内核打补丁**（btrfs 与 ext4 各一处）让它们接受这些选项。
（顺带一提：这**不是我们板子特有的问题** —— 官方支持的 OESPlus 升级到 1.2.0302 后
同样挂载失败，社区里是靠"换一个带补丁的内核"或"每次手工 mount"绕过；
我们让它接受了选项，所以是**开机自动挂载**。）

**坑 3：`trimafs` 文件系统缺失 → 面板不开机自启**
`triminit` 最后会执行 `mount -o trimacl -t trimafs trimafs /fs` ——
那是 fnOS ACL v2 专用的**自定义文件系统类型**。内核没有它 → 初始化链中断 →
`trim_*` 服务开机不启动。现象很迷惑人：**能 ping 通、SSH 也通，就是面板打不开**。
→ 做法：加一个开机兜底单元，在 PostgreSQL 就绪后幂等拉起服务。
（代价：细粒度 ACL 不生效 —— 存储、共享、面板都正常。）

**结果**：`md0` RAID1 → LVM → btrfs 挂到 `/vol2`，930G 可用，面板显示"已挂载/正常"。
三条修复都固化成了脚本与内核补丁，放在仓库里。

> 顺带一个血泪教训：**部署内核必须用 uImage**。
> 我一度把构建出的**裸 `Image`** 拷进 p1，u-boot 的 `bootm` 认不出魔数，
> 板子直接掉进 `BPI-W2>` 提示符 —— 最后是靠 p1 里那对 `.bak` 三条命令救回来的。

## 七、没做成的部分（如实交代）

- **风扇软件调速**：PWM 控制器、引脚复用（debugfs 能看到 `iso_gpio_21 → pwm_0`）、
  通道使能、`fan_ctrl_speed` 写入**全都通了**，但 10%↔100% 循环风扇转速**一点不变**
  → 结论是本板风扇 PWM 线可能不在这个引脚、或本身不受软件控速。
  （另外这风扇**没有测速线**，所以读到的转速恒为 0，不是故障。）
- **SoC 温度读数恒为 0**：传感器驱动 probe 成功，但寄存器布局要跟原厂 4.9 驱动再比对。
  ⚠️ **在读数可信前不要加 `critical` 触发点**，否则万一读出垃圾高温，内核会直接关机。
- **SD 卡 / USB3 / SDIO**：驱动都在内核里，寄存器地址也从原厂 DTB 拿到了，
  只差写设备树节点（SD 还差给驱动补个"GPIO 可选"的容错）。
- 几个与本板无关的飞牛服务仍失败：`nut-*`、`exim4`、`led-set`、`set_gpio-init`。

---

## 八、仓库与备份（全部开源）

**GitHub：<https://github.com/xiaoabiao/CM360-RTD1296-fnnas>**（另有自建 Gitea 镜像）

```
├── boards/rtd1296-cm360/   板级 DTS + 板端脚本 + 原厂固件与反编译 DTS
├── patches/                6 个内核补丁 + ZFS 的 NEON 补丁（每个对应一个实测问题）
├── scripts/                主机侧流水线：拉依赖 → 构建 → 部署 → ZFS → 验证
├── tools/                  brd-ssh 上板助手 / 串口 / ROM Monitor 救砖 / u-boot 交互
├── artifacts/              ★ 可直接落盘的产物：现役内核 uImage、DTB、完整 .config、
│                             ZFS 模块、板子"已知良好状态"快照 + md5 校验清单
├── docs/                  硬件与启动链、内核与 DTS、构建安装、救砖、存储与飞牛、升级、排错
└── evidence/              实测证据：串口日志、两次 panic 与救砖全过程
```

仓库里那份 `artifacts/kernel-6.6.54/` 里的内核/DTB 与**我板子上正在跑的文件逐字节一致**
（md5 可对账），所以别人拿到仓库就能复现一块一样的板子。

---

## 九、给想复刻的人几句实话

1. **只适用于这块板子**（或同方案机型）。DTS 是照原厂 DTB + 实测一点点对的，别乱套。
2. **串口是必需品**（CH340 + 115200），而且必须**独占**——我早期一次 YMODEM 全废，
   真因就是手动开的 `screen` 和脚本抢同一个 tty。
3. **绝对不要碰 eMMC 低区**（`hwsetting` 在 `blk#0x100`，u-boot 环境在 `blk#0x2100`）。
   我之前一次变砖就是把前 1MiB 清了。
4. 改内核/DTB 前留 `.bak`；改完先看串口日志再重启第二遍。
5. 老 ARM 板跑飞牛是可行的，但要接受一个现实：**飞牛部分新特性依赖它自带的新内核**
   （比如 RAID 加速），用自编译内核就用不上。

---

*写于 2026-10-05 · 欢迎同好交流，仓库里每个结论都附了实测证据，踩坑清单在 `docs/07-fnos-upgrade.md`。*
