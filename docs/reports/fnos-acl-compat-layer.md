# fnOS 私有 ACL / faccessat ABI 的用户态兼容层（CM360 + 6.6.54 内核）

**问题**：刷入自编译 6.6.54 内核 + fnOS 1.2.0302 后，面板里「创建存储空间」成功、
`/vol1` 也能挂载和读写，但**在面板「文件」里上传文件必失败**（只提示「上传失败」），
`share_service` 日志里则反复出现：

```
[smb] AddUserFoldersByStorageId, User 1000 has no permission of '/vol1/1000/1111'
```

同时 `trim_trashbind.service` 每 5 秒失败重启一次。

**结论**：不是存储/挂载/磁盘的问题，而是 **fnOS 用户态依赖厂商内核的私有
ACL/faccessat 接口，自编译内核没有**。本目录的 `libtrimcompat.so` 在用户态补齐
这些接口，装好后 SMB/面板的权限判定恢复正常（上传随即可用）。

---

## 1. 根因（证据链）

### 1.1 fnOS 的权限判定走「魔数 faccessat」

`docs/reports/fnos-6.18-kernel-re/USERSPACE-trimafs.md` 已经把 ABI 逆向清楚：
fnOS 把 `faccessat(2)` 的第一个参数（dirfd）当作命令号，取值在
`-21586..-21576`（`0xFFFFABAE..0xFFFFABB8`），第二个参数是**结构体指针**而不是路径。
厂商内核在 `faccessat2` 入口按 dirfd 分发，实现 ACL 感知的权限判定。

用户态调用链（实测反汇编）：

```
share_service: sharing::SysInfo::IsPathReadable(uid, path, flag)
  -> access(path, F_OK)                       // 正常 syscall，OK
  -> trim_access(uid, path, 4, 0, flag)       // libnperm.so
       -> faccessat(-21586, &ctx, mode, flags)   // 需要厂商内核
filemanager.hdl (file.checkUpload) / uploadsrv / trashbind
  -> trim_access(...) + trimacl_get_file/set_file(...)   // 同样依赖
```

`trim_access` 的关键反汇编（`/usr/trim/lib/libnperm.so` `0x2c50`）：

```
2cd8: mov w0, #0xffffabae      ; cmd = -21586
2cdc: str x22, [sp, #80]       ; ctx.path = path
2ce0: stp w19, w21, [sp, #88]  ; ctx.flags / ctx.uid
2cec: bl  faccessat@plt
2cf0: ret                      ; 返回值原样返回：0=有权限，负值=-errno
```

### 1.2 自编译内核上的实测

板端自检程序（本目录 `trim-access-test.c`，直接链 libnperm）：

```
# 未装兼容层
$ LD_LIBRARY_PATH=/usr/trim/lib ./trim-access-test 1000 /vol1/1000/1111 4
trim_access(uid=1000, path=/vol1/1000/1111, mode=4) = -1 (errno=9)   # EBADF

# 装兼容层后
$ LD_PRELOAD=/usr/local/lib/libtrimcompat.so ... ./trim-access-test 1000 /vol1/1000/1111 4
trim_access(uid=1000, path=/vol1/1000/1111, mode=4) = 0 (errno=0)
```

所以 `IsPathReadable()` 永远 `false` → 共享文件夹不生成 → 面板/上传服务的
权限判定也必然失败。

### 1.3 TrimACL 数据也写不进去

TrimACL v2 的 ACL 数据放在 xattr **`system.trim_acl`**（`libtrimacl.so` 硬编码）。
`system.*` 是 VFS 保留命名空间，只有注册了 xattr handler 的文件系统才能写；
主线/自编译 6.6.54 的 btrfs 直接返回 `EOPNOTSUPP`：

```
$ setfattr -n system.trim_acl -v 0x01 /vol1/1000/t
setfattr: /vol1/1000/t: Operation not supported
$ /usr/trim/bin/trimacl -m a:u:1000:rwx:sfd /vol1/1000/t
trimacl_get_file: Operation not supported
```

