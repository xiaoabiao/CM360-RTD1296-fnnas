# 07 · fnOS 系统升级（整块替换 rootfs 子卷）

> 目标：把板上 fnOS 从 **1.1.31** 升到官方 ARM 版 **1.2.0302**，
> 在**不重新烧 eMMC 低区、不动 u-boot、不动内核**的前提下完成，
> 并且随时能回滚。

## 1. 为什么不用官方 OTA

| 途径 | 结论 |
| --- | --- |
| fnOS 面板 OTA | 需要外网 + dlkey/sign 校验；本板**没有外网出口**（curl 外网超时），且面板是按伪装机型 `onethingcloud-oec` 拉更新的，拿不到 ARM 通用镜像 |
| `https://fnnas.com/download-arm` 的 img | ✔ 可用：整盘镜像，含 eMMC 分区表 + boot + rootfs |
| 自己编 fnOS | 不现实（闭源用户态） |

关键认识：**这块板子的内核是我们自编译的 6.6.54 全内置内核，和 fnOS 自带内核无关**，
fnOS 的内核级新特性（RAID 加速等）用不上；升级只换**用户空间 rootfs**。

## 2. 板子上的分区布局（升级方案的基础）

```
mmcblk0p1  256M   内核 + DTB（u-boot 直接用 ext4ls 读：Image-6.6.uimage / rtd1296-cm360.dtb）
mmcblk0p2  7.0G   btrfs，内核 cmdline: rootflags=subvol=root
                  └── 子卷 root      = 正在运行的系统
```

两个由此推出的结论：

1. **内核和 DTB 不在 rootfs 里**（rootfs 的 `/boot` 是空的，两边都一样），
   所以换 rootfs 子卷**不会换错内核**，也不需要碰 u-boot。
2. cmdline 用 `subvol=root` **按名字**找子卷 → 只要把子卷改名成 `root` 就完成"切换"，
   回滚就是把名字改回去。**不需要改动 u-boot 环境**（千万不要 `saveenv`，
   eMMC 低区 blk#0x2100 是 u-boot 环境、blk#0x100 是 hwsetting，动它们就是砖）。

## 3. 前置条件

- **eMMC 必须压缩挂载**：新 rootfs 解压后有 5.1G 逻辑内容，而 p2 只有 7.0G，
  里面还躺着 2.5G 的旧系统。btrfs `compress=zstd` 实测约 3:1（5.1G → 1.5G），
  不压缩必然写满。挂载方式：

  ```sh
  mount -o subvolid=5,compress=zstd,noatime /dev/mmcblk0p2 /mnt/emmc-top
  ```

  > **坑（实测）**：btrfs 的 `compress=` 只在"把文件系统挂上来"的**那一次**
  > （首次 mount，或显式 remount）生效；对**已经挂载过**的文件系统再 mount 一次时，
  > 这个选项会被**静默忽略**。所以：
  > - 复制目标所在的辅助挂载点，挂完后必须显式 `mount -o remount,compress=zstd`
  >   （上面的命令里带了，但重启后就没了）—— 否则写进去的数据一点没压缩，
  >   而 `du` 看不出来，只会看到分区被写满；
  > - 想让压缩**跨重启持久生效**，要把 `compress=zstd` 写到 **`/` 那一行** fstab 上
  >   （本次就是这么修的：`UUID=<eMMC p2> / btrfs defaults,noatime,compress=zstd`，
  >   实测 40MB 文本只占 1.4MB）；
  > - 不要指望 `btrfs property set <目录> compression zstd` 当整棵树的开关：
  >   它**只被直接子项继承**（踩过：给子卷根设了属性，写到子目录照样不压缩）；
  > - 也别靠 `rsync -X` 把压缩属性"带过去" —— 它反而会把目标上已有的
  >   `btrfs.compression` 属性删掉。

- 板子上有 5.1G 空闲空间放镜像（本机放在数据盘 `/vol1`，11T）。
- 串口（`/dev/ttyUSB0`）接好并且**独占**：升级中途万一新系统起不来，
  就靠它进 u-boot 改 `bootargs` 救回来。

## 4. 步骤

### 4.1 取镜像并校验

```sh
# 下载（在主机上）
curl -L -o fnos_arm_1.2.0302_onethingcloud-oes.img.gz \
  https://fnnas.com/download-arm/...        # 具体直链见 docs/refs
md5sum fnos_arm_1.2.0302_onethingcloud-oes.img.gz
# 官方 MD5：45139e41d05c411edf75fa154cf5bf83
```

把 `.gz` 传到板子上解开（板端 CPU 解压 gzip 1.9G 约几分钟）：

