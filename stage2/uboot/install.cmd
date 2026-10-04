echo ======== UB-INSTALL-BEGIN ========
echo ---- [0] 备份原厂 bootcmd（回退用：setenv bootcmd $bootcmd_orig;saveenv）----
setenv bootcmd_orig 'run syno_bootargs;run rtk_spi_boot;run mod_fdt;ping $serverip;go all'
echo ---- [1] fnOS @ eMMC 引导链 ----
echo      ★ fdt_high/initrd_high 必须一起设：现有 boot66 流程就是带着这两个跑的
echo        （置 ~0 = 让 u-boot 不要搬 fdt），漏了会走到没验证过的分支
setenv fnos_args 'setenv fdt_high 0xffffffffffffffff; setenv initrd_high 0xffffffffffffffff; setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon root=/dev/mmcblk0p2 rw rootwait'
setenv fnos_kext4 'mmc dev 0; ext4load mmc 0:1 0x01f00000 rtd1296-cm360.dtb; ext4load mmc 0:1 0x02ffffc0 Image-6.6.uimage'
setenv fnos_kraw 'mmc dev 0; mmc read 0x02ffffc0 800 11c26; mmc read 0x01f00000 12480 f'
setenv fnos_boot 'echo === CM360 fnOS @ eMMC ===; run fnos_args; if run fnos_kext4; then echo KLOAD=EXT4; else echo KLOAD=RAW; run fnos_kraw; fi; bootm 0x02ffffc0 - 0x01f00000'
echo ---- [2] bootcmd 指向它（不再回落 go all：那条会启 audio 把 UART 时钟 gate 掉，反而更难救）----
setenv bootcmd 'run fnos_boot'
echo ---- [3] 保存到 SPI ----
saveenv
echo ---- [4] 回读确认 ----
printenv bootcmd
printenv fnos_boot
printenv fnos_args
echo ---- [5] 变量清单（确认 fnos_* 都在）----
printenv fnos_kext4
printenv fnos_kraw
echo ======== UB-INSTALL-END ========
