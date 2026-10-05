# 阶段 0 操作单：串口接入与原厂系统摸底

> 目标：在不改任何东西的前提下，把 CM360 的**引导链、内存布局、分区表、外设信息**全部记录下来，
> 并完成可回滚的备份。**本阶段全程只读，不做任何写入。**

---

## ✅ 阶段 0 已全部完成（2026-10-04）

**现在的状态：Agent 已能直连串口并自主操作，不再需要你配合上电。**

| 项 | 状态 |
|---|---|
| 串口权限 | ✅ 已修（ACL，`/etc/udev/rules.d/99-ch340-serial-acl.rules` 持久化） |
| 常驻代理 | ✅ `serial_agent.py` 常驻（pid 在跑，持有 `/dev/ttyUSB0`） |
| 板子当前位置 | ✅ 停在 `CM360_DS218>` u-boot 提示符（**未断电，无需重新上电**） |
| u-boot 能力 | ✅ `help` 全表已拿（`booti`/`tftp`/`tftpput`/`mmc`/`sata`/`fdt` 全有） |
| 原厂 DTB | ✅ 全量反解 2,077 行 → `original-dtb.dts.txt` |
| eMMC 分区表 | ✅ 7 个分区已摸清 |
| 主线对比 | ✅ 已完成，两条硬结论已出 |

→ **完整成果见 `阶段0-完整实测报告.md`**（本文档以下内容为历史操作记录，仍可作排错参考）

---

## 权限问题：关了沙箱还不够（2026-10-04 更新）

**旧状况（沙箱开启时）**：沙箱对设备节点做 cgroup 级封锁，`/dev` 里根本看不到 `ttyUSB0`，
绕过沙箱 `mknod` 能建出节点但 `open()` 仍被拒。所以必须你在宿主机终端跑。

**新状况（沙箱关闭后）**：节点出现了，但 **open 依旧 `errno 13`**。根因不是沙箱，是**会话凭据过期**：

| 检查项 | 结果 |
|---|---|
| `/dev/ttyUSB0` 节点 | ✅ 存在，`crw-rw---- root:dialout`（`188:0`） |
| `getent group dialout` | ✅ `dialout:x:20:xiaoabiao` —— **你在组里** |
| 当前会话凭据 `/proc/self/status` 的 `Groups` | ❌ `4 24 27 30 44 46 100 111 114 115 990 994 1000` —— **没有 20** |
| `sudo -n true` | ❌ `interactive authentication is required` |

> **原因**：Linux 只在**登录那一刻**把组信息写进进程凭据。
> `usermod -aG dialout` 是在这个桌面会话启动**之后**执行的，所以本机所有已经在跑的进程
> （包括 Agent 的 shell）都不带 `gid 20`。**重新执行 `usermod` 没有用，必须让凭据刷新。**

### ✅ 一次修好（推荐）

```bash
cd /home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
sudo bash fix-serial-perm.sh
```

这个脚本做三件事：

1. **立刻生效**：`setfacl -m u:xiaoabiao:rw /dev/ttyUSB0`（ACL 不需要重新登录）
2. **一劳永逸**：装 `/etc/udev/rules.d/99-ch340-serial-acl.rules`，以后重插/重启自动带上 ACL
3. **自动验证**：以 `xiaoabiao` 身份试开一次，并打印结果

若 ACL 不可用（文件系统不支持），备用方案：**注销桌面会话 → 重新登录**。

---

## 修好之后：Agent 可以直接接管串口

权限一通，抓取就不用你来跑了。`serial_agent.py` 是常驻代理，**只打开串口一次**，
然后可以跨多次调用持续交互（避免反复 open/close 触发 DTR 电平导致板子复位）：

```bash
# 启动（放后台）
python3 serial_agent.py -d /dev/ttyUSB0 -b 115200 -o session01

# 另一个终端 / 后续任何时刻，往控制文件追加一行就等于"敲一条命令"
echo "help"            >> session01.ctl
echo "@key:TAB"        >> session01.ctl
echo "@burst:8 esc tab" >> session01.ctl     # 连打打断键 8 秒
echo "@sleep:2"        >> session01.ctl
echo "@mark:上电前"     >> session01.ctl     # 只在自己日志里打标记
echo "@quit"           >> session01.ctl

# 看回应
tail -n 60 session01.log
```

| 控制指令 | 作用 |
|---|---|
| `help` （普通文本） | 原样发送并自动补回车 |
| `@key:ESC` / `@key:TAB` / `@key:CR` | 发单个按键 |
| `@raw:1b09` | 发原始十六进制字节 |
| `@burst:8 esc tab` | 以 150ms 间隔连打 8 秒（交替 Esc/Tab） |
| `@sleep:2` | 延迟 2 秒再处理后续指令 |
| `@mark:说明` | 只在本地日志打标记 |
| `@quit` | 退出代理 |

