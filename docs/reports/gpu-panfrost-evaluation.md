# CM360 GPU（Mali-T820）驱动现状评估与修复方案

> 日期：2026-10-26 · 板子：CM360 / RTD1296 / 自编译 Linux 6.6.54 / fnOS 1.2.0302
> 结论：**GPU 驱动确实没有装（内核里既没有 panfrost 模块，DTS 里也没有 GPU 节点）**，
> 但 fnOS 用户态已经带了 Mesa panfrost 驱动和 Mali 固件，**只差内核侧**。
> 真正启用需要一个内核补丁包 + 重新编译/刷内核，细节和风险评估见下文。

---

## 1. 硬件与现状

| 项目 | 事实 |
|---|---|
| SoC | Realtek RTD1296（4×A53 + **Mali-T820**，文档记为 Midgard v5） |
| GPU 基址（上游 RFC） | `0x98050000`，长度 `0x10000` |
| 中断（上游 RFC） | `GIC_SPI 66/67/68` = `gpu` / `job` / `mmu` |
| 时钟 | `RTD1295_CRT_CLK_EN_GPU`（clk id 43，CCF 已注册） |
| 复位 | `RTD1295_CRT_RSTN_GPU`（CCF reset 已注册） |
| 电源门控 | 厂商私有 `realtek,powerctrl-gpu-core` / `powerctrl-sram`（regs 见 §4） |

### 1.1 板上实测（2026-10-26）

```sh
$ ls /dev/mali* /dev/dri*          # 都没有
$ dmesg | grep -iE 'mali|panfrost|drm'   # 只有 drm 模块加载尝试，无 GPU
$ ls /lib/modules/$(uname -r)/     # 只有 metadata，没有 .ko
$ ls /sys/kernel/debug/pm_genpd/   # 没有任何 power domain
```

内核配置（`artifacts/kernel-6.6.54/kernel.config`）：

```
CONFIG_DRM=m
CONFIG_DRM_SCHED=m
CONFIG_DRM_PANFROST=m      # 编译成模块，但**从没被编进/装进系统**
```

板级 DTS（`boards/rtd1296-cm360/rtd1296-cm360.dts`）里**没有 GPU 节点**；
连厂商 DTS（`vendor-firmware/*.dts`）也没有 GPU 设备节点（Realtek 的 Mali 驱动是
平台硬编码，不走 DT），只有 GPU 的时钟/复位/电源门控节点。

### 1.2 用户态反而是齐的（关键发现）

fnOS rootfs 里已经有：

```
/usr/lib/aarch64-linux-gnu/dri/panfrost_dri.so     ← Mesa 的 Panfrost 驱动
/usr/lib/firmware/arm/mali/arch10.8/mali_csffw.bin ← Midgard/Bifrost 固件（274 KB）
/usr/trim/bin/maligpu-fw-symlink                   ← 把上面固件链到 /lib/firmware/mali_csffw.bin
```

但 `maligpu-fw-symlink` 只匹配 **Rockchip RK3582/RK3588/RK3588S**（和 CIX ACPI 机型），
`realtek,rtd1296` 不匹配 → 当前 `/lib/firmware/mali_csffw.bin` 不存在。
也就是说：**只要内核侧把 panfrost 跑起来，用户态和固件都是现成的。**

---

## 2. 结论：缺的是三层里的三样东西

1. **内核驱动没有落地**：`CONFIG_DRM_PANFROST=m`，但我们的构建流程只产出
   `Image-6.6.uimage` + DTB，没有 `make modules` / 安装 `.ko`，rootfs 里也没有模块。
   即使有模块，DTS 没有 `gpu@98050000` 节点，panfrost 也无从 probe。
2. **DTS 里缺 Mali 节点**（pinmux 意义上的资源描述：reg/irq/clk/reset）。
   上游 Andreas Färber 2019 年发过 RFC，给了 RTD1295 的完整节点（见 §3），
   但该系列**从未合入主线**；RTD1296 主线 DTS 至今没有 GPU。
3. **GPU 电源门控没有驱动**：panfrost 需要先给 GPU 上电（厂商的
   `pctrl_gpu` / `pctrl_gpu_core1..3` / `pctrl_l4_icg_gpu`）。内核里没有对应驱动，
   厂商 DTS 的 `status = "disabled"` 也说明这块依赖厂商 4.9 内核的
   `realtek,powerctrl-*` 驱动。**这是整个方案唯一的硬骨头。**
   RFC 作者当年在 Zidoo X9S 上实测就是卡在这里：

   ```
   panfrost 98050000.gpu: clock rate = 503929687
   panfrost 98050000.gpu: gpu soft reset timed out
   panfrost 98050000.gpu: Fatal error during GPU init
   panfrost: probe of 98050000.gpu failed with error -110
   ```

