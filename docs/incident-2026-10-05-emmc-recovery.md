# CM360（RTD1296）移植 fnOS —— eMMC 阶段完整复盘（含救砖全记录）

> 生成时间：2026-10-05 07:00 ｜ **救砖完成：2026-10-05 07:45**
> 项目目录：`~/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/`
> 仓库：Gitea `Xiaoabiao/rtd1296-fnnas`（内网 `http://192.168.0.53:3000/`，外网 `http://xiaoabiao.f3322.net:3000/`）

---

> **关于本文中的路径**
> 这是一份**现场记录**，写于仓库重排之前，文中出现的 `stage0/` `stage1/` `stage2/`
> 是当时的目录名。对照表：
>
> | 当时 | 现在 |
> |---|---|
> | `stage2/<本文>` | `docs/incident-2026-10-05-emmc-recovery.md` |
> | `stage2/rtd1296-cm360.dts` | `boards/rtd1296-cm360/rtd1296-cm360.dts` |
> | `stage2/patches/` | `patches/` |
> | `stage2/logs/` | `evidence/logs/` |
> | `stage2/out/` | `build/` |
> | `stage0/` | `evidence/stage0/` |
> | `stage2/board/` | `boards/rtd1296-cm360/board-scripts/` |
> | `stage2/uboot/` | `boards/rtd1296-cm360/uboot-cmds/` |
> | `stage2/*.py`、`stage2/*.sh` | `tools/` 或 `scripts/` |
>
> ★ 注意：本文是**保留原始判断**的现场记录。文中"洪流导致失败"等早期结论
> 在写作过程中已被实测更正（真因是串口被第二个进程抢占，与洪流是两个独立问题）。
> 以 [`04-recovery.md`](../04-recovery.md) 与 [`06-troubleshooting.md`](../06-troubleshooting.md) 为准。

---

## 〇、结论速览（TL;DR）

| 项 | 结论 |
|---|---|
| **板子现状** | ✅ **已救回**：从 eMMC 独立启动 fnOS v1.1.31（根 = `mmcblk0p2` btrfs `e943d468-6d97-…`），有 IP、SSH/Web UI 在线 |
| **救砖路径** | ROM Monitor（Ctrl+Q）→ `h`/`s`/`d`/`g`，官方文档路径，**一次成功** |
| **成功的两个关键** | ① Ctrl+Q 必须**稀疏**（33 B/s），不是满线洪流；② 串口**必须独占**——手动开的 `screen` 会偷走 ACK |
| **u-boot** | 已换成 BPI-W2 的（`U-Boot 2015.07 (Apr 27 2018)`），env 已 `saveenv` 持久化 |
| **`reboot`** | ✅ **已修好**（2026-10-05 07:58，见第九节）：内核补 `.restart` 回调 + DTS 打开看门狗，实测两次 `reboot` 均自动复位重启，**不再需要手动断电** |
| **待办** | fnOS 若干板级服务失败（`set_gpio-init` / `led-set` / `pwm-fancontrol` / `ovs-vswitchd` / `zramswap` …）；DTS 其余外设（SDMMC/USB）

---

## 一、时间线（本轮全部动作）

