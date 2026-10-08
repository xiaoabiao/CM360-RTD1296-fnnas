# 变更记录

本项目按"阶段"推进，每个阶段都有对应的实测证据留在 `evidence/`。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [未发布]

### 新增

- **电脑端一键刷机工具** `firmware/flash-from-pc.py` + 内置只读 TFTP `tools/tftp-server.py`：
  一条命令完成「备份低区 → 起 TFTP → 重启并自动抢进 u-boot → 逐层 `tftp`+`mmc write`
  → `run bootcmd` → SSH 复核」，支持 `--layers/--rehearse/--dry-run/--backup-only`。
- **端到端演练通过**（2026-10-09）：以 `--layers low --rehearse` 在实机上跑完整流程
  （写入内容与板上现有内容逐字节相同，故为零风险演练）：
  自动进 u-boot ✔ → TFTP 载入 ✔ → mmc write ✔ → 启动 ✔ → 系统起来 ✔ →
  **板上低区 md5 与镜像完全一致** ✔。
- 记录本板 u-boot 的**命令差异**（照网上教程会踩）：网络加载是 `tftp`（无 `tftpboot`）、
  没有 `boot`（用 `run bootcmd`）、没有 `crc32`/`cmp`/`echo`/`dhcp`/`nfs`。
  `flash-uboot.cmd` 与 README 已按实测修正。

### 修复

- **★ 存储空间终于可用**（fnOS 1.2.x 在自编译 6.6.54 上的三处"新内核特性"依赖，全部定位并解决；
  一键安装脚本：`boards/rtd1296-cm360/board-scripts/fnos-kernel-compat.sh`）
  1. **mdadm 4.5 传 `--bitmap=lockless`**（6.7+ 特性）→ 建阵列必失败；更坑的是每次失败都会在内核里
     留下 `state=clear` 的同名 md 设备，导致后续重试永远报 `File exists`（面板只显示"无法创建"）。
     → 兼容层把 `lockless` 降级为等价的 `internal`，并清理残留设备。
  2. **fnOS 挂存储时传私有选项 `-o trimacl,prjquota`** → 6.6 的 btrfs/ext4 直接拒绝挂载
     （`unrecognized mount option`），存储空间永远"未挂载"。
     → **内核补丁** `patches/0007`（btrfs）、`patches/0008`（ext4）接受这些选项（no-op；
     qgroup 配额仍由 fnOS 经 ioctl 开启）。**社区帖证实这是 fnOS 1.2.0302 自身的 bug**
     （官方支持的 OESPlus 升级后同样挂载失败）。
  3. **fnOS 的 `fast_resync_md_raid`** 依赖 lockless bitmap 接口 → 失败会让创建流程整体中止。
     → no-op 兼容层（新阵列跳过首次全量同步，安全；否则 931G 要同步 ~95 分钟导致面板超时）。
  - 结果：`md0` RAID1 → LVM → btrfs 自动挂载到 `/vol2`（930G 可用），面板显示"已挂载/正常"。
- **fnOS 的自定义 `trimafs` 文件系统缺失**（其 ACL v2 用 `mount -t trimafs trimafs /fs`）：
  内核没有该类型 → `triminit` 初始化链中断 → **`trim_*` 服务开机不自启**（表现：能 ping 通但面板打不开）。
  → 处理：`cm360-trim-boot.service` 开机兜底单元（PostgreSQL 就绪后幂等拉起服务）。
  **已知功能缺失**：细粒度 ACL 不生效；存储/共享/面板均正常。

### 修复（此前）

- **★ 构建流程的坑（踩过）**：`scripts/build-kernel.sh` 只产出**裸 `Image`**，
  直接拷到 p1 会让 u-boot 的 `bootm` 认不出（u-boot 2015.07 只认 legacy uImage/FIT）
  → 板子掉进 `BPI-W2>` 提示符。已把 **uImage 打包 + 魔数校验**加进构建脚本；
  部署务必用 `Image-6.6.uimage`（比裸 Image 多 64 字节头）。
- 上一节的 mdadm lint：见 `0392a22`。