---

## 3. 可直接用的上游参考（Mali 节点）

来源：`[RFC 3/7] arm64: dts: realtek: rtd1295: Add Mali node`（2019-11-04，
<https://lore.kernel.org/all/20191104013932.22505-4-afaerber@suse.de/>）。
把它改成本仓库的 CCF 句柄（`&cc` 而不是 `&clkc`）即可：

```dts
&cc { /* 已有 clock-controller，无需改 */ };

/ {
	mali_opp_table: gpu-opp-table {
		compatible = "operating-points-v2";
		opp-500000000 { opp-hz = /bits/ 64 <500000000>; opp-microvolt = <1000000>; };
		/* 其余档位照抄 RFC；本板无 PMIC 调压，可只留一档 */
	};

	soc {
		mali: gpu@98050000 {
			compatible = "realtek,rtd1295-mali", "arm,mali-t820";
			reg = <0x98050000 0x10000>;
			clocks = <&cc RTD1295_CRT_CLK_EN_GPU>;
			clock-names = "core";
			resets = <&cc RTD1295_CRT_RSTN_GPU>;
			interrupts = <GIC_SPI 67 IRQ_TYPE_LEVEL_HIGH>,
			             <GIC_SPI 68 IRQ_TYPE_LEVEL_HIGH>,
			             <GIC_SPI 66 IRQ_TYPE_LEVEL_HIGH>;
			interrupt-names = "job", "mmu", "gpu";
			operating-points-v2 = <&mali_opp_table>;
			#cooling-cells = <2>;
		};
	};
};
```

并要求内核配置（`scripts/build-kernel.sh` 的 6.6 树）：

```
CONFIG_DRM=y                 # panfrost 内置时 DRM 不能再是模块
CONFIG_DRM_SCHED=y
CONFIG_DRM_GEM_SHMEM_HELPER=y
CONFIG_DRM_PANFROST=y
```

> 也可以保持 `DRM=m` + 单独构建/安装 `panfrost.ko`，但要把 .ko 随 rootfs 一起发，
> 并保证 vermagic 完全一致 —— 比直接内置麻烦，不推荐。

---

## 4. 电源门控（真正的难点）

厂商 DTS（`vendor-firmware/ds218-cm360-1020.dts`）里 GPU 相关的三个节点：

```dts
pctrl_gpu {                       # 兼容 realtek,powerctrl-sram
	reg = <0x9800036c 0x04 0x980003a4 0x04>;
	power-state = "off";
};
pctrl_l4_icg_gpu {                # 兼容 realtek,powerctrl-simple（厂商 DTS 里 disabled）
	reg = <0x98055004 0x04 0x980540b4 0x04>;
	shift = <0x10 0x00>; width = <0x01 0x01>;
	on-value = <0x01 0x01>; off-value = <0x00 0x00>;
	is-l4-icg; clocks = <0x2d>; resets = <0x16 0x12>;
};
pctrl_gpu_core@1/2/3 {            # 兼容 realtek,powerctrl-gpu-core
	reg = <0x98050180 0x04 0x980501c0 0x04>;   # on-reg / off-reg
	on-shift = <0 1 2>; off-shift = <0 1 2>;
};
```

启用 GPU 至少要：**给 GPU SRAM/电源岛上电 → 打开 3 个 core 的 on 位 → 解除 L4 ICG**
（顺序/延时/是否需要“先 off 再 on”需要参照厂商 `powerctrl-*` 驱动，目前没有公开主线实现）。
可选路线：

- **A. 移植厂商 powerctrl 驱动**（推荐，正统）：从 Realtek 4.9 BSP（如
  `BPI-SINOVOIP/BPI-W2-bsp` 的 `linux-rtk` 树）把 `realtek,powerctrl-gpu-core` /
  `powerctrl-sram` / `powerctrl-simple` 三个小驱动迁到 6.6（API 改动不大），
  再把厂商 DTS 的 pctrl 节点裁剪进我们的 DTS。
- **B. 写一个最小「GPU 上电」平台驱动**：probe 时按厂商语义写上述寄存器，
  不实现 runtime PM（一直供电）。最快，但寄存器语义要靠试；
  对 NAS 这种 GPU 常闲的机器足够。
- **C. U-Boot 里预上电**：在 `bootcmd` 里 `mw` 写电源寄存器，内核不碰。
  改动最小、最脏，且与 U-Boot 版本耦合；只适合做实验验证。

---

## 5. 还需要做的事

