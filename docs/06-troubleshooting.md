# 06 · 故障排查速查

> 按"症状 → 根因 → 修法"组织。都是本项目实际踩过的。

---

## 启动 / 串口

| 症状 | 根因 | 修法 |
|---|---|---|
| 串口静默、无 IP、卡在 FSBL | eMMC 低区被写过，`hwsetting` 丢了 | 见 [`04-recovery.md`](04-recovery.md) |
| `switch bus width…success` 后 **315 ms** 才出残缺值 | 同上（正常应为 17 ms + `hwsetting size: 00000BE4`） | 同上 |
| 串口输出全是乱码 | ① 波特率不对；② 其实不是乱码 | 先跑 `tools/recovery/baudprobe.py`；`e2 96 88` 是 UTF-8 的 `█`，那是 fnOS 进度条 |
| 上电后一直停着 | 正常，启动要 ~60 s | 先看串口有没有输出，别只 ping |
| 改了 DTB 但板子行为没变 | DTB 没真正装进 p1 | 比对 md5：`md5sum build/rtd1296-cm360.dtb` vs 板上 `/mnt/emmc-boot/...` |

## 串口交互

| 症状 | 根因 | 修法 |
|---|---|---|
| 发送端一直收不到应答、疯狂重传 | **串口被第二个读者抢了**（每个字节只投递给一个进程） | `fuser -v /dev/ttyUSB0`；停掉采集代理 `tools/agent-ctl.sh stop`；关掉手动开的 `screen` |
| ROM Monitor 灌很久也进不去 | 用了满线洪流；或少于 3 个连续 `0x11` | 改稀疏（1 B / 30 ms），只发 `0x11` |
| `reboot` 后板子静默、只能断电 | 内核没有 restart handler | 确认 `patches/0004-wdt-restart.patch` 已应用 + DTS `&wdt` 为 `okay` |

## 内核 / 模块

| 症状 | 根因 | 修法 |
|---|---|---|
| `modprobe: FATAL: Module xxx not found in directory /lib/modules/...` | 全内置内核没有模块目录（**模块其实在**） | 跑 `scripts/deploy-modmeta.sh`（★ 它必须在**板上**跑 `depmod`，只拷文本无效） |
| 换了内核后一堆服务起不来 | 同上 | 同上 |
| `md: personality for level N is not loaded!` | `MD_RAID*` / `MD_LINEAR` 没开 | 见 [`02-kernel-and-dts.md`](02-kernel-and-dts.md) 配置表 |
| zram 报 `write error: Invalid argument` | 缺 `CRYPTO_LZ4`（zram0 只列 `lzo lzo-rle zstd`） | 同上 |
| `modprobe openvswitch` not found | 缺 `CONFIG_OPENVSWITCH` | 同上 |
| I2C/GPIO 寄存器读回全是 `0xdeadbeef` | 双段 `reg` 段序与驱动相反 | 对齐原厂 DTB 的段序 |
| 网口能协商、TX 有、**RX 恒 0** | 多写了原厂没写的属性（如 `output-mode`） | 删掉，用驱动默认值 |

## 存储

| 症状 | 根因 | 修法 |
|---|---|---|
| 两块盘只认到一块，`ata2: SATA link down` | 第二个盘位没上电（缺 `sata-gpios`） | 给 `sata-port@1` 加 `sata-gpios`（[`02`](02-kernel-and-dts.md) 有引脚号判据） |
| 建存储空间失败（所有类型） | 内核缺 mdraid personality | 开 `MD_RAID0/1/10`+`MD_LINEAR` |
| `[ERROR] zfs_create failed` | 选了 ZFS 型空间，但内核无 ZFS | 选非 ZFS 类型，或先编译 ZFS 模块（[`05`](05-storage-and-fnos.md)） |
| `mdadm --zero-superblock /dev/sdb3` 失败 | 分区已被重建，旧设备名不存在 | 一般是清理动作的噪音，不致命；确认失败点在别处 |

## 闪存 / 危险操作

| 症状 | 根因 | 修法 |
|---|---|---|
| **板子变砖** | 动了 eMMC 低区（`hwsetting` 在 `blk# 0x100`） | [`04-recovery.md`](04-recovery.md) |
| 想备份 SPI NOR | 空间已被原厂占 90%，写坏无法原地恢复 | 只读：`rtkspi read …; tftpput …`；**全程禁止写 SPI** |
| `saveenv` 以为会写 SPI | 实际写的是 **eMMC factory 区 `blk# 0x2100`** | 两者不是一回事，别被旧笔记误导 |

---

## 排查方法论（比具体条目更重要）

1. **先找同一台机器改动前的干净日志逐行对比。**
   本项目靠"300 ms vs 17 ms"的时序差把范围缩到 `hwsetting`。
2. **改变量要一次只改一个。**
   "稀疏 Ctrl+Q 成功、洪流失败"这种结论，是靠两种送法分别实测得到的；
   中间如果有两个变量同时变（比如同时换了送法**又**有第二个进程抢串口），
   结论就会错（本项目真的错过一次，见事故复盘第 3 节）。
3. **失败原因要落到机制上。** 有条件就去反汇编/读源码：
   "Ctrl+Q 必须 ≥3 个连续字节"是反汇编 bootcode 得来的，
   比"多按几次试试"这种经验可靠得多。
4. **别把"我加了配置"当成"配置生效了"。**
   构建脚本要逐项复核配置项，仪器要自证（`strings` / `objdump` / sysfs）。
5. **TX 与 RX 分开记录。** 把自发字节和回包写进同一个日志，
   会在"这个字节到底是谁发的"上白耗一轮。
