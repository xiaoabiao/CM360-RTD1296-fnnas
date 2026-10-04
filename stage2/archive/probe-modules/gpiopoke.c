// SPDX-License-Identifier: GPL-2.0
/*
 * gpiopoke v2 —— CM360 盘位供电自动排查（built-in，late_initcall 自动执行）
 *
 * v1 的教训：6.6 gpio-rtd probe 时 gpio_chip.base = -1（动态分配），
 * legacy 整数 API gpio_request(56) 永远 -EPROBE_DEFER —— 整数号根本映射
 * 不到这块 chip。而 ahci_rtk 走 fwnode 描述符 API（devm_fwnode_gpiod_get）
 * 在 sata-port@0 上成功申请了 GPIO56，证明 chip 已注册、desc 存在。
 *
 * v2 改法：
 *   1. gpio_device_find() 直接按 ngpio==101 定位 misc_gpio 的 gpio_device，
 *      再用内部 gdev->descs[56] 拿描述符（同目录可 include gpiolib.h）。
 *      描述符操作不做所有权检查，ahci_rtk 已 request 过也不妨碍我们再驱动。
 *   2. 增加【原始寄存器交叉验证】：ioremap 0x9801b000 直读/直写
 *      DIR/DATO 寄存器。gpiod 路径写完回读寄存器，看写是否真落硬件；
 *      再绕过 gpiolib 直接写一遍，区分"驱动路径坏"和"供电逻辑坏"。
 *
 * 实验序列（每步打时间戳，用户听盘 + console 看 ata1 link up）：
 *   [T0] gpiod 读 56 电平 + 寄存器 dump（看 ahci probe 拉高后的真实现场）
 *   [T1] gpiod 56 -> 0，等 3s（若盘在转，此刻会停）
 *   [T2] gpiod 56 -> 1，等 10s（验证"低→高上电沿"假设）
 *   [T3] 原始寄存器 56 -> 0，等 3s（绕过 gpiolib 的对照组）
 *   [T4] 原始寄存器 56 -> 1，等 10s（若 T2 无效而 T4 有效 = gpiolib 路径问题）
 *   [T5] gpiod 19 -> 1，等 10s（原厂 DTB 的备选脚）
 *   [T6] 结束 dump，56/19 保持当前电平
 *
 * 任何一步盘转起来后，COMINIT 会触发 AHCI 中断 → libata EH → 自动 link up。
 */
#include <linux/module.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/io.h>
#include <linux/platform_device.h>
#include <linux/gpio/driver.h>

#include "gpiolib.h"	/* struct gpio_device 内部：descs[] 数组 */

/* ★ 2026-10-05 定案：GPIO 寄存器在 0x9801b100（vendor reg[1]，vendor 驱动
 *   of_iomap(node,1)；0x9801b000 是中断 ISR/UMSK 区——12 号 boot 全窗口
 *   dump 写前写后零变化、deadbeef 口袋，实锤写错区）。 */
#define MISC_GPIO_PA	0x9801b100UL
#define MISC_GPIO_SZ	0x200

/* rtd1295 misc：DIR 0x0..0xc，DATO 0x10..0x1c，DATI 0x20..0x2c（word*32bit） */
#define REG_DIR(i)	(0x00 + (i) * 4)
#define REG_DATO(i)	(0x10 + (i) * 4)
#define REG_DATI(i)	(0x20 + (i) * 4)

static void __iomem *regs;

static void reg_dump(const char *tag, int pin)
{
	int w = pin / 32;

	pr_info("gpiopoke[%llds]: REGDUMP %s pin%d: DIR[0x%x]=%08x DATO=%08x DATI=%08x\n",
		(long long)(ktime_get_boottime() / 1000000000), tag, pin,
		REG_DIR(w),
		regs ? readl_relaxed(regs + REG_DIR(w)) : 0,
		regs ? readl_relaxed(regs + REG_DATO(w)) : 0,
		regs ? readl_relaxed(regs + REG_DATI(w)) : 0);
}

/* 全量 dump 0x9801b000..0x9801b0ff（64 个 32bit 字，4 个一行） */
static void wide_dump(const char *tag)
{
	int i;

	for (i = 0; i < 64; i += 4) {
		pr_info("gpiopoke[%llds]: %s w%02d: %08x %08x %08x %08x\n",
			(long long)(ktime_get_boottime() / 1000000000), tag, i,
			readl_relaxed(regs + i * 4),
			readl_relaxed(regs + (i + 1) * 4),
			readl_relaxed(regs + (i + 2) * 4),
			readl_relaxed(regs + (i + 3) * 4));
	}
}