| 时间 | 事件 | 结果 |
|---|---|---|
| 06:07~06:29 | 提取 `p1-boot.ext4`、eMMC 重新分区、`btrfs send/receive` 迁移根 | ✅ |
| 06:31~06:45 | 三次尝试抓 u-boot 改 SPI env | ❌ 板子卡死在 FSBL |
| 06:46~06:53 | 定位根因（hwsetting 被覆盖）、下载恢复文件、写 `phoenix_recover.py`（v1 满线洪流） | ❌ 三次尝试均未进 monitor |
| 07:04 | 串口无损嗅探 + TX 探针：排除线缆/自环 | ✅ |
| 07:09 | `screen` 抢串口导致首轮捕获失败（当时误判为 USB 抽风） | ❌ |
| **07:10:07** | **`20-phoenix-v2.py` 稀疏 Ctrl+Q（1B/30ms ≈ 33 B/s）** | **★ 2055 ms 进入 `d/g/r>`** |
| 07:10:16~07:11:07 | 同轮按 `h` 做 YMODEM | ❌ 每帧 3 s 超时、疯狂重传，monitor 26 s 后放弃 |
| 07:12~07:20 | 反汇编 ROM（`bootmon-new.bin`）+ 官方 PDF，定位机制 | ✅ |
| 07:20 | 发现 **`screen`(PID 1867206, 07:10:09 启动) 与脚本同抢 tty** | ✅ 真因 |
| **07:20:59~07:29:52** | **独占串口重跑：进 monitor → `h` 传 hwsetting（2 s）→ `s` → `d` 传 dvrboot（8.9 min）** | **★ 全部成功、零重传** |
| 07:30:54 | 按 `g` 触发烧写 | ✅ burner 写回整条引导链 |
| 07:35:02 | 断电上电 | **★ `hwsetting size: 00000BE4` 干净回归 → u-boot 起来了** |
| 07:36~07:40 | 侦察新 u-boot、从 eMMC 装载内核 + DTB、启动 fnOS | ✅ |
| 07:41:55 | `setenv` + `saveenv`（MAC/bootargs/bootcmd） | ✅ 持久化 |
| 07:47 | 实测 `reboot` | ❌ 系统关掉了但**拉不起复位**，只能手动断电 |
| 07:53~07:54 | 写 `patches/0004-wdt-restart.patch` + DTS 打开 `&wdt`，全量编译 | ✅ |
| 07:56 | 上传新内核/DTB 写入 eMMC p1（旧版先备份到 `out/emmc-boot-backup-20261005/`） | ✅ |
| **07:58 / 08:03** | **两次实测 `reboot`** | **★ 均自动复位并重新起来（`Reboot failed` 0 次）** |

---

## 二、事故复盘：为什么卡死在 FSBL（**已验证，结论不变**）

### 现象（可 100% 复现）
```
C1:80000000
C2
?
C3hswitch frequency to 0x00000046
frequency divider is 0x00000080
switch frequency to 0x00000046
frequency divider is 0x00000004
switch to SDR 8 bit
switch bus width to 0x00000008 bits success
0000001\xff + 34 个 \x00     ← 正常时这里是 "hwsetting size: 00000BE4"
C1:80000000                 ← 退回 C1/C2 重启
C2
?uu3-1                      ← 死等；此后串口静默、无 IP
```

### 三条独立证据钉死根因
1. **原厂 eMMC GPT 分区 1 就叫 `"uboot"`**（LBA 0x8000–0xbfff，8 MiB，无文件系统）；
   u-boot 打印过 `Factory: pp:1, seq#:0x10f, size:0x20400` —— `pp:1` = 分区 1
2. **`dvrboot.exe.bin` 的 strings**（决定性）：
   ```
   hwsetting: block 0x
   emmc: do_hide_hwsetting_e() read blk 0x     ← hwsetting 存在 eMMC 的"隐藏块"
   emmc: do_hide_hwsetting_e() write blk 0x
   hwsetting size:
   ```
3. **时序对比**（干净日志 `stage0/shot_uboot_01.log`，未擦盘、无洪流）：

   | | 擦盘前（正常） | 擦盘后（失败） |
   |---|---|---|
   | `switch bus width…success` → hwsetting | **17 ms** 打出 `hwsetting size: 00000BE4` | **315 ms** 打出残缺值 |
   | 之后 | `C4` → `Goto FSBL: 0x10100000` → u-boot | 退回 `C1/C2` 死等 |

### 结论（本轮救砖**实测印证**）
**RTD1296 把 `hwsetting`（DRAM/eMMC 启动配置）放在 eMMC 低区的"隐藏块"里。**
**本轮 burner 的日志给出了确切的块号：`blk# 0x100`（= 偏移 128 KiB）**，正好落在当初被清零的前 1 MiB 内。

> **教训：分区表之外 ≠ 空的。动闪存前必须先把前 16 MiB 整段 dump 留档。**
> 而且自造的"兜底数据"绝不能放进闪存低区。
> （本轮实测还确认：我们写的裸内核从 LBA 2048 起 72742 扇区，**完整覆盖了原厂 `uboot` 分区** LBA 0x8000–0xbfff。）

---

## 三、★ 救砖全记录（已执行成功）

### 3.1 三次失败 vs 一次成功：变量对照

