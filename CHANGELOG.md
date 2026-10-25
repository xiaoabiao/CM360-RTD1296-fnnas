# 变更记录

本项目按"阶段"推进，每个阶段都有对应的实测证据留在 `evidence/`。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [未发布]

### 新增

- **★ 线刷包改用厂商官方打包工具 `rtd129x_img_gen` 生成元数据**（`tools/make-lineflash-official.sh`
  + `tools/lineflash/emmc_8gb_cm360.json`，文档 `docs/10` §16）：
  - 拿到厂商 `rtd129x_img_gen`（Linux 静态编译）+ 8 GB JSON；**实测**用厂商 iStoreOS CM360 包
    反推的 JSON 重跑，生成的 `config.txt` / `mbr.bin` / `fw_tbl.bin` 与厂商原包**逐字节相同**
    （`layout.txt` 仅生成时间戳不同）→ 工具语义对齐；
  - 本板包改为 `json + 工作目录` 驱动：`size=0x1D2000000`、`part_start=0x2600000`、
    p1 `0x10000000` ext4、p2 剩余空间；`fw`/`gold` 留空（内核/DTB 在 p1，由 u-boot 读）；
  - 实测六个坑并写进文档：① `filesystem` 只认 `squashfs`/`ext4`（p2 btrfs 只能标 ext4，
    该字段不进分区内容）；② 工具给每个分区少算 **16 扇区（8 KiB）**，镜像必须按 MBR
    扇区数生成（p1 `0x7FFF0`=268,427,264 B），否则 ext4/btrfs 挂载报 `bad geometry`；
    ③ `Layout_Type` 是**固定名字白名单**，自定义 `FW_LOWREGION` 被**静默忽略**
    （更正 §11"救援包写低区"的结论）；
    **④ ★ 包内 tar 成员名必须全 ASCII**——工具 `tarlib` 在 GBK locale 下解包，
    遇到 UTF-8 中文名会中断整个解包循环（实机现场：`UnTarTmp` 只剩 4 个 ASCII 成员，
    `omv/` 与 p1/p2 都没解出来，于是报 "Cannot get untartemp project filename"）。
    已改为 `README-lineflash.txt` / `omv/README.txt`，并加打包后非 ASCII 检查；
    **⑤ ★ 单分区载荷必须 < 2 GiB**——工具用 32 位 `long` 存载荷大小
    （`Real_Partition_Data_Size_Point`），≥ 2³¹ 变负数 → 数组越界 → `abort()`
    （WER `0xC0000409`）。实测 2.0 GB 可载入、2.2 GB 必崩、7.5 GB 完整 p2 亦崩。
    新增 `firmware/slim-p2.sh` 把完整 p2 重建为 **2000 MiB 精简镜像**（zstd:15，
    删固件/编译器/文档/多余 locale/VM-GUI 静态资源），分区仍按 7.0 GiB 建立，
    首启 `cm360-firstboot.sh` 的 `btrfs resize max` 扩回；
    **⑥ ★ 烧写阶段要求 `FW_KERNEL` 长度非零**——`ThreadProgramDevice` 用
    `Layout_Type[0].length` 当 `FW_Kernel_Len`，为 0 直接弹 LOST
    "kernel data length not found"，根本不开始写盘。已加 2 字节占位
    `dummy-kernel.bin`（`fw[]` 里一条 `KERNEL` 条目，写到低区 `0x630200`，
    不碰 u-boot/env/p1）；`make-lineflash-official.sh` 会自动打包 JSON 引用的 fw 文件；
    **⑦ ★ 线刷可把整块低区（u-boot/env/factory）一起写回**——实机验证该工具普通刷写会
    重建 eMMC 0x220000/0x420000 的 factory 区（含 `tmp/factory/env.txt`），把 u-boot env
    清掉 → 开机 `[ENV] read_env from factory failed` → 默认 env → 停在 `BPI-W2>`。
    利用"`FW_KERNEL` 的文件按 layout offset 原样写入"把 38 MiB 低区镜像伪装成
    `FW_KERNEL`（`fw_start=0x200`，跳过 512B MBR；写入 0x200~0x2600000，
    刚好贴 p1 起点）⇒ 刷完 env 自动恢复，也能从砖头直接救回。
    注意 offset 不能为 0（`LoadFlashLayout` 把 0 当"条目无效"）。
    脚本开关 `--lowregion <low-region.img>`，产物 `...-full-uboot.img`；
    **⑧ ★ 只写低区还不够：工具最后一步会用 `omv/factory.tar` 重写 factory 区**——
    烧写日志末尾固定出现 `enter , write factory icon[0]` →
    往 eMMC 0x220000（LBA 0x1100）/ 0x420000（0x2100）写 factory.tar；
    包里没有该文件时它写**空白 tar**（~12 KB，无 `env.txt`）→ 把低区刚写回的 env 盖掉。
    工具的流程是「解包 `omv/factory.tar` 到自己的 factory 根目录 → 加 `tmp/factory/` 前缀重打包」，
    所以 **factory.tar 成员必须用根相对路径 `env.txt`**；若写 `tmp/factory/env.txt`，
    会被套成 `tmp/factory/tmp/factory/env.txt`，u-boot 仍找不到 env。
    新增 `tools/make-factory-tar.py`（从低区镜像抽 env → 根相对 factory.tar）
    与脚本开关 `--factory-tar`；
    **⑨ ★ 载入阶段把所有 PART 载荷一次性读进内存，单包总量 ≲2.3 GB，分片无效**——
    32 位进程 + `Real_Partition_Data_Size_Point` 累加；实测 p1 256 MB + p2 1.86 GiB 正常，
    p2 2.2 GB → `abort()`/`0xC0000409`；`--p2-split` 拆成 PART1..PART4（总量不变）
    → `GetLastError:8` + `load [PART2] data failed`。⇒ "p2 全量一次刷完"不可行，
    改用「精简 p2 刷机 + 板端注入功能包」（见下一条），`--p2-split` 仅留作实验记录；
  - **载入 + 烧写 + 自动引导已全程实测通过**（2026-10-21/22）：
    full / full-uboot / full-uboot-f2 均能载入；`FW_KERNEL` 低区整块写入成功
    （日志 `start block: 1`，19×2MB）；最终 `...-full-uboot-f2.img` 刷完
    **断电重启自动进 fnOS**（`Factory: ... size:0x23600` + `tmp/factory/env.txt` 命中）；
  - 本次产物：
    `install-cm360-fnos-1.2.0302-full.img`（2,365,593,600 B，
    md5 `23eef9790b9d391d1c2f6800467afd96`，`FW_KERNEL` 2 B 占位）；
    `install-cm360-fnos-1.2.0302-full-uboot.img`（2,405,437,440 B，
    md5 `9c0c2175571a6c879fd8d18ad8c54948`，含整块低区 + p1 + p2）；
    **`install-cm360-fnos-1.2.0302-full-uboot-f2.img`（2,405,570,560 B，
    md5 `032d1f2d6b1e49c88cc80f429be9183f`，★ 最终可用包：低区 + 系统 +
    `omv/factory.tar`，刷完自动引导）**；
    `install-cm360-fnos-1.2.0302-full-uboot-split.img`（7,817,267,200 B，
    md5 `38272f884f52b5480da6aa9eb22288d7`，p2 拆四段的**失败实验包**，
    载入报 `load [PART2] data failed`，仅留存作 ⑨ 的证据，勿用）。

