// SPDX-License-Identifier: GPL-2.0
/*
 * emmcprobe —— CM360 eMMC 控制器 + CRT eMMC PLL 寄存器一次性转储（只读）
 *
 * 为什么需要它：initramfs 里没有 devmem，而 eMMC 的症状（CMD0/CMD1 无中断、
 * "Card stuck being busy"、驱动 wait_done 反复超时、PLL_STATUS 疑似为 0）
 * 必须在【控制器 + PLL 寄存器真值】层面才能定位。
 * CCF 的 clk_summary 只能说"软件上开着"，硬件到底锁没锁要看寄存器。
 *
 * 本模块【只读】：ioremap 后只 readl，绝不 writel。late_initcall 立即 dump
 * 一次，并挂一个延时工作每 12s 再 dump 一次、共 4 次（覆盖 mmc rescan 窗口）。
 * 目录与 gpiopoke 放一起，纯为复用 drivers/gpio/Makefile 里那行 obj-y。
 */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/workqueue.h>
#include <linux/ktime.h>

/* CRT：eMMC 主 PLL 在 0x1f0..0x1fc（u-boot rtkemmc.h: PLL_EMMC1..4 = 0x980001f0..） */
#define CRT_PA		0x98000000UL
#define CRT_SZ		0x400

/* eMMC 控制器：reg[0] = <0x12000 0xa00> */
#define EMMC_PA		0x98012000UL
#define EMMC_SZ		0x1000

static void __iomem *crt, *mc;
static struct delayed_work dump_work;
static int dump_left = 4;

static void dump_once(const char *tag)
{
	long long s = ktime_get_boottime() / 1000000000;

	if (!crt || !mc) {
		pr_err("emmcprobe: ioremap failed (crt=%p mc=%p)\n", crt, mc);
		return;
	}

	pr_info("emmcprobe[%llds] ===== PLL/CTRL dump %s =====\n", s, tag);

	/* --- CRT eMMC PLL --- */
	pr_info("emmcprobe: PLL_EMMC1(0x1f0)=%08x  PLL_EMMC2(0x1f4)=%08x\n",
		readl_relaxed(crt + 0x1f0), readl_relaxed(crt + 0x1f4));
	pr_info("emmcprobe: PLL_EMMC3(0x1f8)=%08x  PLL_EMMC4(0x1fc)=%08x\n",
		readl_relaxed(crt + 0x1f8), readl_relaxed(crt + 0x1fc));

	/* --- DWC 通用块（0x000..0x048） --- */
	pr_info("emmcprobe: CTRL(0x000)=%08x PWREN(0x004)=%08x CLKDIV(0x008)=%08x\n",
		readl_relaxed(mc + 0x000), readl_relaxed(mc + 0x004),
		readl_relaxed(mc + 0x008));
	pr_info("emmcprobe: CLKSRC(0x00c)=%08x CLKENA(0x010)=%08x TMOUT(0x014)=%08x\n",
		readl_relaxed(mc + 0x00c), readl_relaxed(mc + 0x010),
		readl_relaxed(mc + 0x014));
	pr_info("emmcprobe: CTYPE(0x018)=%08x CLK_CTRL_R(0x02c)=%08x RESP0(0x030)=%08x\n",
		readl_relaxed(mc + 0x018), readl_relaxed(mc + 0x02c),
		readl_relaxed(mc + 0x030));
	pr_info("emmcprobe: RINTSTS(0x044)=%08x STATUS(0x048)=%08x\n",
		readl_relaxed(mc + 0x044), readl_relaxed(mc + 0x048));

	/* --- Realtek wrapper（0x420..0x55c） --- */
	pr_info("emmcprobe: CP(0x41c)=%08x OTHER1(0x420)=%08x DUMMY_SYS(0x42c)=%08x\n",
		readl_relaxed(mc + 0x41c), readl_relaxed(mc + 0x420),
		readl_relaxed(mc + 0x42c));
	pr_info("emmcprobe: AHB(0x430)=%08x CKGEN_CTL(0x478)=%08x DQS_CTRL1(0x498)=%08x\n",
		readl_relaxed(mc + 0x430), readl_relaxed(mc + 0x478),
		readl_relaxed(mc + 0x498));
	pr_info("emmcprobe: DQ_CTRL_SET(0x50c)=%08x CMD_CTRL_SET(0x550)=%08x\n",
		readl_relaxed(mc + 0x50c), readl_relaxed(mc + 0x550));
	pr_info("emmcprobe: WCMD(0x554)=%08x RCMD(0x558)=%08x PLL_STATUS(0x55c)=%08x\n",
		readl_relaxed(mc + 0x554), readl_relaxed(mc + 0x558),
		readl_relaxed(mc + 0x55c));
	pr_info("emmcprobe: =====================================\n");
}

static void dump_worker(struct work_struct *w)
{
	dump_once("delayed");
	if (--dump_left > 0)
		schedule_delayed_work(&dump_work, 12 * HZ);
}

static int __init emmcprobe_init(void)
{
	crt = ioremap(CRT_PA, CRT_SZ);
	mc  = ioremap(EMMC_PA, EMMC_SZ);

	pr_info("emmcprobe: init, crt=%p mc=%p\n", crt, mc);
	dump_once("late_initcall");

	INIT_DELAYED_WORK(&dump_work, dump_worker);
	schedule_delayed_work(&dump_work, 12 * HZ);
	return 0;
}
late_initcall(emmcprobe_init);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("CM360 eMMC/PLL one-shot read-only register dump");