| 轮次 | Ctrl+Q 送法 | 串口独占 | 结果 |
|---|---|---|---|
| v1 (`phoenix_recover.py`) | 16 B / 4 ms ≈ **4000 B/s** 满线洪流，240 s、5 万+ 次 | 否（两个脚本抢口） | ❌ 从未进 monitor |
| v2 第 1 次 (`20-phoenix-v2.py`) | **1 B / 30 ms ≈ 33 B/s** 稀疏 | **否（`screen` 在抢）** | ⚠️ 进了 monitor，但 YMODEM 全废 |
| v2 重跑 | 同上稀疏 | **是** | ✅ **全程成功** |

**两个变量必须同时成立**，缺一不可：

1. **稀疏是必须的**：ROM 把 UART 设成 `FCR=0xC7`（RX 触发级别 14 字节）+ `IER=0x01`（RX 中断使能），
   而**轮询前会先清空 RX FIFO**（`FCR←0x01→0x07`）。4000 B/s 时 FIFO 每 ≈3.5 ms 就撞触发线，
   轮询永远读不到"干净的连续 3 个 0x11"；33 B/s 时要 420 ms 才可能撞线。
2. **独占是必须的**：Linux 下 tty 允许多进程打开，但**每个字节只投递给一个读者**。
   一旦有第二个读者（手动 `screen`、另一个脚本、采集代理），
   **板子回的 ACK 会被另一个进程吃掉** → 发送端只能看到 "None" → 疯狂重传 → 把 monitor 拖到超时。
   这与 v1 的"洪流"是两个**完全独立**的失败原因，上一版复盘把后者也归给了洪流，是错的。

### 3.2 成功那轮的实测时序（`logs/phoenix2-1005-072059-timeline.log`）

```
[ 2667.5 ms] C1:80000000
[ 2667.5 ms] C2
[ 2717.9 ms] ?                    ← 窗口在这里打开（ROM 轮询前清 FIFO）
[ 3120.4 ms] d/g/r>               ← ★ 进入 Phoenix Monitor
[ 3170.7 ms] download to 0x80006020
[ 3724.0 ms] CCCCCC               ← YMODEM 握手（接收端要 'C'）
[ 5185.9 ms] checksum:0x00036E1C
[ 5185.9 ms] crc32:0xBB7E123F, len:0x00000C00   ← hwsetting 收到，24 块仅 ~2 s
[ 8103.8 ms] 98007058 = 0x01500000              ← `s` 写 scratch 寄存器成功
[ 9712.8 ms] download to 0x01500000             ← `d` 从该寄存器取下载地址
[533000.5 ms] checksum:0x07ADA688
[533050.8 ms] crc32:0x36D9EB78, len:0x00142AA8  ← dvrboot 1.32 MB 收完，10326 块零重传
[533702.4 ms] d/g/r>                            ← 回到提示符等 `g`
```

### 3.3 校验：板子自算 vs 本地独立计算（**全部一致**）

| 项目 | 板子报的值 | 本地计算 | 结论 |
|---|---|---|---|
| hwsetting `len` | `0x00000C00` = 3072 | 3072 | ✔ |
| hwsetting `crc32` | `0xBB7E123F` | `zlib.crc32` = `0xBB7E123F` | ✔ |
| hwsetting `checksum` | `0x00036E1C` | 字节和 = `0x00036E1C` | ✔ |
| dvrboot `len` | `0x00142AA8` = 1321640 | 1321640 | ✔ |
| dvrboot `crc32` | `0x36D9EB78` | `zlib.crc32` = `0x36D9EB78` | ✔ |
| dvrboot `checksum` | `0x07ADA688` | 字节和 = `0x07ADA688` | ✔ |

> 两个校验值都落在**未补齐**的原始长度上（补齐 88 B 后 CRC 是 `0x19A67FFD`），
> 说明接收端按 YMODEM 头里声明的长度精确截断——逻辑正确，**1.32 MB 零误码**。

★ **按 `g` 之前必须做这一步**：CRC 不一致说明下载缓冲区里的映像已坏，
跳过去执行一个坏映像后果不可控。

### 3.4 `g` 之后 burner 干了什么（`logs/mon-g-1005-073054.log`）