- **★ "功能完整"路线：精简 p2 刷机 + 板端注入功能包**（`firmware/make-extra-features.sh`
  + `firmware/install-extra-features.sh`，文档 `docs/10` §16.1 / §16.3 ⑨）：
  - 因为工具 32 位内存上限（⑨）无法在单包里塞 7.0 GiB 完整 p2，
    改为把精简掉的组件单独打成注入包：完整 p2 中移除的 `/usr/lib/firmware`、
    AAVMF、LLVM、Qt、gcc、文档、多余 locale 等，**28,190 个成员 / 485 MB**
    （`cm360-extra-features.tar.gz`，508,228,333 B，解开 1.53 GiB，
    md5 `f91c6c9ef0f6ec4fd18a44df761ad018`）；
  - 主机端 `make-extra-features.sh`：挂载完整 p2 镜像 → tar 出被精简的路径
    （含 `libLLVM-*` / `libgallium-*`）→ 输出注入包；
  - 板端 `install-extra-features.sh`：`tar -xzpf ... -C /` + `ldconfig`，需 root，
    刷完 `...-full-uboot-f2.img` 开机后执行一次、重启即得完整功能集；
  - 交付目录 `C:\Users\xiaoa\CM360-lineflash\extra\`（tar.gz + 两个脚本）；
  - 待验证：注入后的功能回归（firmware/AAVMF/LLVM/Qt 是否齐全）。

- **★ 新增 `--full-p2`：一个包直接装完整 7.0 GiB p2（不精简、不分片）**（2026-10-23）：
  厂商 32 位工具吃不下（§16.3 ⑨），但换用其它支持大载荷的刷机工具时，需要一个
  "标准完整包"来验证到底能不能刷 —— 所以加了这个开关：
  - 产物 `install-cm360-fnos-1.2.0302-full-uboot-fullp2.img` **7,817,267,200 B**，
    md5 `f9e52e6e7dac548159623c590514058a`（2026-10-26 修正版；旧版 `c895ae65…` 的
    `omv/factory.tar` 误用了 factory 区原始 blob，刷完 u-boot 读不到 env，勿用）；
  - 内容：低区 `low-region.img` 39,845,376 B（作为 `FW_KERNEL` 写 0x200~0x2600000）
    + MBR + `p1.img` 268,427,264 B + **`p2.img` 7,508,844,544 B**
    （= MBR p2 分区 0xDFC7F0 扇区，与分区等大）+ `omv/factory.tar`
    （**成员根相对 `env.txt`，133,120 B**）；
    layout `PART1 offset=0x12600000 size=0x1bf900000`（声明 7,508,852,736），
    tar 成员名全 ASCII，共 11 个成员；
  - 开关语义：跳过"单载荷 < 2 GiB"检查并打印警告；命名加 `-fullp2` 后缀；
  - **新增防护**：`--factory-tar` 传入 `tmp/factory/env.txt` 结构的原始 blob 时，
    脚本自动改写成根相对 `env.txt` 并告警；不给 `--factory-tar` 且带 `--lowregion` 时
    自动用 `tools/make-factory-tar.py` 生成（少了易错的一步）；
  - 交付：`C:\Users\xiaoa\CM360-lineflash\`（`VALIDATION.txt` 已记录修正前后 md5 与原因）。

- **★ 线刷镜像重建：fnOS 私有 ABI 兼容层（trim-compat）已内置**
  （2026-10-26，交付 `C:\Users\xiaoa\Desktop\2026-10-26 RTD\`）：
  - 用当前工作区（含 `boards/rtd1296-cm360/board-scripts/trim-compat/`，即本文件下方
    「面板上传文件失败 / 共享建不出来」那条的修复）重跑 `firmware/build-images.sh p2`
    + `firmware/slim-p2.sh`；`adapt()` 自动 `install.sh --stage` 注入：15 个服务 drop-in
    （trim_main / trim_upload / filestor_service / trim_http_cgi / share_service /
    trim_app_center / trim_trashbind / finder_service / imagesrv / eventlogger_service /
    sysinfo_service / backup_service / dlcenter / multiple-downloads / trim_open_gateway）、
    关闭 `trim_trashbind` 开机自启、`cm360-fake-fs.service` 已 enable；
    重建后重新挂载自检 13 项全 ✔（`usr/local/lib/libtrimcompat.so`、`cm360-fake-fs.sh`、
    `cm360-fake-fs.service` + `.wants`、`trim_main`/`share_service` drop-in 等）；
    精简镜像同样复核通过（兼容层 + `spl.ko`/`zfs.ko` + `cm360-firstboot` 均在）；
  - 新完整 p2：`7,508,844,544 B` md5 `1bbeea11f65b91aaecdff217ead1ba1e`；
    新精简 p2：`2,097,152,000 B` md5 `262b7cd032e280f0a7d47869b92916d5`（btrfs 实占 1.53 GB）；
  - ★ **精简线刷包** `install-cm360-fnos-1.2.0302-slim-p2.img`
    `2,405,570,560 B` md5 `475053e73e26c3ddb53767a1791a333e`
    （厂商 32 位工具可载入；`p2 < 分区` → 首启 `resize max` 扩回 7.0 GiB）；
  - **完整线刷包** `install-cm360-fnos-1.2.0302-full-p2.img`
    `7,817,267,200 B` md5 `49d8336d2843c7bdf91b2649e06c322f`
    （受 ⑨ 的 32 位内存上限限制，`rtumdfsample.exe` 载入仍会失败；仅供支持大载荷的
    工具或做母盘/离线备份）；
    两包均含低区（`FW_KERNEL` 伪装，刷完 env 自动恢复）+ `omv/factory.tar`
    （成员根相对 `env.txt`）→ 刷完断电重启自动进 fnOS；
  - 旧镜像补救包 `cm360-trim-compat-1.2.0302.tar.gz`（30,906 B，md5
    `866bdd87c5147e0e903300c5bcf75f54`）：已刷旧镜像的板子可板端
    `sudo ./trim-compat/install.sh` 补装。

- **★ 逆向 fnOS 官方 arm64 内核 `6.18.18-trim`**（报告 `docs/reports/fnos-6.18-kernel-reverse-engineering.md`，
  交接文档 `总结.md`）：把"缺 `trimafs`/ACL"从"听说"变成"有全貌"——
  - 上游基线确认为**纯净 v6.18.18**（`NAME="Baby Opossum Posse"`，`-trim` 只是 `LOCALVERSION`），
    内核内嵌 IKCONFIG 与 `/boot/config` **逐字节相同** → 官方 config 可直接复用；
  - 厂商新增函数 **80 个**（构建级对照：官方 65 433 vs 上游自建 65 145）、新增源码文件 8 个（下界）、
    私有全局 `trim_mounts_tree`/`trim_mounts_rwlock`；**无 Kconfig、无符号导出、无自定义 ioctl、无设备表**；
  - `trimafs` 的 `file_system_type` + **全部 `*_operations` 表逐字段还原**（挂载选项只有 `mode`/`debug`，
    命名体系是 shmem/tmpfs 那一套 → 伪文件系统）；用户态挂载原文 = `mount -t trimafs trimafs /fs`（**无 `-o`**）；
  - 被改的上游函数点名：`generic_permission`/`do_mkdirat`/`do_unlinkat`/`do_rmdir`（`fs/namei.c`）、
    `path_mount`/`path_umount`（`fs/namespace.c`，**用 rbtree 维护卷表**）、
    `__arm64_sys_faccessat(2)`（`fs/open.c`）—— 三条独立证据链（调用点 / 调用目标差集 / 构建级尺寸差）互相印证；
  - **★ `trimacl` 在 fnOS 自己的内核里出现 0 次，且 btrfs 未知选项分支仍返回 `-EINVAL`**
    → 确认 `patches/0007`/`0008` 是在**兼容 fnOS 自身的 bug**，不是"我们缺厂商特性"。
- **逆向工具集 `tools/re-kernel/`**（可复用，含 `README.md` 与两个致命坑的记录）：
  `va.sh`（地址标定/反汇编）、`rela.py`（RELA 感知结构体解码）、`xref.py`（调用图）、
  `strxref2.py`（字符串锚定引用）、`vtab.py`（接口表枚举）、`calldiff.py`（调用目标差集）、
  `diff-func.py`（同函数二进制 diff）、`cmp-syms.py`（与上游对照构建做符号/尺寸差）。
- **上游对照构建**：免 root 取 GCC 12 交叉工具链（`apt-get download` + `dpkg-deb -x`），
  用 fnOS 官方 config 构建上游 v6.18.18 的 `vmlinux`（脚本 `~/.cache/fnnas/upstream/build-ref.sh`）。
- **电脑端一键刷机工具** `firmware/flash-from-pc.py` + 内置只读 TFTP `tools/tftp-server.py`：
  一条命令完成「备份低区 → 起 TFTP → 重启并自动抢进 u-boot → 逐层 `tftp`+`mmc write`
  → `run bootcmd` → SSH 复核」，支持 `--layers/--rehearse/--dry-run/--backup-only`。
- **端到端演练通过**（2026-10-09）：以 `--layers low --rehearse` 在实机上跑完整流程
  （写入内容与板上现有内容逐字节相同，故为零风险演练）：
  自动进 u-boot ✔ → TFTP 载入 ✔ → mmc write ✔ → 启动 ✔ → 系统起来 ✔ →
  **板上低区 md5 与镜像完全一致** ✔。
- 记录本板 u-boot 的**命令差异**（照网上教程会踩）：网络加载是 `tftp`（无 `tftpboot`）、
  没有 `boot`（用 `run bootcmd`）、没有 `crc32`/`cmp`/`echo`/`dhcp`/`nfs`。
  `flash-uboot.cmd` 与 README 已按实测修正。

### 修复

- **★ 刷完 fnOS 后「面板上传文件失败」/ SMB 共享建不出来 —— 根因是厂商私有
  ACL/faccessat ABI 缺失**（2026-10-26 实机 192.168.1.234 定位并修复）：
  - **症状**：面板「文件」上传只提示「上传失败」，nginx 日志里**没有任何
    `POST /upload`**；`share_service` 反复报
    `AddUserFoldersByStorageId, User 1000 has no permission of '/vol1/1000/1111'`；
    `trim_trashbind.service` 每 5 s 失败重启。
  - **根因**：fnOS 1.2.x 的权限判定走厂商内核私有接口 ——
    `faccessat(dirfd=−21586..−21576, &ctx, …)`（libnperm / libtrimacl / libnfile）
    与 xattr `system.trim_acl`（TrimACL v2）。自编译 6.6.54 两者都没有：
    前者返回 `EBADF`，后者返回 `EOPNOTSUPP`。实测 `trim_access()` 恒 `-1/EBADF`，
    于是 `file.checkUpload` 返回 `{"errno":9,"result":"fail"}`，客户端直接放弃、
    不发 `POST /upload` —— 与"只提示上传失败 + 服务端无上传请求"完全一致。
    （`file.ls` 之类纯目录操作不经过该检查，所以"能浏览但不能上传"。）
  - **修法**：`boards/rtd1296-cm360/board-scripts/trim-compat/` 用户态兼容层
    `libtrimcompat.so`（LD_PRELOAD，**不重编内核、不改 fnOS 二进制**）：
    拦截魔数 `faccessat`（11 条命令：权限判定/realpath/is_mountpoint/TrimACL 批量读…），
    按 POSIX mode 判权限；把 `system.trim_acl` 的 get/set/remove/listxattr 全族
    重定向到 btrfs 可写的 `user.trim_acl`（内容格式不变）。给
    `trim_main` / `trim_upload` / `filestor_service` / `trim_http_cgi` /
    `share_service` 加 systemd drop-in，`install.sh` 一键安装/卸载（含预编译 .so）。
  - **实测**（`tools/fnos-api.py` 复刻面板 RPC/上传）：装前
    `file.checkUpload -> {"errno":9}`；装后 `-> {"uploadName":"...~#0","result":"succ"}`
    → `POST /upload` HTTP 200 → 4096 B 落盘，md5 与本地逐字节一致；
    SMB 共享 `\\192.168.1.234\1111` 自动生成且 Windows 可写；`trimacl` 读写闭环正常。
    报告：`docs/reports/fnos-acl-compat-layer.md`；复现工具：`tools/fnos-api.py`。
  - **残余**：`trim_trashbind` 仍要读厂商字符设备 `/dev/trim-trashbin`，用户态无法
    伪造（可 `systemctl mask trim_trashbind` 去噪，不影响上传/共享）；`/fs`（trimafs）
    的平台另见下一条；ACL 语义是 POSIX 近似（单用户/家庭场景够用，多用户细粒度授权需谨慎）。
- **FTP/WebDAV 共享视图修复（`/fs` = trimafs 兼容层）**：自编译内核没有厂商私有
  `trimafs`，`share_service` 建 `/fs/<uid>/<proto>/<share>` 符号链接时报
  `[TrimAFS] failed to create '/fs/...'`；只 `mkdir /fs` 时 FTP 的
  `ChrootSet /fs/%U/ftp` 又让绝对符号链接 `/volN/...` 在 chroot 内解析不到
  （实测：根目录能看到共享名，进去列目录为空、GET/PUT 失败）。
  修法：`cm360-fake-fs.sh` + `cm360-fake-fs.service`（每 5s 对账）——保证 `/fs`
  是普通目录，并在每个 `/fs/<uid>/<proto>` 里把 `/volN/<uid>`、`/volN/@team`
  bind 进来；卷那层设 `0111` 只给 x，避免整卷暴露。`share_service` 的 drop-in
  加 `ExecStartPre` 保证开机时 `/fs` 先就位。
  实测：FTP 根目录列出共享、`/1111/` 可列目录、GET 返回内容、PUT 落盘成功；
  模拟开机删除 `/fs` 后服务能自动重建。
- **面板「删除」挂死 / 回收站不可用修复（魔数 `unlinkat` 的用户态实现）**：
  `file.rm` 实际走 `unlinkat(dirfd=-7126, …)`（移入回收站）/ `-7125`（彻底删除），
  厂商内核按负 dirfd 分发；stock 内核返回 `EBADF` 后面板任务永远等完成（转圈）。
  修法：兼容层拦截这两个魔数（`trash-ref.c`）——按实测格式在用户态完成：
  回收站 `/vol<v>/<uid>/.@#local/trash/<相对路径>`（目录 0771 + 复制原父目录
  owner/mtime/ACL；同名用厂商同款 `_<u64>` 后缀；目录删除先子项后目录，做合并
  避免空壳条目），记录 xattr `user.trim-trashbin-record` = `u:<uid>,t:<unix秒>`；
  `-7125` 走递归彻底删除。`trim_trashbind` 依赖的 `/dev/trim-trashbin` 只存在于
  厂商内核，安装时自动 `disable`（不再每 5s 失败重启），`--uninstall` 会恢复。
  实测：删除文件/目录（回收站/彻底删除）返回 `result:succ`；`file.trash.list`
  正确显示 `rmUid/rmTime`；`file.trash.restore` 能恢复到原路径。
  注意：`file.rm`/`trash.restore/clear` 是异步任务，`taskId`/终态帧推送到**登录的
  main WebSocket**，只在 `type=file` socket 上等会误判无响应
  （复现工具 `tools/fnos-rpc-probe.py`）。
