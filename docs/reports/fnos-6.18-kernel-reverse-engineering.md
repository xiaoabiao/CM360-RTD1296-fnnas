# fnOS 6.18.18-trim 内核逆向报告

**逆向对象**：飞牛 fnOS 官方 arm64 内核 `6.18.18-trim`（构建者 `devops@fnnas.com`，`#491 SMP PREEMPT`，
`aarch64-linux-gnu-gcc (Debian 12.2.0-14) 12.2.0`，构建时间 2026-04-17 03:28:48 UTC）。

**为什么做这件事**：本项目（`rtd1296-fnnos`）在 CM360 上用自编译 **6.6.54** 跑 fnOS 1.2.x 用户态，
已知功能缺口是「`trimafs` 缺失 → triminit 链断 → `trim_*` 服务不自启；细粒度 ACL 不生效」。
本文用二进制逆向回答：**fnOS 的内核到底往上游 Linux 6.18.18 里加了什么**，以及**能否、如何在这些点上复刻**。

**一句话结论**：fnOS 的私有改动**不是"打几个配置补丁"**，而是在 VFS 层加了一整套**自研文件系统 `trimafs`
+ 挂载表 `trim_mounts_tree` + 替换 `check_acl`/改 `generic_permission`/改 `faccessat` 的 ACL 强制层
（FilesACL）+ 一个回收站设备 `trim_trashbin`**。同时实测证明：**fnOS 自己的内核根本不认识 `trimacl` 挂载选项**
（见 §6），你项目里 `patches/0007`/`0008` 处理的其实是 **fnOS 自身的 bug**，不是"缺少厂商特性"。

---

## 1. 素材与方法

| 素材 | 来源 | 说明 |
|---|---|---|
| `vmlinuz-6.18.18-trim` | fnOS 官方 arm64 镜像 boot 分区 | **arm64 裸 Image，未压缩**，32 926 208 B |
| `System.map-6.18.18-trim` | 同上 | 5 689 192 B，全符号 |
| `config-6.18.18-trim` | 同上 | 10 080 行 |
| 2 860 个 `.ko` + `modules.builtin.modinfo` | rootfs `usr/lib/modules/6.18.18-trim/` | 模块全集与内建模块设备表 |
| 上游对照源码 | `git clone` Linux stable **v6.18.18** | 用于结构体布局与源码级对照（**不靠记忆**） |

上游镜像与 boot 分区的提取过程见同项目 `docs/reports/fnos-image-anatomy.md` 与
`~/.cache/fnnas/re-extract.sh`；本次新做的只是从 `p1-boot.ext4` 里 `debugfs dump` 出上述三个文件。
**可复核的取素材命令**（`p1-boot.ext4` = 256 MiB 的 boot 分区镜像，无需 root）：

```bash
# 1) 看 boot 分区里有什么
debugfs -R "ls -l /" ~/.cache/fnnas/p1-boot.ext4
# 2) 取出内核/符号表/配置（含 uInitrd）
for f in vmlinuz-6.18.18-trim config-6.18.18-trim System.map-6.18.18-trim uInitrd-6.18.18-trim; do
  debugfs -R "dump /$f /tmp/$f" ~/.cache/fnnas/p1-boot.ext4
done
# 3) initramfs：u-boot legacy uImage（64B 头）→ zstd cpio
tail -c +65 /tmp/uInitrd-6.18.18-trim > /tmp/initrd.zst && mkdir -p /tmp/initrd && cd /tmp/initrd \
  && zstd -d -c /tmp/initrd.zst | cpio -idm
```

### 1.1 素材完整性验证（先证明"我们逆的就是它自己"）

- **内嵌配置对账**：内核开了 `CONFIG_IKCONFIG=y`，配置会以 `IKCFG_ST`…`IKCFG_ED` 标记 + gzip 内嵌在 Image 里
  （本镜像位于 `0x119a828`…`0x11a8a76`）。解出 10 080 行，与 `/boot/config-6.18.18-trim`
  **逐字节相同**（md5 均为 `5d07a2569b9c26249c0157026bd162bb`）
  → 我们手上的 config 就是**真实构建配置**，"复用官方 config 构建上游 6.18.18"这条路线成立。
- **上游基线确认**：`linux-headers-6.18.18-trim/Makefile` 是**纯净上游**内容
  （`VERSION=6 PATCHLEVEL=18 SUBLEVEL=18 EXTRAVERSION=(空) NAME="Baby Opossum Posse"`），
  与我们从 kernel.org 克隆的 `v6.18.18` 一致。版本串里的 `-trim` 来自构建时的 `make LOCALVERSION=-trim`
  （因此 `/boot/config` 里 `CONFIG_LOCALVERSION=""`）。
- **initramfs 已查**：`uInitrd-6.18.18-trim` = u-boot legacy uImage + zstd cpio（1 457 条目），
  **其中没有任何 `trimafs` 引用** → `trimafs` 是主系统起来后由 `triminit` 挂的，不是 initrd 阶段，
  这也解释了为什么缺它时症状是"能 ping 通、面板打不开"（用户态服务链断）而不是"起不来"。

### 1.2 三条关键技术（决定了这份报告能有多"实"）

1. **地址标定**：arm64 Image 文件偏移 `0` ↔ `_text = 0xffff800080000000`，故 `VA = file_off + 0xffff800080000000`。
   验证锚点：`__start_rodata`(VA `0xffff800081170000`) 处读出真实 rodata 字符串；
   `trim_acl_permission` 反汇编出规范函数序言。
   工具：`va.sh`。