（`user.*` / `trusted.*` / `security.*` 和标准 POSIX ACL 都正常，唯独
`system.trim_acl` 不行 —— 这正是厂商内核额外注册的 handler。）

### 1.4 坏了到底是哪一步：`file.checkUpload` 返回 errno=9

面板上传分两步：先 WS RPC `file.checkUpload({size,path,overwrite})`，
成功后才 `POST /upload` 发字节。用板端协议脚本 `tools/fnos-api.py`
（纯标准库复刻面板登录/RPC/上传，见 `docs/reports/fnos-api-repro.md`）
直连复现：

```
# 装兼容层之前
file.ls  vol1/1000                                -> {"files":[...],"result":"succ"}   # 列目录正常
file.checkUpload {path:vol1/1000/1111/x.bin,...}  -> {"errno":9,"result":"fail"}      # ★ 失败
POST /upload                                      -> 浏览器不会发（所以 nginx 日志里没有）

# 装兼容层之后
file.checkUpload ...                              -> {"uploadName":"x.bin.~#0","result":"succ"}
POST /upload                                      -> HTTP 200
/vol1/1000/1111/x.bin                             -> 4096 B，md5 与本地一致
```

`errno 9` = `EBADF`，正是魔数 `faccessat` 在自编译内核上返回的值。
更精确的位置（见 [`fnos-upload-checkupload-re.md`](fnos-upload-checkupload-re.md)）：
`/usr/trim/bin/handlers/filemanager.hdl` 的 `ioreq_handler_checkupload`（`0x10e80`）
在 `mkdirs` 之后调用 `trim_access(uid, parentDir, W_OK, 0, 0)`（`0x10f2c`）→
`faccessat(0xFFFFABAE, &ctx, 2, 0)`；失败分支的 errno→协议码映射表
（`0x110a0–0x1119c`）**不含 9/EBADF，原样透传** → `{"errno":9,"result":"fail"}`。
客户端 `Qr(errno)` 的映射表也没有 9，于是落到 `error.default` 通用文案；
且不会发出 `POST /upload` —— 与用户看到的现象完全吻合。

---

## 2. 修法：`libtrimcompat.so`（LD_PRELOAD，用户态）

不重编内核、不改 fnOS 二进制，只加一个共享库：

| 私有接口 | 兼容层做法 |
|---|---|
| `faccessat(-21586, &perm_ctx, mode, flags)` `internal_check_perm` | 按 `st_uid/st_gid` + POSIX mode（+ 标准 ACL，若编译时带 `HAVE_ACL`）算出 uid 的 rwx，返回 0 / `-EACCES` |
| `faccessat(-21579, …)` `trim_get_perm` | 返回 rwx 位掩码 |
| `faccessat(-21577, …)` `trim_may_delete` | 父目录 w+x + sticky 规则 |
| `faccessat(-21576, …)` `__trimacl_get_file_all` | 读 `user.trim_acl`（不存在则合成 4 字节空 ACL 头） |
| `faccessat(-21582, …)` `is_support_trimacl` | 返回 1（声称支持，走用户态 ACL 路径） |
| `faccessat(-21585/-21581/-21578/-21584/-21583, …)` | `realpath` / `is_mountpoint` / `mode` / 外部磁盘开关 的用户态实现 |
| xattr `system.trim_acl` | 全部 `get/set/remove/listxattr` 族重定向到 **`user.trim_acl`**（btrfs 可写），值原样搬运 |

结构体布局、命令表、ACE 二进制格式全部照
`docs/reports/fnos-6.18-kernel-re/USERSPACE-trimafs.md` §4/§5，没有猜测成分。
`user.trim_acl` 与 `system.trim_acl` 内容逐字节相同（4 字节头 + n×20 字节 ACE），
所以 `trimacl` 工具、`filemanager`、`uploadsrv` 之间读写是自洽的。