- **应用中心「推荐应用存储空间权限」报 `Request failed, please try again later` 修复
  （`trim_app_center` 未覆盖 + TrimACL 权限判定）**：
  面板该操作实际请求 `POST /app-center/v2/config/app/authorization-path`，返回 500。
  根因有两层：
  1. `trim_app_center`（Go + cgo）也依赖 `libtrimacl`/`libnperm`，但最初没被加进
     LD_PRELOAD 名单 → 写 TrimACL 前 `trimacl_get_file()` 返回 `errno=95 EOPNOTSUPP`，
     `/var/log/trim_app_center/error.log` 打印
     `system panic allow user perm ...: acl get_file_acl failed ...` 后 500。
     修法：`install.sh` 的覆盖名单扩到所有链接私有库的 fnOS 服务
     （trim_app_center / finder_service / imagesrv / eventlogger_service /
     sysinfo_service / sysrestore_service / backup_service / dlcenter /
     multiple-downloads / trim-sharelink / trim_open_gateway），并逐个 restart。
  2. 权限检查原来只看 POSIX mode，不读 TrimACL：应用被授权后
     `com.trim.sysinfo.trimAccessStat` 仍返回无权限，`trim_app_center` 日志刷
     `trim access stat error: bad file number`。修法：`trimcompat.c` 的
     `mode_perms()` 解析 `user.trim_acl`（格式：`u32 ver=1` + 20B ACE：
     `tag/type`(bit0=allow)、`permset`(+4，bit0=x/1=w/2=r)、`inherit`(+8)、
     `qualifier`(+12)），按 user/group/everyone/owner 匹配叠加 allow/deny，
     命中时以 TrimACL 为准，否则回退 POSIX mode。
  实测：授权请求 200；`trimacl` 显示 `allow uid:995 permset:rwxpdDaAeEc inherit:sfd`；
  授权后 `trim_access(uid=995, mode=rwx)` 全部通过；`trim access stat error` 计数归零；
  上传/删除/回收站/SMB/FTP 回归正常。