```sh
gunzip -c fnos_arm_1.2.0302_onethingcloud-oes.img.gz > fnos.img   # 3.8G
```

### 4.2 板上挂载镜像

```sh
losetup -P "$(losetup -f)" /vol1/fnos-upgrade/fnos.img
mount -o ro /dev/loop0p2 /mnt/newroot      # 镜像的 rootfs（本身就是 btrfs）
```

镜像里**没有嵌套子卷**（`btrfs subvolume list /mnt/newroot` 为空），
所以可以直接用 rsync 平铺复制。

### 4.3 建子卷并做首次复制

```sh
btrfs subvolume create /mnt/emmc-top/root-new
btrfs property set /mnt/emmc-top/root-new compression zstd
cp tools/upgrade/board-copy-rootfs.sh /vol1/fnos-upgrade/
bash /vol1/fnos-upgrade/board-copy-rootfs.sh      # 后台跑，日志同目录
```

脚本要点（都在 `tools/upgrade/board-copy-rootfs.sh` 里注释了原因）：

- `-aHAXc --numeric-ids --delete-after`：权限/ACL/xattr/硬链接全都保留，
  幂等可重跑（复制中断不必从头来）；
  **`-c`（内容校验）不能省** —— 见下面第 6 节的坑：默认的"大小+时间"比较
  会把"复制中途被复位"留下的坏文件判为一致，一路跳过，
  最后比对还报 0 差异，切过去直接 panic；
- `--bwlimit=12M` + `nice 19`：降低瞬时压力（曾出现复制途中整机复位，
  虽然最后确认是人为复位，但限速没有坏处）；
- 排除 `usr/lib/modules/6.18.18.c944-trim`（252M）和 `usr/src/linux-headers-*`：
  这些是 fnOS 自带内核的模块与头文件，本机内核用不上。

进度怎么看（**不要用 `du`**，它不反映压缩）：

```sh
find /mnt/emmc-top/root-new -xdev | wc -l     # 条目数，源共 92906
btrfs filesystem usage /mnt/emmc-top          # 真实占用
```

复制跑完后先做一次预检（**此时必须 0 差异**）：

```sh
bash /vol1/fnos-upgrade/board-verify-newroot.sh pre
```

`pre` 阶段的判据是"与镜像逐项比对 0 处差异"（`rsync -aHAXn --delete --itemize-changes`
干跑），所以**它只能在适配之前用** —— 适配是故意让两边不一致的。

### 4.4 适配（必须，否则新系统是坏的）

```sh
bash /vol1/fnos-upgrade/board-adapt-newroot.sh
```

四件事：

1. **fstab**：官方镜像的 `/etc/fstab` 写的是**镜像自己的 UUID**
   （`UUID=ad345590-… / btrfs`、`UUID=189A-FB6A /boot vfat`），本机上不存在。
   改成本板一直好用的最小配置（只留 tmpfs，根文件系统由 cmdline 提供）。
2. **内核模块元数据**：本机内核是**全内置**构建，板上没有 `.ko`，
   而 fnOS 大量脚本用 `modprobe` 探测模块（zram/openvswitch/…）→ 全部误判为不可用。
   解决：把 `modules.builtin`/`modules.builtin.modinfo` 放进
   `usr/lib/modules/6.6.54-…/`，并在板上跑一次 `depmod -b /mnt/emmc-top/root-new`。
   参见 `scripts/deploy-modmeta.sh` 的注释。
3. **modules-load.d**：删掉本机内核里不存在的 `trim-zfs.conf`（zfs）、
   `trim-fullconenat-nft.conf`（nft_fullcone）、`modules.conf` 里的 `msr`
   —— 否则每次开机都刷一堆 modprobe 报错。
4. **`/var/tmp/kernel_version_output`**：fnOS 运行时读的内核/平台标识，镜像里没有。

> 顺序很重要：**适配必须在 rsync 之后做**。
> `--delete-after` 会把目标目录里"源里没有"的文件恢复成源的样子，
> 手改过的 fstab 会被覆盖回去。

适配完再做一次预检（这一步会做 chroot 起壳测试）：

```sh
bash /vol1/fnos-upgrade/board-verify-newroot.sh ready
```

### 4.5 切换并重启

```sh
bash /vol1/fnos-upgrade/board-switch-rootfs.sh switch
reboot
```

做的事：`root` → `root-1.1.31`（**只改名，不删除**）、`root-new` → `root`、
`btrfs subvolume set-default` 指向新 root、`sync`。

### 4.6 首次开机验证

串口上能看到完整的启动过程；起来之后确认：

