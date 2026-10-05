# CM360（RTD1296）移植 fnOS

小睿 CM360 NAS 盒子 —— Realtek **RTD1296**（4× Cortex-A53、2 GiB DDR4、8 GiB eMMC、
原生双 SATA、千兆网口）上跑 **飞牛 fnOS** 的移植工程。

本仓库记录**完整的方法论、取证过程与可复现的产物**：不只放结果，
更放"为什么这么改"的证据链，以及踩过的每一个坑。

> ### ⚠️ 2026-10-05：板子曾被打成砖，当天已完整救回
> 清空 eMMC 低区时覆盖了 SoC 的 **`hwsetting`**（藏在 `blk# 0x100`），板子卡死在 FSBL。
> 当天用 **ROM Monitor（Ctrl+Q → `h`/`s`/`d`/`g`）** 走官方恢复路径救回，
> 全过程（含三次失败与一次成功的对照、ROM 反汇编、YMODEM 校验）见
> **`stage2/CM360移植fnOS_eMMC阶段完整复盘_2026-10-05.md`**。

---

## 当前进度

| 子系统 | 状态 | 关键证据 |
|---|---|---|
| 串口 / 内存 / GIC / 时钟 | ✅ | |
| **SMP 四核** | ✅ | `smp: Brought up 1 node, 4 CPUs`；`online=0-3`、`nproc=4` |
| **SATA（12 TB）** | ✅ | `ata1: SATA link up 6.0 Gbps`、`HUH721212ALE600` 23437770752 扇区 |
| **eMMC（HS200）** | ✅ | `mmcblk0` 7.28 GiB、HS200、寿命健康 |
| **eth0（原生 GMAC）** | ✅ | ping 0% 丢包、31.5 MB 传输 md5 一致 |
| **eMMC 独立启动** | ✅ | BPI-W2 u-boot → p1 取内核/DTB → p2 btrfs 根，**不再依赖 TFTP/SATA** |
| **fnOS 运行** | ✅ | `fnOS v1.1.31`、SSH(22)/Web UI(5666)/80/443 全通，IP `192.168.1.173` |
| **`reboot`** | ✅ | 内核补 restart 回调 + DTS 打开看门狗，实测两次自动复位重启 |
| SDMMC / SDIO | ⬜ | 驱动已在 `.config`，**只缺 DTS 节点** |
| USB3 | ⬜ | 驱动已在 `.config`，**只缺 DTS 节点 + PHY 时序** |
| fnOS 板级服务收尾 | ⬜ | `set_gpio-init`/`led-set`/`pwm-fancontrol`/`ovs-vswitchd` 等 FAILED |

**事故+救砖完整复盘**：`stage2/CM360移植fnOS_eMMC阶段完整复盘_2026-10-05.md`
**详细可行性结论**：`stage2/移植可行性评估.md`
**SMP 攻关全过程**：`stage2/logs/SMP-SUCCESS-REPORT.md`

---

## 现在的板子（直接可用）

- **上电即启动**：u-boot 已换成 BPI-W2 的（`U-Boot 2015.07 (Apr 27 2018)`，提示符 `BPI-W2>`），
  `bootcmd`/`bootargs` 已 `saveenv` 持久化 —— 从 eMMC p1 取内核/DTB，根指向 p2 btrfs。
- **网络**：`192.168.1.173`（MAC 由 fnOS 的 `system_setmac.service` 按 eMMC CID 设定）；
  SSH / Web UI `http://192.168.1.173:5666`。
- **上板方式**（本机 paramiko 缺失，改用系统 ssh）：
  ```bash
  cd stage2
  ./brd-ssh.sh run  'uptime'          # 普通命令
  ./brd-ssh.sh sudo 'lsblk'           # sudo（自动喂密码）
  ./brd-ssh.sh put  out/Image-6.6.uimage /tmp/x   # 上传
  ./brd-ssh.sh get  /mnt/emmc-boot/rtd1296-cm360.dtb ./  # 下载
  ```
  凭据仍读 `~/.brd_cred`（用户名/密码/IP/端口，**不入库**）。