- **fnOS 1.2.x 面板"创建存储空间"失败**（完整脚本见
  `boards/rtd1296-cm360/board-scripts/mdadm-lockless-compat.sh`）：
  - **症状**：面板只说"无法创建"；`journalctl -u trim_main` 里是
    `[MDADM ERROR] mdadm: Fail to create mdN when using
    /sys/module/md_mod/parameters/new_array, fallback to creation via node`
    + `[ERROR] md_create failed: /dev/mdN`，并自动重试 10 次全失败。
  - **真因**：fnOS 1.2.x 自带的 **mdadm 4.5 建阵列时传 `--bitmap=lockless`**
    （无锁写意图位图，上游内核 **6.7+** 才有），而我们的自编译 6.6.54
    **根本没有这个特性**（`drivers/md` 源码里搜不到）→ mdadm 打印一句
    `Experimental lockless bitmap` 警告后**静默失败**。
    更坑的是：**每次失败都在内核里留下一个 `state=clear` 的同名 md 设备**
    （md0/md1/…），于是后续重试写 `new_array` 必然 `File exists` → 永久失败。
  - **修法**：在 `/usr/trim/bin/mdadm` 位置放一层透明兼容层，把
    `--bitmap=lockless` 降级为等价的 `--bitmap=internal`；同时清掉残留 md 设备。
    原二进制保留为 `/usr/trim/bin/mdadm.real`，`--remove` 可一键还原。
  - **实测**：用 fnOS 的**原命令**（含 `--bitmap=lockless`）经兼容层 →
    `mdadm: array /dev/md180 started.`（退出码 0）、`Intent Bitmap : Internal`、
    `md180 : active raid1 sda1[1] sdb1[0]`。
  - **同类风险**：1.2.x 的部分新特性是按 6.18 内核设计的，自编译老内核时会持续
    遇到这种"用户态要求新内核特性"的坑（ZFS 模块、lockless bitmap 都属于此类）。

### 待办

- **风扇调速：软件链路已全部打通，但风扇对占空比无响应**。
  已完成的四步（都有实测输出）：
  1) PWM 控制器就位：`/sys/class/pwm/pwmchip0` 有 4 通道，原厂 `pwm@980070D0` 的
     四通道子节点属性照抄；
  2) 引脚复用已生效：新增 pinctrl 节点后 debugfs 显示
     `pin 21 (iso_gpio_21): 980070d0.pwm … function pwm_0 group iso_gpio_21`；
  3) 通道真正使能：`patches/0006` 补上了驱动漏掉的 `pwm_enable()`；
  4) `fan_ctrl_speed` 可写（0~10）。
  但把转速在 10% ↔ 100% 之间循环多轮，**风扇转速完全不变**（用户实测听感）。
  ⇒ 结论：本板风扇的 PWM 线大概率不在这几个引脚上，或者它根本不受软件控速
  （4 针扇在 PWM 输入悬空时本来就按满速转 —— 现在风扇是转的）。
  **下一步（三条路，任选）**：
  ① 用示波器/万用表量 iso_gpio_21 在 10%/100% 下有无 ~26kHz PWM：
     有 → 引脚不对；无 → 驱动寄存器写错位（pinctrl 基址待复核）；
  ② 把 `pwm_1..3` 也 mux 到 iso_gpio_22/23/24，导出后用 sysfs 逐通道扫
     （通道 1~3 未被驱动占用，可直接 `echo N > export` 测，不需重编内核）；
  ③ 查 `rtk_fan` 硬件块路径（原厂 fan 节点是 `status="disabled"`，本板可能根本不走它）。
- **SoC 温度读数为 0**：`rtd129x-thermal-sensor` probe 成功（日志有
  `wait 24ms to be ready`，说明 reset 流程跑到过），但
  `/sys/class/thermal/thermal_zone0/temp` 恒为 0。
  **下一步**：dump 0x9801d100~0x9801d170 的寄存器值，与原厂 4.9 驱动的
  `Realtek,rtd1295-thermal` 实现比对（本树用的是 rtd129x 描述，偏移可能不同）。
  在此之前**不要**加 `critical` 触发点 —— 读数不可信时会让内核误判过热关机
  （DTS 里已刻意只写 passive）。
- **SD 卡**：`MMC_RTK_SDMMC` 已内置、`sd` 节点已在 DTS（reg/clocks/interrupts 齐），
  但驱动把 `sd-power` / `sd-wp` / `sd-cd` 三个 GPIO 当**必需**资源，
  需先给驱动加容错（避免盲写引脚）或确认这三个引脚。
