# CM360（RTD1296）SMP 攻关成功报告

**日期**：2026-10-05 04:31
**结论**：四核全部上线，`smp: Brought up 1 node, 4 CPUs`。
**内核**：`Linux version 6.6.54-gbe79582cba58-dirty ... #21 SMP PREEMPT Mon Oct 5 04:29:25 CST 2026`

---

## 一、问题链条（两段式）

### 第 1 段：原厂给的 enable-method 名字，主线不认

初次上板只有 CPU0：

```
[0.000000] /cpus/cpu@1: missing enable-method property
[0.000000] /cpus/cpu@2: missing enable-method property
[0.000000] /cpus/cpu@3: missing enable-method property
[0.095545] smp: Brought up 1 node, 1 CPU
```

**根因**：原厂 DTB 用 `enable-method = "rtk-spin-table"`（对应 Realtek 自研
`rtk_smp_spin_table_ops`），而主线 `arch/arm64/kernel/cpu_ops.c` 的
`dt_supported_cpu_ops[]` **只认** `"spin-table"` / `"psci"` 两个字面量，
匹配不上就报 `missing enable-method` 并让该核掉线。

**修法**：DTS 里四个核改成主线名 `"spin-table"`，并补 `cpu-release-addr`（2 cell）：

```dts
cpu1: cpu@1 {
    enable-method = "spin-table";
    cpu-release-addr = <0x0 0x9801aa44>;
};
```

### 第 2 段（更隐蔽）：改完 DTB 后，内核**直接挂死**，无任何报错

```
[0.0455] Mountpoint-cache hash table entries: ...
（此处之后 console 永久静止，无 panic、无 oops、无 Call trace）
```

**定位方法**：拿上次单核成功的日志对比，找出"下一个本该出现的行"。
单核日志此处会打：`RCU Tasks: Setting shift to 0 and lim to 1 ...`，
它位于 `rcu_init_tasks_generic()`（main.c 1540 行），**在 `smp_prepare_cpus()` 之后**。
⇒ 卡在 `smp_prepare_cpus()` 的 `ops->cpu_prepare(cpu)` 循环里。

**根因**：`cpu-release-addr = 0x9801aa44` **不是内存**。
`0x9801a000 + 0xa44` —— 它落在 `pinctrl@9801A000` 的 reg 区间内，
是 SoC 的"从核释放"**硬件握手寄存器**。

而 ARM 官方 spin-table 规范规定该地址是**内存**（bootloader 在该处轮询、内核写入入口地址），
主线 `smp_spin_table_cpu_prepare()` 照规范实现：

```c
/* 上游主线 —— 按"内存"访问设备寄存器 → 总线挂死 */
release_addr = ioremap_cache(cpu_release_addr[cpu], sizeof(*release_addr));  /* PROT_NORMAL */
writeq_relaxed(pa_holding_pen, release_addr);                                /* 8 字节缓存突发写 */
dcache_clean_inval_poc((unsigned long)release_addr, ... + sizeof(*release_addr));
sev();
```

一次缓存的 8 字节突发写打到设备寄存器空间 → 总线 hang。

---

## 二、修复（三处，已固化为补丁）

### 1) DTS：`rtd1296-cm360.dts`

```dts
enable-method = "spin-table";                      /* 原厂 "rtk-spin-table" → 主线名 */
cpu-release-addr = <0x0 0x9801aa44>;               /* 必须 2 cell，of_property_read_u64 */
```

### 2) 内核：`arch/arm64/kernel/smp_spin_table.c` → `smp_spin_table_cpu_prepare()`

对照原厂 `linux-rtk/drivers/soc/realtek/rtd129x/rtd129x_spin_table.c`
（`rtk_smp_spin_table_ops`）逐项改：

| 项 | 上游主线（挂死） | 原厂 Realtek（正解） | 本轮 |
|---|---|---|---|
| 映射 | `ioremap_cache()` PROT_NORMAL | `ioremap()` PROT_DEVICE_nGnRE | ✅ 改 |
| 写宽度 | `writeq_relaxed()` 8 字节 | `writel_relaxed()` 4 字节 | ✅ 改 |
| 类型 | `__le64 __iomem *` | 32 位 | ✅ `__le32` |
| cache 维护 | `dcache_clean_inval_poc()` | 无（设备映射无 cache 可同步） | ✅ 去掉 |
| 收尾 | 无 | `iounmap()` | ✅ 加 |

**注意边界（这两处故意不改）**：
- `write_pen_release()` 里的 `dcache_clean_inval_poc` **必须保留** ——
  那里访问的是**内存**变量 `secondary_holding_pen_release`。
