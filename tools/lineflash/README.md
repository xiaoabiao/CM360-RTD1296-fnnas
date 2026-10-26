# tools/lineflash —— 官方线刷包打包链路

本目录是「用厂商官方工具生成 CM360 线刷包（Windows USB MP Tool / RTD-Flasher 能认的
install.img）」所需的全部**非镜像类**输入。镜像（p1/p2/低区）不在这里，见
[`docs/13-lineflash-packaging-guide.md`](../../docs/13-lineflash-packaging-guide.md)。

| 文件 | 说明 |
|---|---|
| `rtd129x_img_gen` | **厂商打包器**（Realtek，Linux x86-64 静态 ELF，850,856 B，md5 `700154c366659bc43d2ec465121ebd7a`）。原样取自厂商 `rtd129x_img_tools-linux_x86_64.tar.gz`，**未做任何修改**；不可执行时先 `chmod +x`。用法：`rtd129x_img_gen <json> <workdir>` → 生成 `config.txt` / `layout.txt` / `mbr.bin` / `fw_tbl.bin`。 |
| `emmc_8gb_cm360.json` | 打包器输入：eMMC 总容量 `0x1D2000000`、`fw_start`、`part_start=0x2600000`、p1/p2 尺寸与文件系统类型。 |
| `cm360-mbr-2part.bin` | 标准 2 分区 MBR：p1 `LBA 0x13000` 共 `0x7FFF0` 扇区、p2 `LBA 0x93000` 共 `0xDFC7F0` 扇区。`--keep-mbr` / 后处理时替换用。 |
| `dummy-kernel.bin` | 2 字节占位。工具要求 layout 里 `FW_KERNEL` 长度非零（否则 `LOST: kernel data length not found`）；不带 `--lowregion` 时用它顶上。 |

## 为什么二进制入库

`rtd129x_img_gen` 是纯静态 Linux ELF，无法从公开渠道下载、又必须在 CI 里跑（GitHub Actions
的 `ubuntu-24.04` 可直接执行），所以随仓库一起走，保证「仓库 + 官方 fnOS 镜像 → 可刷线刷包」
完全可复现。它只做打包（生成 config/layout/mbr/fw_tbl），不含 fnOS 任何内容。

包装入口：

```sh
bash tools/make-lineflash-official.sh --help   # 单包打包（细粒度参数）
bash tools/build-release-assets.sh --fnos-image <官方整盘镜像> --out dist/release   # 全套资产
```