2. **指针在 `.rela.dyn` 里，不在原地**（内核开了 `CONFIG_RELOCATABLE`）：
   直接按 8 字节读结构体字段会读到 0，必须查 `Elf64_Rela{ r_offset, r_info, r_addend }` 中
   `type=1027 (R_AARCH64_RELATIVE)` 的记录：`r_offset` = 槽位 VA，`r_addend` = 指针值。
   **这一步是解开 `file_system_type`/`s_ops`/`file_operations` 等所有结构体的前提**。
   工具：`rela.py`。
3. **交叉引用扫描**（逆向这类"改上游函数"的补丁最有杀伤力）：
   - `xref.py`：扫全 `.text` 解码 `BL/B` 的 26 位相对偏移 → **谁调用了厂商符号**；
   - `strxref2.py`：扫 `ADRP+ADD`/`ADRP+LDR`/`ADR`/`LDR-literal` → **谁引用了厂商私有字符串**（用于抓"没有新符号"的改动）。
   > 踩坑记录（工具第一版全漏报）：`ADRP` 之后的 `ADD/LDR` 必须比对 **Rn（基址寄存器）**，我最初错比了 Rd；
   > 且 `printk` 格式串在内存里的真实起点**前面还有 `\001`+loglevel 控制前缀**，按正则捞到的地址偏后 1~3 字节，
   > 精确等值查引用必然落空 —— 必须按"字符串区间"反查。

工具源码留档在 `evidence/fnos-6.18-kernel-re/`（见 §9）。

---

## 2. 厂商新增了哪些源码文件

方法：把内核二进制里所有 `__FILE__` 形态的路径串（`embedded-paths.txt`，1 659 条）与
上游 v6.18.18 的完整文件清单（91 178 条）做差集（路径先归一化 `./` 与 `..`，`LC_ALL=C` 排序）。

**结果（8 个）**：

```
fs/trimafs/inode.c                          ← fnOS 私有文件系统
fs/trim_trashbin/trim_trashbin.c            ← fnOS 私有回收站（内建模块）
drivers/misc/event_report/er.c              ← fnOS 事件上报
drivers/misc/event_report/er_netlink.c
drivers/dma-buf/heaps/page_pool.c           ← Rockchip BSP（非 fnOS 特有）
drivers/dma-buf/heaps/rk_cma_heap.c
drivers/dma-buf/heaps/rk_system_heap.c
drivers/iommu/rockchip-iommu-av1d.c
```

> ⚠️ **这是下界，不是全集**：只有使用 `__FILE__`（`WARN`/`BUG`/显式打印）的源文件才会在二进制里留路径串。
> 例如 `fs/trimafs/` 显然不止 `inode.c` 一个文件（它实现了 super/lookup/dentry 等），但只有 `inode.c` 露了名字。
> 因此**不能**据此断言"厂商只加了这 8 个文件"——只能断言"这 8 个文件在上游不存在"。

---

## 3. 厂商新增符号（权威枚举）

方法：`System.map` 的全部函数符号（`T/t/W/w`）减去「上游整棵源码树里出现过的标识符集合」
（用 rg 从 `*.c/*.h/*.S/Kconfig/Makefile` 抽出 5 262 461 个唯一标识符）。
再剔除宏生成的噪声（`*_driver_exit`/`*_init` 这类 `module_driver()` 展开名）。

厂商私有函数（fnOS 特有部分，按地址排序）：

| 区段 | 函数 |
|---|---|
| `fs/open.c`（改） | `trim_syscall_faccessat`、`trim_syscall_realpath`（只有 `.constprop.0` 版本） |
| `fs/namei.c`（改） | `trim_check_acl`、`trim_access_check_acl`、`is_str_num`、`may_user_dir_d`、`is_user_dir`、`is_team_trashbin_dir_and_check_acl`、`is_mount_on_vol_d`、`is_mount_on_vol`、`is_vol_path_d`、`is_vol_path`、`is_vol`、`trim_is_in_group`、`trim_access_permission_check`、`vol_setattr_force`、`get_team_trashbin_access`、`is_move_to_trash`、`trim_do_trashbin`、`_trim_is_on_trashbin_whitelist`、`trim_is_on_trashbin_whitelist`、`trim_mounts_query_by_sb` |
| ACL 实现 | `trim_acl_permission`、`trim_access_acl_permission`、`trim_access_posix_acl_permission` |
| `fs/trimafs/` | 43 个 `trimafs_*`（`fill_super`/`get_tree`/`get_inode`/`lookup`/`readdir`/`getattr`/`statfs`/`set_acl`/`create`/`mkdir`/`unlink`/`rmdir`/`rename`/`symlink`/`setattr`/`encode_fh`/`parse_param`/`kill_sb`…）+ `do_statfs_sum`、`do_trimafs_mknod`、`trimafs_init_cachep`、`init_trimafs_fs`、`exit_trimafs_fs` |
| `fs/trim_trashbin/` | `trim_trashbin`、`trim_trashbin_open/release/read/write`、`trim_trashbin_processing_set_comp(_all)`、`trim_trashbin_init/cleanup`、`trim_trashbin_fops` |

