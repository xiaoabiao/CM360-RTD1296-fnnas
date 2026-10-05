echo
echo ======== UB-RECON-BEGIN ========
echo ---- [1] version ----
version
echo ---- [2] bdinfo ----
bdinfo
echo ---- [3] printenv（完整环境，用作备份 + 之后拼 env 脚本）----
printenv
echo ---- [4] mmc list（eMMC 是哪个设备号）----
mmc list
echo ---- [5] mmc dev 0 ----
mmc dev 0
echo ---- [6] mmcinfo ----
mmcinfo
echo ---- [7] mmc part（能否解析我们写的 MBR/DOS 表；原来这块是 GPT）----
mmc part
echo ---- [8] ext4ls mmc 0:1 /（分区解析 + ext4 读能力）----
ext4ls mmc 0:1 /
echo ---- [9] ext4load 内核 -> 0x02ffffc0 ----
ext4load mmc 0:1 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
echo ---- [10] ext4load DTB -> 0x01f00000 ----
ext4load mmc 0:1 0x01f00000 rtd1296-cm360.dtb
md 0x01f00000 4
echo ---- [11] 兜底：mmc read 裸内核（LBA 0x800=2048, 0x11c26=72742 扇区）----
mmc read 0x02ffffc0 800 11c26
iminfo 0x02ffffc0
echo ---- [12] 兜底：mmc read 裸 DTB（LBA 0x12480=74880, 0xf=15 扇区）----
mmc read 0x01f00000 12480 f
md 0x01f00000 4
echo ---- [13] SPI 工具 ----
rtkspi
rtkspi init
echo ---- [14] SPI 整片 8MiB 备份 -> TFTP spi-8m.bin ----
rtkspi read 0x0 0x10000000 0x800000
tftpput 0x10000000 0x800000 spi-8m.bin
echo ---- [15] hush if/then/else 支持测试 ----
if test 1 = 1; then echo HUSH-IF-OK; else echo HUSH-IF-BAD; fi
echo ---- [16] run 变量可执行性测试 ----
setenv __t1 'echo RUN-VAR-OK'
run __t1
echo ---- [17] DTB 根节点 ----
fdt addr 0x01f00000
fdt print / 2>/dev/null
echo ---- [18] 读 eMMC 上的 btrfs？(预期失败, 只是确认无 btrfs 支持) ----
ext4ls mmc 0:2 /
echo ======== UB-RECON-END ========
