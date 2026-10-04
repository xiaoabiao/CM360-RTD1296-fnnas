@key:CR
help mmc
@sleep:2.5
help sata
@sleep:2.5
help rtkspi
@sleep:2.5
help loady
@sleep:2.5
help gosd
@sleep:1.8
help go
@sleep:1.8
help bootr
@sleep:1.8
help fdt
@sleep:1.8
help ext4load
@sleep:1.8
help fatload
@sleep:1.8
help iminfo
@sleep:1.8
rtkspi read 0x0 0x06000000 0x10000
@sleep:2.5
fdt addr 0x06000000
@sleep:2.5
fdt list /
@sleep:2.5
mmc list
@sleep:2.5
mmc info
@sleep:2.5
mmc part
@sleep:2.5
help tftpput
@sleep:2
help bootr
@sleep:2
fdt header
@sleep:2
@mark:开始 fdt print /
fdt print /
@key:CR
@mark:===== 阶段1 网络连通性侦察 =====
printenv ipaddr
printenv serverip
printenv netmask
printenv tftpdstp
printenv tftpblocksize
@sleep:2
@mark:===== ping 主机 192.168.1.254 =====
ping 192.168.1.254
@sleep:6
@mark:===== 测试 tftpdstp 自定义端口 6969 =====
setenv tftpdstp 6969
tftp 0x03000000 hello.txt
@sleep:6
@mark:===== 清掉刚才试探用的 tftpdstp =====
setenv tftpdstp
printenv tftpdstp
@sleep:2
@mark:===== 阶段1-A  TFTP 数据通路校验（1MB 下载）=====
setenv tftpblocksize 1468
ping 192.168.1.254
@sleep:2
tftp 0x03000000 probe1m.bin
@sleep:6
@mark:===== 复核A：再抓一次（看是否仍出现重复 RRQ）=====
tftp 0x03000000 probe1m.bin
@sleep:5
@mark:===== 阶段1-A2  校验命令探测 + 反向 tftpput =====
crc32 0x03000000 0x100000
@sleep:3
tftpput 0x03000000 0x100000 readback.bin
@sleep:8

@raw:0d0a
printenv bootargs
version
setenv ipaddr 192.168.1.100
setenv serverip 192.168.1.254
setenv netmask 255.255.255.0
tftp 0x03000000 Image
tftpput 0x03000000 0x2d0c900 rb_Image
help booti
tftp 0x01f00000 cm360.dtb
tftp 0x08000000 initramfs.cpio.gz
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon
printenv bootargs
booti 0x03000000 0x08000000:0xa16e5 0x01f00000
md 0x03000000 8
md 0x01f00000 4
@raw:0d0a
version
@mark:agenttest
@burst:4 esc tab
@raw:0d0a
@raw:0d0a
@raw:03
@raw:0d0a