- **启动需要耐心**：到网络可用约 **60 秒**（SATA spin-up + 一批 systemd 服务），
  别用一次 ping 就判死。
- **更新内核**：`./04-build-66.sh` → `./mk-uimage.py` → 挂 `mmcblk0p1` 覆盖两个文件
  （**先 `get` 备份旧版**，步骤见复盘文档第九节）。

---

## 技术路线

**A′ 路线**：`XpressReal/linux` **6.6.54** vendor 树 + 自写板级 DTS。

选它的理由：该树是 Realtek「全家桶」驱动树（RTD119x/129x/139x/13xx/16xx 驱动
都已移植到 6.6，含 CCF 时钟、pinctrl、gpio、eMMC/SD/SATA/GMAC），
但 **129x 的板级 DTS 仍停留在上游极简骨架** —— 即「**驱动齐、DTS 空**」。
于是工作量从"移植几万行驱动"压缩成"写一份 DTS + 少量驱动修正"。

对比：原可行性评估（基于 6.12/6.18 主线）预估需移植 ~39,037 行，
其中"时钟 1,650 行 / eMMC 10,828 行"被认为最难 —— 这条路把它们都省掉了。

---

## 目录结构

```
rtd1296-fnnas/
├── RTD1296-主线驱动现状盘点.md     # 立项时的驱动可行性评估（含实测勘误）
├── stage0/                        # 信息收集：串口代理、原厂日志、原厂 DTB 反编译
│   ├── original-dtb.dts.txt       # ★ 原厂固件 DTB 反编译 —— 一切属性的"圣旨"
│   ├── serial_agent.py            # 串口代理（命令队列 + 输出日志）
│   └── 阶段0-日志分析-*.md         # 两份原厂启动日志的分析
├── stage1/                        # 引导链：TFTP 服务、引导脚本
│   ├── tftp_server.py
│   └── run-tftp.sh
└── stage2/                        # 内核移植主体
    ├── rtd1296-cm360.dts          # ★ 板级 DTS（本项目的核心产出）
    ├── patches/                   # ★ 内核侧改动（固化为补丁，幂等可重放）
    ├── 18~24-*.py                 # ★ 串口/救砖工具链（见下）
    ├── brd-ssh.sh                 # ★ 上板 SSH 助手（替代 brd.py）
    ├── refs/                      # 参考资料（**未入库**：标注 Confidential，只留 URL）
    ├── archive/probe-modules/     # 只读诊断模块归档（取证用，已从内核移除）
    ├── logs/                      # 上板验证日志 + 报告 + 救砖证据
    ├── *.sh                       # 构建 / 部署 / 验证脚本链
    ├── CM360移植fnOS_eMMC阶段完整复盘_2026-10-05.md  # ★ 事故+救砖全记录
    └── 移植可行性评估.md           # ★ 下一步方案
```

---

## 脚本链（复现路径）

