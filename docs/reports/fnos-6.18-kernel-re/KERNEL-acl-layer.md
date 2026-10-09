# fnOS 6.18.18-trim 内核 ACL 层逆向报告（KERNEL-acl-layer）

**分析对象**：飞牛 fnOS 官方 arm64 内核 `vmlinuz-6.18.18-trim`（未压缩裸 Image，32 MB），上游基线 Linux v6.18.18。
**核心结论（来自主报告实测）**：fnOS 在内核 VFS 层加了一整套私有 ACL（FilesACL）强制层，包括自研 `trimafs` 文件系统、厂商自维护挂载树 `trim_mounts_tree`、替换 `check_acl` 的 `trim_check_acl`/`trim_acl_permission`、改写的 `generic_permission` 与重写的 `faccessat` 系统调用。

**地址标定**：Image 文件偏移 0 ↔ `_text = 0xffff800080000000`，线性映射（已验证）。本报告所有"短地址"均指 `0xffff8000xxxxxxxx` 的低 32 位。
**指针约定**：`CONFIG_RELOCATABLE` 下所有指针在 `.rela.dyn`（R_AARCH64_RELATIVE, type 1027），直读 8 字节为 0，必须用 `rela.py` 解码。
**证据分级**：【实测】= 有二进制原始输出；【推断】= 有理由但未直接证实；未能确定者明写"未能确定"。

工具：`tools/re-kernel/`（`va.sh` / `rela.py` / `xref.py` / `strxref2.py` / `diff-func.py` / `calldiff.py`）。素材：`~/.cache/fnnas/re-6.18/`。

---

## 0. 目录

- §1 `trim_check_acl` —— 厂商版 check_acl（替代上游 acl_permission_check）
- §2 `trim_acl_permission` —— ACL 命中判定核心（替代上游 posix_acl_permission）
- §3 `trim_access_acl_permission` / `trim_access_posix_acl_permission` —— 访问路径封装
- §4 `trim_is_in_group` / `trim_access_permission_check` —— 组/权限组合判定
- §5 `is_vol` / `is_vol_path` / `is_mount_on_vol` / `is_user_dir` —— 卷/用户目录判定
- §6 `trim_mounts_query_by_sb` 与 `trim_mounts_tree` 节点布局还原
- §7 `trim_syscall_faccessat` / `trim_syscall_realpath` —— faccessat 魔数通道
- §8 `generic_permission` 判定链对照（diff-func.py）
- §9 结论与未解问题

---

## 1. `trim_check_acl`（0xffff8000803fe028）

分析中。

## 2. `trim_acl_permission`（0xffff800080480d80）

分析中。

## 3. `trim_access_acl_permission`（0xffff800080480c60） / `trim_access_posix_acl_permission`（0xffff800080480adc）

分析中。

## 4. `trim_is_in_group`（0xffff800080403d14） / `trim_access_permission_check`（0xffff800080403d48）

分析中。

## 5. `is_vol`（0xffff800080403cd4）/ `is_vol_path`（0xffff8000804003d0）/ `is_mount_on_vol`（0xffff80008040031c）/ `is_user_dir`（0xffff8000803fff30）

分析中。

## 6. `trim_mounts_query_by_sb`（0xffff80008041fa9c）与 `trim_mounts_tree` 节点布局

分析中。

## 7. `trim_syscall_faccessat`（0xffff8000803e8df4）/ `trim_syscall_realpath`（0xffff8000803e8a6c）

分析中。

## 8. `generic_permission` 判定链对照

分析中。

## 9. 结论与未解问题

分析中。