- **`firmware/build-images.sh` 的全新 clone 构建必挂**（2026-10-20）：
  `adapt()` 要拷 `artifacts/kernel-6.6.54/modules.order`，但这个文件被 `.gitignore`
  的 `*.order` 规则排除、根本不在仓库里 → 无论 p1 还是 p2，跑到"装入模块元数据"
  就 `die`（本次实测：p2 已经 rsync 完 2 GB 才在最后一步失败）。
  修法：缺失时用空文件兜底（`modules.order` 只是模块链接顺序，全内置内核下为空即可，
  板上 `cm360-firstboot.sh` 的 `depmod -a` 会重建索引），不再把正常情况当失败。
- **`docs/10` §11 的错误结论更正**：`FW_LOWREGION` 等自定义 `layout.txt` 条目会被
  厂商工具**静默忽略**（`Layout_Type` 是固定名字白名单），旧"救援包会把低区一起写进去"
  的说法不成立；线刷包不写低区，低区恢复走 `dd`/TFTP/`only upgrade bootloader`（见 §16.3）。
- **已知坏文件**：`rom/release/install-sysonly.img.gz` 是**截断**的（1,064,960 B，
  gzip 头声明原始 3,848,440,792 B，`gzip -t` 报 `unexpected end of file`），
  拿它线刷必然"载入固件就错误"。用 §16 的 full 包替代。