static int match_misc_gpio(struct gpio_chip *gc, void *data)
{
	/*
	 * ★ 坑：gpiolib 的 gpiochip_add_data_with_key 只把 fwnode 挂在
	 *   gdev->dev 上，不回填 gc->fwnode；gpio-rtd 也没显式设 fwnode，
	 *   所以 gc->fwnode 永远是 NULL（v2 初版在这里全军覆没）。
	 *   1296 上只有 misc GPIO 是 101 线（iso 是 35），ngpio 判据足够唯一。
	 */
	return gc->ngpio == 101;
}

static struct gpio_desc *get_desc(int hwnum)
{
	struct gpio_device *gdev;
	struct gpio_desc *desc;
	int tries;

	for (tries = 0; tries < 20; tries++) {
		gdev = gpio_device_find(NULL, match_misc_gpio);
		if (gdev)
			break;
		msleep(500);
	}
	if (!gdev) {
		pr_info("gpiopoke: misc_gpio chip 未注册（等了 10s）\n");
		return NULL;
	}
	pr_info("gpiopoke: chip=%s base=%d ngpio=%d (tries=%d)\n",
		gdev->chip->label, gdev->base, gdev->ngpio, tries);

	/* ★ 打印驱动实际映射的物理地址（与其 data->base 同源） */
	if (gdev->chip->parent) {
		struct resource *res;
		int n;

		for (n = 0; n < 2; n++) {
			res = platform_get_resource(
				to_platform_device(gdev->chip->parent),
				IORESOURCE_MEM, n);
			if (res)
				pr_info("gpiopoke: 驱动 resource%d = %pap-%pap\n",
					n, &res->start, &res->end);
		}
	}

	desc = &gdev->descs[hwnum];
	pr_info("gpiopoke: desc[%d] 全局号=%d\n", hwnum, desc_to_gpio(desc));
	return desc;
}

static int __init gpiopoke_init(void)
{
	struct gpio_desc *d56;
	int ret;

	d56 = get_desc(56);
	if (!d56)
		return 0;

	regs = ioremap(MISC_GPIO_PA, MISC_GPIO_SZ);
	if (!regs)
		pr_info("gpiopoke: ioremap 失败，寄存器交叉验证不可用\n");

	/* T0：读初值 + 全量现场 dump（含 ahci probe 已拉高后的状态） */
	ret = gpiod_get_value(d56);
	pr_info("gpiopoke[%llds]: T0 gpiod_get_value(56)=%d ret逻辑值\n",
		(long long)(ktime_get_boottime() / 1000000000), ret);
	reg_dump("T0 初值", 56);
	if (regs)
		wide_dump("T0");

	/*
	 * ★ 2026-10-05 #13 教训：T1/T3 写实验把盘的供电在起转途中掐了三次
	 *   （2s、15s），libata 的 EH 重训预算耗尽在 21.4s，盘 ~25s 才稳定
	 *   → 端口休眠、无 sda。DSM 干净时间线（供电后 23.6s link up）证明
	 *   只要供电一次到位 + 不折腾，EH 重试窗口足够。
	 *   所以 v4 全程【只读】：供电完全交给 ahci_rtk probe（1s 拉高不松手）。
	 *   这里只周期性观察链路/寄存器状态，给 console 留证据。
	 */
	{
		int i;

		for (i = 0; i < 6; i++) {
			msleep(10000);
			ret = gpiod_get_value(d56);
			pr_info("gpiopoke[%llds]: 只读观察#%d gpiod(56)=%d ata状态见 ata1 日志\n",
				(long long)(ktime_get_boottime() / 1000000000), i, ret);
		}
	}

	reg_dump("T6 结束(56)", 56);
	pr_info("gpiopoke: === 实验序列结束（56/19 保持当前电平）===\n"
		"gpiopoke: 若盘已转，等 COMINIT 触发热插拔，ata1 应自动 link up\n");
	if (regs)
		iounmap(regs);
	return 0;
}

late_initcall(gpiopoke_init);
MODULE_LICENSE("GPL");
