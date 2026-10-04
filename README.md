# CM360（RTD1296）移植 fnOS

小睿 CM360 NAS 盒子 —— Realtek **RTD1296**（4× Cortex-A53、2 GiB DDR4、8 GiB eMMC、
原生双 SATA、千兆网口）上跑 **飞牛 fnOS** 的移植工程。

本仓库记录**完整的方法论、取证过程与可复现的产物**：不只放结果，
更放"为什么这么改"的证据链，以及踩过的每一个坑。

---

## 当前进度

| 子系统 | 状态 | 关键证据 |
|---|---|---|
| 串口 / 内存 / GIC / 时钟 | ✅ | |
| **SMP 四核** | ✅ | `smp: Brought up 1 node, 4 CPUs`；`online=0-3`、`nproc=4` |
| **SATA（12 TB）** | ✅ | `ata1: SATA link up 6.0 Gbps`、`HUH721212ALE600` 23437770752 扇区 |
| **eMMC（HS200）** | ✅ | `mmcblk0` 7.28 GiB、HS200、寿命健康 |
| **eth0（原生 GMAC）** | ✅ | ping 0% 丢包、31.5 MB 传输 md5 一致 |
| SDMMC / SDIO | ⬜ | 驱动已在 `.config`，**只缺 DTS 节点** |
| USB3 | ⬜ | 驱动已在 `.config`，**只缺 DTS 节点 + PHY 时序** |
| fnOS 安装器适配 | ⬜ | 见 `stage2/移植可行性评估.md` |

**详细结论**：`stage2/移植可行性评估.md`
**SMP 攻关全过程**：`stage2/logs/SMP-SUCCESS-REPORT.md`

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
    ├── archive/probe-modules/     # 只读诊断模块归档（取证用，已从内核移除）
    ├── logs/                      # 上板验证日志 + 报告
    ├── *.sh                       # 构建 / 部署 / 验证脚本链
    └── 移植可行性评估.md           # ★ 下一步方案
```

---

## 脚本链（复现路径）

```bash
cd stage2

# 构建
./04-build-66.sh              # 应用补丁 + 编译内核 + DTB（只改 DTS 时 DTB_ONLY=1）
./05-deploy-66.sh             # 套 uImage + 推送到 TFTP 根目录

# 类型化上板验证（守候断电上电 → 抓 u-boot → bootm → 只读体检）
./10-sata-run.sh 1800         # SATA
./11-emmc-run.sh 1800         # eMMC
./12-smp-run.sh  1800         # SMP

# 单项体检（在 initramfs shell 里跑，或由上面的 run 脚本调用）
./06-verify-clk-irq.sh
./07-verify-sata.sh
./08-verify-emmc.sh
./09-verify-smp.sh
```

**核心机制**：
- `apply-kernel-patches.sh` —— 把 `patches/*.patch` 打到内核树，**幂等**
  （正向 dry-run 成功就应用；失败但反向成功则跳过；都失败才报错）。
- `board.sh` —— 串口命令封装（`boot66` = tftp 三个文件 + `bootm`）。
- `00-catch-uboot2.sh` —— 满线 ESC 洪流抢 u-boot console（`bootdelay=0` 也能抢到）。

---

## 内核侧改动（`stage2/patches/`）

| 补丁 | 内容 |
|---|---|
| `0000-preexisting-driver-patches.patch` | `irq-realtek-mux.c` 的 `.data` 复制 bug + `phy-rtk-sata.c`（SATA 供电） |
| `0001-emmc-rtd1296.patch` | 时钟/驱动早期适配 |
| `0002-emmc-rtkemmc.patch` | ★ 移植 jjm2473 的 `rtkemmc.c`（17 文件）→ eMMC 一次点亮到 HS200 |
| `0003-smp-rtk-spin-table.patch` | ★ SMP：`ioremap` + `writel_relaxed` 写从核释放寄存器 |

---

## 三个最有价值的结论（都给证据）

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

---

## 风险与纪律

- ⚠️ **SPI NOR 只有 8 MB**，已被原厂四个镜像占 **90.6%**（含盲区 99.2%）。
  **全程禁止写 SPI，禁止 `saveenv`**（u-boot 环境也在 SPI 里）。
- ⚠️ 上板验证**一次实验只上电一次**；串口命令 < 32 字符（无流控会截断，
  伪装成设备故障）。
- ⚠️ 改内核后**同时**要确认：补丁已应用 + Image 里真有改动
  （`strings` / `objdump` 自证），不能只看"我改了源码"。

---

## 环境

- 内核树：`~/.cache/rtd1296/xpressreal-linux`（XpressReal/linux 6.6.54）
- 工具链：GCC 16.2.0 aarch64-linux
- 参考源：`~/.cache/rtd1296/BPI-W2-bsp`（vendor 4.9 BSP）、
  `~/.cache/rtd1296/jjm2473-emmc`（jjm2473/rtd1295-next，Linux 5.9）
- 串口：`/dev/ttyUSB0` @ 115200 8N1