**厂商新增全局数据**：`trim_mounts_tree` @ `0xffff800081fd5af0`、`trim_mounts_rwlock` @ `0xffff800081fd5ae8`、
`trimafs_fs_type` @ `0xffff800081e35a68`、`trimafs_fs_parameters` @ `0xffff8000811ff900`、
`trim_trashbin_fops` @ `0xffff800081200110`。
`trim_mounts_tree` 是本层的核心：**一张由厂商自己维护的挂载树**，`trim_mounts_query_by_sb()` 用 `sb` 去查它。

> 同样注意：这是"名字在二进制里有、上游源码里没有"的**下界**（若某厂商函数名恰好出现在上游注释里就会被漏掉）。

---

## 4. 厂商改了哪些**上游**函数（调用点级证据）

`xref.py` 扫出的、**上游函数体内部出现厂商调用**的清单（格式：上游函数 → 被插进去的厂商调用）：

| 被改的上游函数 | 插入点 | 厂商调用 | 含义 |
|---|---|---|---|
| `generic_permission` | `+0x44` | `trim_mounts_query_by_sb`(0x8041fa9c) | VFS 通用权限判定**入口**先查厂商挂载表，非零即直接返回 |
| `generic_permission` | `+0x374` | `trim_check_acl`(0x803fe028) | **替换了上游的 `acl_permission_check()`**，返回后与 `-EACCES`(-13) 比较 |
| `do_mkdirat` | `+0x18c` | `trim_mounts_query_by_sb` | 建目录前查卷表 |
| `do_rmdir` | `+0x23c` | `trim_do_trashbin`(0x804063e0) | 删目录走回收站 |
| `do_unlinkat` | `+0x36c` | `trim_do_trashbin` | 删文件走回收站 |
| `__arm64_sys_faccessat` | `+0xa4`, `+0xb4` | `trim_syscall_faccessat`、`trim_syscall_realpath` | **faccessat 系统调用体被改** |
| `__arm64_sys_faccessat2` | `+0xa0`, `+0xb0` | 同上 | 同上 |
| `btrfs_parse_param` | — | 仍走上游"未识别选项 → `-EINVAL`"分支 | 见 §6 |

`trim_check_acl` 自身反汇编显示它就是上游 `check_acl()` 的厂商版：

```asm
; RCU 分支（mask & MAY_NOT_BLOCK）
bl   0x8047f3a4          ; get_cached_acl_rcu()
bl   0x80480d80          ; trim_acl_permission(idmap, inode, acl, mask)  ← 取代 posix_acl_permission()
; 非 RCU 分支
bl   0x8048066c          ; get_inode_acl()
bl   0x80480d80          ; trim_acl_permission(...)
; 之后是 posix_acl 引用计数释放（ldaddl / dmb ishld 序列）
```

即：**上游 POSIX ACL 判定被厂商的 `trim_acl_permission` 整体接管**，ACL v2 语义就实现在这里。
`trim_acl_permission` 直接按 `struct posix_acl` 布局（`a_count` @ +4、`a_entries` @ +0x18、每项 8 字节）遍历，
说明厂商 ACL 是"**寄生在 posix_acl 结构上的扩展**"，而不是另起一种 in-memory 格式。

> 一个易错的细节：`acl_permission_check` 在**两侧都没有符号**——上游把它（以及 `check_acl`）**内联**进了
> `generic_permission`。fnOS 做的是"把这段内联代码换成一个对 `trim_check_acl` 的调用"，
> 而不是"删掉了某个函数"。所以符号差集里看不到它，只有反汇编与调用目标差集能看到。

### 4.2 调用目标差集（`calldiff.py`：同一函数两侧的 `bl` 目标做符号名差集）

这是比"看谁调用厂商符号"更灵敏的一招：厂商有些改动**不调用任何新符号**（直接在原函数里操作厂商全局表），
只有把两侧的调用目标集合做差才能抓到。本轮实测结果（原始输出见
`evidence/fnos-6.18-kernel-re/calldiff-report.txt`）：

| 上游函数 | 上游→fnOS 调用点数 | **fnOS 新增的调用目标** | 读出来的改动 |
|---|---|---|---|
| `path_mount` | 70 → 92 | `_raw_write_lock/_unlock`、`rb_insert_color`、`kfree`、`__kmalloc_cache_noprof`、`memmove`、`strnlen`、`dput`、`lockref_get`、**`is_mount_on_vol_d`**、`__fortify_panic` | **挂载成功时把这条挂载插进厂商的 rbtree（`trim_mounts_tree`），带写锁** |
| `path_umount` | 27 → 42 | `rb_erase`、`_raw_write_lock/_unlock`、`kfree`、`memset`、`strncpy`、`_printk` | 卸载时从树上**摘除**记录 |
| `do_mkdirat` | 12 → 14 | `strcmp`、`trim_mounts_query_by_sb` | 建目录前查卷表 |
| `generic_permission` | 12 → 28 | `is_team_trashbin_dir_and_check_acl`、`is_user_dir`、`is_vol_path`、`make_kgid`、`trim_check_acl`、`trim_mounts_query_by_sb`、`__stack_chk_fail` | VFS 权限判定入口整体被厂商接管 |
| `do_unlinkat` | 25 → 31 | `strcmp`、`trim_do_trashbin` | 删除文件走回收站 |
| `do_rmdir` | 13 → 21 | `strcmp`、`trim_do_trashbin` | 删除目录走回收站 |
| `__arm64_sys_faccessat` | 1 → 6 | `user_path_at`、`path_put`、`trim_syscall_faccessat`、`trim_syscall_realpath`、`__stack_chk_fail` | **faccessat 系统调用被整体重写**（上游那 1 个调用点已不是同一条路径） |

