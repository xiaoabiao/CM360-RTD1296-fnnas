# 03 · 构建与安装

> 目标读者：拿到本仓库、手上有一台 CM360（或兼容 RTD1296 板）的人。
> 从零到"板子上跑起 fnOS"，全部命令都在这里。

---

## 0. 依赖与准备

### 主机侧

```bash
# Debian / Ubuntu
sudo apt install build-essential git flex bison bc libssl-dev \
                 gcc-aarch64-linux-gnu
# Fedora
sudo dnf install @development-tools git flex bison bc openssl-devel \
                 gcc-aarch64-linux-gnu
```

### 本机配置（可选，但推荐）

仓库内**不写死任何绝对路径**。本机差异写进仓库根的 `local.conf`
（已 gitignore，模板见 `local.conf.example`）：

```bash
cp local.conf.example local.conf
$EDITOR local.conf
```

可配置项：`KTREE`（内核树）、`CROSS_COMPILE`（工具链前缀）、`JOBS`、
`SERIAL_DEV`、`SERIAL_BAUD`、`BOARD`。
`local.conf` 是**被 bash source 的**，所以需要时也能写 shell 代码。

自检：

```bash
./scripts/setup-deps.sh --check     # 或 make check
```

### 板子侧

- USB-TTL 串口接到板子的 UART0（115200 8N1）。**救砖时它是唯一的生命线**，
  务必确认可用（`ls /dev/ttyUSB*`，权限问题见 `tools/serial/fix-serial-perm.sh`）。
- 网络：板子默认从 DHCP 取地址。

---

## 1. 拉内核树并生成基线

```bash
./scripts/setup-deps.sh
```

它会：

1. 环境自检（交叉编译器 / flex / bison / bc）；
2. 把 `github.com/XpressReal/linux` **按锁定 commit `be79582cb`（6.6.54）**
   用 `--filter=blob:none` 拉到 `build/kernel`；
3. 应用 `patches/*.patch`（幂等：已打过会跳过，冲突会报错）。

> 为什么锁 commit：产物版本串会变成 `6.6.54-gbe79582cba58-...`，
> 与 `evidence/` 里的实测日志一致。换 commit 等于换基线，
> 补丁可能打不上，请同步更新 `patches/`。

---

## 2. 构建

```bash
./scripts/build-kernel.sh          # 或 make build
```

产物（都在 `build/`，已 gitignore）：

| 文件 | 说明 |
|---|---|
| `build/Image-6.6` | 裸 arm64 内核 |
| `build/rtd1296-cm360.dtb` | 板级设备树 |

只改了 DTS 时用 `DTB_ONLY=1 ./scripts/build-kernel.sh`（或 `make dtb`），几秒钟出结果。

套成 u-boot 能 `bootm` 的 legacy uImage：

```bash
./scripts/make-uimage.py build/Image-6.6 build/Image-6.6.uimage 0x03000000
```

构建脚本内部做了什么、每个内核配置项的"不配会怎样"，见
[`02-kernel-and-dts.md`](02-kernel-and-dts.md)。

---

## 3. 安装到板子

### 3.1 装到 eMMC（推荐，独立启动）

板子的 eMMC 布局（本项目使用）：

```
blk# 0x100       hwsetting（★ SoC 启动配置，绝不能碰）
blk# 0x2100      u-boot 环境（saveenv 落点）
低区其余          bootcode / FSBL / BL31
LBA 77824 (38M)  p1  ext4 256 MiB  LABEL=BOOT ← Image-6.6.uimage + rtd1296-cm360.dtb
LBA 602112(294M) p2  btrfs 6.99 GiB LABEL=rootfs ← fnOS 根
```

**只更新内核**（最常用）：把两个文件写进 p1 即可，不必重做分区。

