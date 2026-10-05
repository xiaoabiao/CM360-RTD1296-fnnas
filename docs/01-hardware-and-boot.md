# 01 · 硬件与启动链

## 1. 硬件概要

| 项 | 值 |
|---|---|
| SoC | Realtek **RTD1296**（4× Cortex-A53 @1.4 GHz，2 GiB DDR4） |
| eMMC | Samsung **8GTF4**，7.28 GiB，HS200 8-bit（CID 实测 `8GTF4R`） |
| SATA | 2 端口（AHCI 兼容，6 Gbps） |
| 网络 | 内嵌 GPHY 千兆（`r8169soc`） |
| SPI NOR | **S25FL064K_4s**，8 MiB（原厂固件占约 90%） |
| 串口 | UART0 `0x98007800` @ 115200 8N1 |
| 原厂机型标识 | `syno_hw_version=DS218`（原厂 u-boot 环境变量） |

内核地址空间里的关键块（都用得上）：

```
0x98000000  CRT（时钟/复位）        0x9803f000  SATA(AHCI)   0x9803ff60  SATA PHY
0x98007000  ISO（含 GPIO/看门狗）   0x98007680  看门狗        0x98007100  ISO GPIO
0x98007800  UART0                  0x9801a000  SB2          0x9801b000  MISC
0x9801b100  MISC GPIO              0x98016000  GMAC
```

---

## 2. 启动链

```
上电
 │
 ├─ mask ROM（片内）
 │    ├─ 初始化 eMMC → 从**隐藏块**读 hwsetting（blk# 0x100）
 │    ├─ 打印 C1:80000000 / C2 / ? / C3 + eMMC 频率与位宽切换
 │    ├─ 打印 "hwsetting size: 00000BE4" → C4
 │    └─ Goto FSBL: 0x10100000
 │
 ├─ FSBL
 │    ├─ 再切一次 eMMC 频率/位宽、做 PHY 训练
 │    ├─ 加载 BL31（ARM Trusted Firmware v1.2）+ TEE(OP-TEE)
 │    └─ 加载 BOOTCODE（u-boot / dvrboot）到 0x00020000
 │
 ├─ u-boot（本项目现状：BPI-W2 的 2015.07 / Apr 27 2018）
 │    ├─ 串口 ESC/TAB 可进 console（窗口只有 ~16 ms，命中率约 79%）
 │    └─ 执行 bootcmd
 │
 └─ Linux 6.6.54（本项目）
      ├─ 内核：eMMC p1（ext4）里的 Image-6.6.uimage
      ├─ DTB ：同上 rtd1296-cm360.dtb
      └─ 根   ：eMMC p2（btrfs，`subvol=/root`）
```

### 关于 `C1/C2/C3` 那串输出

它们由 **bootcode**（不是 mask ROM 的 printf）打印，字符串逐一对应：

```
"\nC1:"  "\nC2"  "\n?"  "\nC3"  "h"  "\nhwsetting size: "  "\nd/g/r>"
```

注意 `C3h` 是**两条独立字符串拼在一起**（`"\nC3"` + `"h"`），不是笔误。
`\nd/g/r>` 就是 ROM Monitor 提示符（见 [`04-recovery.md`](04-recovery.md)）。

### 正常 vs 变砖的判据

| | 擦盘前（正常） | 变砖 |
|---|---|---|
| `switch bus width … success` → hwsetting | **17 ms**，打印 `hwsetting size: 00000BE4` | **315 ms**，打印残缺值 `0000001\xff` |
| 之后 | `C4` → `Goto FSBL` → u-boot | 退回 `C1/C2`，`?uu3-1` 死等 |

---

## 3. eMMC 布局（本项目）

```
blk# 0x100  (128 KiB)   hwsetting            ← mask ROM 读它，★ 绝对不能碰
blk# 0x2100 (~4.1 MiB)  u-boot 环境          ← saveenv 落点
低区其余                 bootcode/FSBL/BL31  ← ROM Monitor 的 h/g/s/d 写这里
LBA 77824   (38 MiB)    p1  ext4 256 MiB LABEL=BOOT   ← 内核 + DTB
LBA 602112  (294 MiB)   p2  btrfs 6.99 GiB LABEL=rootfs
```

> ⚠️ **纪律**：分区表之外 ≠ 空的。
> 动 eMMC 之前先把**前 16 MiB 整段 dump 留档**；
> 自造的"兜底数据"（比如裸内核）**绝不能放进低区**。
> 本项目当初正是把 37 MB 裸内核写在 LBA 2048 起，覆盖了低区配置。

原厂分区表（事故前，供恢复参考）：

```
Part  Start LBA   End LBA     Name        Type
  1   0x00008000  0x0000bfff  "uboot"     EFI（8 MiB，无文件系统）
  2   0x0000c000  0x0010bfff  "primary"   EFI
```

---

## 4. SPI NOR

8 MiB，原厂放四段镜像（DTB 0x0 / 音频 0xC0000 / 内核 0x100000 / rootfs 0x3F0000，
合计约 90.6%）。原厂 u-boot 的 `bootcmd` 就是从 SPI 读内核。

**本项目全程禁止写 SPI**（空间已满，写坏无法原地恢复）。
只读备份方法（u-boot 里）：

```
rtkspi read 0x0 0x06000000 0x800000      # 整片到内存
tftpput 0x06000000 0x800000 spi-full.bin # 回传到 TFTP
```

---

## 5. 串口

- 设备 `/dev/ttyUSB0`（CH340 即可），115200 8N1，**流控必须 NONE**
  （`0x11`/`0x13` 是有意义的数据）。
- 权限：把用户加进 `dialout`，或跑 `tools/serial/fix-serial-perm.sh`。
- 只读嗅探：`tools/serial/monsniff.py 15`（不发任何字节，也不拉 DTR/RTS）。
- 采集代理：`tools/serial/serial_agent.py`（命令队列 + 输出留档），
  由 `tools/agent-ctl.sh` 控制启停。**恢复脚本要独占串口，必须先 stop。**
