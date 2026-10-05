# artifacts —— 可直接落盘的构建产物（备份用）

本目录放**能直接恢复板子**的二进制产物，目的是：主机重装、工具链丢失、内核树被删时，
仍然能一键把这块板恢复成可用状态。每个文件都有 md5（见 `MD5SUMS.txt`）。

## kernel-6.6.54/

| 文件 | 用途 | 恢复位置 |
|---|---|---|
| `Image-6.6.uimage` | 内核（legacy uImage，load=0x03000000；板子现在跑的就是它） | 板子 eMMC `mmcblk0p1:/Image-6.6.uimage` |
| `rtd1296-cm360.dtb` | 板级设备树（eMMC / SATA / GMAC / PWM / 风扇 / 温度 / pinctrl 节点） | `mmcblk0p1:/rtd1296-cm360.dtb` |
| `kernel.config` | 生成上述内核用的**完整 .config**（重现构建的关键） | — |

- 内核版本串：`6.6.54-gbe79582cba58-dirty`（`patches/0001`~`0006` 全在其中）
- 恢复方式（板子在跑时）：

  ```sh
  ./tools/brd-ssh.sh put artifacts/kernel-6.6.54/Image-6.6.uimage /tmp/Image-6.6.uimage
  ./tools/brd-ssh.sh put artifacts/kernel-6.6.54/rtd1296-cm360.dtb /tmp/rtd1296-cm360.dtb
  ./tools/brd-ssh.sh sudo 'mount /dev/mmcblk0p1 /mnt/p1 && \
      cp /tmp/Image-6.6.uimage /tmp/rtd1296-cm360.dtb /mnt/p1/ && sync && umount /mnt/p1'
  ```
- 重建：`make setup && make build && make uimage`（配置叠加见 `scripts/build-kernel.sh`）

## zfs-2.4.1/

| 文件 | 说明 |
|---|---|
| `zfs.ko` / `spl.ko` | OpenZFS 2.4.1 内核模块；vermagic = `6.6.54-gbe79582cba58-dirty SMP preempt mod_unload aarch64` |

- 安装：拷到板子 `/usr/lib/modules/<内核版本>/extra/`，然后 `depmod -a <内核版本>`，
  `modprobe zfs`；开机自启用 `/etc/modules-load.d/trim-zfs.conf`
- 重建：`./scripts/build-zfs.sh`（交叉编译的四个坑写在脚本头注释里）

## 没有入库的大文件（体积原因，已登记）

| 文件 | 体积 | 位置 / 重新获取 |
|---|---|---|
| 官方 fnOS ARM 镜像 | 1.9G | 主机 `build/fnos-images/fnos_arm_1.2.0302_onethingcloud-oes.img.gz`；MD5 `45139e41d05c411edf75fa154cf5bf83`；可从 <https://fnnas.com/download-arm> 重下 |
| 旧系统（fnOS 1.1.31）整份备份 | 1.8G | 主机 `~/fnos-work/old-root-1.1.31.tar.gz`（4.98G tar 经 gzip），升级前的完整 rootfs，用于回滚 |

> 这两份加起来 3.7G，放进 git 会让每次 clone 都拖这么大，所以只登记位置。
> 如果确实需要异地备份，建议走 Gitea 的 **Release 附件**（不要进 git 历史）。

## 原厂固件

见 `boards/rtd1296-cm360/vendor-firmware/`（1.4M，原厂 DTB + 整条启动链，已入库）。
