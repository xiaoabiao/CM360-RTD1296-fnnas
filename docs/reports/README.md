# reports/ —— 阶段性技术报告

这些是**开发过程中留下的现场报告**，不是"教程"，所以：

- 保留原始措辞与当时的判断（包括后来被更正的结论）；
- 文中路径是**重排前**的 `stage0/` `stage1/` `stage2/`；
  对照表见 [`../incident-2026-10-05-emmc-recovery.md`](../incident-2026-10-05-emmc-recovery.md) 开头。

想看"现在该怎么做"，请回到 [`../../README.md`](../../README.md) 与 `docs/01`~`docs/06`。

| 文件 | 内容 |
|---|---|
| `feasibility-assessment.md` | 立项时的移植可行性评估（含后来实测的修正） |
| `driver-inventory.md` | 主线驱动现状盘点（哪些驱动缺、缺多少行） |
| `peripherals-sata-gmac-emmc.md` | 外设摸底实测报告 |
| `smp-success-report.md` | SMP 四核攻关全过程（含失败路径） |
| `stage0-*.md` | 原厂固件信息收集阶段的分析（启动日志、DTB 反编译） |
| `fnos-image-anatomy.md` / `fnos-rootfs-checklist.md` | fnOS 镜像结构与 rootfs 适配清单 |
| `ophub-fnnas-assessment.md` | ophub fnNAS 方案对比 |
| `devlog-stage2.md` | 内核移植阶段的开发日志（较长，含逐项实测过程） |
| `fnos-6.18-kernel-re/` | fnOS 官方 6.18 内核 + 用户态私有 ABI 逆向（trimafs / TrimACL / 魔数 faccessat / trashbin） |
| `fnos-acl-compat-layer.md` | **6.6.54 上补齐私有 ACL/faccessat ABI 的用户态兼容层**（面板「上传文件失败」、共享文件夹建不出的修复） |
| `fnos-api-repro.md` | 面板登录 + 文件 RPC + 上传的脚本化复现（`tools/fnos-api.py`），含 shim 开/关 A/B 对照 |
| `fnos-upload-checkupload-re.md` | `file.checkUpload` / uploadsrv 写路径的逐检查反汇编（errno 9 来源、错误码表、配额/空间残余风险） |
| `fnos-trashbin-re.md` | 回收站私有 ABI 逆向后端：魔数 `unlinkat`、回收站目录/记录 xattr 格式、RPC 验证、`trash-ref.c` 参考实现 |
| `gpu-panfrost-evaluation.md` | **GPU（Mali-T820）现状与修复方案**：为什么没有 `/dev/dri`、上游 Mali 节点、panfrost/固件/用户态现状、供电门控难点与两条实施路线 |
| `cm360-led-gpio-re.md` | 盘位指示灯 GPIO 逆向：证据链、候选排序、`board.json` 变体、最小风险单引脚写测试 |
| `cm360-usb-led-fix.md` | **USB-A / Type-C 与盘位指示灯修复（已上板验证）**：DTS 缺口、硬件拓扑坐标、驱动契约、极性写反的教训、`disk-activity` 为何不闪、灯守护设计、部署回滚 |
| `uefi/firmware-options.md` | 固件侧：U-Boot/EDK2 对 RTD129x 的支持现状、EFI_LOADER 要求、Armbian RTD129x 补丁、移植工作量 |
| `uefi/installer-options.md` | 安装器侧：Debian/Ubuntu arm64 ISO 引导链、d-i 内核驱动矩阵、`booti`/hd-media 路径、方案对比 |