- **USB3 / SDIO**：驱动都在（`phy-rtk-usb3` / `phy-rtk-usb2` / `dwc3-rtk`），
  缺 DTS 节点；寄存器地址可从原厂 `ds218-cm360-1020.dtb` 取。
- LED：原厂 DTB 里没有 gpio-leds 节点，`led-set.service` 仍失败（待确认板上是否有系统灯）。
- 清理与移植无关的 fnOS 服务（`nut-*` / `exim4` / `wsdd2` / `trim_raid_check`）。

---

## [0.5.0] — 2026-10-05 · ZFS 可用 + 风扇/温度/PWM 首轮接入

### 新增

- `scripts/build-zfs.sh` + `patches/zfs/0001-disable-aarch64-neon-raidz.patch`：
  为 6.6.54 交叉编译 OpenZFS 2.4.1 模块的完整配方（含 4 个实测坑，见脚本头注释）。
- `tools/brd-ssh-raw.sh`：裸 ssh 封装 —— 远端输出可直接进管道/文件
  （brd-ssh.sh 的 sudo 模式要拿 stdin 喂密码，没法当管道用），也供 `rsync -e` 使用。
- `tools/upgrade/board-fix-files.sh`：源不可用时，把少数坏文件**就地**写回目标 rootfs。
- DTS 新增三个节点（引脚/寄存器全部取自原厂 `ds218-cm360-1020.dtb`）：
  - `pwm@70d0`（compatible `realtek,rtk-pwm`，4 通道，四通道子节点属性照抄原厂）
  - `rtk_fan@1bc00`（compatible `realtek,rtk-fan`，`pwms = <&pwm 0 …>`，GIC SPI 29 测速）
  - `thermal-sensor@1d100`（compatible `realtek,rtd129x-thermal-sensor`）+ 温度分区
- 内核配置新增：`EXPERT`/`GPIO_SYSFS`、`PWM_RTK`、`RTK_FAN`、`RTK_THERMAL`、
  `SENSORS_PWM_FAN`（`MMC_RTK_SDMMC` 原本就已内置）。
- `patches/0005-rtk-fan-tolerate-missing-clk-reset.patch`：`rtk_fan` 的 probe 对
  缺失 `clocks`/`resets` 属性**不做错误检查**就 `clk_prepare_enable()`/`reset_control_deassert()`，
  直接解引用 `ERR_PTR` → oops → 内核 panic。补上判断后驱动可正常 probe。
- `patches/0006-rtk-fan-enable-pwm.patch`：`rtk_fan` 只调 `pwm_config()` 从**不调
  `pwm_enable()`**，而新内核 PWM 框架对 disabled 通道会直接丢弃新状态
  （`pwm-rtk.c` 的 apply 在 `!state->enabled` 时提前 return）
  ⇒ 无论写什么转速，硬件占空比永远不会变。补一次 `pwm_enable()`。
- DTS 新增 pinctrl 节点（`realtek,rtd1295-iso-pinctrl`，reg[0]=0x9801a000）+
  `pwm0-pins`（`iso_gpio_21` → `pwm_0`），并被 PWM 节点引用 —— 这是让 PWM
  真正出现在引脚上的必要一步。

### 完成

- **ZFS 型存储空间可用**：`zfs.ko`/`spl.ko`（2.4.1-1，vermagic 与板上内核一致）
  装机验证 —— `modprobe zfs` 成功、`zpool create/list/destroy` 与写读全通过，
  `/etc/modules-load.d/trim-zfs.conf` 已恢复（升级时因为模块还不存在被我删过）。
- 旧 rootfs 子卷已删除（旧系统先备份到主机 `old-root-1.1.31.tar.gz`，1.77G），
  eMMC 根分区可用空间从 **2.1G 回升到 4.3G**。
- 升级途中损坏的 14 个库文件用 `board-fix-files.sh` 就地修好，新系统此后
  多次冷启动正常。

### 关键结论（都有实测支撑）

- **p1 里的 `.bak` 是改内核/DTB 的救命稻草**：本次 `rtk_fan` panic 后，就是靠
  串口进 u-boot、`ext4load … Image-6.6.uimage.bak` + `… .dtb.bak` + `bootm`
  一次性把系统起回来的（只改内存，不 `saveenv`）。