```
g → jump to 0x01500000 / 64b            ← 读 0x98007058 取跳转地址，64 位跳转
[  753 ms] write hwsetting   blk# 0x000100   size 0x00000BE4   → read back from UDA ✔
[  853 ms] write bootcode    ...
[ 1354 ms] write fsbl_s...   fsbl_size ...   read back 0x000119 ✔
[ 1605 ms] write fsbl_os     blk# 0x000005   size 0x0007BD80   read back 0x000083 ✔
[ 2107 ms] write bl31        blk# ...62      size ...280       read back ✔
[ 2157 ms] write data to UDA → read from UDA → flush
```

写回内容与早先逆向出的 `bind.bin` 结构一致（hwsetting + uboot + fsbl + fsbl-os + bl31
写进分区表之前的裸引导区），**每一步都有回读校验**。

> 输出是乱码：burner 重设了 eMMC/UART 时钟（碎片里能看到 `switch frequency` / `frequency divider`），
> 波特率偏离 115200。信息仍可从乱码中辨识，不必为此调整。

### 3.5 恢复后的启动（`logs/bootcap-1005-073502.log`，**6591 B 全干净 ASCII、零乱码**）

```
C1:80000000 / C2 / ? / C3hswitch… / switch bus width…success
hwsetting size: 00000BE4          ← ★ 干净的值回来了（同一条行、同一节奏）
C4 / f / 5-5 / s_f / 5-5-2
Goto FSBL: 0x10100000             ← ★ 成功交棒
Welcome to FSBL ... → FW_TYPE_GOLD_TEE → FW_TYPE_GOLD_BL31 → FW_TYPE_BOOTCODE
NOTICE: BL31: v1.2(debug) ... Apr 27 2017
U-Boot 2015.07 (Apr 27 2018 - 09:10:25 -0700)      ← ★ 全新的 BPI-W2 u-boot
DRAM: 2 GiB ｜ eMMC 8GTF4 7.3 GiB HS200 ｜ SPI S25FL064K_4s 8 MB
... 扫 USB/SD 救援镜像失败 ...
Enter console mode, disable watchdog ...
BPI-W2>
```

### 3.6 从 eMMC 独立启动 fnOS

```
$ mmc part                        → p1@77824(524288 扇区, Boot)  p2@602112(14665728)
$ ext4ls mmc 0:1 /                → Image-6.6.uimage (37243456 B) + rtd1296-cm360.dtb (7424 B)
$ ext4load mmc 0:1 0x03000000 Image-6.6.uimage   → 37243456 bytes read in 2243 ms (15.8 MiB/s)
$ ext4load mmc 0:1 0x02100000 rtd1296-cm360.dtb  → 7424 bytes
$ bootm 0x03000000 - 0x02100000
    → fnOS v1.1.31 / Hostname: Xiaoabiao / Web UI: http://192.168.1.164:5666
    → VFS: Mounted root (btrfs filesystem); BTRFS device mmcblk0p2 e943d468-6d97-…
```

**关键结论：eMMC 上 38 MiB 之后的 p1/p2 完好无损，`kernels + fnOS 根` 根本不用重做。**
（burner 只写了最前面几 MiB 的裸引导区。）

### 3.7 持久化（`logs/ubcmd-1005-074155.log`）

```
setenv ethaddr 02:cc:cd:ed:2a:20        ← 恢复原厂 MAC（BPI 默认值会覆盖成 00:10:20:30:40:50）
setenv bootargs 'earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 loglevel=7 \
                 root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root rootwait rw'
setenv bootcmd 'echo === FNOS-BOOT ===; ext4load mmc 0:1 0x03000000 Image-6.6.uimage; \
                ext4load mmc 0:1 0x02100000 rtd1296-cm360.dtb; bootm 0x03000000 - 0x02100000'
saveenv
  → Saving Environment to FACTORY...
    [FAC] Save to eMMC (blk#:0x2100, buf:0x07000000, len:0x20a00)
    [FAC] Save to eMMC (seq#:0x1, pp:1)
    done
printenv → 三个变量均已生效；`run bootcmd` 实测直接起好 fnOS
```

> env 落在 eMMC **blk# 0x2100（约 4.1 MiB）**、长度 `0x20a00`、`pp:1` —— 在 p1（38 MiB）之前，
> **不会碰 fnOS 的根**。

---

## 四、ROM Monitor 机制（反汇编 Realtek 官方 GPL bootcode 所得）