- **★ ZFS 在"全新刷入的系统"上必然不可用 —— 镜像链里两处过期逻辑**（2026-10-11 定位并修好）：
  `scripts/build-zfs.sh` 在 0.5.0 编出了 `zfs.ko`/`spl.ko`，但镜像/升级链**没跟上**：
  - `firmware/build-images.sh`（p2）与 `tools/upgrade/board-adapt-newroot.sh`（rootfs 替换）
    **仍然按旧假设删掉 `/etc/modules-load.d/trim-zfs.conf`**，注释理由是"本机内核没有 zfs"；
  - 两处都**从不把模块装进 rootfs**（`build-images.sh` 只装 `modules.builtin`/`modinfo`/`order` 三个元数据文件）。
  - ⇒ "删配置 + 不装模块"：刷完机的系统里 `modprobe zfs` 必然失败。README 状态表里
    ZFS 那一行长期是 ⬜，根因就在这里（模块本身是好的）。
  **修法**（按 `build-zfs.sh` 已有的同一约定，不引入新约定）：
  - 两处都改为把 `artifacts/zfs-2.4.1/{spl,zfs}.ko` 装到
    `/usr/lib/modules/<krel>/extra/`（644），并**保留 / 补写** `trim-zfs.conf`（内容 `zfs`）；
    模块索引由板上首次开机的 `cm360-firstboot.sh` 跑 `depmod` 生成。
  - `tools/upgrade/board-verify-newroot.sh`：断言从"必须已删除"**翻转**为
    "必须保留 + `extra/{zfs,spl}.ko` 必须在位"。
  - `tools/fnos-cleanup.sh`：不再删 `trim-zfs.conf`（只删 `nft_fullcone`/`msr`）。
  - 文档同步：`docs/07-fnos-upgrade.md`、`docs/reports/fnos-rootfs-checklist.md`。
  **本机已验证**：两个模块的 `vermagic` = `6.6.54-gbe79582cba58-dirty SMP preempt mod_unload aarch64`
  （与板上内核逐字一致）；4 个脚本按入库 LF 内容 `bash -n`/`sh -n` 全通过；
  部署逻辑在假 rootfs 上仿真通过（落位/权限/配置内容/vermagic 全部核对）。
  **待上板验证**：用新 `build-images.sh` 出的 p2 刷机后，`zfs` 是否开机自启、面板能否建 ZFS 空间。

- **★ 存储空间终于可用**（fnOS 1.2.x 在自编译 6.6.54 上的三处"新内核特性"依赖，全部定位并解决；
  一键安装脚本：`boards/rtd1296-cm360/board-scripts/fnos-kernel-compat.sh`）
  1. **mdadm 4.5 传 `--bitmap=lockless`**（6.7+ 特性）→ 建阵列必失败；更坑的是每次失败都会在内核里
     留下 `state=clear` 的同名 md 设备，导致后续重试永远报 `File exists`（面板只显示"无法创建"）。
     → 兼容层把 `lockless` 降级为等价的 `internal`，并清理残留设备。
  2. **fnOS 挂存储时传私有选项 `-o trimacl,prjquota`** → 6.6 的 btrfs/ext4 直接拒绝挂载
     （`unrecognized mount option`），存储空间永远"未挂载"。
     → **内核补丁** `patches/0007`（btrfs）、`patches/0008`（ext4）接受这些选项（no-op；
     qgroup 配额仍由 fnOS 经 ioctl 开启）。**社区帖证实这是 fnOS 1.2.0302 自身的 bug**
     （官方支持的 OESPlus 升级后同样挂载失败）。
  3. **fnOS 的 `fast_resync_md_raid`** 依赖 lockless bitmap 接口 → 失败会让创建流程整体中止。
     → no-op 兼容层（新阵列跳过首次全量同步，安全；否则 931G 要同步 ~95 分钟导致面板超时）。
  - 结果：`md0` RAID1 → LVM → btrfs 自动挂载到 `/vol2`（930G 可用），面板显示"已挂载/正常"。
