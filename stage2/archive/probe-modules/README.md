# 诊断模块归档说明

这两个模块是 CM360 移植过程中的**只读取证工具**，已完成使命，从内核树中移除。
源码保留在此，供后续调试（如 SDMMC/USB 攻关）复用。

## 为什么移除

| 模块 | 原作用 | 移除原因 |
|---|---|---|
| `emmcprobe.c` | eMMC 控制器 + CRT eMMC PLL 寄存器转储 | eMMC 已点亮（HS200），且它**每 12s 周期性 dump**，持续污染 console |
| `gpiopoke.c` | 盘位供电 GPIO 排查（后改为只读观察） | SATA 已点亮，且它也**每 10s × 6 次**刷 console |

两者共同的问题：**周期性 pr_info 会干扰串口命令接收**（实测导致
`ttyS0: 1 input overrun(s)`）。在内核已经稳定后，这属于纯粹噪声。

## 移除方式（本次实际执行）

1. `drivers/gpio/Makefile` 删掉两行：
   ```
   obj-y += gpiopoke.o
   obj-y += emmcprobe.o
   ```
2. 删除 `drivers/gpio/emmcprobe.c`、`drivers/gpio/gpiopoke.c`
3. 清构建缓存：`rm -f drivers/gpio/{emmcprobe,gpiopoke}.o
   drivers/gpio/.{emmcprobe,gpiopoke}.o.cmd drivers/gpio/built-in.a`
4. **`patches/0000-preexisting-driver-patches.patch` 同步裁剪** ——
   该补丁原本含"Makefile 加两行 + 新建两个 .c"，移除后只剩
   `irq-realtek-mux.c` 与 `phy-rtk-sata.c` 两处真实驱动修复。
   否则 `apply-kernel-patches.sh` 会因"新增文件缺失"报
   `既不能正向应用也不能反向应用`。

## 验证方式（可复用）

```bash
# 1) 源码与 Makefile 无残留
grep -rn "emmcprobe\|gpiopoke" drivers/gpio/

# 2) Image 里无模块字符串（应为 0）
strings out/Image-6.6 | grep -c "emmcprobe\|gpiopoke"

# 3) 对照：应有的功能痕迹还在（SMP 修复）
strings out/Image-6.6 | grep -c "Booted secondary processor"   # 应 = 1

# 4) 补丁幂等
patch -p1 --dry-run --reverse --silent < patches/0000-*.patch  # 应成功
```

## 复用提示

若要给 SDMMC / USB 做寄存器级取证，直接照 `emmcprobe.c` 的骨架改：
```
late_initcall + of_iomap/ioremap + readl only（绝不 writel）
```
**切记：调试完成后把周期性打印也去掉**，或改成"只 dump 一次"，
否则又会污染 console。更省事的做法是改用 `devmem`（若 initramfs 里有）
或 debugfs 节点，避免编进内核。