证据：`github.com/Spitzbube/rtd1295-bootloader` 的 `bootimage/bootmon-new.bin`
（AArch64，装载基址 `0x80000000`，编译路径 `/home2/ericwu/work/Kylin/romcode/src/bin`）。

1. **按键是 Ctrl+Q（0x11）**，另接受 `0x81` 与 **`0x12`(Ctrl+R，备用键)**；ESC 与此无关。
2. **必须 ≥3 个连续字节**：`cmp w19,#2; b.ls 继续轮询`，且**任何其它字节把三个计数器全部清零**
   → 单敲一次必然失败，这才是文档说"按住不放"的真正原因。
3. **窗口在板子打印 `\n?` 之后立刻打开**，且**轮询前先清空 RX FIFO**。
   rodata 逐字节对齐：`"\nC1:"` / `"\nC2"` / `"\n?"` / `"\nC3"` / `"h"` / `"\nhwsetting size: "` / `"\nd/g/r>"`
   —— 这也解释了日志里那个怪串 `C3h`（`"C3"` 与 `"h"` 是两条独立字符串）。
4. **串口 115200 8N1、流控 NONE**（DLL=15，从未写 MCR）。
   ROM 却设了 `FCR=0xC7`（RX 触发 14 字节）+ `IER=0x01`（RX 中断使能）。
5. **`s` = 写 32 位内存**：`s98007058` + `01500000` = 把 `0x01500000` 写进 scratch 寄存器 `0x98007058`；
   `d` 从该寄存器取下载地址（无效则回退 `0x20000`），`g` 从该寄存器取跳转地址。
   `0x01500000` 就是 SDK `Makefile` 里的 `LOAD_ADDR`。
6. **bootmon 里没有任何 SD 初始化字符串**（只有 `start spi init.` / `start emmc init.`）。
   ⚠️ 因此早先"hwsetting 可以放 SD 卡"的线索是**误读**：BPI 论坛那句 `sd write 0x1500000 0x50 0x3f0`
   是把 **SD 版 `u-boot.bin` 写到 SD 卡 LBA 0x50**，而 `sd write` 是 **U-Boot 命令**，需要活着的 U-Boot。

---

## 五、eMMC 现在的布局（实测）

| 位置 | 内容 | 来源 |
|---|---|---|
| blk# 0x100（128 KiB） | **hwsetting**（size `0xBE4`） | burner 写回 |
| blk# 0x2100（≈4.1 MiB） | **u-boot env / factory 区**（len `0x20a00`，pp:1） | `saveenv` |
| 裸引导区其余 | bootcode + FSBL + FSBL_OS + BL31 | burner 写回 |
| LBA 77824（38 MiB） | p1 **ext4** 256 MiB `LABEL=BOOT` | 事故前所写，**完好** |
| LBA 602112（294 MiB） | p2 **btrfs** 6.99 GiB（`subvol=/root`，`e943d468…`） | 事故前所写，**完好** |

> ⚠️ 我们当初写的"兜底裸内核"（LBA 2048 起 72742 扇区）**已被 burner 覆盖**，
> 这类自造数据**永远不要再放进闪存低区**。

---

## 六、本轮新增文件与工具

### 上板 / 调试
| 文件 | 用途 |
|---|---|
| `stage2/18-monsniff.py` | 串口**无损**嗅探（不发一个字节，不拉 DTR/RTS），输出唯一字节直方图 |
| `stage2/19-txprobe.py` | TX 方向探针（自环检测 + 0x11 回声计数） |
| `stage2/20-bootcap.py` | **纯被动**启动基线捕获（带毫秒时间戳 + 原始字节 + 直方图） |
| `stage2/20-phoenix-v2.py` | **救砖主力**：稀疏 Ctrl+Q + TX/RX 分离记录 + 抗 USB 重枚举自动重连 |
| `stage2/21-mon-lab.py` | 在 monitor 内做 YMODEM 协议实验（多种速率/包型逐帧试） |
| `stage2/22-mon-g.py` | 补发按键（默认 `g`）并记录烧写过程 |
| `stage2/23-ubcmd.py` | **新 u-boot（BPI-W2）**命令行交互器，支持 `--wait-prompt` 等断电上电 |
| `stage2/24-baudprobe.py` | 逐个候选波特率试读串口并打分（排除"乱码=波特率错位"这类误判） |
| `stage2/brd-ssh.sh` | 上板 SSH 助手（替代 `brd.py`；本机只有 py3.14，paramiko 却是给 3.13 装的）。`run`/`sudo`/**`put`**/**`get`**/`shell` |
| `stage2/patches/0004-wdt-restart.patch` | **修 `reboot`**：给 `rtd119x_wdt` 加 `.restart` 回调（见第九节） |