- `smp_spin_table_cpu_boot()` 不改 —— 首次 bring-up 走 `cpu_prepare`，不走它。
- 原厂用 `__pa()`、主线用 `__pa_symbol()`：本内核 `CONFIG_RANDOMIZE_BASE is not set`
  → 二者等价，沿用 `__pa_symbol()`。

### 3) 补丁固化

`stage2/patches/0003-smp-rtk-spin-table.patch`（3141 字节，67 行），
反向 dry-run 通过 ⇒ 幂等，可被 `apply-kernel-patches.sh` 反复执行。

---

## 三、上板实测结果

### 内核启动日志

```
[0.056370] RCU Tasks: Setting shift to 2 and lim to 1 rcu_task_cb_adjust=1.
                                                        ↑ 单核时是 0 —— 该值随 nr_cpu_ids 变，本身即 SMP 生效信号
[0.090704] smp: Bringing up secondary CPUs ...
[0.096423] CPU1: Booted secondary processor 0x0000000001 [0x410fd034]
[0.097093] CPU2: Booted secondary processor 0x0000000002 [0x410fd034]
[0.097727] CPU3: Booted secondary processor 0x0000000003 [0x410fd034]
[0.097819] smp: Brought up 1 node, 4 CPUs
```

### 用户态确认

```
/ # cat /sys/devices/system/cpu/online      →  0-3
/ # cat /sys/devices/system/cpu/present     →  0-3
/ # nproc                                   →  4
/ # head -3 /proc/interrupts
           CPU0       CPU1       CPU2       CPU3
  9:          0          0          0          0     GICv2  25 Level     vgic
 11:        654        306        410        816     GICv2  30 Level     arch_timer
```

- `/proc/cpuinfo` 四段（processor 0/1/2/3，`CPU part: 0xd03` = Cortex-A53 r0p4）
- `missing enable-method` = **0**，`Unsupported enable-method` = **0**
- **`arch_timer` 中断分布 654 / 306 / 410 / 816** —— 四核都非零，
  证明中断真的在被多核分担，而不只是表头列出了核名。

### 外设未受破坏

`ata1: SATA link up 6.0 Gbps (SStatus 133 SControl 300)` @19.7s，
`HUH721212ALE600` 23437770752 扇区、`sda1/2/3` 均可见 ⇒ SMP 与外设共存正常。

---

## 四、产物清单（均已逐字节校验）

| 文件 | 大小 | md5 |
|---|---|---|
| `out/Image-6.6` | 31552000 | `e85bbc2463b1edc8a3fde9d1dec14a88` |
| `Image-6.6.uimage`（部署到 tftproot） | 31552064 | `adfe34032f3c7c559e6099933a6581c1` |
| `rtd1296-cm360.dtb` | 7424 | `a6605ea4d65157394fbf78554ce0fd96` |
| `initramfs.cpio.gz` | 664566 | `1f817b26151554ef2096efed51ffd574` |

**uImage 载荷 md5 校验**：`tail -c +65 Image-6.6.uimage | md5sum`
= `e85bbc2463b1edc8a3fde9d1dec14a88` = `out/Image-6.6` 的 md5 ⇒ 部署的确是含修复的内核。

**反汇编自证**（修复真进了二进制）：
```
110: mov x1, #0x4              ← 4 字节长度
114: bl  0 <ioremap_prot>      ← 设备映射路径（非 ioremap_cache）
120: str w19, [x0]             ← 32 位存储
124: sev
```

---

## 五、复现命令

```bash
cd /home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage2
./04-build-66.sh          # 编译（含内核+DTS）
./05-deploy-66.sh         # 推 tftproot
./12-smp-run.sh 1800      # 守候：抓 u-boot → boot66 → 等 shell → SMP 体检
```

## 六、遗留

1. **`emmcprobe.c` 调试模块仍在每 12s 周期性 dump**（2s → 113s+）→ 污染 console，
   致 `ttyS0: 1 input overrun(s)` 干扰命令接收。**量产前必须摘掉或关定时打印**。
2. `resume-entry-addr` 的 `FDT_ERR_BADOFFSET` 警告仍在（u-boot 从
   `compatible = "Realtek,rtk_boot"` 节点读，原厂 DTB 无此节点、由 u-boot 运行期加）
   —— 只影响 hotplug / 挂起恢复，不影响首次 bring-up。
3. 下一站候选：SDMMC / USB / fnOS 安装器适配 / VPU 转码（可选）。
