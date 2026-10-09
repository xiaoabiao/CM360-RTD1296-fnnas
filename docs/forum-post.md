# 论坛发帖文案（恩山无线论坛 / 飞牛论坛）

> 用途：把 CM360 移植飞牛 fnOS 的成果发到社区。两个论坛受众不同，所以准备了两版：
> **恩山版**偏折腾/技术（启动链、内核、救砖），**飞牛版**偏"能不能用/怎么装"。
> 正文用【】小标题 + · 列表 + 缩进命令块，**没有 markdown 表格**，粘贴到 Discuz / 飞牛编辑器都不会乱 ✔
>
> 发帖前请自行核对：① 论坛是否允许外链与加群 ② 图片需要重新上传（GitHub 的图床链接在论坛里可能被吞）

---

## 一、标题备选

**恩山无线论坛（挑一个）**

1. 小睿 CM360（RTD1296）刷飞牛 fnOS 成功：自编译 Linux 6.6.54 + 全套镜像与救砖方案（附下载）
2. 【已跑通】RTD1296 小睿 CM360 上飞牛 fnOS：内核 6.6.54 移植、启动链逆向、dd/线刷镜像都做好了
3. 冷门盒子重生：小睿 CM360（RTD1296）→ 飞牛 fnOS，含 ROM Monitor 串口救砖实录

**飞牛论坛（挑一个）**

1. 【教程】小睿 CM360（RTD1296 / 2G 内存 / 双盘位）安装飞牛 fnOS 1.2.0302：镜像已发布，三种刷入方式
2. 老 ARM 盒子也能跑飞牛：CM360（RTD1296）刷机镜像 + 图文步骤，风扇/温度还在求助中
3. 给飞牛加一台设备：小睿 CM360 刷入 fnOS 1.2.0302 实录（含下载与刷入说明）

---

## 二、配图清单（建议 6~8 张，先传图再写正文）

1. 刷完后飞牛面板首页（显示设备名 / 版本 1.2.0302）
2. 存储空间页面：双盘 RAID1 正常挂载
3. 串口启动日志截图：`u-boot` → 内核 → 登录
4. 本机 `dd` 刷入过程的终端截图（低区 3.7s / p1 1.7s / p2 146s）
5. 磁盘测速（SATA 6Gbps、千兆网口 iperf/传输速度）
6. Docker 容器跑起来的截图
7. 板子本体 + 串口接线照片（USB-TTL 接 UART0）
8. 【可选】GitHub Releases 页面截图（让大家知道下哪个文件）

---

# 恩山无线论坛版（正文）

【前言】

小睿 CM360 是台冷门 ARM NAS 盒子，SoC 是 Realtek RTD1296（4×Cortex-A53 @1.4GHz / 2GB DDR4 / 8GB eMMC / 双 SATA 6Gbps / 千兆网口）。原厂固件是类群晖系统（原厂 u-boot 里 `syno_hw_version=DS218`），系统老、能玩的少。

我把它换成了自编译的 Linux 6.6.54 + 飞牛 fnOS 1.2.0302，现在**已经稳定跑起来**，并且把整个过程做成了可复现的工具链与可直接下载的刷机镜像。

项目地址（含全部文档与逆向记录）：
https://github.com/xiaoabiao/CM360-RTD1296-fnnas

刷机镜像下载（免注册）：
https://github.com/xiaoabiao/CM360-RTD1296-fnnas/releases/tag/v1.2.0302

（如果外链被吞，直接搜仓库名 CM360-RTD1296-fnnas）

【硬件与接口】

· SoC：Realtek RTD1296，4×Cortex-A53 @1.4GHz，2GB DDR4
· 存储：8GB eMMC（Samsung 8GTF4，HS200 8bit，实测可用 7.28GiB）
· 硬盘：2×SATA 盘位（AHCI 兼容，实测 `SATA link up 6.0 Gbps`）
· 网络：内嵌 GPHY 千兆（`r8169soc`），实测 0% 丢包
· SPI NOR：8MiB（原厂固件占约 90%，原厂 u-boot 的 bootcmd 就是从 SPI 读内核）
· 串口：UART0，115200 8N1（USB-TTL 就行，CH340 可用；进系统后 getty 是 57600）
· 按键：板上 SW5（按住可进 USB 下载模式，配套 Type-C 口）
· 启动链：Mask ROM → bootcode → hwsetting → FSBL → BL31(TEE) → u-boot 2015.07 → 内核(p1) → rootfs(p2)