```sh
uname -r                      # 应仍是 6.6.54-gbe79582cba58-dirty（内核没换）
cat /usr/trim/etc/version     # 应为 1.2.0302（注意不是 /etc/trim/version）
lsblk                         # 两块盘 + md0 + LVM 都在
modprobe zram && echo ok      # 模块元数据生效
```

### 4.7 回滚

新系统起来了但不满意：

```sh
bash /vol1/fnos-upgrade/board-switch-rootfs.sh rollback && reboot
```

**新系统完全起不来**（连 SSH 都没有）时，用串口进 u-boot 一次性救回
（只改内存里的 bootargs，**不要 saveenv**）：

```
BPI-W2> printenv bootargs
BPI-W2> setenv bootargs <把 rootflags=subvol=root 改成 rootflags=subvol=root-1.1.31，其余照抄>
BPI-W2> run bootcmd
```

（`tools/uboot/ubcmd.py` 可以直接发这些命令，见 `docs/04-recovery.md`。）

## 5. 代价与注意事项

- **fnOS 的配置库在 rootfs 里**（账号、存储空间、共享、应用设置）→
  换 rootfs = 配置清空，新系统里要重做一遍。
- **`/vol1` 上的数据不受影响**（数据在数据盘 LVM 上），
  但新系统第一次进"存储空间"向导时**不要格式化**，应该认出已有的
  `trim_*` 名字的 mdraid + LVM 卷；认不出就先别动，回滚旧系统即可。
- 旧 rootfs 子卷 `root-1.1.31` 一直留着当后路，确认新系统稳定后再删除。
- 板子没有外网出口，所有文件都得从主机传过去（`tools/brd-ssh.sh`）。

## 6. 踩坑清单（都实际发生过）

| 现象 | 真因 | 处理 |
| --- | --- | --- |
| 复制一半 eMMC 写满 | 挂载没带 `compress=zstd`，`du` 又看不出来 | 带参数重挂 + 写进 fstab + 给子卷打 `compression` 属性 |
| 复制完成但内容没压缩 | `rsync -X` 把 `btrfs.compression` 属性删了 | 用 `btrfs property set` 而不是靠 rsync 带属性 |
| 新系统起不来/挂载报错 | 镜像 fstab 里是镜像自己的 UUID | 4.4 的适配步骤 |
| `modprobe` 全失败 | 全内置内核没有 `/lib/modules/<版本>/` 索引 | 装 `modules.builtin*` + 板上 `depmod` |
| 开机一堆 modprobe 报错 | modules-load.d 要加载 zfs/nft_fullcone/msr | 删掉这三处 |
| 复制中断后重跑发现手改没了 | `--delete-after` 把适配改动覆盖回去 | 先复制完、再适配；脚本里有 rsync 运行检查 |
| 复制中途整机重启 | 人为复位（查过：无 panic、无 watchdog、无过热） | 重跑即可（rsync 幂等）；已开 journald 持久化便于下次取证 |
| **切过去后 PID 1 直接 panic**：`/sbin/init: error while loading shared libraries: /lib/aarch64-linux-gnu/libaudit.so.1: invalid ELF header` | 复位前那轮 rsync 写坏了这个文件，而它**大小和时间戳都与源一致** → 默认 rsync 比较判定"无需传输"，最终比对也报 0 差异 | 复制与校验都必须带 `-c`（内容比较）；预检里加 `chroot <新rootfs> /usr/lib/systemd/systemd --version` 烟雾测试（只测 bash 不够，bash 不链接 libaudit） |
| 切过去起不来，怎么救 | panic 默认不自动重启，板子死等；此时 SSH 没了、串口还在 | 断电重启 → 串口连打 Esc/Tab 进 u-boot 控制台 → `setenv bootargs … rootflags=subvol=root-1.1.31`（只改内存，**不要 saveenv**）→ `run bootcmd`；起来后跑 `board-switch-rootfs.sh rollback` 把子卷名改回来 |

## 7. 实战记录：2026-10-05 从 1.1.31 升到 1.2.0302

**结果**：新系统正常启动，`/usr/trim/etc/version = 1.2.0302`，
`uname -r = 6.6.54-gbe79582cba58-dirty`（内核没换，符合预期），
Web 面板 80/443 起监听，zram swap 941 MB，
`modprobe zram/md_mod/overlay/openvswitch` 全部成功（模块元数据方案生效）。
旧系统留档在 `root-1.1.31`。

**重启验证（做完适配后的再次冷启动）**：

- `/` 挂载参数带上了 `compress=zstd:3`（fstab 里 `UUID=<p2> / btrfs defaults,noatime,compress=zstd`）——
  实测写入 40MB 文本只占 1.4MB；
