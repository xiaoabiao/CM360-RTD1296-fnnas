# 05 · 存储与 fnOS 适配

## 1. fnOS 的存储栈

把 fnOS 的存储处理器 `/usr/trim/bin/handlers/storage.hdl` 里的字符串读出来，
能看出它支持哪些形态：

```
makefs_btrfs / mkfs.btrfs / btrfs_create_subvol / btrfs_enable_quota
makefs_ext4_with_quota / mkfs.ext4
--level=linear                         ← 跨盘"基础"空间
zfs_create / zpool create / draid1..3  ← ZFS 型（需要 ZFS 模块）
md/raid_disks / mklabel gpt mkpart … set 1 raid on
```

即 **两条路径**：

| 路径 | 组成 | 本项目状态 |
|---|---|---|
| 非 ZFS | mdraid（raid0/1/10/linear）→ LVM → btrfs/ext4 | ✅ 可用 |
| ZFS | `zpool create trim_<uuid> … failmode=continue` | ⬜ 缺 ZFS 模块 |

### 建存储空间失败的两个真实原因

**① 内核缺 mdraid personality。** 症状：

```
/proc/mdstat → Personalities : [raid6] [raid5] [raid4]   ← 缺 0/1/10/linear
dmesg        → md: personality for level 1 is not loaded!
mdadm --detail /dev/md0 → Raid Level : raid1, State : active, FAILED, Not Started
```

fnOS 建空间（**含单盘"基础"模式**）底层就是 `mdadm --level=1`，
所以缺 personality 时**所有类型都建不出来**，与插几块盘无关。
修法：内核打开 `MD_RAID0/1/10` + `MD_LINEAR`（见 [`02-kernel-and-dts.md`](02-kernel-and-dts.md)）。

**② 走 ZFS 路径时缺 ZFS 模块。** 症状：

```
trim[…]: [create]=>6: failmode=continue
trim[…]: [ERROR] zfs_create failed: trim_<uuid>       ← 每 2 秒重试一次
```

ZFS 是树外模块。板上用户态是 **OpenZFS 2.4.1**，
fnOS 自带内核把 ZFS 作为独立模块发布
（`/lib/modules/6.18.18-trim/updates/trim/zfs/zfs.ko`）。
本项目内核 `CONFIG_MODULES=y`，**可以为 6.6.54 交叉编译一套 OpenZFS 2.4.1 模块**
（尚未做）。在此之前 fnOS 会反复轮询 `zpool status` 失败（无害，刷日志）。

### 成功后的形态

```
md0 : active raid1 sda1[0] sdb1[1]      ← 双盘 RAID1，[2/2] [UU]
 └─ vg/trim_<uuid>-0 (LVM)
      └─ ext4 → 挂 /vol1
```

---

## 2. 双盘识别（SATA 供电）

插两块盘只认到一块、`ata2: SATA link down (SStatus 0)` → **第二个盘位没上电**。
两个盘位分别上电，DTS 每个 `sata-port@N` 都要给 `sata-gpios`。
详见 [`02-kernel-and-dts.md`](02-kernel-and-dts.md) 的"SATA 两个盘位是分别供电的"。

---

## 3. fnOS 服务适配

`systemctl --failed` 里逐一查清后的结论：

| 服务 | 状态 | 说明 |
|---|---|---|
| `ovs-vswitchd` / `ovsdb-server` | ✅ 已修 | 缺 `CONFIG_OPENVSWITCH` → `modprobe` 失败 |
| `zramswap` | ✅ 已修 | 缺 `CRYPTO_LZ4` → 设 lz4 报 `Invalid argument`；修后 941 MB swap 起来 |
| `smartmontools` | ✅ 可用 | 盘能正常出 SMART 状态 |
| `docker` | ✅ 已修 | 见下方"docker 的两个坑" |
| `wsdd2` | ⬜ | `/usr/trim/bin/wsdd2` **二进制在镜像里不存在**（fnOS 打包缺失） |
| `trim_raid_check` | ⬜ | 二进制要求 **glibc 2.38**，而系统是 Debian 12（2.36）——镜像内部不一致 |
| `nut-server` / `nut-monitor` | ⬜ | `ups.conf` 无 UPS 定义（没接 UPS），属预期 |
| `exim4` | ⬜ | `/var/log/exim4` 权限问题（可 `chown` 修） |
| `led-set` / `set_gpio-init` / `pwm-fancontrol` | ⬜ | 都读 `/boot/board.json`，而镜像里**没有这个文件**，见下 |

### docker 的两个坑（fnOS 自带缺陷）

`docker.service` **每次开机必挂**，两个原因叠加：

1. 它的 `ExecStop="docker stop --time 3 $(docker ps -a -q)"`
   在**一个容器都没有**时展开成 `docker stop --time 3` → 报错退出 1 → 单元判 failed；
2. 即使有容器，`dockerd` 正在关闭时 `docker stop` 会一直等 → 单元长期卡 `deactivating`。

而 fnOS 的 `dockermgr` 会在 docker 启动约 7 秒后停/重启它 → 开机必现。

修法用 systemd drop-in（**不改它的原单元**，fnOS 升级覆盖原文件时这份仍生效）：

```bash
sudo install -D -m 644 boards/rtd1296-cm360/files/docker-override.conf \
     /etc/systemd/system/docker.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart docker
```

---

## 4. 板级缺口：`/boot/board.json` 与风扇

`set_gpio-init` / `led-set` / `pwm-fancontrol` 三个服务都读 **`/boot/board.json`**，
由它描述"这块板的 LED/风扇/GPIO 用哪些脚"。该文件是**厂商做板级支持时写的**，
本镜像里整个不存在（`find / -name board.json` 无结果），所以：

- LED / GPIO 初始化失败（无害，只是没有灯效）；
- **`pwm-fancontrol` 静默退出 → 风扇没有受控**。

实测温度（满负载前）：`sda 49 °C`（该盘历史最高 52 °C）、`sdb 34 °C`。
对双盘 NAS 来说这是**需要处理的隐患**。

要做的事：

1. 为本板写一份 `board.json`（风扇 PWM 通道 / LED GPIO / 编号映射）；
2. 内核启用 `CONFIG_GPIO_SYSFS`（脚本走 `/sys/class/gpio/export`，
   而当前内核里 `/sys/class/gpio` 不存在）。

线索：板的 LED/风扇引脚定义可从原厂 DTB
（`evidence/stage0/original-dtb.dts.txt`）与 DTS 现有的 GPIO 节点推出来。

---

## 5. 其它

- **启动耗时**：到网络可用约 60 秒（SATA 上电 + 一批 systemd 服务）。
- **MAC**：由 fnOS 的 `system_setmac.service`（"Set stable MAC addresses from MMC CID"）
  按 eMMC CID 设定 —— 所以换 u-boot 后 MAC 也不会变。
- **`reboot`**：已修好（见 [`02-kernel-and-dts.md`](02-kernel-and-dts.md)）。
  在打那个补丁之前，每次重启都必须手动断电。