@raw:0d0a
root
@sleep:1
@raw:0d0a
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@raw:03
@raw:0d0a
printenv kernel_loadaddr fdt_loadaddr rootfs_loadaddr bootcmd bootdelay
rtkspi read 0x100000 0x0b000000 0x2F0000
lzmadec 0x0b000000 0x03000000 0x2F0000
iminfo 0x03000000
md 0x03000000 8
setenv ipaddr 192.168.1.100
setenv serverip 192.168.1.254
setenv netmask 255.255.255.0
ping 192.168.1.254
tftp 0x01f00000 cm360.dtb
tftp 0x03000000 Image
md 0x03000000 8
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x022a16e5
setenv bootargs console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon
fdt print /chosen
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon"
fdt print /chosen
go all
go k
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@raw:03
@raw:0d0a
version
printenv
help go
help booti
help iminfo
@raw:03
@raw:0d0a
tftp 0x03000000 Image.uimage
iminfo 0x03000000
tftp 0x01f00000 cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon'
fdt print /chosen
go k
@raw:0d0a
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@burst:15 esc tab
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
version
printenv
help go
help booti
help iminfo
@raw:03
@raw:0d0a
@mark:probe-cr
@raw:0d0a
@raw:0d0a
@mark:console-verify
@raw:0d0a
version
@raw:03
@raw:0d0a
tftp 0x02fff000 Image.uimage
iminfo 0x02fff000
md 0x03000000 4
tftp 0x01f00000 cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
booti 0x02fff000 0x02200000:0xa16e5 0x01f00000
@raw:0d0a
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
booti 0x02ffffc0 0x02200000:0xa16e5 0x01f00000
@mark:cmdlist
help
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
@mark:bootm-try
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
echo ARGS_NOW=$bootargs
bootm 0x02ffffc0 - 0x01f00000
echo ===SHELL-ALIVE===
uname -a
cat /sys/devices/system/cpu/online
@burst:3 esc
@burst:3 esc
echo 1 > /proc/sys/kernel/sysrq
@burst:3 esc
echo b > /proc/sysrq-trigger
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
version
printenv
help go
help booti
help iminfo
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
echo ===SHELL2===
dmesg | tail -5
ls /sys/class/mmc_host 2>&1; ls /sys/bus/mmc/devices 2>&1
dmesg | grep -iE "mmc|sdhci|dw-mshc|dw_mmc|sata|ahci|gmac|stmmac|r8168|eth" 
ls /sys/bus/platform/devices | tr "\n" " "
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
version
printenv
help go
help booti
help iminfo
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
@raw:0d0a
@burst:3 esc
@raw:03
@burst:3 esc
@raw:0d0a
@raw:03
@raw:0d0a
@burst:3 esc
@raw:03
@raw:0d0a
@burst:3 esc
@raw:03
@raw:0d0a
@burst:3 esc
@raw:03
@raw:0d0a
@raw:03
@burst:3 esc
@raw:0d0a
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@raw:0d0a
@raw:0d0a
version
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
version
printenv
help go
help booti
help iminfo
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon clk_ignore_unused"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon clk_ignore_unused'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon clk_ignore_unused initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000