- ZFS 交叉编译三坑：`--host=` 之后需要**带 libc** 的交叉 gcc（内核工具链是 nolibc 的）；
  必须导出 `ARCH`/`CROSS_COMPILE`，否则它编译内核测试模块失败、误报
  "This kernel does not include the required loadable module support"；
  2.4.1 的 aarch64 NEON RAIDZ 内联汇编在新版 GCC 上编不过，要摘掉 NEON 实现。
- **btrfs 删子卷后空间要到下次挂载/事务提交才真正落账**：本次删完 `df` 纹丝不动，
  重启后才回收（`btrfs subvolume sync` 也等不到）。
- 全内置内核也**可以有模块**：`CONFIG_MODULES=y` 下 `CONFIG_SENSORS_PWM_FAN=m`
  之类仍会产出 `.ko`，`make modules` 也能生成外部模块编译所需的 `Module.symvers`。

### 证据

`evidence/logs/` 里的升级 panic 与 u-boot 救砖日志；本次风扇驱动 panic 的串口
日志见 `evidence/logs/fan-driver-panic-2026-10-05.log`（含 `pc : clk_prepare` /
`lr : rtk_fan_probe` 的完整调用栈）。

---

## [0.4.0] — 2026-10-05 · fnOS 升级路径（1.1.31 → 1.2.0302）

### 新增

- [`docs/07-fnos-upgrade.md`](docs/07-fnos-upgrade.md)：**整块替换 rootfs 子卷**的升级流程，
  含代价说明、回滚与"新系统起不来"时的 u-boot 救砖路径。
- `tools/upgrade/`（板端执行，逐步可重跑）：
  - `board-copy-rootfs.sh`：镜像 rootfs → eMMC 新子卷的幂等增量复制
  - `board-adapt-newroot.sh`：换 rootfs 前的本机适配（fstab / 模块元数据 /
    modules-load.d / kernel_version_output）
  - `board-verify-newroot.sh`：切换前预检（与镜像逐项比对 + chroot 起壳测试）
  - `board-switch-rootfs.sh`：子卷改名切换 / 一键回滚（**旧系统只改名不删除**）
  - `board-fix-files.sh`：源不可用时，把少数坏文件**就地**写回目标 rootfs
    （`cat > 文件` 不改 inode → 属主/权限/xattr 全保留）

### 结果（2026-10-05 实测）

- 板上 fnOS 从 **1.1.31 升到 1.2.0302**，`uname -r` 仍是自编译的
  `6.6.54-gbe79582cba58-dirty`（换 rootfs 不影响内核，符合设计预期）。
- Web 面板 80/443 监听、zram swap 941 MB、
  `modprobe zram/md_mod/overlay/openvswitch` 全部成功 → 模块元数据方案在新系统同样生效。
- 旧 rootfs 留档 `root-1.1.31`，可一键回滚。
- 详细过程与两个真实故障（复位写坏 14 个库文件、升级途中数据盘被换导致 `/vol1` 只读）
  见 `docs/07-fnos-upgrade.md` 第 7~9 节。

### 关键结论（实测）

- **内核和 DTB 在 `mmcblk0p1`、由 u-boot 直读**，两个 rootfs 的 `/boot` 都是空的
  → 换 rootfs 不会换错内核，也不需要动 u-boot。
- cmdline 是 `rootflags=subvol=root`，**按名字**找子卷 → 切换/回滚 = 子卷改名，
  不必写 u-boot 环境（`saveenv` 会碰 eMMC 低区，属于禁操作）。
- 官方镜像的 `/etc/fstab` 写的是**镜像自己的 UUID**（root + /boot vfat），
  换到本机必须改，否则挂载报错。
- eMMC 必须 `compress=zstd`：新 rootfs 5.1G 逻辑内容 / 92906 个条目，而 p2 只有 7.0G
  且已放 2.5G 旧系统；实测压缩比约 3:1。注意 btrfs 的 `compress=` 只在“挂上去的那一次”
  生效——对已挂载过的 fs 再 mount 会被静默忽略，`btrfs property` 又只被直接子项继承，
  所以持久生效要写在 `/` 那一行 fstab（实测 40MB 文本占 1.4MB）。
- 镜像自带内核 `6.18.18.c944-trim` 的模块与头文件（252M+）可直接排除；
  本机是自编译 6.6.54 全内置内核，需另补 `modules.builtin*` + 板上 `depmod`。
