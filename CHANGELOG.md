# 变更记录

本项目按"阶段"推进，每个阶段都有对应的实测证据留在 `evidence/`。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [未发布]

### 待办

- **风扇 / LED 板级支持**：机制已查明 —— fnOS 的 `set_gpio-init.service` 启动时读
  `/boot/board.json` 的 `gpio[]` 数组（`name/pin/value/delay`），用
  `/sys/class/gpio/export` 拉引脚；文件不存在则直接退出（所以现在不会乱动 GPIO）。
  要做的事：为本板写一份 `board.json`（放到 rootfs 的 `/boot/board.json` 即可，
  不必挂 p1）+ 内核开 `CONFIG_GPIO_SYSFS`。在此之前**风扇未受控**
  （`pwm-fancontrol` 静默退出，`sda` 实测 48~51 °C）。
- **ZFS 型存储空间**：为 6.6.54 交叉编译 OpenZFS 2.4.1 模块
  （板上用户态即 2.4.1，fnOS 把它作为独立模块发布）。
- SDMMC / SDIO、USB3：驱动已在 `.config`，缺 DTS 节点（USB3 还需 PHY 时序）。
- 清理与移植无关的 fnOS 服务（`nut-*` / `exim4` / `wsdd2` / `trim_raid_check`）。

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
- eMMC 必须 `compress=zstd` 挂载：新 rootfs 5.1G 逻辑内容 / 92906 个条目，
  而 p2 只有 7.0G 且已放 2.5G 旧系统；实测压缩比约 3:1。
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