eMMC 布局（实测，**别用常规分区思路动手**）：

· 低区：LBA 0 ~ 0x12FFF（38MiB）= MBR + hwsetting + bootcode + u-boot + BL31/TEE + env
· p1：LBA 0x13000（38MiB 起），256MiB ext4，放内核 Image + 板级 DTB
· p2：LBA 0x93000（294MiB 起），6.99GiB btrfs，子卷 root

【现在已经能正常工作的】

· 串口 / 内存 / GIC / 时钟 / **SMP 四核**（`smp: Brought up 1 node, 4 CPUs`）
· eMMC HS200 启动与读写
· **双盘 SATA 6Gbps**，mdraid + LVM 存储空间正常（双盘 RAID1 → /vol1、/vol2）
· **千兆网口**（原生 GMAC 驱动，传输 md5 校验一致）
· **eMMC 独立启动**：不依赖 TFTP、不依赖 SATA，断电重启自己起来
· **飞牛 fnOS 1.2.0302 正常跑**：Web 面板（5666 端口）、SSH、Docker、SMART、zram swap 都能用
· `reboot` 与看门狗（内核补了 restart 回调 + DTS 开 wdt，实测能自动复位）

【还没搞定的（求大佬）】

· **风扇不受控**：缺厂商板级描述，目前风扇按默认状态转，长时间高负载请自己注意散热
· **SoC 温度读数恒 0**：温感节点没接对，欢迎指点
· LED 控制、SDMMC/SDIO 节点、USB3 控制器（驱动就绪，缺 DTS 节点）
· ZFS 型存储空间：需要为 6.6.54 交叉编译 OpenZFS 模块

关于内核：不是拿现成内核凑的，6.6.54 是本仓库按锁定 commit 拉取、打补丁、交叉编译出来的，一共 6 个板级补丁，每个补丁对应的都是实测撞到的坑（比如这颗 SoC 的 `cpu-release-addr` 不是内存而是硬件寄存器，按规范做缓存写会**总线挂死且零报错**）。

【怎么刷：三种方式】

■ 方式一：dd 直刷（**推荐，端到端实测过**）

前提：板子已经能进系统（哪怕是原来的系统也能用，只要是能起 Linux 的 CM360）。

1. 下载 `dd-set-cm360-1.2.0302.tar.gz`（49MB，含低区镜像 + 内核分区 + 脚本 + 中文说明）
2. 另外下载 `p2.img.gz`（1.73GB，含完整 fnOS rootfs），解压得到 `p2.img`（6.99GiB）
3. 把 dd 套装解压，把 `p2.img` 放进同一个目录，整个目录拷到板子
4. 板端执行：

       sudo ./dd-flash.sh --check     # 先校验镜像大小 / md5 / 目标设备
       sudo ./dd-flash.sh             # 三层全刷：低区 + 内核分区 + rootfs

实测耗时：低区 3.7 秒 / p1 1.7 秒 / p2 146 秒（约 51MB/s）。

■ 方式二：u-boot + TFTP / U 盘（系统起不来但能进 u-boot 时用）

开机有 3 秒窗口可进 `BPI-W2>`（低区里已设 `bootdelay=3`），然后 tftp 拉分区镜像写 eMMC。
仓库里带了纯 Python 的只读 TFTP 服务端与一键脚本。注意内核必须加载到 0x20000000 以上（BL31/TEE 占了低地址），一次最多 64MiB。

■ 方式三：Windows USB MP Tool 线刷（**板砖了 / 从原厂固件开始**）

· 下载 `install-cm360-fnos-1.2.0302-boot-compact-full.img.gz`（1.98GB，含引导链 + 精简 rootfs）
· 或 `install-cm360-fnos-1.2.0302-boot-full.img.gz`（1.79GB，含引导链 + 完整 rootfs）
· 工具目录放**纯 ASCII 路径**，装好 usb_driver，**按住 SW5** 只插 Type-C 线（不接 DC 电源）约 3 秒，设备管理器出现 `Realtek generic USB Device`
· 打开 USB MP Tool：`flash type = EMMC`、`DDR Type = 4DDR4_2GB`，`open` 选 `.img`（先解压），点小绿人