1. **固件软链**：启用后需要 `/lib/firmware/mali_csffw.bin` →
   `/usr/lib/firmware/arm/mali/arch10.8/mali_csffw.bin`。
   可以在 `cm360-firstboot.sh` 或兼容层安装脚本里加一行（幂等）。
   （panfrost 6.6 找 `mali_csffw.bin`；fnOS 用软链而不是拷贝。）
2. **fnOS 服务**：`mediasrv` 等是否会因 GPU 出现而改变行为未知；风险低。
3. **验证**：
   ```sh
   dmesg | grep -i panfrost            # 期望 probe 成功、显示 mali-t820
   ls /dev/dri/                        # 期望 renderD128
   cat /sys/class/drm/renderD128/device/uevent
   # Mesa 侧（需要 GL 应用，fnOS 上没有 glxinfo；可用 mesa 自带工具或自编）
   ```
4. **注意**：fnOS 的「硬件转码」走的是 **VPU/VE**（V4L2/MPP），不是 GPU；
   GPU 只影响 OpenGL ES/OpenCL 类负载。也就是说：**修好 GPU 不会让「影视」转码
   变硬解**，这一点要先对齐预期（VPU 驱动是另一个更大的坑）。

---

## 6. 工作量 / 风险评估

| 路线 | 改动 | 预计工作量 | 风险 |
|---|---|---|---|
| 不做 | — | 0 | fnOS 现有功能不受影响（当前就是软件路径） |
| A：panfrost + 移植 powerctrl | DTS + 内核 config + 3 个电源驱动 + 固件软链 | 2~5 天（含调试） | 中：电源时序错会 `reset timeout`；不会砖，只 probe 失败 |
| B：最小上电驱动 | DTS + config + 1 个小驱动 | 1~2 天 | 中：寄存器语义靠试；`/dev/mem` 误写有重启风险 |
| C：U-Boot 预上电 | U-Boot 环境变量 | 半天 | 低（可回滚），但不可持续 |

**共同前提**：必须有能编译 6.6.54 内核的环境（`~/.cache/rtd1296/xpressreal-linux`
+ 交叉工具链）并愿意刷 p1/p2 做验证 —— 这块在当前这台 Windows 工作机上做不了，
只能在你的 Linux 构建机上执行。

---

## 7. 建议的下一步

1. 先确认目标：只是为了「系统信息里有 GPU / 能跑 OpenGL」，还是想解决某个具体功能
   （转码？相册 AI？）。如果是后者，**GPU 大概率不是正确方向**（VPU 才是）。
2. 若确认要做：按 A 路线，我可以先产出
   - `boards/rtd1296-cm360/rtd1296-cm360.dts` 的 Mali 节点补丁（默认不启用，注释开关）；
   - `scripts/build-kernel.sh` 的 config 片段；
   - 从 BPI-W2 BSP 剥离的 `powerctrl-*` 驱动移植草稿；
   - 固件软链的一行 firstboot 逻辑；
   - 一份「编译→刷 p1→dmesg 验证」的操作清单。
   但移植驱动需要在构建机上反复编译/试错，无法在本机闭环。
3. 如果只是想把「GPU 缺失」记录清楚：本文档就是结论，可直接给同事/后续版本引用。

---

## 8. WSL 构建 + 板端验证（**kexec 在本板不可用**）

已确认本机 WSL（Ubuntu-26.04，16 核 / 7.6 GiB / 881 GiB 空闲）可以承担 6.6.54
内核构建，并且已经成功编出带 GPU 的 `Image-6.6`（38.5 MB）和 DTB（9 KB）。

### 8.1 为什么不能用 kexec（2026-10-26 实测）

板子 `CONFIG_KEXEC=y`，kexec-tools 也装好了，但 `kexec -l` 直接失败：

```
kexec_load failed: Device or resource busy
dmesg: Can't kexec: CPUs are stuck in the kernel.
```

原因在 arm64 的 `machine_kexec_prepare()` → `cpus_are_stuck_in_kernel()`：
`smp_spin_tables = (num_possible_cpus() > 1 && !have_cpu_die())`。
本板 SMP 用的是 **rtk-spin-table**（不是 PSCI），cpu_ops 没有 `cpu_die`，
于是内核直接拒绝 kexec。**这是平台限制，不是配置问题**，所以「零风险 kexec 试内核」
这条路走不通。

### 8.2 可行且低风险的验证方式：u-boot 串口 + ext4load 测试内核

不修改 `bootcmd`、不覆盖现有内核，只把测试内核作为**另一个文件**放进 p1：