**三条结论**：

1. `trim_mounts_tree` 的写入方就是 `path_mount`/`path_umount` —— 也就是说，
   **厂商是在 VFS 挂载路径上维护"哪些挂载点属于哪个卷"这张表的**。
   这解释了为什么 ACL 层要 `trim_mounts_query_by_sb(sb)`：从超级块反查卷。
2. 被改的上游文件由此可以点名：`fs/namespace.c`（path_mount/path_umount）、`fs/namei.c`
   （generic_permission/do_mkdirat/do_unlinkat/do_rmdir/link_path_walk 一带）、`fs/open.c`（faccessat）。
3. 上表 7 个函数全部落在"**权限 + 命名空间 + 删除**"这条主轴上，没有一个是无关改动 ——
   这本身是对"我们不能用上游 6.18 直接替代 fnOS 内核"的量化说明。

### 4.3 构建级对照（`cmp-syms.py`：官方内核 vs 上游自建 v6.18.18）★

本轮把"验证手段"从静态分析升级到了**对照构建**：用 **fnOS 自己的 config**（§1.1 已证明逐字节可信）
配合免 root 取得的交叉工具链（`apt-get download gcc-12-aarch64-linux-gnu` + `dpkg-deb -x`，
官方用 Debian GCC 12.2.0、对照用 Ubuntu GCC 12.5.0）构建上游 **v6.18.18** 的 `vmlinux`，然后按
"下一个符号地址 − 本符号地址"算出每个函数的尺寸做对照（脚本 `cmp-syms.py`，原始输出
`evidence/fnos-6.18-kernel-re/symdiff-vs-upstream.txt`）：

| 指标 | 值 |
|---|---|
| 函数总数 | fnOS 65 433 / 上游 65 145 |
| **仅 fnOS 有的函数** | **293**（其中属于 fnOS 私有命名族的正好 **80 个**，与 §3、§5.1 的手工枚举**完全一致**） |
| 仅上游有的函数 | 5（`__add_cma_heap`、`ata_hpa_resize`、`dw_mci_wait_while_busy.part.0`、`rk_iommu_disable`、`test_and_set_bit_lock` —— 全是内联/拆函数的产物，**不是被删函数**） |
| 尺寸不同 | 15 006（23.0%），其中 14 489 个 `|Δ| ≤ 16` 字节 → 属 GCC 12.2/12.5 代码生成噪声 |

**方法自检（重要）**：§4.1 用 xref 认定的 5 处改动**全部**在尺寸差里现身，且方向一致：

```
generic_permission        628 → 1268   (Δ +640)
__arm64_sys_faccessat     52  → 320    (Δ +268)
__arm64_sys_faccessat2    52  → 320    (Δ +268)
do_rmdir                  400 → 660    (Δ +260)
do_unlinkat               648 → 892    (Δ +244)
```

**两条独立证据链（调用点 / 尺寸）互相印证**，所以"被改过的上游函数"这份清单是有冗余验证的。

**尺寸差带来的新发现**（`|Δ|` 大且与 fnOS 私有功能相关）：

| 函数 | Δ | 说明 |
|---|---|---|
| `path_mount` | +708 | §4.2 已用调用目标差集证实：插入厂商挂载树 |
| `path_umount` | +380 | 同上：从树里摘除 |
| `__ext4_ioctl` | +312 | ext4 ioctl 被改（**待查**：与 fnOS 存储/配额有关？） |
| `ext4_resize_fs` | +288 | 同上 |
| `ext4_try_to_trim_range` | +256 | 同上 |
| `ata_dev_configure` | **+2540** | libata 被大幅改动 |
| `ata_eh_link_report` / `sata_pmp_error_handler` / `ata_eh_reset` / `ata_set_mode` / `ata_dev_print_features` | +736 / +456 / +244 / +240 / +248 | libata 一批 —— **对 CM360 的 SATA 路径可能有参考价值** |
| `system_heap_allocate` | **−932** | 上游实现被缩成 36 字节的壳 → 换成了厂商的 `rk_system_heap.c` 实现 |
| `cma_heap_allocate` / `system_heap_create` / `add_default_cma_heap` | −608 / +592 / +324 | Rockchip dma-buf heap 体系被替换 |
| `rockchip_pd_power` / `rk_iommu_resume` / `px30_otp_read` | −308 / +208 / −240 | Rockchip BSP 改动 |

> ⚠️ 上表里 Rockchip/libata 那几项**不能直接算作"fnOS 私有"**：它们更可能来自 Rockchip 的 BSP 分支。
> 但 `path_mount`/`path_umount`/`__ext4_ioctl` 这一组落在 fnOS 私有功能主轴上，判为 fnOS 改动。
> 这是**推断**，标注在此以免误用。


---

## 5. `trimafs`：一整个厂商私有文件系统

`trimafs_fs_type` 解出的字段（与上游 `include/linux/fs.h` 的 `struct file_system_type` 逐项对齐）：