### 参考资料
| 文件 | 来源 |
|---|---|
| `stage2/refs/RTD1619_RTD129x_Bootcode.pdf` / `.txt` | Realtek 官方 bootcode 文档（Ctrl+Q / `d/g/r>` / `h`,`s`,`d`,`g` 流程出处） |
| （**未入库**：文档标注 "Realtek Confidential"，公开仓库不转发；URL 见文末） | |

### 关键证据日志（`stage2/logs/`）
| 文件 | 内容 |
|---|---|
| `phoenix2-1005-071007-*` | 稀疏 Ctrl+Q **首次进入 monitor**（2055 ms） |
| `phoenix2-1005-072059-*` | **成功那轮**完整时序（进 monitor → `h` → `s` → `d`） |
| `mon-g-1005-073054.log` | `g` 之后 burner 写回整条引导链 |
| `bootcap-1005-073502.log` | **恢复后干净启动**（hwsetting 00000BE4 → u-boot） |
| `ubcmd-1005-073641.log` | 从 eMMC 启动 fnOS |
| `ubcmd-1005-074155.log` | `setenv` + `saveenv` 持久化 |
| `bootcap-1005-075741.log` | **`reboot` 修复后的第一次重启**（关机 → 1~2s 复位 → 全新启动；`Reboot failed` 0 次） |

---

## 七、踩坑速查（本轮新增，接上一版）

16. ★★ **串口必须真独占**：不只是"两个恢复脚本抢口"，**手动开的 `screen` / 串口终端同样会偷走 ACK**。
    症状是"发送端一直收不到应答、疯狂重传"，极易误判为协议/速率问题。
    **动手前先 `fuser -v /dev/ttyUSB0`**。
17. ★★ **Ctrl+Q 正确形态是稀疏单字节（20~40 ms 一颗），不是满线洪流**；ROM 轮询前清 FIFO。
18. ★ **必须 ≥3 个连续 Ctrl+Q**，中途夹任何其它字节会清零计数。
19. ★ **TX/RX 必须分开记录**。上一版把自发字节和板子回包写进同一个日志，
    导致"52104 个 0x11 是谁发的"这种分析黑洞白耗一轮（0x44/0x14 其实是 0x11 波形
    在帧偏移 2/6 处的错位解码，即自发自收的耦合产物）。
20. ★ **`s98007058` 是"写内存"不是"读"**：它把 `0x01500000` 写进 scratch 寄存器，
    后面的 `d`/`g` 都从该寄存器取值。
21. ★ **按 `g` 之前先核对 `len` + `crc32` + `checksum`**（板子会自己算并在 YMODEM 收完后打印），
    与本地独立计算结果比对通过再烧。
22. ★ **`reboot` 曾会挂死**（关得掉系统、拉不起复位）：板子静默、网络消失、串口无输出，
    只能手动断电。**根因与修法见第九节**（已修复，实测两次 reboot 均自动重启成功）。
23. ★ 换 u-boot 后 MAC 会从 `02:cc:cd:ed:2a:20` 变成 BPI 默认的 `00:10:20:30:40:50`，
    DHCP 租约随之从 `.173` 变 `.164`。两层原因：u-boot 默认 env 里有 `ethaddr`，
    而 **fnOS 自己也跑了一个 `system_setmac.service`（"Set stable MAC addresses from MMC CID"）**——
    MAC 最终由 fnOS 按 eMMC CID 设定。在 u-boot 里 `setenv ethaddr <原厂 MAC>` + `saveenv` 可固定。
24. ★ **`pgrep -f <脚本名>` 会匹配到调用者自己的命令行**（老坑，本轮又踩一次：
    `pgrep -af 'phoenix_[r]ecover|serial_agent'` 命中的是它自己那条 `bash -c`）。
    用 `/proc` 遍历 + `comm` 判断更稳（`agent-ctl.sh` 就是这么做的）。