- **fnOS 的自定义 `trimafs` 文件系统缺失**（其 ACL v2 用 `mount -t trimafs trimafs /fs`）：
  内核没有该类型 → `triminit` 初始化链中断 → **`trim_*` 服务开机不自启**（表现：能 ping 通但面板打不开）。
  → 处理：`cm360-trim-boot.service` 开机兜底单元（PostgreSQL 就绪后幂等拉起服务）。
  **已知功能缺失**：细粒度 ACL 不生效；存储/共享/面板均正常。

### 修复（此前）

- **★ 构建流程的坑（踩过）**：`scripts/build-kernel.sh` 只产出**裸 `Image`**，
  直接拷到 p1 会让 u-boot 的 `bootm` 认不出（u-boot 2015.07 只认 legacy uImage/FIT）
  → 板子掉进 `BPI-W2>` 提示符。已把 **uImage 打包 + 魔数校验**加进构建脚本；
  部署务必用 `Image-6.6.uimage`（比裸 Image 多 64 字节头）。
- 上一节的 mdadm lint：见 `0392a22`。

- **fnOS 1.2.x 面板"创建存储空间"失败**（完整脚本见
  `boards/rtd1296-cm360/board-scripts/mdadm-lockless-compat.sh`）：
  - **症状**：面板只说"无法创建"；`journalctl -u trim_main` 里是
    `[MDADM ERROR] mdadm: Fail to create mdN when using
    /sys/module/md_mod/parameters/new_array, fallback to creation via node`
    + `[ERROR] md_create failed: /dev/mdN`，并自动重试 10 次全失败。
  - **真因**：fnOS 1.2.x 自带的 **mdadm 4.5 建阵列时传 `--bitmap=lockless`**
    （无锁写意图位图，上游内核 **6.7+** 才有），而我们的自编译 6.6.54
    **根本没有这个特性**（`drivers/md` 源码里搜不到）→ mdadm 打印一句
    `Experimental lockless bitmap` 警告后**静默失败**。
    更坑的是：**每次失败都在内核里留下一个 `state=clear` 的同名 md 设备**
    （md0/md1/…），于是后续重试写 `new_array` 必然 `File exists` → 永久失败。
  - **修法**：在 `/usr/trim/bin/mdadm` 位置放一层透明兼容层，把
    `--bitmap=lockless` 降级为等价的 `--bitmap=internal`；同时清掉残留 md 设备。
    原二进制保留为 `/usr/trim/bin/mdadm.real`，`--remove` 可一键还原。
  - **实测**：用 fnOS 的**原命令**（含 `--bitmap=lockless`）经兼容层 →
    `mdadm: array /dev/md180 started.`（退出码 0）、`Intent Bitmap : Internal`、
    `md180 : active raid1 sda1[1] sdb1[0]`。
  - **同类风险**：1.2.x 的部分新特性是按 6.18 内核设计的，自编译老内核时会持续
    遇到这种"用户态要求新内核特性"的坑（ZFS 模块、lockless bitmap 都属于此类）。

### 待办

- **风扇调速：软件链路已全部打通，但风扇对占空比无响应**。
  已完成的四步（都有实测输出）：
  1) PWM 控制器就位：`/sys/class/pwm/pwmchip0` 有 4 通道，原厂 `pwm@980070D0` 的
     四通道子节点属性照抄；
  2) 引脚复用已生效：新增 pinctrl 节点后 debugfs 显示
     `pin 21 (iso_gpio_21): 980070d0.pwm … function pwm_0 group iso_gpio_21`；
  3) 通道真正使能：`patches/0006` 补上了驱动漏掉的 `pwm_enable()`；
  4) `fan_ctrl_speed` 可写（0~10）。
  但把转速在 10% ↔ 100% 之间循环多轮，**风扇转速完全不变**（用户实测听感）。
  ⇒ 结论：本板风扇的 PWM 线大概率不在这几个引脚上，或者它根本不受软件控速
  （4 针扇在 PWM 输入悬空时本来就按满速转 —— 现在风扇是转的）。
  **下一步（三条路，任选）**：
  ① 用示波器/万用表量 iso_gpio_21 在 10%/100% 下有无 ~26kHz PWM：
     有 → 引脚不对；无 → 驱动寄存器写错位（pinctrl 基址待复核）；
  ② 把 `pwm_1..3` 也 mux 到 iso_gpio_22/23/24，导出后用 sysfs 逐通道扫
     （通道 1~3 未被驱动占用，可直接 `echo N > export` 测，不需重编内核）；
  ③ 查 `rtk_fan` 硬件块路径（原厂 fan 节点是 `status="disabled"`，本板可能根本不走它）。
- **SoC 温度读数为 0**：`rtd129x-thermal-sensor` probe 成功（日志有
  `wait 24ms to be ready`，说明 reset 流程跑到过），但
  `/sys/class/thermal/thermal_zone0/temp` 恒为 0。
  **下一步**：dump 0x9801d100~0x9801d170 的寄存器值，与原厂 4.9 驱动的
  `Realtek,rtd1295-thermal` 实现比对（本树用的是 rtd129x 描述，偏移可能不同）。
  在此之前**不要**加 `critical` 触发点 —— 读数不可信时会让内核误判过热关机
  （DTS 里已刻意只写 passive）。
- **SD 卡**：`MMC_RTK_SDMMC` 已内置、`sd` 节点已在 DTS（reg/clocks/interrupts 齐），
  但驱动把 `sd-power` / `sd-wp` / `sd-cd` 三个 GPIO 当**必需**资源，
  需先给驱动加容错（避免盲写引脚）或确认这三个引脚。
- **USB3 / SDIO**：驱动都在（`phy-rtk-usb3` / `phy-rtk-usb2` / `dwc3-rtk`），
  缺 DTS 节点；寄存器地址可从原厂 `ds218-cm360-1020.dtb` 取。
- LED：原厂 DTB 里没有 gpio-leds 节点，`led-set.service` 仍失败（待确认板上是否有系统灯）。
- 清理与移植无关的 fnOS 服务（`nut-*` / `exim4` / `wsdd2` / `trim_raid_check`）。

---

## [0.5.0] — 2026-10-05 · ZFS 可用 + 风扇/温度/PWM 首轮接入

### 新增