| 偏移 | 字段 | 值 |
|---|---|---|
| `+0x00` | `name` | `"trimafs"`（@ `0xffff80008152e160`） |
| `+0x08` | `fs_flags` | `0x08` = **`FS_USERNS_MOUNT`**（允许在 user namespace 里挂载） |
| `+0x10` | `init_fs_context` | `trimafs_init_fs_context` |
| `+0x18` | `parameters` | `trimafs_fs_parameters` |
| `+0x28` | `kill_sb` | `trimafs_kill_sb` |

**挂载选项表**（`struct fs_parameter_spec[]`，32 字节/项，用 `rela.py fs-params` 解码）：

| # | name | type | opt | flags | 说明 |
|---|---|---|---|---|---|
| 0 | `mode` | `fs_param_is_u32` | 0 | 0 | 数值参数 |
| 1 | `debug` | `NULL` | 1 | 0 | 布尔 flag |
| — | `NULL` | — | — | — | 数组结束 |

> 布局自检（不靠记忆）：用同一工具解码内核里**上游自带**的 `btrfs_fs_parameters`、`shmem_fs_parameters`，
> 都得到完全正确的选项（`acl`/`noacl` 的 `flags=0x2` 正是上游 `fs_param_neg_with_no`；
> `clear_cache`/`compress`/`autodefrag` 齐全）。**并且 `shmem` 的 `mode` 项同样带 `data=0x8`**，
> 证明这不是厂商改动而是上游 `fsparam_u32` 的既有形态 —— 也侧面说明 **trimafs 的选项表是照 shmem/tmpfs 写的**，
> 它大概率是一个 **ramfs/tmpfs 型的伪文件系统视图**（把真实存储卷映射成目录树）。

**关键点：`trimafs` 没有任何 Kconfig 符号**（`config-6.18.18-trim` 里搜不到 `TRIMAFS`），
它被硬编进内核本体（`fs/Makefile` 里 `obj-y`），并且不导出任何符号
（`Module.symvers` 的 20 531 条导出里没有任何 `trimafs_*`/`trim_*`）。

**用户态怎么用它**（fnOS rootfs 证据）：`triminit` 里有字符串 **`mount -t trimafs trimafs /fs`**，
并带符号 `_Z13mount_trimafsv`（`mount_trimafs()`）、`_Z17is_volume_mountedPKcPc`、
`_Z26fix_volume_mountpoint_permv` —— 即 **`/fs` 是 trimafs 的挂载点**，
fnOS 把"卷"挂在 trimafs 之下，再由它统一呈现。

---

### 5.1 完整接口表（VFS 面已闭合）

厂商函数只以两种方式"接进内核"：代码里 `BL` 直调（§4），或被填进某张 `*_operations` 表由 VFS 按 vtable 分发。
用 `RELA` 反查（谁指向了厂商函数 → 槽位 → 所在符号）可以把**全部操作表逐字段解出来**
（原始输出见 `evidence/fnos-6.18-kernel-re/vtab-tables.txt`）：

| 表（符号） | 逐字段内容（字段偏移 → 函数） |
|---|---|
| `trimafs_fs_type` | `name="trimafs"`, `fs_flags=FS_USERNS_MOUNT`, `init_fs_context`, `parameters`, `kill_sb` |
| `trimafs_context_ops`（`fs_context_operations`） | `+0x00 free_fc`、`+0x10 parse_param`、`+0x20 get_tree` |
| `trimafs_ops`（`super_operations`） | `+0x00 alloc_inode`、`+0x08 destroy_inode`、`+0x10 free_inode`、`+0x28 drop_inode`、`+0x68 statfs`、`+0x80 show_options` |
| `trimafs_dir_inode_operations` | `lookup` `permission` `get_inode_acl` `create` `unlink` `symlink` `mkdir` `rmdir` `mknod` `rename` `setattr` `getattr` `listxattr` `set_acl` |
| `trimafs_file_inode_operations` | `permission` `get_inode_acl` `setattr` `getattr` `listxattr` `set_acl` |
| `trimafs_page_symlink_inode_operations` | `+0x08 get_link`、`+0x18 get_inode_acl`、`+0x20 readlink`、`+0x68 setattr`、`+0x70 getattr`、`+0x78 listxattr`、`+0xa8 set_acl` |
| `trimafs_dir_operations`（`file_operations`） | `+0x10 llseek(dir_lseek)`、`+0x40 iterate_shared(readdir)`、`+0x68 dir_open`、`+0x78 dir_close` |
| `trimafs_file_operations` | `+0x68 file_open`、`+0x98 get_unmapped_area(mmu_get_unmapped_area)` |
| `trimafs_dentry_operations` | `+0x20 dentry_delete`、`+0x30 dentry_release` |
| `trimafs_export_ops` | `+0x00 encode_fh`、`+0x08 fh_to_dentry` |
| `trim_trashbin_fops`（`file_operations`） | `+0x18 read`、`+0x20 write`、`+0x68 open`、`+0x78 release` |

三条由表结构直接读出的结论：