自检（不需要真串口，用 socketpair 冒充）：

```bash
python3 selftest_agent.py     # 18 项断言
```

---

## 旧流程（仅当权限还没修好时用）

---

## 第 0 步：先关掉 screen（重要）

你的 `screen` 如果还开着，它会和抓取脚本**抢同一个字节流**——串口是"谁先读谁拿走"，
两边各读一半，日志会变成碎片。

```bash
# screen 内：按 Ctrl-A，再按 K，按 y 确认
# 或者直接：
pkill -f "screen /dev/ttyUSB0"
```

确认没人占着端口：

```bash
fuser -v /dev/ttyUSB0     # 应该无输出
```

---

## 第 1 步：抓启动日志（只读）

```bash
cd /home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0

python3 serial_capture.py log -t 120 -o shot_log_01
```

**敲下回车后立刻给板子上电。** 脚本会抓 120 秒，全程不发送任何按键。

产出：
- `shot_log_01.log` —— 带时间戳，给人看
- `shot_log_01.raw` —— 原始字节，一个不丢

---

## 第 2 步：打断 autoboot，抓 u-boot 环境变量 ✅ 已完成

```bash
python3 serial_capture.py uboot -t 90 -o shot_uboot_01
```

**回车后立刻上电。** 实测的提示语是

```
Hit Esc or Tab key to enter console mode or rescue linux:  0
```

所以打断键是 **Esc / Tab**（**不是回车**）。脚本已修正：开机后前 8 秒每 150ms**交替连打 Esc/Tab**，
之后自动发送 `printenv`。已两次稳定复现，进到提示符 `CM360_DS218>`。

> 这一步会停在 u-boot 提示符下。**只读操作，不写任何东西。**
> 脚本绝不会发送烧写类命令，但你自己在提示符下也**不要**手敲
> `erase` / `sf` / `mmc write` / `nand erase` / `setenv` / `saveenv` 之类的命令。
>
> ✅ 附带好处：进 console 时 u-boot 会打印 `Enter console mode, disable watchdog ...`，
> **看门狗被关掉了**，在提示符下慢慢敲命令不会被复位。

产出 → 分析报告：`阶段0-日志分析-shot_uboot_01.md`

---

## 第 3 步：探查 u-boot 支持哪些命令（决定阶段 1 走法）⬅ 现在就做这一步

```bash
python3 serial_capture.py probe -t 45 -o shot_uboot_02
```

**回车后立刻上电。** 脚本自动：前 8 秒交替连打 Esc/Tab 抢提示符 →
之后依次发送下面这些**全部只读**的命令，每条间隔 3 秒：

| 顺序 | 命令 | 想知道什么 |
|---|---|---|
| 1 | `help` | **命令总表**（本轮最重要的一条） |
| 2 | `version` | u-boot 版本与编译配置 |
| 3 | `bdinfo` | 板级信息 / 内存分布 |
| 4 | `help usb` | 有没有 USB 子系统 |
| 5 | `help fatload` | 能不能从 FAT 分区载入（U 盘方案） |
| 6 | `help tftpboot` | **能不能走网络载入（最优方案）** |
| 7 | `help mmc` | eMMC 访问能力 |
| 8 | `help bootm` | **能不能启动标准 uImage（决定内核镜像格式）** |

> 这条命令的输出**就是阶段 1 方案选择的唯一输入**。
> 若某项命令不存在，u-boot 会再打一遍总表——无害，忽略即可。

---

## 第 4 步：告诉我就行

跑完跟我说一声，我直接读文件做分析。已经从日志里挖出来的（打勾=已完成）：

### 已完成 ✅
- [x] **引导链结构**：FSBL → BOOTCODE → U-Boot 2015.07，二阶引导
- [x] **内存布局**：DRAM 2 GiB；`fdt 0x01f00000` / `kernel 0x03000000` / `rootfs 0x02200000` / `audio 0x01b00000`
- [x] **bootargs 全量**：`root=/dev/md0`、`console=ttyS0,115200`、`syno_hw_version=DS218`、`ihd_num=2`
- [x] **SPI 分区布局**（8 MB，已用 90.6%~99.2%）与 eMMC 型号（Samsung 8GTF4 / 7.3 GiB）
- [x] **以太网**：SoC 内置 GMAC `r8169soc @ 0x98016000`；u-boot 侧 `r8168#0` 驱动可用
- [x] **USB 控制器**：三个 xhci 全部起来；VBUS GPIO = 102 / 132 / 133
- [x] **原生双 SATA**：`/sata@9803F000`，需带 `tx-driving <2>` / `rx-sensitivity <2>`
- [x] **u-boot 环境变量全量 `printenv`**，含 `bootcmd` / `bootdelay=0` / 各 `loadaddr`