```bash
cd scripts
../tools/brd-ssh.sh sudo 'mount /dev/mmcblk0p1 /mnt/emmc-boot'
../tools/brd-ssh.sh get  '/mnt/emmc-boot/Image-6.6.uimage' ../build/backup/      # ★ 先备份
../tools/brd-ssh.sh put  ../build/Image-6.6.uimage /tmp/Image-6.6.uimage.new
../tools/brd-ssh.sh put  ../build/rtd1296-cm360.dtb /tmp/rtd1296-cm360.dtb.new
../tools/brd-ssh.sh sudo 'cp /tmp/Image-6.6.uimage.new /mnt/emmc-boot/Image-6.6.uimage
                          cp /tmp/rtd1296-cm360.dtb.new /mnt/emmc-boot/rtd1296-cm360.dtb
                          sync && umount /mnt/emmc-boot'
```

> ★ **换内核后必须补一步**，否则 `modprobe` 全部失败（zramswap、OVS 等服务会起不来）：
> ```bash
> ./scripts/deploy-modmeta.sh
> ```
> 原因见 [`02-kernel-and-dts.md`](02-kernel-and-dts.md#为什么需要-modmeta)。

**从零刷机**（eMMC 布局也要重建）：用
`./scripts/emmc-prepare.sh` + `./scripts/emmc-write.sh`，
**但务必先读 [`04-recovery.md`](04-recovery.md) 与事故复盘**——
这两个脚本会写闪存低区，是当初把板子打成砖的操作。

### 3.2 只做验证（TFTP 引导，不写闪存）

想先试内核、不动 eMMC：

```bash
./scripts/build-initramfs.sh
./scripts/deploy-tftp.sh          # 三个文件推到 build/tftproot
# 然后在 u-boot console 里：
#   setenv serverip <你主机的IP>
#   tftp 0x03000000 Image-6.6.uimage
#   tftp 0x02100000 rtd1296-cm360.dtb
#   bootm 0x03000000 - 0x02100000
```

上板命令封装：`tools/uboot/board.sh`（串口侧），
或 `tools/uboot/ubcmd.py --wait-prompt 300 '<命令>'`（脚本侧）。

---

## 4. 安装后验证

```bash
./tools/brd-ssh.sh run 'uname -r; uptime'          # 或 make board CMD='uname -r'
```

期望：

- `uname -r` = `6.6.54-gbe79582cba58-dirty`
- 两块盘都出现：`lsblk` 里 `sda` / `sdb`
- `cat /proc/mdstat` 首行含 `[linear] [raid0] [raid1] [raid10] [raid6] [raid5] [raid4]`
- 存储空间挂载：`df -h /vol1`
- `systemctl is-active docker ovs-vswitchd zramswap smartmontools` → `active`
- `reboot` 能自动重启（而不是挂住，见下文）

更细的体检脚本在 `scripts/verify/`（串口侧执行）。

---

## 5. 常见操作

| 想做的事 | 命令 |
|---|---|
| 上板跑命令 | `./tools/brd-ssh.sh run 'uptime'` |
| 上板跑 sudo | `./tools/brd-ssh.sh sudo 'lsblk'` |
| 上传/下载文件 | `./tools/brd-ssh.sh put <本地> <远端>` / `get <远端> <本地>` |
| 改 DTS 后快速重编 | `make dtb` |
| 看串口 | `tools/serial/monsniff.py 15`（只读，不发字节） |
| 重启板子 | `./tools/brd-ssh.sh sudo 'reboot'`（已修好，见下方注意） |
| 板子起不来 | 读 [`04-recovery.md`](04-recovery.md) |

### 注意

- **启动要耐心**：到网络可用约 **60 秒**（SATA 上电 + 一批 systemd 服务）。
  别用一次 `ping` 不通就判死 —— 先看串口有没有输出。
- **凭证**：`tools/brd-ssh.sh` 读 `~/.brd_cred`（第 1 行用户名 / 第 2 行密码 /
  第 3 行 IP / 第 4 行端口），该文件**不入库**，权限请设 600。