> **字段偏移的核对方式**（不靠记忆）：上表里的"函数↔偏移"是**实测**（RELA 反查），
> 而"偏移对应哪个回调"用上游 `include/linux/fs.h`/`fs_context.h` 的字段顺序核对：
> `file_operations` = owner(0x00) fop_flags(0x08) llseek(0x10) **read(0x18) write(0x20)**
> read_iter(0x28) write_iter(0x30) iopoll(0x38) **iterate_shared(0x40)** poll(0x48)
> **unlocked_ioctl(0x50)** compat_ioctl(0x58) mmap(0x60) **open(0x68)** flush(0x70) **release(0x78)**；
> `super_operations` = **alloc_inode(0x00) destroy_inode(0x08) free_inode(0x10)** dirty_inode(0x18)
> write_inode(0x20) **drop_inode(0x28)** evict_inode(0x30) put_super(0x38) sync_fs(0x40)
> freeze_super(0x48) freeze_fs(0x50) thaw_super(0x58) unfreeze_fs(0x60) **statfs(0x68)** … **show_options(0x80)**；
> `fs_context_operations` = **free(0x00)** dup(0x08) **parse_param(0x10)** parse_monolithic(0x18) **get_tree(0x20)** reconfigure(0x28)。
> 三张表**逐槽对齐**，没有"对不上的空位"——这本身就说明我们拿到的是完整表，而不是被截断的一部分。

1. **命名体系完全是 shmem/tmpfs 那一套**（`page_symlink_inode_operations`、`dir_operations` 里挂
   `iterate_shared`、`super_operations` 只实现 `alloc/free/destroy/drop_inode + statfs + show_options`）
   → trimafs 是**从 tmpfs/shmem 改出来的伪文件系统**，不是"真磁盘文件系统"。这与 §5 的选项表对照结论一致，
   且解释了为什么它需要 `do_statfs_sum`（自己算不出真实容量，得向底层卷求和）。
2. **厂商接口不用 ioctl**：`trim_trashbin_fops` 的 `+0x50 (unlocked_ioctl)` **实测为空**，
   trimafs 的各张表里也没有 `ioctl` 字段 → 用户态与内核的私有交互走的是
   **`read`/`write` 消息 + xattr + 文件系统语义**，不是 ioctl 号。目标清单里的"ioctl 约定"因此可以明确回答：
   **本内核的 fnOS 私有层没有自定义 ioctl**（这一点是"实测为空"，不是"没找到"）。
3. **ACL 三个入口都在 inode_operations 里**：`get_inode_acl` / `set_acl` 出现在 dir、file、symlink 三张表上
   （`+0x18` 与 `+0xa8`），说明 **ACL v2 的读写是标准 inode-op 路径**（即 `get_acl`/`set_acl` 回调 +
   xattr 通道），进一步印证 ACL 数据以 xattr 形态落盘。
4. **无设备表（of/pci/usb alias）**：`modules.builtin.modinfo` 里 `trim_trashbin` 只有
   `license=GPL` 与 `file=fs/trim_trashbin/trim_trashbin` 两项，**没有任何 `alias=of:…`**
   （对照：全内核内建模块共 1 074 条 `alias=of:`）→ 它是**手工注册的设备**（`class_create`/`device_create`），
   不是靠 DT `compatible` 匹配的驱动。这条对"要不要给 CM360 的 DTS 加节点"很关键：**不需要**。

---

## 6. ★ `trimacl`：fnOS 自己的内核也不认这个选项（实测）

本项目 `CHANGELOG.md` 记录：fnOS 用户态挂存储时传 `-o trimacl,prjquota`，vanilla 6.6 报
`unrecognized mount option 'trimacl'` 而拒绝挂载，于是写了 `patches/0007`（btrfs）、`patches/0008`（ext4）
把它当 no-op 接受。本次逆向给出了这个判断的**直接证据**：

1. **字符串级**：在整个 `vmlinuz-6.18.18-trim` 里搜 `trimacl`（整镜像字节搜索，含大小写变体）
   → **出现 0 次**。而 `prjquota` 出现 2 次（来自内建的 ext4 与 f2fs，与厂商无关）。
2. **代码级**：fnOS 内核的 `btrfs_parse_param` 在遇到未识别选项时**仍然返回 `-EINVAL`**：

```asm
cmp  w0, #0x22                    ; fs_parse() 返回的参数类型
b.ls 0x805bd334                   ; 已识别 → 正常处理
bl   <btrfs_warn/err>             ; 未识别 → 打日志
adrp+add → 0xffff800081513ac0     ; "\0013unrecognized mount option '%s'"
mov  w0, #0xffffffea              ; = -22 = -EINVAL   ★ 直接拒绝
```

**结论**：fnOS **官方内核同样会拒绝 `-o trimacl`**。也就是说这不是"自编译 6.6 内核太老"，
而是 **fnOS 1.2.0302 用户态与它自己内核之间的不一致（fnOS 自身的 bug）**——
与本项目引用的社区帖（官方支持的 OESPlus 升级后同样挂载失败）完全吻合。

**对项目的意义**：`patches/0007`/`0008` 的定位应从"补上厂商特性"改为"**为 fnOS 自身的 bug 做兼容**"，
并且它们的行为（接受并忽略）比 fnOS 官方内核更宽容 —— 这是**正确的做法**，但要在文档里说清性质，
避免误导成"我们缺东西"。反过来，**真正缺的东西是 `trimafs` 与 ACL 层**（§5、§4）。

---

## 7. 回收站：`trim_trashbin`

- 形态：**内建模块** `kernel/fs/trim_trashbin/trim_trashbin.ko`（`license=GPL`，
  `initcall __initcall__kmod_trim_trashbin__757_343_trim_trashbin_init6`），源码 `fs/trim_trashbin/trim_trashbin.c`。
- 具备 `file_operations`（`trim_trashbin_fops` @ `0xffff800081200110`）与 `open/release/read/write`，
  说明它是一个**字符设备接口**，由用户态读写来驱动删除/还原。