```sh
# 板端 Linux：把测试内核塞进 p1（p1 是 ext4，直接挂 loop 拷贝）
mkdir -p /mnt/p1 && mount /dev/mmcblk0p1 /mnt/p1
cp /vol1/.../Image-6.6.uimage /mnt/p1/Image-6.6-test.uimage
cp /vol1/.../rtd1296-cm360-test.dtb /mnt/p1/rtd1296-cm360-test.dtb
umount /mnt/p1

# 串口进 u-boot（bootdelay 3 秒），手动：
ext4load mmc 0:1 0x03000000 Image-6.6-test.uimage
ext4load mmc 0:1 0x02100000 rtd1296-cm360-test.dtb
bootm 0x03000000 - 0x02100000
```

- `bootcmd` 没动：正常重启仍然引导旧内核；
- 测试内核起不来就按复位，机器照常回旧内核；
- 需要一根 USB-TTL 串口线（本机 COM1 是主板内置串口，不是板子的 UART）。

### 8.3 WSL 侧复现构建（已验证可跑通，约 8 分钟）

```sh
cd /mnt/c/Users/xiaoa/CM360-RTD1296-fnnas
export KTREE=/root/cm360-build/kernel OUT=/root/cm360-build/out-gpu
./scripts/setup-deps.sh     # 拉 XpressReal/linux 的 be79582cb
./scripts/build-kernel.sh   # DTS + config 已包含 GPU 节点/开关
```

当前仓库已就位的最小改动：
- `boards/rtd1296-cm360/rtd1296-cm360.dts` 新增 `gpu@50000`（`arm,mali-t820`）；
- `scripts/build-kernel.sh` 新增 `-e DRM -e DRM_PANFROST`（把 defconfig 的 `=m` 内置）。

预期结果分两种：
1. `dmesg` 出现 `panfrost ... mali-t820` + `/dev/dri/renderD128` → CM360 的 GPU
   电源是常开的，**到此就完成了**（再补个 Mesa 使用验证）。
2. `gpu soft reset timed out` → 说明需要做 §4 的电源门控移植（路线 A/B）。

### 8.1 关于固件
6.6 的 panfrost 在 Midgard 上**不加载固件**（`panfrost_device.c` 里没有
`request_firmware`），fnOS 那个 `mali_csffw.bin` 软链是给别的驱动/用户态用的，
GPU 实验阶段可以不管。

---

## 9. VPU（硬件转码）能不能一起搞？

**能，但和 GPU 不是一个量级的工作，且 fnOS 的转码链路不认 Realtek。**

| 层 | 现状 | 要做的事 |
|---|---|---|
| 内核 | 无任何 Realtek VE/JPU 驱动（主线没有；XpressReal 树只有厂商 4.9 的 `rtk_ve`） | 把 BPI-W2 BSP 的 `rtk_ve`（VDI/JDI，含 `vpu.c`/`jpu.c`）移植到 6.6：DMA/IOMMU、mmap/ioctl、时钟/复位/电源域、媒体堆 reserved-memory 全要重做 |
| 用户态 | fnOS 自带 ffmpeg 的 `-hwaccels` = cuda/drm/opencl/rkmpp/v4l2request，**没有 Realtek** | 厂商 API 的 `ffmpeg-rtk`（jjm2473）或 libvpu；还要保证 ABI 能被 fnOS 的 `mediasrv` 调用 |
| fnOS 服务 | `mediasrv` 自己决定用软件 x264/x265；转码参数由它拼 | 要么替换 fnOS 的 ffmpeg 并让它走 hwaccel，要么改 `mediasrv`（闭源 Go），风险高 |

结论：
- **GPU**：1~5 天（先 kexec 试，失败再移植电源门控），风险可控。
- **VPU**：先做 1 天 spike（把 `rtk_ve` 拉到 6.6 直接 `make`，统计 API 断裂点与
  缺失的 media-heap 依赖），**再**决定要不要投入 2~4 周；且即便驱动跑通，
  不保证 fnOS 的「影视」会用上（那是它自己的转码服务）。
- 如果目标是「自己的媒体流水线硬转码」（而不是 fnOS 影视），VPU+GStreamer/ffmpeg-rtk
  是独立可行的，但那是另一个项目，和 fnOS 无关。

---

## 10. 参考

- Mesa Panfrost 支持列表（T820 在列，GLES 3.1/GL 3.1/OpenCL 3.0）：
  <https://docs.mesa3d.org/drivers/panfrost.html>
- Mali 节点 RFC（RTD1295）：
  <https://lore.kernel.org/all/20191104013932.22505-4-afaerber@suse.de/>
- RTD1296 BSP（厂商 powerctrl / Mali 驱动参考）：
  <https://github.com/BPI-SINOVOIP/BPI-W2-bsp>（`linux-rtk` 树）
- 本仓库相关：`docs/reports/driver-inventory.md`（§PVR/VPU 缺失）、
  `artifacts/kernel-6.6.54/kernel.config`、`boards/rtd1296-cm360/vendor-firmware/`