部署：给 `trim_main` / `trim_upload` / `filestor_service` / `trim_http_cgi` /
`share_service` 加 systemd drop-in `Environment=LD_PRELOAD=...`，重启服务即可
（`install.sh` 全自动，`--uninstall` 可完整回退）。

---

## 2.2 `/fs`（trimafs）兼容：普通目录 + bind mount

FTP/WebDAV/NFS 的共享视图走 `/fs/<uid>/<proto>/<share>`。原来 `/fs` 是厂商私有
`trimafs` 伪文件系统（shmem 改造，见 `reports/fnos-6.18-kernel-re/`），自编译内核
没有 → `share_service` 建符号链接时 `[TrimAFS] failed to create '/fs/...'`。

直接 `mkdir /fs` 只解决一半：`share_service` 会用 `symlink(2)` 建
`/fs/1000/ftp/1111 -> /vol1/1000/1111`，但 FTP 的 `ChrootSet @ /fs/%U/ftp`
会在该目录上 `chroot`，**绝对符号链接 `/vol1/...` 在 chroot 里解析不到**
（实测：FTP 根目录能看到 `1111`，但进去列目录为空、GET/PUT 失败）。

`cm360-fake-fs.sh` 的做法（`/usr/local/lib/cm360-fake-fs.sh`，systemd 服务
`cm360-fake-fs.service`，每 5 秒对账一次）：

1. 保证 `/fs` 存在（普通目录，755）；
2. 对每个 `/fs/<uid>/<proto>`，把 `/volN/<uid>` bind 到 `<proto>/volN/<uid>`、
   `/volN/@team` bind 到 `<proto>/volN/@team`。于是 chroot 内的绝对符号链接
   `/volN/<uid>/...` 解析为 `<chroot>/volN/<uid>/...` → 落到 bind mount 上；
3. 卷这一层目录设成 `0111`（只给 x 不给 r）：FTP 根目录里会出现一个 `vol1`
   名字，但进不去/列不出，避免把整卷暴露给 chroot 用户；
4. `share_service` 的 drop-in 里加了 `ExecStartPre=…/cm360-fake-fs.sh once`，
   保证它启动时 `/fs` 一定在（开机时 `triminit` 会先删掉 `/fs`）。

实测（FTP，`ChrootSet` 生效）：根目录列出 `1111`，`/1111/` 能列目录、
GET 返回文件内容、PUT 能落盘到 `/vol1/1000/1111/`（见 §3.5）。

---

## 2.3 回收站 / 删除：魔数 `unlinkat` 的用户态实现

面板删除原来也不可用：`file.rm` 会调
`unlinkat(dirfd=-7126, path, flags)`（移入回收站）或 `-7125`（彻底删除），
厂商内核按负 dirfd 分发；stock 内核返回 `EBADF`，`trim` 的任务就永远等不到完成。
`strace` 实测（未装 shim 时）：

```
unlinkat(-7126, "vol1/1000/1111/x.txt", 0) = -1 EBADF
unlinkat(-7125, "vol1/1000/1111/x.txt", 0) = -1 EBADF
```

格式（`trashbind` 反汇编 + 面板 RPC 双向验证，详见
[`fnos-trashbin-re.md`](fnos-trashbin-re.md)）：

- 回收站根：`/vol<v>/<uid>/.@#local/trash`（团队：`/vol<v>/@team/<team>/.@#local/trash`），
  目录 0700；条目父目录 0771（复制原父目录的 owner/mtime/ACL）；
- 条目名 = 原路径去掉 `vol<v>/<uid>/` 的相对路径（保留子目录层级，不做 base64）；
- 每条 inode 的 xattr `user.trim-trashbin-record` = 纯文本 `u:<uid>,t:<unix秒>`；
- 面板恢复 = `rename(<trash路径>, 去掉 "/.@#local/trash/" 段后的原路径)`。