说明：这两个线刷包的格式是从厂商包逆向出来的（layout / fw_tbl / MBR），**包本身与内容我都验证过，但厂商工具是否接受自定义 layout 条目我还没有 Windows 环境实测**，欢迎有条件的坛友反馈。包里已包含 u-boot，所以不需要先手动刷引导。

【三个必须提醒的坑】

1. **别手写 eMMC 前 1MiB！** RTD1296 的 `hwsetting`（DRAM/启动配置）就在偏移 128KiB（blk# 0x100），分区表之外不等于空的。我自己就因为清空前 1MiB 把板子打成砖。要覆盖就直接用 38MiB 的低区镜像整块写。
2. **刷 p2 = 清空飞牛的账号/共享/设置**（等于重装系统），但**两块硬盘上的存储空间（RAID/LVM/btrfs）不受影响**，刷完重新创建账号并把存储空间导入即可。刷之前先把硬盘拔了最稳。
3. **动了 eMMC 就有砖的风险**，请先确认自己能进串口。真砖了也不用编程器：本项目的 ROM Monitor 串口救砖流程实测走通过，全过程记录在仓库 `docs/04-recovery.md` 与事故复盘 `docs/incident-2026-10-05-emmc-recovery.md`。

【成果文件一览（GitHub Releases）】

· `low-region-38MiB.img.gz` 17.5MB —— 引导链（含 u-boot），dd 写 eMMC 起始 38MiB
· `p1-256MiB.img.gz` 31.8MB —— 内核分区（只换内核时用）
· `dd-set-cm360-1.2.0302.tar.gz` 49MB —— dd 套装（低区 + p1 + 脚本 + 说明）
· `p2.img.gz` 1.73GB —— 完整 fnOS rootfs
· `p2-compact.img.gz` 1.92GB —— 精简 rootfs（2.75GiB，首启用自动扩容）
· `install-…-boot-sysonly.img.gz` 65MB —— 线刷包（不含 rootfs，救砖/换内核）
· `install-…-boot-full.img.gz` 1.79GB —— 线刷包（含完整 rootfs，**下载体积最小**）
· `install-…-boot-compact-full.img.gz` 1.98GB —— 线刷包（含精简 rootfs，**写入量最小**）
· `MD5SUMS.txt` / `SHA256SUMS.txt` —— 校验清单（`md5sum -c MD5SUMS.txt`）

也有仓库自带的一键构建脚本，官方镜像不随发布分发（版权原因），想自己重编一条命令就行。

【求助与交流】

如果你也有这台盒子，欢迎回帖说下你的板子批次与遇到的问题。要省事的话，回帖带这三样我更容易定位：

· 串口日志（从 Mask ROM 开始那几行最有价值）
· `cat /proc/device-tree/model` 与 `dmesg | head -50` 的输出
· 你用的是哪个方式刷的（dd / u-boot / 线刷）

【免责声明】

刷机有风险，变砖、数据丢失请自行承担。本项目不含任何厂商版权物（原厂固件、飞牛官方镜像、厂商刷机工具），请从官方渠道自行获取。rootfs 镜像源自官方飞牛 ARM 镜像，版权归飞牛所有。

---

# 飞牛论坛版（正文）

【成果】

把小睿 CM360（Realtek RTD1296，4 核 A53 / 2G 内存 / 8G eMMC / 双 SATA 盘位 / 千兆网口）刷上了**飞牛 fnOS 1.2.0302**，跑的是自编译的 **Linux 6.6.54**（板级设备树 + 6 个内核补丁 + 1.2 兼容补丁）。

镜像已经做好并公开下载，**不需要你懂内核，照着步骤刷就行**。

项目与文档：https://github.com/xiaoabiao/CM360-RTD1296-fnnas
镜像下载：https://github.com/xiaoabiao/CM360-RTD1296-fnnas/releases/tag/v1.2.0302

（外链若被吞，搜仓库名 CM360-RTD1296-fnnas；也可以回帖问我）

【刷完之后能干什么（实测可用）】

· 飞牛 Web 面板正常（`http://盒子IP:5666`），账号、共享、备份这些常规功能都在
· SSH 可用，Docker 能装能跑，SMART 能看硬盘健康，zram swap 正常
· 双盘 SATA 6Gbps 正常，存储空间走 mdraid + LVM，双盘 RAID1 建好后挂载正常
· 千兆网口满速可用，断电重启能自己起来（eMMC 独立启动，不依赖网络）
· `reboot` 正常（顺手把看门狗也点上了）

【刷之前需要知道的（诚实版）】