25. ★ **判断"板子是死了还是在启动"别只看一次 ping**：救砖后第一次上电，
    我在 45 秒时 ping 不通就以为失败，实际 fnOS 要 **~60 秒**才把网络拉起来
    （SATA 盘 spin-up + 一堆 systemd 服务）。**先看串口有没有进度条，再下结论。**
26. ★ **串口出现 `e2 96 88` 这类字节不要误判成波特率错位**：那是 UTF-8 的 `█`，
    fnOS 开机横幅/进度条就是这么打的（`24-baudprobe.py` 可用来排除真正的波特率问题）。

---

## 八、当前状态与下一步

### 已达成
- ✅ **板子救回**：ROM Monitor 写入成功，`hwsetting` 恢复（`00000BE4` 干净回归）
- ✅ **eMMC 独立启动**：BPI-W2 u-boot → 从 p1 取内核/DTB → p2 btrfs 根 → **fnOS v1.1.31 在线**
- ✅ **持久化**：`bootcmd`/`bootargs`/`ethaddr` 已 `saveenv`
- ✅ **`reboot` 已修好**：内核补 restart 回调 + DTS 打开看门狗，两次实测自动重启成功（见第九节）
- ✅ **网络可用**：SSH(22) / Web UI(5666) / 80 / 443 全通（当前 IP `192.168.1.173`）
- ✅ 里程碑未受影响：fnOS 启动、eMMC 完整系统、内核 6.6.54 + 自写 DTS 四核/SATA/eMMC/eth0

### 下一步（按优先级）
1. ★ **板级 systemd 服务收尾**：开机日志里有一批 FAILED，多数是群晖/原厂专用服务在这块板上无对应硬件：
   `set_gpio-init`（GPIO 初始化）、`led-set`（LED）、`pwm-fancontrol`（风扇）、
   `ovs-vswitchd`/`openvswitch`（Open vSwitch）、`zramswap`、`smartmontools`、`wsdd2`。
   逐个确认该修还是该禁用（`fnos-cleanup.sh` 就是干这个的）。
2. 补 DTS 其余外设：SDMMC、USB（当前 USB 扫描有 `Unknown request, typeReq = 0x200c` 噪声）。
3. 注意启动耗时：到网络可用约 **60 秒**（SATA spin-up + 服务），别误判为失败。
4. （可选）把 `20-phoenix-v2.py` 的 `Mon2.ser.timeout` 从 50 ms 降到 5 ms：
   dvrboot 传输可由 8.9 min 提速到约 2 min（当前每块被读超时粒度卡在 19.8 块/秒）。

---

## 九、`reboot` 修好记（2026-10-05 07:58）

### 现象
`reboot` 后内核把系统关干净（systemd-shutdown 打完 "All filesystems unmounted"），
然后**什么都没发生**：串口静默、网络消失、板子再不起来，只能手动断电。

### 根因
arm64 的 `machine_restart()` 在没有任何 restart handler 时走兜底分支：

```c
	do_kernel_restart(cmd);
	mdelay(1000);
	pr_emerg("Reboot failed -- System halted\n");
	while (1);
```

而这台板子上**恰好一个 handler 都没有**：
- CPU 用 `enable-method = "spin-table"`（**不是 PSCI**），设备树里也**没有 psci 节点**（原厂 DTB 同样没有）；
- 内核树里没有 Realtek 的 `rtk-rstctrl` / SoC restart 驱动（`drivers/soc/realtek/` 是空的）；
- `rtd119x_wdt` 驱动**没有 `.restart` 回调**，而且它自己调了 `watchdog_stop_on_reboot()`；
- DTS 里 `&wdt` 被**显式关掉**（`status = "disabled"`，当初为排查"跑几十秒神秘重启"）。

### 修法（两层，缺一不可）

**① 内核侧** `patches/0004-wdt-restart.patch`：给 `drivers/watchdog/rtd119x_wdt.c` 加：