```bash
cd stage2

# ── 构建 / 部署 ────────────────────────────────────────────────
./04-build-66.sh              # 应用补丁 + 编译内核 + DTB（只改 DTS 时 DTB_ONLY=1）
./05-deploy-66.sh             # 套 uImage + 推送到 TFTP 根目录

# ── 类型化上板验证（守候断电上电 → 抓 u-boot → bootm → 只读体检）──
./10-sata-run.sh 1800         # SATA
./11-emmc-run.sh 1800         # eMMC
./12-smp-run.sh  1800         # SMP

# ── 单项体检（在 initramfs shell 里跑，或由上面的 run 脚本调用）──
./06-verify-clk-irq.sh
./07-verify-sata.sh
./08-verify-emmc.sh
./09-verify-smp.sh

# ── eMMC 写入链（⚠️ 会碰闪存低区，先读复盘文档！）────────────
./13-prep-emmc.sh && ./14-emmc-write.sh

# ── 上板 / 串口 / 救砖工具链 ──────────────────────────────────
./agent-ctl.sh stop|start|status   # 串口采集代理（恢复脚本要独占串口）
./brd-ssh.sh run|sudo|put|get|shell # 上板（系统 ssh + ~/.brd_cred）
./18-monsniff.py 15                # 串口无损嗅探（不发一个字节）
./19-txprobe.py                    # TX 方向探针（自环 / 回声）
./20-bootcap.py --max 300          # 纯被动启动捕获（带毫秒时间戳）
./20-phoenix-v2.py --hwsetting … --dvrboot …   # ★ ROM Monitor 救砖主力
./22-mon-g.py --key 67             # 在 monitor 里补发按键（如 g）
./23-ubcmd.py --wait-prompt 420 'version' …    # 与 u-boot 命令行交互
./24-baudprobe.py                  # 逐个波特率试读，排除波特率误判
```

**核心机制**：
- `apply-kernel-patches.sh` —— 把 `patches/*.patch` 打到内核树，**幂等**
  （正向 dry-run 成功就应用；失败但反向成功则跳过；都失败才报错）。
- `board.sh` —— 串口命令封装（`boot66` = tftp 三个文件 + `bootm`）。
- `20-phoenix-v2.py` —— 稀疏 Ctrl+Q（1B/30ms ≈ 33 B/s）进 ROM Monitor，
  TX/RX **分开记录**，YMODEM 收完会拿板子自算的 `len`/`crc32`/`checksum` 与本地比对。
- `brd-ssh.sh` —— 用系统 `ssh` + `SSH_ASKPASS` 读密码（本机只有 py3.14，
  paramiko 却装在 3.13 的 site-packages 里，`brd.py` 已不可用）。

---

## 内核侧改动（`stage2/patches/`）

| 补丁 | 内容 |
|---|---|
| `0000-preexisting-driver-patches.patch` | `irq-realtek-mux.c` 的 `.data` 复制 bug + `phy-rtk-sata.c`（SATA 供电） |
| `0001-emmc-rtd1296.patch` | 时钟/驱动早期适配 |
| `0002-emmc-rtkemmc.patch` | ★ 移植 jjm2473 的 `rtkemmc.c`（17 文件）→ eMMC 一次点亮到 HS200 |
| `0003-smp-rtk-spin-table.patch` | ★ SMP：`ioremap` + `writel_relaxed` 写从核释放寄存器 |
| `0004-wdt-restart.patch` | ★ **修 `reboot`**：给 `rtd119x_wdt` 加 `.restart` 回调，把看门狗当整机复位源 |

---

## 四个最有价值的结论（都给证据）

### 1. `cpu-release-addr` 不是内存，是硬件寄存器

ARM 官方 spin-table 规范说它是**内存**，主线 `smp_spin_table.c` 照此用
`ioremap_cache()` + `writeq_relaxed()`（8 字节缓存写）。
但 RTD129x 把它接到 `pinctrl@9801A000` 区间内的**握手寄存器**（`0x9801aa44`）
→ 一次缓存的 8 字节突发写打到设备寄存器 → **总线挂死，无任何报错**。

```
症状：日志停在 "Mountpoint-cache hash table entries" 之后，
     本该出现的 "RCU Tasks: Setting shift to 0 ..." 不再打印
修法：ioremap() + writel_relaxed()（32 位），去掉 dcache 维护
```
→ `patches/0003-smp-rtk-spin-table.patch`

### 2. 原厂双段 reg 的段序可能与主线驱动相反

vendor `of_iomap(node,0)` 取的是**中断**段、`(node,1)` 才是 GPIO；
而主线驱动 `resource0` 就是 GPIO。段序写反 → 寄存器写全打空、
读回全是 `0xdeadbeef`（Realtek SoC 上"地址不存在"的信号）。

### 3. 原厂 DTB 里"没有的属性"是语义，不是遗漏