· **风扇目前不受控**（缺厂商板级描述）：机器会转，但不会随温度调速，长时间高负载请留意散热
· **温度读数显示 0**：温感节点还没接对，所以面板上的温度不可信
· LED 灯、SD 卡槽、USB3 口还在做（驱动有，设备树节点没补）
· ZFS 类型存储空间暂不支持（双盘 RAID1 没问题）

这些坑我在 GitHub 上都写了文档，欢迎懂设备树的朋友一起补。

【怎么刷：推荐用 dd，全程约 5 分钟】

前提：盒子已经能进 Linux（原系统也行）。

1. 下载这两个文件（都在上面那个 Releases 页面）：
   · `dd-set-cm360-1.2.0302.tar.gz`（49MB，含引导链 + 内核分区 + 刷入脚本 + 中文说明）
   · `p2.img.gz`（1.73GB，完整飞牛系统 rootfs）
2. `p2.img.gz` 解压得到 `p2.img`，和 dd 套装解压出来的文件放同一个目录
3. 整个目录拷到盒子（U 盘 / scp / SFTP 都可以）
4. 盒子上执行：

       sudo ./dd-flash.sh --check     # 先看校验结果，不动数据
       sudo ./dd-flash.sh             # 开始刷（低区 + 内核 + 系统）

实测：低区 3.7 秒、内核分区 1.7 秒、系统 146 秒，一共不到 3 分钟，加上重启和初始化 5 分钟搞定。

【如果你只想在 Windows 上刷（连引导一起刷）】

下载 `install-cm360-fnos-1.2.0302-boot-compact-full.img.gz`（1.98GB）或 `install-cm360-fnos-1.2.0302-boot-full.img.gz`（1.79GB），解压后用 Realtek USB MP Tool：

· 工具放纯英文路径，装好 usb_driver
· **按住板上 SW5 键**，只插 Type-C 线（不接电源）约 3 秒，等设备管理器出现 `Realtek generic USB Device`
· 工具里选 `flash type = EMMC`、`DDR Type = 4DDR4_2GB`，`open` 选那个 `.img`，点开始

这条路适合"系统已经起不来"或"想从原厂固件直接换"的情况，包已含引导链，不用先刷 u-boot。
（提示：包格式是从厂商包逆向做的，包本身验证过，但厂商工具对自定义条目的接受度我还没条件实测，期待反馈。）

【三个提醒】

1. **刷系统会清空飞牛的账号与设置**（等于重装），但**硬盘上的存储空间不会被动**，刷完重新建账号再把存储空间导入就行。最稳的做法是刷之前把硬盘拔掉。
2. **别去手动清 eMMC 前 1MiB**：这颗 SoC 的启动配置就藏在 128KiB 处，清掉会直接变砖（我踩过）。
3. 变砖也不用编程器：本项目有串口救砖流程，实测救回来了，文档在仓库里。

【为什么值得发这个帖】

CM360 这类老 ARM 盒子二手很便宜，飞牛对 ARM 的支持让它们有了第二春。我把踩过的坑（启动链、设备树、内核补丁、刷入方式、救砖）全部写成文档放在仓库，后面谁再折腾同款 SoC 可以少走弯路。

【求支援】

· 有 CM360 或同 SoC（RTD1296/RTD1295）设备的朋友，欢迎一起补**风扇调速**与**温度传感器**的节点
· 有 Windows 环境 + SW5 条件的，帮忙验证一下线刷包，反馈我改进
· 刷成功/失败的都欢迎回帖，附上串口日志最好

【免责声明】

刷机有风险，请自行承担。本发布不含原厂固件与飞牛官方镜像等版权物；rootfs 镜像源自官方飞牛 ARM 镜像，版权归飞牛所有。

---

## 三、发帖注意事项

· **先传图再写正文**：Discuz 与飞牛编辑器对外链图片都不太友好，截图请直接上传
· **外链**：两个论坛都对低等级账号限外链，若被吞，把链接写成"GitHub 搜 CM360-RTD1296-fnnas"或分两段发
· **加群/打赏**：请先确认版规；仓库 README 里的交流群二维码建议只在被问到时发，避免被判广告
· **回帖互动**：准备好 2~3 张关键截图（启动日志、面板、测速）随时回应"能跑吗/稳吗/怎么刷"三类问题
· **标题别用"最强/秒杀"**一类词，容易引战；用"已跑通/附下载/实测"更稳