echo ===GMAC-1-ip-link===
ip link
echo ===GMAC-2-dmesg===
dmesg | grep -iE 'r8169|eth0|gmac'
echo ===GMAC-3-addr===
ip addr show eth0
echo ===GMAC-4-up===
ip link set eth0 up
ip link show eth0
echo ===GMAC-5-dhcp===
udhcpc -i eth0 -q -n -t 4 -T 3
echo ===GMAC-6-addr-after-dhcp===
ip addr show eth0
echo ===GMAC-7-ping-host===
ip addr add 192.168.1.100/24 dev eth0 2>/dev/null; ip route add default via 192.168.1.254 2>/dev/null; ip addr show eth0
ping -c 3 -W 2 192.168.1.254
echo ===GMAC-DONE===
echo __S1__
ip addr show eth0
echo __S2__
ip link set eth0 up
echo __S3__
ip link show eth0
echo __S4__
cat /sys/class/net/eth0/carrier; cat /sys/class/net/eth0/speed
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
echo __RESCUED__
echo __G1__
ip addr show eth0
echo __G2__
ip link set eth0 up
echo __G3__
ip link show eth0
echo __G4__
cat /sys/class/net/eth0/operstate
echo __G5__
cat /sys/class/net/eth0/carrier
echo __G6__
cat /sys/class/net/eth0/address
echo __G7__
dmesg
echo __G8__
udhcpc -i eth0 -n -t 4 -T 3
echo __G9__
ip addr show eth0
echo __G10__
ping -c 3 -W 2 192.168.1.254
echo __G11__
echo __ALLDONE__
echo __P1__
ip addr add 192.168.1.100/24 dev eth0
echo __P2__
ip addr show eth0
echo __P3__
ping -c 3 -W 2 192.168.1.254
echo __P4__
arp
echo __P5__
echo __PINGDONE__
echo __Q1__
ifconfig eth0 192.168.1.100
echo __Q2__
ifconfig eth0
echo __Q3__
ping -c 3 -W 2 192.168.1.254
echo __Q4__
arp
echo __Q5__
echo __Q_DONE__
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
version
printenv
help go
help booti
help iminfo
@raw:0d0a
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
@raw:03
@raw:0d0a
echo __P1__
@raw:1b5b313b3152
@raw:0d0a
echo __P2__
@raw:03
@raw:1b5b313b3152
@raw:6563686f205f5f50335f5f0d
@raw:1b5b313b3152
@raw:03
@raw:0d0a
echo __P4__
echo __R01__
mkdir -p /sys/kernel/debug
echo __R02__
mount -t debugfs none /sys/kernel/debug
echo __R03__
ls /sys/kernel/debug/clk
echo __R04__
grep ur0 /sys/kernel/debug/clk/clk_summary
echo __R05__
grep -i etn /sys/kernel/debug/clk/clk_summary
echo __R06__
cat /proc/interrupts
echo __R07__
ifconfig eth0 192.168.1.100
echo __R08__
ifconfig eth0
echo __R09__
ping -c 3 -W 2 192.168.1.254
echo __R10__
cat /proc/interrupts
echo __R11__
arp
echo __R12__
cat /proc/net/arp
echo __R13__
echo __R_DONE__
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@burst:3 esc
@flood:0
@raw:0d0a
@raw:0d0a
@raw:0d0a
@flood:1 esc
@raw:0d0a
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:0
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:90 esc
@flood:0
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
md 0x9801a200 8
which devmem
devmem 0x9801a200
devmem 0x9801a204
dd if=/dev/mem bs=4 skip=637571712 count=2 2>/dev/null | od -A x -t x4
dd if=/dev/mem bs=4 skip=637560832 count=32 2>&1 | od -A x -t x4 | head -12
@flood:90/8 esc
reboot
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
echo 9803f000.sata > /sys/bus/platform/drivers/rtk_ahci/unbind
sleep 2
echo 9803f000.sata > /sys/bus/platform/drivers/rtk_ahci/bind
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
md 0x9803f128 1
md 0x9803f12c 1
md 0x9803f1a8 1
md 0x9803f000 1
md 0x9801a200 2
md 0x98007800 1
md 0x9803ff60 2
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a16e5
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa16e5'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@mark:运行时DTB排查
find /sys/firmware/devicetree/base -name "sata-port@0"
find /sys/firmware/devicetree/base -name "sata-gpios"
ls /sys/class/gpio
cat /sys/class/gpio/gpiochip*/label
cat /sys/class/gpio/gpiochip*/ngpio
ls /sys/bus/platform/devices/
ls -l /sys/bus/platform/devices/9801b000.gpio/driver
ls -l /sys/bus/platform/devices/9801b000.syscon/driver
ls -l /sys/bus/platform/devices/98007000.syscon/driver 2>/dev/null
cat /sys/kernel/debug/gpio 2>/dev/null
ls /sys/firmware/devicetree/base/soc/bus@98000000/syscon@1b000
od -A d -t x1 /sys/firmware/devicetree/base/soc/bus@98000000/sata@3f000/sata-port@0/sata-gpios
od -A d -t x1 /sys/firmware/devicetree/base/soc/bus@98000000/syscon@1b000/gpio@0/phandle
od -A d -t x1 /sys/firmware/devicetree/base/soc/bus@98000000/syscon@1b000/gpio@0/#gpio-cells
ls /sys/class/ata_link
echo 3 > /sys/class/ata_link/ata1/sata_spd_limit
ls /sys/class/ata_link/link1
echo 3 > /sys/class/ata_link/link1/sata_spd_limit
which devmem
devmem 0x9801b004
devmem 0x9801b014
dd if=/dev/mem bs=4 count=1 skip=635979637
busybox | head -1
ls /bin /usr/bin /sbin 2>/dev/null | tr '\n' ' ' | head -c 600
ls /sys/class/ata_port/ata1
ls -l /sys/class/ata_port/ata1
busybox --list | grep -x -E "ip|ifconfig|tftp|wget"
ip link set eth0 up
ip addr add 192.168.1.100/24 dev eth0
sleep 2
ip link show eth0
cd /tmp && wget http://192.168.1.254:8000/gpio-rtk
chmod +x /tmp/gpio-rtk
/tmp/gpio-rtk info
ping -c 3 192.168.1.254
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@mark:盘位供电实验开始
/bin/gpio-rtk info
/bin/gpio-rtk
/bin/gpio-rtk set 56 1
echo rc=$?
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@flood:0
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:03
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
__T1__
cat /sys/class/ata_link/ata1/sata_spd
ls /sys/class/gpio
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
echo __Q1__
ifconfig eth0 192.168.1.100
echo __Q2__
ifconfig eth0
echo __Q3__
ping -c 3 -W 2 192.168.1.254
echo __Q4__
arp
echo __Q5__
echo __Q_DONE__
__G1__
ifconfig eth0
dmesg
__G_DONE__
ping -c 3 192.168.1.254
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
cat /proc/partitions
echo __S02__
ls /sys/class/ata_port
echo __S03__
ls /sys/bus/ata/devices
echo __S04__
cat /sys/block/sda/size
echo __S05__
cat /sys/block/sda/device/model
echo __S06__
ls /dev/sd*
echo __S07__
ls /dev
echo __S08__
cat /proc/partitions
echo __S09__
cat /proc/interrupts
echo __S10__
echo __S_DONE__
echo __Q1__
ifconfig eth0 192.168.1.100
echo __Q2__
ifconfig eth0
echo __Q3__
ping -c 3 -W 2 192.168.1.254
echo __Q4__
arp
echo __Q5__
echo __Q_DONE__
__W1__
wget -q -O /tmp/t.bin http://192.168.1.254:8000/rtd1296-cm360.dtb
ls -l /tmp/t.bin
ifconfig eth0
__W2__
time wget -q -O /tmp/big.bin http://192.168.1.254:8000/Image-6.6
ls -l /tmp/big.bin
ifconfig eth0
time wget -q -O /tmp/big.bin http://192.168.1.254:8000/Image-6.6.uimage
ls -l /tmp/big.bin
ifconfig eth0
md5sum /tmp/big.bin
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __E01__
dmesg
echo __E02__
ls /sys/class/mmc_host
echo __E03__
cat /proc/partitions
echo __E04__
ls /dev/mmcblk0
echo __E05__
cat /sys/block/mmcblk0/size
echo __E06__
cat /sys/block/mmcblk0/device/type
echo __E07__
cat /sys/block/mmcblk0/device/name
echo __E08__
cat /sys/block/mmcblk0/device/cid
echo __E09__
cat /sys/block/mmcblk0/device/csd
echo __E10__
cat /proc/interrupts
echo __E11__
echo __E_DONE__
echo __K01__
ls /sys/kernel/debug
echo __K02__
ls /sys/kernel/debug/clk
echo __K03__
mkdir /dbg
echo __K04__
mount -t debugfs none /dbg
echo __K05__
ls /dbg/clk
echo __K06__
cat /dbg/clk/clk_summary
echo __D00__
which devmem
echo __D01__
devmem 0x980001f0
echo __D02__
devmem 0x980001f4
echo __D03__
devmem 0x980001f8
echo __D04__
devmem 0x980001fc
echo __D05__
devmem 0x98012000
echo __D06__
devmem 0x98012008
echo __D07__
devmem 0x9801200c
echo __D08__
devmem 0x98012010
echo __D09__
devmem 0x98012018
echo __D10__
devmem 0x98012420
echo __D11__
devmem 0x98012478
echo __D12__
devmem 0x98012550
echo __D13__
devmem 0x9801255c
echo A1
ls /sys/kernel/debug/regmap
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __E01__
dmesg
echo __E02__
ls /sys/class/mmc_host
echo __E03__
cat /proc/partitions
echo __E04__
ls /dev/mmcblk0
echo __E05__
cat /sys/block/mmcblk0/size
echo __E06__
cat /sys/block/mmcblk0/device/type
echo __E07__
cat /sys/block/mmcblk0/device/name
echo __E08__
cat /sys/block/mmcblk0/device/cid
echo __E09__
cat /sys/block/mmcblk0/device/csd
echo __E10__
cat /proc/interrupts
echo __E11__
echo __E_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __E01__
dmesg
echo __E02__
ls /sys/class/mmc_host
echo __E03__
cat /proc/partitions
echo __E04__
ls /dev/mmcblk0
echo __E05__
cat /sys/block/mmcblk0/size
echo __E06__
cat /sys/block/mmcblk0/device/type
echo __E07__
cat /sys/block/mmcblk0/device/name
echo __E08__
cat /sys/block/mmcblk0/device/cid
echo __E09__
cat /sys/block/mmcblk0/device/csd
echo __E10__
cat /sys/devices/platform/98012000.emmc/emmc_info
echo __E11__
cat /proc/interrupts
echo __E12__
echo __E_DONE__
echo __H01__
cat /sys/class/mmc_host/mmc0/mmc0:0001/life_time
echo __H02__
cat /sys/class/mmc_host/mmc0/mmc0:0001/pre_eol_info
echo __H03__
cat /sys/class/mmc_host/mmc0/mmc0:0001/oemid
echo __H04__
cat /sys/class/mmc_host/mmc0/mmc0:0001/serial
echo __H05__
cat /sys/class/mmc_host/mmc0/mmc0:0001/hwrev
echo __H06__
cat /sys/class/mmc_host/mmc0/mmc0:0001/fwrev
echo __H07__
cat /sys/class/mmc_host/mmc0/mmc0:0001/date
echo __H08__
cat /sys/class/mmc_host/mmc0/mmc0:0001/manfid
echo __H09__
ls /sys/class/mmc_host/mmc0/mmc0:0001
echo __H10__
ls /sys/block/mmcblk0
echo __H11__
ls /dev/mmcblk0boot0 /dev/mmcblk0boot1 /dev/mmcblk0rpmb
echo __H12__
dmesg | grep -i 'hs200\|new .* MMC card\|mmcblk0:'
echo __H13__
echo __H_DONE__
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
@raw:0d0a
echo __S01__
dmesg | grep -i "secondary\|CPU1\|CPU2\|CPU3\|enable-method\|Brought up\|smp"
echo __S02__
grep -c processor /proc/cpuinfo
echo __S03__
cat /proc/cpuinfo
echo __S04__
ls /sys/devices/system/cpu/
echo __S05__
cat /sys/devices/system/cpu/online
echo __S06__
cat /sys/devices/system/cpu/present
echo __S07__
cat /sys/devices/system/cpu/possible
echo __S08__
head -3 /proc/interrupts
echo __S09__
nproc
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
dmesg | grep -i "secondary\|CPU1\|CPU2\|CPU3\|enable-method\|Brought up\|smp"
echo __S02__
grep -c processor /proc/cpuinfo
echo __S03__
cat /proc/cpuinfo
echo __S04__
ls /sys/devices/system/cpu/
echo __S05__
cat /sys/devices/system/cpu/online
echo __S06__
cat /sys/devices/system/cpu/present
echo __S07__
cat /sys/devices/system/cpu/possible
echo __S08__
head -3 /proc/interrupts
echo __S09__
nproc
echo __S10__
echo __S_DONE__
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
@raw:0d0a
echo __S01__
dmesg | grep -i "secondary\|CPU1\|CPU2\|CPU3\|enable-method\|Brought up\|smp"
echo __S02__
grep -c processor /proc/cpuinfo
echo __S03__
cat /proc/cpuinfo
echo __S04__
ls /sys/devices/system/cpu/
echo __S05__
cat /sys/devices/system/cpu/online
echo __S06__
cat /sys/devices/system/cpu/present
echo __S07__
cat /sys/devices/system/cpu/possible
echo __S08__
head -3 /proc/interrupts
echo __S09__
nproc
echo __S10__
echo __S_DONE__
echo HELLO
echo alive
echo A01
cd /sys/block/sda
echo A02
cat size
echo A03
ls
echo A04
cat device/model
echo T-sda1
cat sda1/start
echo U-sda1
cat sda1/size
echo T-sda2
cat sda2/start
echo U-sda2
cat sda2/size
echo T-sda3
cat sda3/start
echo U-sda3
cat sda3/size
echo B01
ls /dev/sd*
echo B02
blkid /dev/sda1
echo C01
ls /dev/sd*
echo C02
mknod /dev/sda b 8 0
echo C03
blockdev --getsize64 /dev/sda
echo D01
ifconfig
echo D02
ip route
echo E01
ls /sys/class/net
echo F01
ifconfig eth0 up
echo F02
ifconfig eth0 192.168.1.100
echo F03
ifconfig eth0
echo F04
ping -c2 192.168.1.254
echo G01
cd /dev
echo G02
nc 192.168.1.254 8899 > sda
echo H01
sync
echo H02
blkid /dev/sda
echo H03
mount -t btrfs /dev/sda /mnt
echo H04
ls /mnt
@flood:90/8 esc
reboot
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@flood:0
reboot
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@flood:0
echo T1
echo back

