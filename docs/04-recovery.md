# 04 · 救砖：ROM Monitor 恢复

> 适用：板子卡在 FSBL / 串口静默 / 无 IP，u-boot 都进不去。
> 本项目实测走通过，**不需要编程器**。
>
> 原理一句话：Realtek RTD1296 的 **mask ROM 里带一个恢复控制台**
> （官方文档叫 On-Chip Recovery Mode，提示符 `d/g/r>`），
> 它能在 FSBL / u-boot 全坏的情况下通过串口重写引导链。

---

## 0. 先判断是不是这种情况

典型症状（本项目事故时的原始串口输出）：

```
C1:80000000
C2
?
C3hswitch frequency to 0x00000046
...
switch bus width to 0x00000008 bits success
0000001\xff              ← 正常这里应该是 "hwsetting size: 00000BE4"
C1:80000000              ← 退回 C1/C2 重启
C2
?uu3-1                   ← 死等，此后串口静默、无 IP
```

**判据**：`switch bus width … success` 之后本该 17 ms 内出现 `hwsetting size: 00000BE4`，
却变成几百毫秒后一个残缺值 → SoC 读不到 `hwsetting`。

原因基本只有一类：**动过 eMMC 低区**（`hwsetting` 存在 `blk# 0x100`，偏移 128 KiB）。

---

## 1. 准备

### 需要的文件

| 文件 | 说明 |
|---|---|
| `hwsetting`（如 `RTD1296_hwsetting_BOOT_4DDR4_4Gb_s1866_padding.bin`，3072 B） | 板级 DRAM/eMMC 启动配置 |
| `dvrboot.exe.bin`（约 1.32 MB） | eMMC 版 bootloader（含烧写程序） |

这两个文件来自 BPI-W2 / RTD1296 的官方恢复包。
**放哪都行，脚本用参数指定**；本仓库不转发（体积 + 来源许可）。

### 串口必须独占（★ 最容易栽的地方）

Linux 允许多进程打开同一 tty，但**每个字节只投递给一个读者**。
如果还有第二个读者（采集代理、手动开的 `screen`、另一个脚本），
它会**偷走板子的应答**，表现为"发送端一直收不到 ACK、疯狂重传"，
极易误判成协议或速率问题。

```bash
fuser -v /dev/ttyUSB0          # 必须为空
./tools/agent-ctl.sh stop      # 停掉串口采集代理
```

---

## 2. 进 Monitor（关键：稀疏 Ctrl+Q）

```bash
cd tools/recovery
python3 phoenix-monitor.py \
    --hwsetting /path/to/RTD1296_hwsetting_BOOT_4DDR4_4Gb_s1866_padding.bin \
    --dvrboot   /path/to/dvrboot.exe.bin \
    --tx-mode sparse --key-gap-ms 30 \
    --no-press-g                 # 先不烧写，确认无误再按 g
```

然后**给板子断电 → 等 5 秒 → 上电**。

### 为什么是"稀疏"而不是"洪流"

| 送法 | 结果 |
|---|---|
| 16 B / 4 ms（≈4000 B/s）连续洪流 | ❌ 从未进入 monitor |
| **1 B / 30 ms（≈33 B/s）稀疏** | ✅ 实测 **2055 ms** 打出 `d/g/r>` |

原因（ROM 反汇编所得，见 [`reports/`](reports/)）：

- ROM 把 UART 设为 `FCR=0xC7`（RX 触发级别 14 字节）+ `IER=0x01`（RX 中断使能），
  而**轮询前会先清空 RX FIFO**。4000 B/s 时 FIFO 每 ~3.5 ms 就撞触发线，
  轮询永远读不到"干净的连续 3 个 `0x11`"；33 B/s 时要 420 ms 才可能撞线。
- **必须连续 ≥3 个 `0x11`**（`cmp w19,#2; b.ls`），
  且**中间夹任何其它字节都会把计数清零** —— 这才是官方文档说"按住 Ctrl+Q"的真实含义。
- 窗口在板子打印 `\n?` 之后立刻打开；看到 `d/g/r>` 就**立刻停发**。

成功后的串口输出（本仓库 `evidence/logs/phoenix2-*.log` 有完整留档）：