### 待补 ⬜
- [ ] **`help` 命令表** → TFTP / U 盘 / 私有 `go all` 三选一（第 3 步）
- [ ] 插网线后重跑 `log`：看 PHY 协商速率、`eth0` 拿 IP、DSM httpd:5000
- [ ] 插一块硬盘后重跑 `log`：验证原生 SATA 认盘（NAS 可行性）
- [ ] SoC revision（B00 与否，影响 `r8169soc` 初始化分支）
- [ ] eMMC 当前内容（DSM 完全没碰它，可能还是原厂 Android）
- [ ] DSM 登录凭据 —— 若知道密码，走 SSH/web 备份比走 u-boot 方便得多
- [ ] ~~PCIe 是否物理存在~~ —— 已非必需（SoC 有原生双 SATA），降级为"顺便确认"

---

## 排错表

| 现象 | 原因 | 处理 |
|---|---|---|
| 一个字节都没收到 | 板子没上电 / 启动太快 | 重新跑，回车后立即上电 |
| 全是乱码 `▒▒▒` | 波特率不对（多数是 115200，少数 57600/1500000） | 试 `-b 57600`；Realtek BSP 常配 115200 |
| 少量数据后中断 | TTL 线序反了 | 板子 `TX` → 模块 `RX`，板子 `RX` → 模块 `TX`，**GND 必须共地** |
| 完全无输出但板子能开机 | TTL 电平接成 5V；或串口没引出 | 电平拨到 **3.3V**；确认接口是调试串口不是普通 UART |
| `Permission denied` | 不在 dialout 组 | `sudo usermod -aG dialout $USER` 后重新登录，或加 `sudo` |
| `Busy` / `Resource busy` | screen 还占着 | 见第 0 步 |
| 抓到的日志有重复行 | 两个进程同时读串口 | 见第 0 步 |

脚本还附带一个自检，可以随时验证抓取逻辑本身没问题：

```bash
python3 selftest_capture.py     # 应输出「全部通过」
```

---

## 第 4 步（等拿到 shell 之后再做）：备份

**备份需要设备上的 shell，所以本阶段先不做。** 拿到 shell 后按下面执行。

### 4.1 先摸清分区

```bash
cat /proc/mtd                    # SPI/NAND 分区（有 mtd 才有）
cat /proc/partitions             # eMMC / SD 分区
cat /proc/cmdline                # bootargs
ls -l /dev/mmcblk* /dev/mtd* /dev/mtdblock* 2>/dev/null
```

### 4.2 备份 SPI/NAND（如果有 mtd）

```bash
mkdir -p /tmp/bak
for p in /dev/mtdblock*; do
  n=$(basename "$p")
  echo "dump $n ..."
  dd if="$p" of="/tmp/bak/$n.img" bs=1M 2>&1 | tail -1
done
ls -lh /tmp/bak/
```

### 4.3 备份 eMMC 关键分区

```bash
# 先看清楚哪些是 bootloader / dtb / kernel，别把整个 8GB 全 dump 出来
cat /proc/partitions
# 按上一步查到的偏移，逐个 dump（示例：前 4MB 通常含 bootloader + dtb）
dd if=/dev/mmcblk0 of=/tmp/bak/emmc_head_4M.img bs=1M count=4
```

> ⚠️ **不要**对 `/dev/mmcblk0` 做 `dd of=` 方向的操作，那是覆盖写。

### 4.4 把备份取出来

优先走网络（scp / nc / http），其次 ADB `pull`，最后才考虑串口（串口传 100MB 不现实）。

装好 `dropbear`/`openssh` 或用现成的服务：

```bash
# 设备端：开个临时 http 服务，宿主机 wget 拉走
cd /tmp/bak && python3 -m http.server 8000
# 宿主机：
wget -r -np http://<设备IP>:8000/
```

### 4.5 备份清单要留档

把下面这些贴进 `stage0/BACKUP.md` 存档：
- 备份了哪些分区、文件名、大小、SHA256
- 原厂固件版本号、日期
- `printenv` 全量输出
- `cat /proc/cmdline` 输出

---

## 阶段 0 完成判据

- [x] `shot_log_01.log` 非空且可读（934 行，看到 u-boot banner 与 Linux 启动全程）
- [x] `shot_uboot_01.log` 里含 `printenv` 的完整输出（163 行，1421/131068 字节）
- [x] 内存布局已记录；SPI 分区布局已推算
- [x] 打断 autoboot 的方法已验证（Esc/Tab，两次稳定复现）
- [ ] **`help` 命令表**（第 3 步，最后一项）
- [ ] （拿到 shell 后）bootloader / dtb / kernel 分区已备份并校验

`help` 一拿到，就可以进**阶段 1**（写 CM360 板级 DTS + 编一个能进 shell 的主线内核）。