- 两个**厂商私有 xattr**（`user.` 命名空间，普通用户即可读写，与 `FS_USERNS_MOUNT` 的设计一致）：
  - `user.trim-trashbin`（由 `is_move_to_trash()` 引用，`0x8040636c`/`0x804063c8`）
  - `user.trim-team-trashbin-access`（团队共享回收站访问控制）
- 删除路径：`do_unlinkat`/`do_rmdir` → `trim_do_trashbin` → 判定（`trim_is_on_trashbin_whitelist`、
  `is_move_to_trash`）→ 需要时调用 `trim_trashbin`。
- 详细协议（设备名、读写消息格式、xattr 值格式）见配套文档 `fnos-6.18-kernel-re/KERNEL-trashbin.md`。

---

## 8. 对 CM360 项目的落地含义

### 8.1 为什么"缺 trimafs"会连锁成"面板打不开"

链路（与 `CHANGELOG.md` 的现场症状完全对得上）：

```
triminit: mount -t trimafs trimafs /fs
   └─ 自编译内核没有 trimafs  → mount 失败
        └─ triminit 初始化链中断
             └─ trim_* 服务不自启（能 ping 通、面板打不开）
```

因此 `cm360-trim-boot.service` 那种"兜底拉起服务"的做法是**绕过**而不是修复。
真正要拿到完整 fnOS，只有两条路：

| 路线 | 内容 | 现实性 |
|---|---|---|
| **A. 在 6.6.54 上复刻一个 `trimafs`** | 实现一个最小伪文件系统：`register_filesystem` + `init_fs_context`/`fill_super`/`kill_sb` + `mode`/`debug` 两个选项 + 能 `mount -t trimafs trimafs /fs` 成功。**先要能挂上，让 triminit 链走完**；ACL 语义可以先是 no-op | ★ 可行，工作量集中在"还原路径/卷映射语义"（见 §4/§5 与配套文档） |
| **B. 6.6 → 6.18 全量移植** | 把 RTD129x 驱动提到 6.18，直接用 fnOS 官方内核（含 trimafs/ACL/trashbin/OTA） | 工作量大，但**本文证明了官方内核的私有部分体量可控**：约 80 个函数 + 2 张表，不是黑盒 |

### 8.2 本文对决策的三个直接输入

1. **`trimafs` 的接口面很小**：`name="trimafs"` + `fs_flags=FS_USERNS_MOUNT` + 两个挂载选项。
   复刻起点不需要猜：`init_fs_context`/`parse_param`/`get_tree`/`fill_super` 的签名都能从上游同型
   （shmem/tmpfs）对照推出。
2. **ACL 层不是"必须一起做"**：它挂在 `generic_permission`/`acl_permission_check`/`faccessat` 三个点上，
   而这三个点**在 6.6 上同样存在**（名字/位置不同但职责一致）。要用最小代价换"面板能用"，
   只需 `trimafs` 能挂载；要 ACL 真生效才需要这一层。
3. **fnOS 内核 = 上游 6.18.18 + 可控增量**：上游 tag `v6.18.18` 确认存在，`config` 可直接复用，
   私有代码集中在 `fs/` 下少数文件。**这使"路线 B"从"黑盒赌一把"变成"可评估的移植工程"**。

---

## 9. 证据与工具留档

| 文件 | 内容 |
|---|---|
| `evidence/fnos-6.18-kernel-re/raw-evidence.txt` | 本文全部硬证据的原始输出（构建指纹、标定锚点、8 个厂商文件、fs_type 字段、选项表解码、`trimacl` 计数、btrfs `-EINVAL` 反汇编、xattr 串引用） |
| `evidence/fnos-6.18-kernel-re/vendor-files.txt` | 厂商新增源码文件（8 个） |
| `evidence/fnos-6.18-kernel-re/vendor-functions-real.txt` | 厂商新增符号候选全量（3 987 条，含宏生成噪声，供复核） |
| `evidence/fnos-6.18-kernel-re/embedded-paths.txt` | 内核二进制内嵌的 1 659 条源码路径串 |
| `evidence/fnos-6.18-kernel-re/vtab-tables.txt` | 厂商接口表逐字段枚举（RELA 反查结果） |
| `evidence/fnos-6.18-kernel-re/config-embedded.txt` | 从 Image 内嵌的 IKCONFIG 解出的构建配置 |
| `tools/re-kernel/` | **逆向工具集（已入库，可复用）**：`va.sh` 地址标定/反汇编、`rela.py` RELA 感知结构体解码、`xref.py` 调用图、`strxref2.py` 字符串锚定引用、`vtab.py` 接口表枚举；用法与两个致命 bug 的踩坑记录见该目录 `README.md` |

配套深度分析（各含独立证据小节）—— **注意：只有第 4 份真正完成，前三份待重做**（见 §11）：