兼容层拦截 `unlinkat` 的两个魔数（`trash-ref.c`）：
`-7126` → `trimcompat_trash_move()`（mkdir/复制 ACL/rename/写 xattr，同名冲突用
厂商同款 `_<u64>` 后缀；删目录时 filemanager 会先逐个 trash 子项再 trash 目录本身，
这里对“目录合并”做兜底，避免出现空壳目录条目）；`-7125` →
`trimcompat_rm_force()`（文件 unlink / 目录递归删除）。

> 实测提醒：`file.rm` / `file.trash.restore` / `file.trash.clear` 属于**异步任务**，
> 其 `taskInfo`/`taskId`/最终 `result` 帧推送到**登录时那条 `type=main` WebSocket** 上；
> 只监听 `type=file` socket 会误判“没有响应”。见 `tools/fnos-rpc-probe.py`。

---

## 3. 实测验证（2026-10-26，板 192.168.1.234）

1. **共享恢复**：装好后 `share_service.log` 不再报 “no permission”，
   `count: 1`，`/etc/samba/users/1000.share.conf` 生成 `[1111] path=/vol1/1000/1111`；
   Windows 侧 `\\192.168.1.234\1111` 可写（写 `hello.txt` 成功）。
2. **TrimACL 闭环**：`trimacl -m a:u:1000:rwx:sfd` 写入 → `getfattr` 可见
   `user.trim_acl` → `trimacl` 能读回 `1 <allow> uid:1000 permset:rwx`。
3. **权限判定**：`trim-access-test` 从 `-1/EBADF` 变为 `0`（见 §1.2）。
4. **面板上传（端到端）**：`tools/fnos-api.py` 复刻面板流程实测：

   | 步骤 | 装兼容层前 | 装兼容层后 |
   |---|---|---|
   | `file.ls vol1/1000` | succ | succ |
   | `file.checkUpload` (1 KiB) | **`{"errno":9,"result":"fail"}`** | `{"uploadName":"...~#0","result":"succ"}` |
   | `POST /upload` | （不会发出） | `HTTP 200` |
   | 落盘文件 | — | 4096 B，`md5=6d6dd6f11354726a973564ef879a8b19` 与本地一致 |

5. **`/fs`（trimafs）兼容层**：`cm360-fake-fs.sh` + bind mount 后，FTP 实测：

   ```
   $ curl --list-only ftp://Xiaoabiao:***@127.0.0.1/
   1111                                  # 共享（symlink 由 share_service 建）
   $ curl --list-only ftp://.../1111/    # 深度进入（chroot 内符号链接可解析）
   ftptest.txt
   $ curl ftp://.../1111/ftptest.txt
   ftp-data-123                          # GET 正常
   $ curl -T put.txt ftp://.../1111/put.txt   # PUT 正常，落盘 /vol1/1000/1111/put.txt
   ```

6. **删除 / 回收站（端到端，`tools/fnos-rpc-probe.py` 复刻面板 RPC）**：

   | 操作 | 结果 |
   |---|---|
   | `file.rm` 文件 + moveToTrashbin=true | 主 socket 收到 `taskId` + `{"result":"succ"}`；文件出现在 `/vol1/1000/.@#local/trash/1111/<name>`，xattr `u:1000,t:<秒>` |
   | `file.rm` 文件 + moveToTrashbin=false | `succ`；文件被彻底删除 |
   | `file.rm` 目录（两种模式） | `succ`；目录整体进回收站（子项合并成一条），或递归彻底删除 |
   | `file.trash.list` | 列出回收站条目，返回 `rmUid`/`rmTime`（来自记录 xattr） |
   | `file.trash.restore` | `succ`；条目（含目录及内容）恢复回原路径 |
   | `trim_trashbind.service` | 已 `disable`（回收站改由兼容层完成，不再每 5s 失败重启） |