- `uname -r` 仍是 `6.6.54-gbe79582cba58-dirty`，`/usr/trim/etc/version` 仍是 1.2.0302；
- 串口启动日志里**没有 panic / 库加载错误**；SSH 约 70 秒恢复（首次启动要初始化 fnOS，约 210 秒）；
- 回滚点 `root-1.1.31` 完好。

**过程中真出事的只有两处**：

1. 第一次切过去直接 panic，真因是**复制中途板子被复位**，写坏了
   `/usr/lib/aarch64-linux-gnu/lib{asound,ass,assuan,asyncns,atk,atomic,atspi,attr,audit,avahi*,avc1394}`
   这一小段连续区间的库文件（共 14 个），而它们**大小/时间戳与源一致**，
   默认 rsync 比较直接跳过。→ 教训已写进第 6 节，脚本全部改用 `-c`。
2. 升级所需的镜像文件放在数据盘 `/vol1` 上，而那块盘在升级途中被换掉/拔掉，
   ext4 因写到超出实际磁盘容量的区域而中止日志、`/vol1` 变只读 →
   **镜像文件不可用**。→ 不再依赖 `/vol1`，改用下面的"增量补文件"路线。

## 8. 增量补文件（源在别处也能修）

当目标 rootfs 已经复制得差不多、只是少数文件内容坏了时，**重新整盘复制是浪费**。
更快的做法是"先比出坏文件、再只补它们"，而且不需要在板上放大文件：

```sh
# 主机：从官方镜像解出参考树（非 root 也可以，内容为准）
gzip -dc fnos.img.gz > fnos.img
# 分区偏移/长度用 fdisk -l 看，p2 是 rootfs
dd if=fnos.img of=p2.img bs=1M iflag=skip_bytes,count_bytes skip=<p2偏移> count=<p2长度>
btrfs restore -i p2.img ref          # 参考树（属主会丢，内容准）

# 两边各生成一份 md5 清单（板上要以 root 生成，普通文件读不全）
cd ref && find . -xdev -type f -print0 | xargs -0 md5sum > ref.md5
# 板上：cd /mnt/emmc-top/root-new && find . -xdev -type f -print0 | xargs -0 md5sum > dest.md5

# 主机：按路径 join 出内容不一致的文件（注意 sort/join 都用 LC_ALL=C，否则结果有重复项）
LC_ALL=C sort -t $'\t' -k1,1 … && LC_ALL=C join … | awk -F'\t' '$2!=$3'

# 只把坏文件传到板上暂存目录，再由 root **就地**写回（tools/upgrade/board-fix-files.sh）
tar -C ref -czf fix.tar.gz -T 坏文件清单
# 板上：rsync/scp 到 /mnt/emmc-top/stage/（该目录 chown 给普通用户）→ 解包 →
#       bash board-fix-files.sh /mnt/emmc-top/root-new /mnt/emmc-top/stage/files
```

`board-fix-files.sh` 用 `cat stage/<p> > dest/<p>` 就地覆盖：**inode 不变**，
所以属主/权限/xattr/ACL 这些"本来是对的"元数据全部保留 —— 这是用 rsync/cp/tar
覆盖做不到的（它们都会先 unlink 再创建）。

本次实测：94611 个条目里只有 14 个文件内容不一致（几 MB），
补完重算 md5 清单 → 只剩 `/etc/fstab`（适配时故意改的）一处差异，
随后切换一次成功。

## 9. 升级后待办

- **fnOS 首次配置**：面板里建账号/存储空间。**不要格式化已有数据的盘**，
  fnOS 认不出的盘会挂到 `/vol00/<型号>` 下（本次两块 1T 盘就是这样，数据可读）。
- **docker**：新装未初始化时 fnOS 会主动停一次 docker，而 `ExecStop`
  （`docker-shutdown-containers.sh`）停不下来、超时被 SIGKILL → 那一刻单元显示 failed。
  **首次初始化走完、重启之后自己就正常了**（本次复查 `systemctl is-active docker` = active），
  不需要 1.1.31 时代那个 drop-in；若以后又出现 failed，再套用
  `boards/rtd1296-cm360/files/docker-override.conf`。
- **风扇 / LED**：`set_gpio-init.service`（读 `/boot/board.json`）与 `led-set.service`
  仍失败 —— 机制见 CHANGELOG 待办，写好 `board.json` 即可。
- `nut-*` / `exim4` 等与本板无关的服务可以关掉（见 CHANGELOG 待办）。
- 确认新系统稳定后，删掉 `root-1.1.31` 子卷回收 ~2.5G（eMMC 只有 7G）。
