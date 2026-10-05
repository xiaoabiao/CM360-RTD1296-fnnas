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