- `scripts/build-zfs.sh` + `patches/zfs/0001-disable-aarch64-neon-raidz.patch`：
  为 6.6.54 交叉编译 OpenZFS 2.4.1 模块的完整配方（含 4 个实测坑，见脚本头注释）。
- `tools/brd-ssh-raw.sh`：裸 ssh 封装 —— 远端输出可直接进管道/文件
  （brd-ssh.sh 的 sudo 模式要拿 stdin 喂密码，没法当管道用），也供 `rsync -e` 使用。
- `tools/upgrade/board-fix-files.sh`：源不可用时，把少数坏文件**就地**写回目标 rootfs。
- DTS 新增三个节点（引脚/寄存器全部取自原厂 `ds218-cm360-1020.dtb`）：
  - `pwm@70d0`（compatible `realtek,rtk-pwm`，4 通道，四通道子节点属性照抄原厂）
  - `rtk_fan@1bc00`（compatible `realtek,rtk-fan`，`pwms = <&pwm 0 …>`，GIC SPI 29 测速）
  - `thermal-sensor@1d100`（compatible `realtek,rtd129x-thermal-sensor`）+ 温度分区
- 内核配置新增：`EXPERT`/`GPIO_SYSFS`、`PWM_RTK`、`RTK_FAN`、`RTK_THERMAL`、
  `SENSORS_PWM_FAN`（`MMC_RTK_SDMMC` 原本就已内置）。
- `patches/0005-rtk-fan-tolerate-missing-clk-reset.patch`：`rtk_fan` 的 probe 对
  缺失 `clocks`/`resets` 属性**不做错误检查**就 `clk_prepare_enable()`/`reset_control_deassert()`，
  直接解引用 `ERR_PTR` → oops → 内核 panic。补上判断后驱动可正常 probe。
- `patches/0006-rtk-fan-enable-pwm.patch`：`rtk_fan` 只调 `pwm_config()` 从**不调
  `pwm_enable()`**，而新内核 PWM 框架对 disabled 通道会直接丢弃新状态
  （`pwm-rtk.c` 的 apply 在 `!state->enabled` 时提前 return）
  ⇒ 无论写什么转速，硬件占空比永远不会变。补一次 `pwm_enable()`。
- DTS 新增 pinctrl 节点（`realtek,rtd1295-iso-pinctrl`，reg[0]=0x9801a000）+
  `pwm0-pins`（`iso_gpio_21` → `pwm_0`），并被 PWM 节点引用 —— 这是让 PWM
  真正出现在引脚上的必要一步。

### 完成

- **ZFS 型存储空间可用**：`zfs.ko`/`spl.ko`（2.4.1-1，vermagic 与板上内核一致）
  装机验证 —— `modprobe zfs` 成功、`zpool create/list/destroy` 与写读全通过，
  `/etc/modules-load.d/trim-zfs.conf` 已恢复（升级时因为模块还不存在被我删过）。
- 旧 rootfs 子卷已删除（旧系统先备份到主机 `old-root-1.1.31.tar.gz`，1.77G），
  eMMC 根分区可用空间从 **2.1G 回升到 4.3G**。
- 升级途中损坏的 14 个库文件用 `board-fix-files.sh` 就地修好，新系统此后
  多次冷启动正常。

### 关键结论（都有实测支撑）

- **p1 里的 `.bak` 是改内核/DTB 的救命稻草**：本次 `rtk_fan` panic 后，就是靠
  串口进 u-boot、`ext4load … Image-6.6.uimage.bak` + `… .dtb.bak` + `bootm`
  一次性把系统起回来的（只改内存，不 `saveenv`）。
- ZFS 交叉编译三坑：`--host=` 之后需要**带 libc** 的交叉 gcc（内核工具链是 nolibc 的）；
  必须导出 `ARCH`/`CROSS_COMPILE`，否则它编译内核测试模块失败、误报
  "This kernel does not include the required loadable module support"；
  2.4.1 的 aarch64 NEON RAIDZ 内联汇编在新版 GCC 上编不过，要摘掉 NEON 实现。
- **btrfs 删子卷后空间要到下次挂载/事务提交才真正落账**：本次删完 `df` 纹丝不动，
  重启后才回收（`btrfs subvolume sync` 也等不到）。
- 全内置内核也**可以有模块**：`CONFIG_MODULES=y` 下 `CONFIG_SENSORS_PWM_FAN=m`
  之类仍会产出 `.ko`，`make modules` 也能生成外部模块编译所需的 `Module.symvers`。

### 证据

`evidence/logs/` 里的升级 panic 与 u-boot 救砖日志；本次风扇驱动 panic 的串口
日志见 `evidence/logs/fan-driver-panic-2026-10-05.log`（含 `pc : clk_prepare` /
`lr : rtk_fan_probe` 的完整调用栈）。

---

## [0.4.0] — 2026-10-05 · fnOS 升级路径（1.1.31 → 1.2.0302）

### 新增

- [`docs/07-fnos-upgrade.md`](docs/07-fnos-upgrade.md)：**整块替换 rootfs 子卷**的升级流程，
  含代价说明、回滚与"新系统起不来"时的 u-boot 救砖路径。
- `tools/upgrade/`（板端执行，逐步可重跑）：
  - `board-copy-rootfs.sh`：镜像 rootfs → eMMC 新子卷的幂等增量复制
  - `board-adapt-newroot.sh`：换 rootfs 前的本机适配（fstab / 模块元数据 /
    modules-load.d / kernel_version_output）
  - `board-verify-newroot.sh`：切换前预检（与镜像逐项比对 + chroot 起壳测试）
  - `board-switch-rootfs.sh`：子卷改名切换 / 一键回滚（**旧系统只改名不删除**）
  - `board-fix-files.sh`：源不可用时，把少数坏文件**就地**写回目标 rootfs
    （`cat > 文件` 不改 inode → 属主/权限/xattr 全保留）

### 结果（2026-10-05 实测）

- 板上 fnOS 从 **1.1.31 升到 1.2.0302**，`uname -r` 仍是自编译的
  `6.6.54-gbe79582cba58-dirty`（换 rootfs 不影响内核，符合设计预期）。