它表示"用驱动默认值"，而默认值往往就是这台机器的正确硬件模式。
实例：网口 gmac 节点原厂**没给** `output-mode` → 驱动默认 0 = 内嵌 GPHY。
我们"好心补上" `output-mode = <2>`（外置 PHY）→ 链路能协商、TX 能出、
**RX 恒 0**。删掉即通。

### 4. `reboot` 挂死：这台机器一个 restart handler 都没有

arm64 的 `machine_restart()` 在没有任何 restart handler 时走兜底分支：
`pr_emerg("Reboot failed -- System halted")` + `while(1)` —— 表现就是
"系统关得干净、但拉不起复位，串口静默、只能手动断电"。

而这块板子恰好四方皆空：CPU 用 `spin-table`（**非 PSCI**，原厂 DTB 里也没有 psci 节点）、
内核树里没有 `rtk-rstctrl`、`rtd119x_wdt` 没有 `.restart`、DTS 里 `&wdt` 还被关掉了。
修法是**两层**：内核补 `.restart`（设 1s 超时 → 使能 → 不再喂狗 → 硬件拉复位）
+ DTS 把 `&wdt` 打开。详见复盘文档第九节。

---

## 风险与纪律

- ⚠️ ★★ **绝对不要动闪存低区**。RTD1296 把 `hwsetting`（DRAM/eMMC 启动配置）
  放在 eMMC **`blk# 0x100`（偏移 128 KiB）**，分区表之外 ≠ 空的。
  本仓库 2026-10-05 那次变砖就是这么来的。**动闪存前先把前 16 MiB 整段 dump 留档。**
- ⚠️ ★★ **串口必须真独占**。Linux 允许多进程打开同一 tty，但**每个字节只投递给一个读者**——
  手动开的 `screen` / 第二个脚本会**偷走板子的 ACK**，症状是"发送端收不到应答、疯狂重传"，
  极易误判成协议或速率问题。**动手前先 `fuser -v /dev/ttyUSB0`**。
- ⚠️ **ROM Monitor 进不去的两种典型原因**：① 用了满线洪流（应为稀疏 33 B/s 单字节）；
  ② 少于 3 个连续 Ctrl+Q，或中途夹了其它字节（`0x11` 计数会被清零）。
- ⚠️ **SPI NOR 只有 8 MB**，已被原厂四个镜像占 **90.6%**（含盲区 99.2%）。
  **全程禁止写 SPI。**
  （更正：`saveenv` **不是**写 SPI，而是写 **eMMC factory 区 `blk# 0x2100`**
  —— 见复盘文档 3.7 的实测输出；但写 SPI 依然禁止。）
- ⚠️ 上板验证**一次实验只上电一次**；串口命令 < 32 字符（无流控会截断，
  伪装成设备故障）。
- ⚠️ 改内核后**同时**要确认：补丁已应用 + Image 里真有改动
  （`strings` / `objdump` 自证），不能只看"我改了源码"。
- ⚠️ 烧 `dvrboot` 之前**先核对长度与 CRC**（板子会在 YMODEM 收完后打印
  `len`/`crc32`/`checksum`，与本地独立计算比对通过再按 `g`）。

---

## 环境

- 内核树：`~/.cache/rtd1296/xpressreal-linux`（XpressReal/linux 6.6.54）
  （另有 `~/.cache/cm360-bringup/ktree` = 6.17 主线树，供 `01-build.sh` 用）
- 工具链：GCC 16.2.0 aarch64-linux
- 参考源：`~/.cache/rtd1296/BPI-W2-bsp`（vendor 4.9 BSP）、
  `~/.cache/rtd1296/jjm2473-emmc`（jjm2473/rtd1295-next，Linux 5.9）
- 串口：`/dev/ttyUSB0` @ 115200 8N1（CH340）
- 板子：`192.168.1.173`，SSH 端口 22；凭据在 `~/.brd_cred`（不入库）