reboot
@flood:300 esc
@flood:0

reboot -f
@flood:300 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@raw:03
@raw:0d0a
version
printenv
@raw:03
@raw:0d0a
tftp 0x02ffffc0 Image-6.6.uimage
iminfo 0x02ffffc0
md 0x03000000 4
tftp 0x01f00000 rtd1296-cm360.dtb
tftp 0x02200000 initramfs.cpio.gz
md 0x01f00000 4
fdt addr 0x01f00000
fdt resize
fdt chosen 0x02200000 0x22a23f6
fdt set /chosen bootargs "console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon"
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon'
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
fdt print /chosen
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,0xa23f6'
bootm 0x02ffffc0 - 0x01f00000
echo J01
cat /proc/version
echo J02
blkid /dev/sda
echo J03
mount -t btrfs /dev/sda /mnt
echo J04
ls /mnt
echo K01
ls -l /mnt/bin /mnt/lib
echo K02
cat /mnt/etc/fstab
echo K03
cat /mnt/etc/os-release
echo L01
cd /mnt/etc
echo L02
grep -v mmcblk0 fstab > x
echo L03
mv x fstab
echo L04
cat fstab
echo M01
ls -l /mnt/sbin/init
echo M02
cd /
echo M03
mount --move /dev /mnt/dev
echo M04
mount --move /proc /mnt/proc
echo M05
mount --move /sys /mnt/sys
echo M06
ls /mnt/dev /mnt/proc
switch_root /mnt /sbin/init
echo N01
echo $$
echo N02
cat /proc/1/comm
echo N03
grep -w /mnt /proc/mounts
exec switch_root mnt /sbin/init
root

echo P01
uname -a
echo P02
df -h /
echo P03
ip -4 addr
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:90/8 esc
@flood:0
@flood:0
@flood:0
@raw:0d0a
@raw:0d0a
echo PINGPROBE
@flood:0
@flood:30/8 esc
@flood:600/8 esc
@flood:0
@flood:0
@flood:0
@flood:0