| 文档 | 内容 | 状态 |
|---|---|---|
| `docs/reports/fnos-6.18-kernel-re/USERSPACE-trimafs.md` | 用户态（`triminit` 等）的挂载调用、`system.trim_acl` xattr 约定、`/dev/trim-trashbin` 与 `user.trim-trashbin-record` | ✅ 已完成（1 899 行） |
| `docs/reports/fnos-6.18-kernel-re/KERNEL-acl-layer.md` | ACL 判定链逐函数伪代码、`trim_mounts_tree` 字段布局、`trim_syscall_*` 与上游 `fs/open.c` 逐点对照 | ❌ 待重做 |
| `docs/reports/fnos-6.18-kernel-re/KERNEL-trimafs.md` | trimafs 是真 fs 还是伪视图、inode/dentry 来源、挂载依赖、最小复刻清单 | ❌ 待重做 |
| `docs/reports/fnos-6.18-kernel-re/KERNEL-trashbin.md` | 回收站设备形态、读写消息格式、两个 xattr 的作用 | ❌ 待重做 |

---

## 10. 未解与存疑（不要当成已解决）

1. **`trimafs` 的完整源码文件集未知**：只能确认 `fs/trimafs/inode.c` 存在，其它文件（super/dir/…）无从命名。
2. **`trim_mounts_tree` 的字段布局未完全还原**：只确认它是本层核心表、由 `trim_mounts_rwlock` 保护。
3. **ACL v2 的持久化与"进内核通道"尚未闭合**（本轮有重要更正）：
   用户态侧 `[实测]`（`USERSPACE-trimafs.md` §3.2）ACL 存在 **xattr `system.trim_acl`** 里
   （另有 `trusted.trim_team_id`），且 `libtrimacl.so` **不用 ioctl**，而是用**魔数 dirfd 的 `faccessat()`**
   作为私有 ABI —— 这正好解释了 §4.2 里 `__arm64_sys_faccessat(2)` 被整体重写、并新增
   `trim_syscall_faccessat`/`trim_syscall_realpath` 的原因。
   但 **内核整镜像里搜 `trim_acl` / `system.trim` 都是 0 次** → 内核不是靠"按名字匹配 xattr"处理 ACL 的。
   **已核实并作废一个错误推测**：上游 VFS 对 `system.*` 并不限制
   （`fs/xattr.c: xattr_permission()` 注释原文 *"No restriction for security.* and system.* from the VFS.
   Decision on these is left to the underlying filesystem / security module."*），
   所以"厂商一定改了 `fs/xattr.c`"**不成立**。仍待查：`system.trim_acl` 落在哪种文件系统上
   （btrfs/ext4 无此名 handler → `-EOPNOTSUPP`；trimafs 是 shmem 型、handler 有限）。
4. **未做运行时验证**：本文结论全部来自**静态**分析（符号/字符串/调用图/结构体/局部反汇编）
   + **构建级对照**（§4.3）。
   没有在 QEMU 或真实板上跑过 fnOS 的 6.18.18 内核（RTD1296 无对应驱动，跑不起来）。
   → 想再提高置信度只剩两条路：①在能跑的机器上装 fnOS 官方系统，用 ftrace/kprobe 观察
   `trim_mounts_query_by_sb`/`trim_check_acl`/`trim_trashbin_read` 的真实调用次数与参数；
   ②把 §8.1 的"最小 trimafs"写出来，在 CM360 上实测 `mount -t trimafs trimafs /fs` 是否能让
   triminit 链走完 —— **这是可上板验证的、成本最低的一条**。
5. **`is_str_num`/`may_user_dir_d` 等归属**：这些名字在上游源码里不存在，但**不能**据此断定它们是 fnOS 加的
   （也可能是 Rockchip BSP 带的）。按地址邻接它们坐在 `fs/namei.c` 的代码块里，倾向判定为 fnOS，
   但这条是**推断**，不是实测。
6. **`drivers/misc/event_report/`（fnOS 事件上报）未展开**：只确认它上游不存在；
   用户态侧 `usr/trim/bin/sysdiag` 与 `usr/sbin/ModemManager` 里有 `event_report` 字样，
   但**不足以下结论**说"CM360 上必须补它"。树莓派式的"板上有没有这东西"需要上板验证。
7. **未做构建级对照的"全量"部分**：§4.3 已经做了符号/尺寸对照并验证了方法，
   但只人工分析了 `|Δ|` 最大的约 80 个函数。**"被改但改动很小（|Δ| ≤ 64 字节）"的函数没有被逐个人工确认**，
   那部分（十几万行里的绝大多数）目前只能说"未确认"，不能说"没改"。
   要收口需要按 §4.3 的脚本把 `|Δ| > 64` 的全部候选逐条用 `calldiff.py`/`diff-func.py` 过一遍。

---

## 11. 本轮未完成的部分（交接说明）

见仓库根 **`总结.md`** 的"未完成事项"一节。要点：本轮 4 个深度分析子代理里只有"用户态用法"一份落盘
（1 899 行、内容完整），另外 3 份（ACL 判定链 / trimafs 模型 / 回收站协议）在写出文件前**失败**。因此：

- §4.2 / §5.1 / §7 给出的接口与调用关系是**主报告这边的实测结论**，已足够支撑"要不要做、怎么做"的决策；
- 但**逐函数伪代码级**的重建（例如 `trim_acl_permission` 每个 ACL tag 分支的确切语义、
  `trim_trashbin_read/write` 的字节级消息格式、`trimafs` 的 inode/dentry 来源）**尚未产出**，需要重做。

重做所需的一切都已就绪：素材位置、工具（`tools/re-kernel/`）、地址标定与两个致命坑的说明、
以及每个子任务的精确提示词，全部写在 `总结.md` 里。

---

*报告基于静态逆向 + 构建级对照，所有结论标明了证据出处；推断部分已在文中显式标注。*