```c
static int rtd119x_wdt_restart(struct watchdog_device *wdev,
			       unsigned long action, void *data)
{
	struct rtd119x_watchdog_device *wdata = watchdog_get_drvdata(wdev);

	writel_relaxed(clk_get_rate(wdata->clk), wdata->base + RTD119X_TCWOV);  /* 1s */
	writel_relaxed(RTD119X_TCWTR_WDCLR, wdata->base + RTD119X_TCWTR);       /* 清计数 */
	rtd119x_wdt_start(wdev);                                               /* 使能后不再喂狗 */
	mdelay(3000);                                                          /* 等硬件复位 */
	return 0;
}
```

外加 `.ops.restart = rtd119x_wdt_restart`、`watchdog_set_restart_priority(&wdd, 128)`
和 `#include <linux/delay.h>`（`mdelay` 需要，第一次编译就栽在这）。

关键点：`watchdog_core.c` 只要看到 `wdd->ops->restart` 非空就会
`register_restart_handler()`，而且它的 restart notifier **不检查 watchdog 是否 active**——
所以即使没人打开 `/dev/watchdog`，`reboot` 也能走到这里。

**② DTS 侧** `rtd1296-cm360.dts`：把 `&wdt` 改回 `status = "okay"`，驱动才会 probe。

**地址核对**：该节点在 `&iso`（`syscon@7000`，父总线 `rbus` 基址 `0x98000000`）下 `reg = <0x680>`
⇒ 实际 `0x98007680`，与**原厂 DTB** 的 `watchdog@0x98007680` 一致；
运行时 sysfs 也印证了这一点：
```
watchdog0 -> .../98000000.bus/98007000.syscon/98007680.watchdog/watchdog0
```

### 实测证据（两次）
```
# 关机阶段（串口）
systemd-shutdown[1]: Using hardware watchdog 'rtd119x-wdt', version 0, device /dev/watchdog0
systemd-shutdown[1]: All filesystems unmounted.
   ↓ 1~2 秒内完成复位（不是 systemd 那个 2min 超时，是我们回调设的 1s）
# 之后
[  116.647469] md: md0 stopped.        ← 全新一轮内核启动
OS version: fnOS v1.1.31 / IPv4 for eth0: 192.168.1.173
```
- 第一次：捕获日志中 `Reboot failed` 出现 **0 次**；`uptime` 归零、网络自动恢复。
- 第二次：同样成功（`up 0 min`、eth0 `192.168.1.173/24`、`watchdog0` 已注册）。
- ⚠️ 注意 fnOS 到网络可用约 **60 秒**，45 秒时 ping 不通是正常的。

### 部署方式（可复用）
```bash
./04-build-66.sh                       # 全量编译（改了驱动 C 代码，必须全量）
./mk-uimage.py out/Image-6.6 out/Image-6.6.uimage 0x03000000
./brd-ssh.sh sudo 'mount /dev/mmcblk0p1 /mnt/emmc-boot'
./brd-ssh.sh get  '/mnt/emmc-boot/Image-6.6.uimage' out/emmc-boot-backup-20261005/   # ★ 先备份
./brd-ssh.sh put  out/Image-6.6.uimage /tmp/Image-6.6.uimage.new
./brd-ssh.sh sudo 'cp /tmp/Image-6.6.uimage.new /mnt/emmc-boot/Image-6.6.uimage && sync && umount /mnt/emmc-boot'
```
（`brd-ssh.sh` 本轮新增了 `put` / `get` 两个子命令，基于系统 `scp` + `SSH_ASKPASS`。）

---

## 附：关键来源 URL

- Realtek 官方 bootcode 文档（Ctrl+Q / `d/g/r>` / `h/s/d/g`）：
  <https://cdn.jsdelivr.net/gh/jjm2473/jjm2473.github.io@master/assets/files/RTD1619_RTD129x_Bootcode.pdf>
- Realtek GPL 释放的 bootcode 源码/二进制（`bootmon-new.bin` 反汇编来源）：
  <https://github.com/Spitzbube/rtd1295-bootloader>
- BPI-W2 官方文档（"按住 ctrl+q"语义、`s98007058` 写法）：
  <https://bananapi.gitbook.io/banana-pi-bpi-w2-with-realtec-rtd1296/bpi-w2-software/openwrt>
- 中文实操（"ctrl+q 手动大法"分解动作、115200 8N1 None、TTL 线要接好）：
  <https://bbs.nasdiyer.com/forum.php?mod=viewthread&action=printable&tid=10032>