```
[ 2667.5 ms] C1:80000000
[ 2667.5 ms] C2
[ 2717.9 ms] ?
[ 3120.4 ms] d/g/r>
[ 3170.7 ms] download to 0x80006020
[ 3724.0 ms] CCCCCC                       ← YMODEM 握手
[ 5185.9 ms] crc32:0xBB7E123F, len:0x00000C00   ← hwsetting 收完（24 块 ~2 s）
[ 8103.8 ms] 98007058 = 0x01500000       ← s：写 scratch 寄存器
[ 9712.8 ms] download to 0x01500000      ← d：从该寄存器取下载地址
```

### 官方流程（脚本自动执行）

| 步骤 | 动作 |
|---|---|
| 1 | 按住 Ctrl+Q（0x11）上电 → 出现 `d/g/r>` |
| 2 | `h` → YMODEM 发 hwsetting |
| 3 | `s` → 输入 `98007058` ↵ `01500000` ↵ |
| 4 | `d` → YMODEM 发 `dvrboot.exe.bin` |
| 5 | `g` → 开始烧写 |

> `s` 的语义容易误解：它是**写 32 位内存**，把 `0x01500000`（DRAM 装载地址）
> 写进 scratch 寄存器 `0x98007058`；后面的 `d`/`g` 都从该寄存器取值。

---

## 3. 按 `g` 之前的**强制校验**

YMODEM 收完后板子会自己打印 `len` / `crc32` / `checksum`。
**必须与本地独立计算比对通过再按 `g`** —— 不一致说明下载缓冲区里的映像已坏，
跳过去执行一个坏映像后果不可控。

```
hwsetting len 0xC00      crc32 0xBB7E123F   checksum 0x00036E1C
dvrboot   len 0x142AA8   crc32 0x36D9EB78   checksum 0x07ADA688
```

（`crc32` = `zlib.crc32`；`checksum` = 全部字节和的低 32 位。
两个值都按 YMODEM 头里声明的长度精确截断后计算，不含补齐字节。）

脚本只在 `--no-press-g` 未指定时才按 `g`；想手动控制可在同一会话里用：

```bash
python3 monitor-key.py --key 67 --secs 300     # 发 'g' 并记录烧写过程
```

烧写成功的标志（`evidence/logs/mon-g-*.log`，输出是乱码属正常 ——
burner 重设了 eMMC/UART 时钟）：

```
g → jump to 0x01500000 / 64b
write hwsetting   blk# 0x000100   size 0x00000BE4   → read back from UDA ✔
write bootcode    ...
write fsbl / fsbl_os / bl31   （逐个回读校验）
write data to UDA → read from UDA → flush
```

---

## 4. 恢复后

烧写完 burner 不会自动重启，**断电上电**即可。正常的话串口会重新出现
干净的 `hwsetting size: 00000BE4` → FSBL → u-boot。

```
C1:80000000 / C2 / ? / C3h... / switch bus width…success
hwsetting size: 00000BE4          ← ★ 干净的值回来了
C4 / f / 5-5 / s_f / 5-5-2
Goto FSBL: 0x10100000             ← ★ 成功交棒
...
U-Boot 2015.07 (Apr 27 2018 …)    ← 若刷的是 BPI-W2 的 bootloader
BPI-W2>
```

之后可能需要做的：

1. 在 u-boot 里把引导配置持久化（`setenv bootcmd/bootargs` + `saveenv`）；
2. 按 [`03-build-and-install.md`](03-build-and-install.md) 重新部署内核到 eMMC；
3. ★ **不要再动 eMMC 低区**。

---

## 5. 疑难

| 症状 | 原因 / 对策 |
|---|---|
| 灌了很久也没有 `d/g/r>` | ① 用了满线洪流 → 改稀疏（1 B/30 ms）；② 串口被第二个进程抢了；③ 计数被其它字节清零（确认只发 `0x11`） |
| 收到应答但疯狂重传 | 串口被抢占（`fuser -v /dev/ttyUSB0`），或 ACK 被另一个读者吃掉 |
| 单敲一次 Ctrl+Q 无效 | 正常：必须 ≥3 个连续字节 |
| 串口全是乱码 | 先排除波特率（`tools/recovery/baudprobe.py`）；也可能是 UTF-8 的块状字符（`█` = `e2 96 88`），那是 fnOS 的进度条，不是乱码 |
| 进不去 monitor，怀疑硬件 | 板上用户态/ROM 版本差异、或启动链门控寄存器不同。本项目**实测这条路可行**，先按上面排查 |
| burner 输出乱码 | 正常，它重设了 UART 时钟 |

> 备选路径（本项目未实测）：在 u-boot 可用时用 ESC/TAB 进 console 再刷；
> 或 USB 相关恢复模式。详见 [`reports/`](reports/) 里的调研记录。