- Web 面板 80/443 监听、zram swap 941 MB、
  `modprobe zram/md_mod/overlay/openvswitch` 全部成功 → 模块元数据方案在新系统同样生效。
- 旧 rootfs 留档 `root-1.1.31`，可一键回滚。
- 详细过程与两个真实故障（复位写坏 14 个库文件、升级途中数据盘被换导致 `/vol1` 只读）
  见 `docs/07-fnos-upgrade.md` 第 7~9 节。

### 关键结论（实测）

- **内核和 DTB 在 `mmcblk0p1`、由 u-boot 直读**，两个 rootfs 的 `/boot` 都是空的
  → 换 rootfs 不会换错内核，也不需要动 u-boot。
- cmdline 是 `rootflags=subvol=root`，**按名字**找子卷 → 切换/回滚 = 子卷改名，
  不必写 u-boot 环境（`saveenv` 会碰 eMMC 低区，属于禁操作）。
- 官方镜像的 `/etc/fstab` 写的是**镜像自己的 UUID**（root + /boot vfat），
  换到本机必须改，否则挂载报错。
- eMMC 必须 `compress=zstd`：新 rootfs 5.1G 逻辑内容 / 92906 个条目，而 p2 只有 7.0G
  且已放 2.5G 旧系统；实测压缩比约 3:1。注意 btrfs 的 `compress=` 只在“挂上去的那一次”
  生效——对已挂载过的 fs 再 mount 会被静默忽略，`btrfs property` 又只被直接子项继承，
  所以持久生效要写在 `/` 那一行 fstab（实测 40MB 文本占 1.4MB）。
- 镜像自带内核 `6.18.18.c944-trim` 的模块与头文件（252M+）可直接排除；
  本机是自编译 6.6.54 全内置内核，需另补 `modules.builtin*` + 板上 `depmod`。
- **rsync 默认的"大小+时间"比较不够**：复制中途复位会留下"元数据一致、内容已坏"
  的文件，后续 rsync 全部跳过，最终比对还报 0 差异 —— 升级/校验一律要带 `-c`。
  预检额外加一条 `chroot <新rootfs> /usr/lib/systemd/systemd --version`
  （只测 `bash` 会漏掉：bash 不链接 libaudit，而 PID 1 链接）。

### 决策

- **不走官方 OTA**：板子没有外网出口，且面板按伪装机型 `onethingcloud-oec`
  拉更新，拿不到 ARM 通用镜像；改为整块替换 rootfs。
- 升级会清空 fnOS 配置库（账号/存储空间/共享），`/vol1` 数据不受影响；
  旧 rootfs 子卷保留为回滚点。

---

## [0.3.0] — 2026-10-05 · 存储与服务可用

### 修复

- **第二块硬盘不被识别**：`ata2: SATA link down` → 第二个盘位没上电。
  给 `sata-port@1` 补 `sata-gpios`（引脚号取原厂 DTB 的 `misc_gpio 19`，
  而非官方参考 dtsi 的 `iso_gpio 15`）。
- **fnOS 创建存储空间失败**：内核缺 mdraid personality
  （`md: personality for level 1 is not loaded!`）。
  补 `MD_RAID0/1/10`、`MD_LINEAR`、`DM_THIN_PROVISIONING/SNAPSHOT/RAID/CRYPT`、
  `QFMT_V1/V2`、全套 dm-crypt 相关 crypto。
  修后：双盘 RAID1 → LVM → ext4，挂 `/vol1`。
- **`ovs-vswitchd` / `ovsdb-server` 失败**：缺 `CONFIG_OPENVSWITCH`。
- **`zramswap` 失败、无 swap**：缺 `CRYPTO_LZ4`（zram0 只提供 lzo/zstd）。
  修后 941 MB swap。
- **`docker` 每次开机必挂**：fnOS 自带 `ExecStop` 在无容器时报错 +
  `dockerd` 关闭时 `docker stop` 会挂住。用 systemd drop-in 覆盖（不改原单元）。
- **`modprobe` 对内置模块一律失败**：全内置内核没有模块目录。
  新增 `scripts/deploy-modmeta.sh`（拷元数据 + **板上 depmod**）。

### 新增

- `boards/rtd1296-cm360/files/docker-override.conf`
- `scripts/queue` 中的 `deploy-modmeta.sh`

---

## [0.2.0] — 2026-10-05 · 救砖 + 独立启动 + reboot

### 新增

- **ROM Monitor 救砖全流程**（`tools/recovery/`）：稀疏 Ctrl+Q（33 B/s）
  + YMODEM + 长度/CRC 校验。实测一次成功，把板子从"卡 FSBL"救回。
- **eMMC 独立启动**：u-boot 换成 BPI-W2 的，`bootcmd`/`bootargs` 已 `saveenv`。
- `patches/0004-wdt-restart.patch`：修 `reboot` 挂死。

### 关键发现（都是实测/反汇编所得）

- **Ctrl+Q 必须稀疏**：33 B/s 成功、4000 B/s 洪流失败。
  ROM 轮询前会清 RX FIFO，且要求 **≥3 个连续 `0x11`**。
- **串口必须真独占**：第二个读者会偷走板子的应答 ——
  上一轮 YMODEM "全废"的真因是手动开的 `screen` 与脚本同抢 tty，
  与洪流是**两个独立原因**（早期复盘把它们混为一谈，已更正）。
- **`reboot` 挂死的根因是"一个 restart handler 都没有"**：
  PSCI / rtk-rstctrl / 看门狗回调三者皆无。

### 证据

`evidence/logs/phoenix2-*.log`（进 monitor 与传输全过程）、
`evidence/logs/mon-g-*.log`（烧写）、`evidence/logs/bootcap-*.log`（恢复后干净启动）。

---

## [0.1.0] — 2026-10-04 · 板子点亮

### 新增

- Linux 6.6.54 在这块板上跑起来：串口 / GIC / 时钟 / eMMC(HS200) / SATA / GMAC。
- **SMP 四核**（`patches/0003`）：从核释放寄存器必须 `ioremap` + 32 位写。
- 板级 DTS 从上游极简骨架写到可用（节点注释含证据来源）。
- `evidence/reports/` 里的阶段性技术报告。
