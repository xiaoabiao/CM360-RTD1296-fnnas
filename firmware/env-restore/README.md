# env-restore —— 刷完厂商线刷包后恢复 u-boot 环境（`read_env from factory failed`）

**症状**（与 `docs/10-vendor-usb-mp-tool-package.md` §16.3 ⑦ 记录完全一致）：

```
Factory: MMC
Factory: pp:1, seq#:0x1, size:0x2e00
------------can't find tmp/factory/000BootParam.h
[ENV] read_env from factory failed
Using default environment
*** Warning - bad CRC, using default environment
...
BPI-W2>
```

原因：厂商 USB MP 工具每次普通刷写都会重建 factory 区（eMMC `0x220000` / `0x420000`
的 factory tar），把 u-boot env 清掉 → 默认 env 走 Realtek 默认引导流程 → 停在 `BPI-W2>`。
**系统本身没坏**，手动 `bootm` 能进（见 `docs/08-flashing-approaches.md`）。

本目录的 `factory-env-0x220000-0x20a00.bin` 是从仓库的
`firmware/low-region-38MiB.img.gz`（md5 `22dc832126b42cd1b2f77e305e13c76b`）里
原样切出的 **已知可用 factory 区**（含 `bootcmd=... FNOS-BOOT ...`、`bootdelay=3`）：

| 项 | 值 |
|---|---|
| 文件 | `factory-env-0x220000-0x20a00.bin` |
| 大小 | 133,632 B = `0x20A00` = 261 个 512B 扇区 |
| eMMC 目标 | 偏移 `0x220000`（LBA `0x1100`），`saveenv` 的落点 |
| md5 | `1e54a915cb4456ccd61b97bf4dcd22ad` |

---

## 修法 1（推荐，最快）：在 u-boot 里 `setenv` + `saveenv`

在 `BPI-W2>` 提示符下（默认 env 走到这里就有提示符）：

```
setenv bootargs 'earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200 loglevel=7 root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root rootwait rw'
setenv bootcmd 'echo === FNOS-BOOT ===; ext4load mmc 0:1 0x03000000 Image-6.6.uimage; ext4load mmc 0:1 0x02100000 rtd1296-cm360.dtb; bootm 0x03000000 - 0x02100000'
setenv bootdelay 3
saveenv
```

> 这三个变量是仓库低区镜像里**实测可用**的原值（不是猜的）。
> `saveenv` 会重写 `0x220000` 的 factory 区（`[FAC] Save to eMMC (blk#:0x1100, ...)`），
> 正好把被清空的 env 恢复。写的时候别断电。

重启后应看到 `bootdelay=3` 的 3 秒窗口，然后自动进 fnOS。

## 修法 2（修法 1 失败时）：把 factory 区整块写回

把 `factory-env-0x220000-0x20a00.bin` 改名为 `factory.bin` 放进 **FAT32 U 盘**（或 TFTP 根目录），
在 `BPI-W2>` 里：

```
# U 盘：
usb start
fatload usb 0 0x20000000 factory.bin

# 或 TFTP：
setenv serverip <你电脑的IP>
tftp 0x20000000 factory.bin

# 写入（0x1100 = 0x220000/512，0x105 = 0x20A00/512）：
mmc dev 0
mmc write 0x20000000 0x1100 0x105
reset
```

⚠️ 这是**写低区**。写之前确认 `fatload`/`tftp` 真的成功了（会打印字节数 133632 = 0x20A00），
写入期间不要断电；写错位置可能变砖（救砖路线见 `docs/04-recovery.md`）。

## 修法 3：用带低区的线刷包重刷

`tools/make-lineflash-official.sh --lowregion firmware/low-region-38MiB.img ...`
生成的 `*-full-uboot.img` 会把整块 38 MiB 低区（含 env/factory）一起写回，
见 `docs/10-vendor-usb-mp-tool-package.md` §16.3 ⑦。风险同样在"写低区中途断电"。

---

## 验证

重启后 u-boot 阶段应看到：

- 不再有 `[ENV] read_env from factory failed` / `bad CRC`；
- `Hit Esc or Tab key to enter console mode or rescue linux:  3`（`bootdelay=3` 生效）；
- 不按键则自动打印 `=== FNOS-BOOT ===` 并 `bootm`。

## 附：为什么要防着它

厂商 USB MP 工具（`rtd129x_img_gen` / `kylin_usb_mp_tools`）**每次普通刷写都会重建 factory 区**，
这是工具行为，不是包的问题。以后每次用该工具刷完，都要重新做一次修法 1；
或者直接用带低区的包（修法 3）省掉这一步。
