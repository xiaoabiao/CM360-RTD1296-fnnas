# 11 · 发布流程与云端构建（CI）

> 本文说明"别人下载下来怎么刷"背后的**发布链路**：镜像怎么生成、CI 怎么跑、
> Release 里每个文件是什么。刷机操作本身看 [`../README.md`](../README.md) 与
> [`../firmware/README.md`](../firmware/README.md)。

---

## 1. 一条命令产出全部发布资产

所有构建逻辑集中在 [`tools/build-release-assets.sh`](../tools/build-release-assets.sh) ——
**CI 与本地跑的是同一个脚本**，所以云端产物可以在本机复现、本地问题也能在云端复现。

```sh
./tools/build-release-assets.sh --p2 firmware/images/p2.img --out /mnt/out   # 含 p2（完整）
./tools/build-release-assets.sh --no-p2 --out /mnt/out                       # 不含 p2（默认）
./tools/build-release-assets.sh --fnos-image ~/downloads/fnos_arm_*.img.gz   # 现场从官方镜像构建 p2
./tools/build-release-assets.sh --dry-run                                    # 只看计划
```

脚本做的事：

| 步骤 | 内容 |
|---|---|
| 1 | 低区镜像解压 + **md5 校验**（`firmware/low-region-38MiB.img.gz`） |
| 2 | 构建 p1（`firmware/build-images.sh p1`，需要 sudo 做 loop 挂载） |
| 3 | p2：用现成镜像 / 从官方镜像现场构建 / 跳过 |
| 3b | 可选：`firmware/shrink-p2.sh` 生成**精简 p2**（实测 6.99 → 2.75 GiB） |
| 4 | dd 套装 tar（低区 + p1 + `dd-flash.sh` + 中文说明 + md5） |
| 5 | 线刷包 `install-cm360-fnos-<ver>-boot-sysonly.img`（不含 p2）与完整/精简版（含 p2） |
| 6 | 大文件 gzip（有 `pigz` 用 pigz）+ **超过 1.9 GiB 自动分卷** |
| 7 | `MD5SUMS.txt`、`SHA256SUMS.txt`、`ASSETS.md`（直接作为 Release 正文） |

**分卷**：GitHub Release 单个资产上限 2 GiB，所以超过 1.9 GiB 的会自动切成
`名字.part01/02/…`，下载后 `cat 名字.part* > 名字` 合并即可（已实测合并 md5 一致）。

---

## 2. 云端构建（GitHub Actions）

[`.github/workflows/release.yml`](../.github/workflows/release.yml)

| 触发 | 行为 |
|---|---|
| **push tag `v*`** | 自动构建 → 创建 Release（tag 名去掉 `v` 作为版本号，如 `v1.2.0302` → `1.2.0302`） |
| **workflow_dispatch** | 手动触发；可填版本号、官方镜像直链、以及"发布到哪个 tag"（留空 = 只上传 Actions artifact） |

CI 步骤：装依赖（`btrfs-progs e2fsprogs rsync pigz`）→ 解析版本/tag →
调 `tools/build-release-assets.sh` → 上传 artifact → `gh release create/upload`。

工作目录用 `/mnt`（托管 runner 上空间最大，p2 路径需要约 15 GB），不可用时自动退回 `RUNNER_TEMP`。

### 关于 p2 的版权边界

fnOS 官方镜像与 rootfs 属 **fnOS 版权物**，默认**只把 p2 构建物放进 Actions artifact**：

- 打 tag 的自动发布（未给官方镜像直链）= **不含 p2** 的那套（引导链/u-boot、p1、dd 套装、救援线刷包）✔
- workflow_dispatch 传官方镜像直链时，可构建 p2 与完整线刷包，**是否公开发布由发布者决定**：
  - 不填 `release_tag` → 只进 Actions artifact（不公开）✔
  - 填了 `release_tag` → 公开进 Release（视为发布者已确认有权分发）✔
- **v1.2.0302 的实际做法**：p2 与完整线刷包用同一个脚本在本地构建后上传 ✔

**关于官方直链的实操坑**：fnOS 的 ARM 镜像下载地址是**带签名与时间戳**的临时链接
（形如 `...img.gz?sign=…&t=1791536543`），有效期只有几十分钟。要让 **CI 自己下载**，
必须在拿到链接后**立刻**触发 workflow（下载在作业开头）✔；链接过期就只能
下载到本地后用 `--fnos-image <本地路径>` 在本地构建 ✔（不能把官方镜像提交到仓库 ✗）。

---

## 3. Release 资产对照

| 资产 | 是什么 | 路线 |
|---|---|---|
| `low-region-38MiB.img.gz` | **引导链**（hwsetting+bootcode+FSBL+BL31+**u-boot**+env，38 MiB） | dd 写 `/dev/mmcblk0` 起始 |
| `p1-256MiB.img.gz` | 内核分区（ext4：uImage + 板级 DTB + `.bak`） | dd 写 `/dev/mmcblk0p1` |
| `dd-set-cm360-<ver>.tar.gz` | dd 套装：低区 + p1 + `dd-flash.sh` + 说明 | 板内 `sudo ./dd-flash.sh` |
| `p2.img.gz[.partNN]` | rootfs 整分区镜像（btrfs 子卷 `root`） | dd 写 `/dev/mmcblk0p2` |
| `p2-compact.img.gz` | 精简 rootfs（2.75 GiB，首启自动扩回分区） | 线刷用；单用需自行扩容 |
| `install-…-boot-sysonly.img.gz` | 线刷包（含引导链，不含 p2） | Windows USB MP Tool |
| `install-…-boot-full.img.gz` | 线刷包（含引导链 + 完整 p2） | 同上 |
| `install-…-boot-compact-full.img.gz` | 线刷包（含引导链 + 精简 p2） | 同上 |
| `MD5SUMS.txt` / `SHA256SUMS.txt` | 校验清单 | `md5sum -c MD5SUMS.txt` |
| `ASSETS.md` | Release 正文（资产表 + 三条路线 + 校验方式） | — |

---

## 4. 本地发布（不依赖 CI）

CI 不可用时，用同一条命令构建后手动发：

```sh
./tools/build-release-assets.sh --p2 firmware/images/p2.img --out /mnt/out
gh release create v1.2.0302 /mnt/out/* \
   --title "CM360 刷机镜像 v1.2.0302" \
   --notes-file /mnt/out/ASSETS.md
```

> 注意：`dist/` 与 `firmware/images/` 都是 gitignore 的构建产物，不入库；
> 仓库里只有**低区镜像（gzip）**与**内核 uImage/DTB**这些"原料"。

---

## 5. 本地验证过的实测数据（供对照）

| 项 | 实测 |
|---|---|
| p1 构建 | 几秒；`p1-256MiB.img.gz` ≈ 31.7 MB |
| 低区资产 | 17.5 MB（gz） |
| dd 套装 tar | ≈ 49 MB（不含 p2） |
| 救援线刷包 | `install-…-boot-sysonly.img` 346 MB → gz 65 MB |
| 完整线刷包（含 2.75 GiB 精简 p2） | 3.30 GB → gz 1.98 GB |
| `p2.img.gz`（2.75 GiB 输入） | 1.92 GB |
| 分卷逻辑 | 5 MB 文件按 2 MB 切 3 卷，`cat` 合并后 md5 与原文件一致 ✔ |

厂商版权物不在上述任何资产中。