7. **应用中心给应用授权（`POST /app-center/v2/config/app/authorization-path`）**：
   `trim_app_center` 覆盖前该请求返回 **500**（`/var/log/trim_app_center/error.log`：
   `system panic allow user perm ...: acl get_file_acl failed ... trimacl_get_file
   returned nil (errno=95:operation not supported)`）；覆盖后返回
   `{"code":0}`，`trimacl` 显示 `allow uid:995 permset:rwxpdDaAeEc inherit:sfd`，
   授权后 `trim_access(uid=995, mode=rwx)` 全部通过，
   `trim access stat error` 不再出现（此前每次授权都刷 `bad file number`）。


---

## 4. 已知限制 / 残余工作

- **`trim_trashbind` 已由兼容层取代**：它依赖的 `/dev/trim-trashbin` 字符设备只存在于
  厂商内核；回收站/删除现在由 `unlinkat` 魔数拦截在用户态完成，`install.sh` 会
  `systemctl disable --now trim_trashbind`（若要回退 `--uninstall` 会重新 enable）。
  回收站目录在 `/vol<v>/<uid>/.@#local/trash/`，删除的文件仍可用面板「回收站」查看/恢复。
- **`/fs`（trimafs）已由 `cm360-fake-fs.sh` 兼容**（普通目录 + bind mount），
  FTP 实测列目录/GET/PUT 正常。残余细节：FTP 根目录会多出一个不可进入的
  `vol1` 目录名（`0111` 只给 x）；WebDAV/NFS 若启用同样走 `/fs/<uid>/<proto>`，
  应一并生效（本机未启用，未实测）。
- **ACL 语义是近似（但已读取 TrimACL）**：`mode_perms()` 会解析 `user.trim_acl`
  （TrimACL v2：4 B 头 + 20 B ACE，`tag/type` bit0=allow、`permset` +4、
  `inherit` +8、`qualifier` +12），按 user/group/everyone/owner 四类 tag 叠加
  allow/deny；命中时以 TrimACL 为准，否则回退 POSIX mode / 标准 POSIX ACL。
  尚未实现继承位（inherit 用于面板展示，不参与当前对象判定）与项目配额、
  `a:`/`e:` 等高级位语义。单用户/家庭场景够用，**应用中心给应用授权已实测生效**
  （详见 §3.6）；多用户细粒度继承场景需谨慎。
- **配额/空间检查**：`check_upload` 的空间检查走 `is_not_enough_space`
  （`libquota` 的 `trim_get_quota` + 逐级 `statfs`）。本板实测
  `trim_get_quota` 返回 `limit=-1`（不限额），当前不阻塞；`uploadsrv` 写路径
  **没有**配额/空间预检，596/597 只会在内核 `open/write/mkdir` 真的返回
  `EDQUOT/ENOSPC`（真配了用户配额 / 磁盘写满）时出现 —— 届时需再实测。
  @team 路径的 `trim_project_id_get` 在本板返回 `EINVAL` 会静默回退 `statfs`，
  不阻塞上传。
- 这是**用户态补丁**，fnOS 升级（`/usr/trim` 被替换）后需重新执行
  `install.sh`；升级也可以顺手复查 `system.trim_acl`/魔数表是否变化。

---

## 5. 使用

```sh
# 板端 root
sudo ./install.sh                 # 编译（无 gcc 时用预编译 .so）+ 安装 + 重启服务 + 自检
sudo ./install.sh --log           # 同时写调试日志 /tmp/trimcompat.log
sudo ./install.sh --uninstall     # 完整卸载
```

自检：

```sh
LD_LIBRARY_PATH=/usr/trim/lib ./trim-access-test 1000 /vol1
# 期望：trim_access(...) = 0
```

调试日志（`TRIMCOMPAT_LOG`，默认 `/tmp/trimcompat.log`）会记录每次魔数调用的
路径/uid/mode/结果，便于判断是哪一类检查在起作用。