- **rsync 默认的"大小+时间"比较不够**：复制中途复位会留下"元数据一致、内容已坏"
  的文件，后续 rsync 全部跳过，最终比对还报 0 差异 —— 升级/校验一律要带 `-c`。
  预检额外加一条 `chroot <新rootfs> /usr/lib/systemd/systemd --version`
  （只测 `bash` 会漏掉：bash 不链接 libaudit，而 PID 1 链接）。

### 决策

- **不走官方 OTA**：板子没有外网出口，且面板按伪装机型 `onethingcloud-oec`
  拉更新，拿不到 ARM 通用镜像；改为整块替换 rootfs。
- 升级会清空 fnOS 配置库（账号/存储空间/共享），`/vol1` 数据不受影响；
  旧 rootfs 子卷保留为回滚点。

---

## [0.3.0] — 2026-10-05 · 存储与服务可用

### 修复

- **第二块硬盘不被识别**：`ata2: SATA link down` → 第二个盘位没上电。
  给 `sata-port@1` 补 `sata-gpios`（引脚号取原厂 DTB 的 `misc_gpio 19`，
  而非官方参考 dtsi 的 `iso_gpio 15`）。
- **fnOS 创建存储空间失败**：内核缺 mdraid personality
  （`md: personality for level 1 is not loaded!`）。
  补 `MD_RAID0/1/10`、`MD_LINEAR`、`DM_THIN_PROVISIONING/SNAPSHOT/RAID/CRYPT`、
  `QFMT_V1/V2`、全套 dm-crypt 相关 crypto。
  修后：双盘 RAID1 → LVM → ext4，挂 `/vol1`。
- **`ovs-vswitchd` / `ovsdb-server` 失败**：缺 `CONFIG_OPENVSWITCH`。
- **`zramswap` 失败、无 swap**：缺 `CRYPTO_LZ4`（zram0 只提供 lzo/zstd）。
  修后 941 MB swap。
- **`docker` 每次开机必挂**：fnOS 自带 `ExecStop` 在无容器时报错 +
  `dockerd` 关闭时 `docker stop` 会挂住。用 systemd drop-in 覆盖（不改原单元）。
- **`modprobe` 对内置模块一律失败**：全内置内核没有模块目录。
  新增 `scripts/deploy-modmeta.sh`（拷元数据 + **板上 depmod**）。

### 新增

- `boards/rtd1296-cm360/files/docker-override.conf`
- `scripts/queue` 中的 `deploy-modmeta.sh`

---

## [0.2.0] — 2026-10-05 · 救砖 + 独立启动 + reboot

### 新增

- **ROM Monitor 救砖全流程**（`tools/recovery/`）：稀疏 Ctrl+Q（33 B/s）
  + YMODEM + 长度/CRC 校验。实测一次成功，把板子从"卡 FSBL"救回。
- **eMMC 独立启动**：u-boot 换成 BPI-W2 的，`bootcmd`/`bootargs` 已 `saveenv`。
- `patches/0004-wdt-restart.patch`：修 `reboot` 挂死。

### 关键发现（都是实测/反汇编所得）

- **Ctrl+Q 必须稀疏**：33 B/s 成功、4000 B/s 洪流失败。
  ROM 轮询前会清 RX FIFO，且要求 **≥3 个连续 `0x11`**。
- **串口必须真独占**：第二个读者会偷走板子的应答 ——
  上一轮 YMODEM "全废"的真因是手动开的 `screen` 与脚本同抢 tty，
  与洪流是**两个独立原因**（早期复盘把它们混为一谈，已更正）。
- **`reboot` 挂死的根因是"一个 restart handler 都没有"**：
  PSCI / rtk-rstctrl / 看门狗回调三者皆无。

### 证据

`evidence/logs/phoenix2-*.log`（进 monitor 与传输全过程）、
`evidence/logs/mon-g-*.log`（烧写）、`evidence/logs/bootcap-*.log`（恢复后干净启动）。

---

## [0.1.0] — 2026-10-04 · 板子点亮

### 新增

- Linux 6.6.54 在这块板上跑起来：串口 / GIC / 时钟 / eMMC(HS200) / SATA / GMAC。
- **SMP 四核**（`patches/0003`）：从核释放寄存器必须 `ioremap` + 32 位写。
- 板级 DTS 从上游极简骨架写到可用（节点注释含证据来源）。
- `evidence/reports/` 里的阶段性技术报告。
