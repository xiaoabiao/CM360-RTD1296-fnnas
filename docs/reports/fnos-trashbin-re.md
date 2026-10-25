# fnOS 回收站（trashbin）私有 ABI 逆向 + 用户态实现

- 板卡：CM360 / RTD1296，fnOS **1.2.0302**，自编译 **6.6.54** 内核（`#38 SMP PREEMPT ... aarch64`）
- 目标文件：`/usr/trim/bin/filemanager`、`/usr/trim/bin/handlers/filemanager.hdl`、`/usr/trim/bin/trashbind`、`/usr/trim/lib/libnfile.so`、`/usr/trim/lib/libnperm.so`
- 实测时间：2026-10-26 02:42–03:05（Asia/Shanghai）
- 交付物：本文 + `boards/rtd1296-cm360/board-scripts/trim-compat/trash-ref.c`
- 结论一句话：**回收站完全由用户态实现**（格式=目录镜像+xattr 文本记录），已用「手工构造条目 → 面板 RPC 列表 → 面板 RPC 还原」闭环验证通过；`trimcompat_trash_move()` 已在板上编译运行，并被面板原样识别/还原。

---

## 0. TL;DR（给接线的人）

1. `unlinkat` 的魔数 dirfd = **`-7125 - g_move_to_trashbin`**：`-7125` = 永久删除，`-7126` = 入回收站。
   调用点只有两处（`rm_dir` / `files_rm`），文件和目录都走同一个 `unlinkat`，目录多带 `AT_REMOVEDIR(0x200)`。
2. 在 shim 里拦截 `unlinkat(-7126, path, flags)` → 调 `trimcompat_trash_move(path, uid, flags)`；
   拦截 `unlinkat(-7125, path, flags)` → 用真实 `unlinkat(AT_FDCWD, path, flags)` 真删。
3. 回收站布局（相对 `/`，trim 的 cwd 就是 `/`）：
   - 根：`vol<N>/<uid>/.@#local/trash`（团队：`vol<N>/@team/<name>/.@#local/trash`），`mkdir 0700`
   - 条目名 = 原路径去掉 `vol<N>/<uid>/` 后剩下的部分，**保留子目录层级**（不是 base64！）
   - 条目父目录必须 `mkdir 0771` 并**复制原父目录的 owner/gid/mtime/ACL**，否则面板 list 报 `errno 4352`
   - xattr：`user.trim-trashbin-record` = 纯文本 `u:<uid>,t:<unix秒>`（**不是**二进制结构）
4. 面板 RPC（实测可用）：
   - `file.trash.list`：`{"path":"vol1/1000/.@#local/trash/1111"}` 或 `{"uid":1000}`（列回收站根）
   - `file.trash.restore`：`{"files":["vol1/1000/.@#local/trash/1111/x.txt"]}`
   - 两者**都会真的执行**，但服务端最终应答帧不会回来（客户端超时；详见 §6.5，原因未能确认）。

---

## 1. 现场：file.rm 为什么卡死

（本节 strace 由任务/Lead 在板上取得，2026-10-26；我按代码路径复核了它的来源）

```
trash     (moveToTrashbin=true) : unlinkat(-7126, "vol1/1000/1111/x.txt", 0)          = -1 EBADF
permanent (moveToTrashbin=false): unlinkat(-7125, "vol1/1000/1111/x.txt", 0)          = -1 EBADF
```

复核结果（`/usr/trim/bin/filemanager`，未 strip，`.symtab` 可用）：

```
_Z6rm_dirPKc            (rm_dir,      0x0aaf4)   ; 目录删除
_Z8files_rmRN6PPJson5ValueE.part.0 (files_rm, 0x1398c) ; 文件删除

0000abd8  add      x3, x21, #0x870        ; x3 = GOT 基址
0000abdc  mov      w4, #-0x1bd5           ; -7125
0000abe0  mov      x1, x25                ; path
0000abe4  mov      w2, #0                 ; flags(文件) / 0x200(目录, 见 0xa0f8)
0000abe8  ldrb     w0, [x3, #0x198]       ; w0 = g_move_to_trashbin (1 字节全局)
0000abec  sub      w0, w4, w0             ; dirfd = -7125 - g_move_to_trashbin
0000abf0  bl       unlinkat
```

`g_move_to_trashbin` 是 `.data` 里的 1 字节全局，vaddr **0x40a08**（`shndx=25`, `st_size=1`）。
`files_rm` 里是同一段模式（0x13a84–0x13a9c）。

因此：**-7126 / -7125 不是两个独立常量，而是同一个基址 `-7125` 加一个 0/1 布尔**。
这解释了为什么在 `filemanager` 整个 `.text` 里用立即数扫描只能找到 `-0x1bd5` 而找不到 `-0x1bd6`。

`rm_dir` 中同一处还有 `ldrb w0,[x3,#0x198]` → 目录删除也受同一开关控制；面板“永久删除”只是把这个全局置 0。
（`file.rm` 卡死发生在 `unlinkat` 返回 EBADF **之后**：`do_remove_with_progress()` 等的完成路径依赖厂商内核的回收站回调，stock 内核永远不会回。→ 我们只需在 shim 里把这次 `unlinkat` 变成用户态真动作并返回 0，就不再依赖它。）

---

## 2. 魔数 dirfd 表（完整）

### 2.1 `unlinkat` 族（本次新发现，回收站 ABI）

| dirfd | 十六进制 | 含义 | 证据 |
|---|---|---|---|
| **-7125** | `0xFFFFE42B` | 永久删除（unlink / rmdir） | `filemanager:rm_dir` 0x0abdc, `files_rm` 0x13a88；`trashbind:process_packet` 0x28e4（`AT_REMOVEDIR` 兜底） |
| **-7126** | `0xFFFFE42A` | 移入回收站 | 同一处 `sub w0, w4, w0`，`g_move_to_trashbin=1` 时；与 strace `unlinkat(-7126,...)` 吻合 |

编码：`dirfd = -7125 - (unsigned)g_move_to_trashbin`。`flags` 仍是标准 `unlinkat` 语义：
`0` = 文件，`0x200` (`AT_REMOVEDIR`) = 目录。

全量扫描结论（不是抽样）：
- `filemanager` 全 `.text`（0x6d00–0x2f7xx，约 13 万条指令）里，落在 `[-7300,-7000]` 或 `[0xe3c0,0xe500]` 的立即数**只有** `-0x1bd5`；不存在 -7124 / -7127 / 0xe42a 字面量。
- `filemanager.hdl`、`libnfile.so`、`libnperm.so`、`trashbind`：`-0x1bd5/-0x1bd6` 立即数**零命中**（`trashbind` 里 0x28e4 的 `mov w0,#-0x1bd5` 是唯一一处，我上面的扫描脚本按 PLT 上下文捕获到）。
- 全文件字节扫描 `2a e4 ff ff` / `2b e4 ff ff` 在 `filemanager` 只命中 0x1ebbf，属跨指令误命中（`2a0003e8` + `17ffffe4`），不是常量池。

### 2.2 已有的 `faccessat` 族（`trimcompat.c` 已实现，此处仅登记）

`-21586 .. -21576`（`0xFFFFABAE .. 0xFFFFABB8`）：`check_perm / trim_realpath / set_ext_access / get_ext_access / is_support / is_mountpoint / get_perm / trimacl_to_mode / may_delete / get_file_all`。
详见 `docs/reports/fnos-acl-compat-layer.md`；本次**没有**新增该族的成员。

### 2.3 其它 syscall 的魔数

`renameat2 / rename / mkdirat / openat` 上**没有**发现魔数 dirfd（`filemanager` 里 `renameat2` 全部用 `AT_FDCWD(-100)`）。
`trashbind` 本身也用 `AT_FDCWD`。→ 回收站只需要拦 `unlinkat`。

---

## 3. trashbind 逆向：目录布局、命名、记录

`/usr/trim/bin/trashbind` 未 strip；实际符号地址（任务书里的旧地址已过期，以此为准）：

```
get_trash_file_relative_path  0x2160    parse_trash_path        0x21b0
rename_self                   0x2340    set_trash_record        0x23f0
trashbin_make_parent_dir      0x2460    process_packet          0x26b0
get_path_storid_uid           0x2960    get_path_storid_teamdir 0x2af0
mkdirs_prevent_userdir_created 0x2c90   util::build_unused_filename 0x4270
```

### 3.1 路径模板（`.rodata`，`trashbind`）

| vaddr | 字符串 |
|---|---|
| 0x5708 | `vol%u/%u/.@#local/trash` |
| 0x5720 | `vol%u/%u` |
| 0x5730 | `vol%u/@team/%s/.@#local/trash` |
| 0x5750 | `vol%u/@team/%s` |
| 0x5760 | `u:%u,t:%lu` |
| 0x5770 | `user.trim-trashbin-record` |
| 0x5790 | `/` （`main` 开头 `chdir("/")`，所以所有路径都相对 `/`） |
| 0x5798 | `/dev/trim-trashbin` （`open(O_RDWR|O_CLOEXEC)`） |
| 0x58f0 / 0x58f8 | `%s_%llu` / `%s/%s_%llu.%s`（冲突改名格式） |

`parse_trash_path(path, buf_trashdir, buf_basedir, buf_rest, buf_target)`（0x21b0）逻辑：

1. `get_path_storid_uid(path,&storid)` 成功（普通用户空间）→
   `trashdir = "vol<storid>/<uid>/.@#local/trash"`，`basedir = "vol<storid>/<uid>"`，`skip = 2 + (path[0]=='/')`
2. 失败 → `get_path_storid_teamdir()` → team 模板，`skip = 3 + (path[0]=='/')`
3. 从 path 里跳过 `skip` 个 `/` 之后的剩余部分 = `rest`（例：`1111/x.txt`）
4. `target = trashdir + "/" + rest`

> 注意：**条目名不是 base64**，就是原相对路径；`rest` 保留子目录。我在板上用 5 个候选名做过对照实验（见 §5.5），base64/sha/下划线/百分号编码都会被面板当成“文件名原样显示”，只有镜像路径能被正确还原。

### 3.2 `process_packet(fd, req)`（0x26b0）——真正干活的地方

```
0x2794  mkdirs_prevent_userdir_created(trashdir, 0700, -1, -1)     ; trash 根, 0700
0x27c0  trashbin_make_parent_dir(trashdir, basedir, rest, req->uid) ; 建 trash 里的父目录
0x27e4  lstat(src)
        ├─ 非目录: build_unused_filename(target) → renameat2(-100, src, -100, target, RENAME_NOREPLACE)
        └─ 目录  : rename(src, target)  （失败 EXDEV/EEXIST 时 rename_self 重试；
                                        ENOTDIR 时 unlinkat(-7125, src, AT_REMOVEDIR) 兜底）
0x2868 / 0x2924  sprintf(buf,"u:%u,t:%lu", req->uid, time(NULL));
                 lsetxattr(target, "user.trim-trashbin-record", buf, len, 0)
0x272c  reply 12 字节: u64(serial=req+4) + s32(errno 取负)
```

`trashbin_make_parent_dir(a=trashdir, b=basedir, c=rest, d=uid)`（0x2460）：

```
x19 = a + "/" + <rest 的第一段>          ; 例: vol1/1000/.@#local/trash/1111
x22 = b + "/" + <rest 的第一段>          ; 例: vol1/1000/1111        (原父目录)
mkdir(x19, 0771)  -- EEXIST 且是目录则继续；否则 rename_self 后重建
如果 lstat(x22) 成功:  open(x19) → fchown(源 uid/gid) → futimens(源 atime/mtime) → close
                       trimacl_get_file(x22) → trimacl_set_file(x19)   ; 复制 fnOS ACL
否则:                  lsetxattr(x19, "user.trim-trashbin-record", "u:%u,t:%lu")
返回 0 / -1
```

→ **这就是面板能 list 出子目录条目的前提**：`trash/<子目录>` 的属主/时间/ACL 必须跟原目录一致。
实测证据见 §6 第 3 条：ACL 没复制时报 `errno 4352`，复制后立刻能列。

### 3.3 记录 xattr 的实际字节

`set_trash_record`（0x23f0）反汇编（关键 4 条）：

```
0x2414  bl time
0x242c  sprintf(buf, "u:%u,t:%lu", mode_arg /*w21*/, time(NULL))
0x2448  bl lsetxattr(path, "user.trim-trashbin-record", buf, <sprintf 返回值>, 0)
```

板上 hexdump（手工构造的条目，`t` 故意设成 1792900000 以便区分）：

```
entry : /vol1/1000/.@#local/trash/1111/hand-made.txt
name  : user.trim-trashbin-record
len   : 19
hex   : 75 3a 31 30 30 30 2c 74 3a 31 37 39 32 39 30 30 30 30 30
ascii : u:1000,t:1792900000
        ^ ^    ^ ^
        | |    | └─ 't' 值：unix 秒（strtoll）
        | |    └─── 分隔符 ','
        | └──────── 'u' 值：uid（strtol）
        └────────── key 单字符
```

解析侧确认：`filemanager:get_trashbin_fileinfo(path, unsigned *uid, long *mtime)` @0x94e0：

```
getxattr(path, "user.trim-trashbin-record", buf, 0x400)
if buf 非空: 循环 key = strchr(rest,':') 前的内容, val = strchr(rest,',') 前的内容
   key=="u" → strtol(val,10)  → *uid
   key=="t" → strtoll(val,10) → *mtime
```
（key 必须**恰好 1 字符** `u`/`t`；多余字段会被忽略，顺序任意。）
返回值：1 = 有记录，0 = 无记录/读取失败 → 面板就不填 `rmUid/rmTime`（实测见 §6 第 2 条的 `re-noattr.txt`）。

**记录里没有“原路径”字段**——原路径就是条目在 `trash/` 下的相对路径本身。这从根上决定了命名不能编码。

### 3.4 `/dev/trim-trashbin` 线格式（部分确认）

`trashbind main`（0x1d40）：`chdir("/")` → `open("/dev/trim-trashbin", O_RDWR|O_CLOEXEC)` → 256 KiB 读缓冲，循环按包解析。

| 偏移 | 类型 | 含义 | 证据 |
|---|---|---|---|
| +0x00 | u32 | 本包总长（含头），用于切包 | `ldr w3,[x21+w28]` @0x1e34 |
| +0x04 | u64 | serial/cookie，原样回写应答 | @0x1e58 `ldur x3,[x19,#4]`；0x272c 回写 |
| +0x0c | u32 | uid（= 记录里的 `u:`） | @0x27b0 `ldr w3,[x19,#0xc]` |
| +0x14 | u32 | 发起进程 pid（调试用，读 `/proc/%u/comm`） | @0x1e60 `ldr w3,[x19,#0x14]` |
| +0x34 | char[] | 路径（相对 `/`） | @0x26d8 `add x22,x1,#0x34` |

应答 12 字节：`u64 serial` + `s32 -errno`。
**未能确认**：+0x10、+0x18..+0x33 的字段含义（`-v` 调试格式串 `[%lu] serial:%lu, uid:%u, pid:%u[%s], %s` 只用到上面几个）。

> 这段对 shim 没用（stock 内核不会来包），但能解释 vendor 架构：**移动动作本来是内核把请求丢给 trashbind 用户态去做**，`unlinkat(-7126)` 只是触发器。我们在 shim 里直接做等价动作即可。

---

## 4. 面板侧：`file.trash.*` 的实现位置

- `filemanager.hdl` 只有 RPC 名清单（`file.trash.list/clear/restore` 字符串 @0x161c0..0x16308），无实现。
- 实现全在 `/usr/trim/bin/filemanager`（未 strip）：

```
req_trash_list            0x18634    req_trash_ls_userroot 0x18510
req_trash_restore         0x12e10    req_team_trash_restore 0x13450
req_trash_clear           0x143e0    req_team_trash_clear 0x14a00
do_trash_clear            0x0fce4    do_team_trash_clear   0x0fef0
get_trashbin_fileinfo     0x094e0    do_ls                 0x17810
```

- 路径模板（`filemanager` `.rodata`）：`vol%u/%u/.@#local/trash` @0x28210、`%s/.@#local/trash` @0x28598、
  `%s/%s/.@#local/trash` @0x28c48、`/.@#local/trash/` @0x28408。
- `req_trash_list` 的 JSON key 只有 **`path`**（@0x28018）；`uid` 由别处取（实测 `uid` 也生效）。
- 列出条目时走通用 `do_ls()`，每条再用 `get_trashbin_fileinfo()` 补 `rmUid`/`rmTime`；
  路径不属于 `.@#local/trash` 时不补（所以 `{"path":"vol1/1000"}` 只是普通 ls，见 §5.2）。

---

## 5. 实测：RPC 参数与返回（原文粘贴）

工具：`tools/fnos-api.py`（Windows 侧，`MSYS_NO_PATHCONV=1`），`--kind file`。

### 5.1 `file.trash.list`：三种可用形态

```jsonc
// A) uid → 列该用户回收站根（面板非管理员形态：B.file.trashList({uid:Number(t)})）
{"req":"file.trash.list","uid":1000}
// B) path 指向回收站内某目录（含子目录；注意 path 是相对路径）
{"req":"file.trash.list","path":"vol1/1000/.@#local/trash/1111"}
// C) path 指向回收站根
{"req":"file.trash.list","path":"vol1/1000/.@#local/trash"}
```

实测返回（B，手工构造条目）：

```json
{"files":[{"name":"hand-made.txt","uid":1000,"size":12,"mtim":1792955090,
           "btim":1792955090,"rmUid":1000,"rmTime":1792900000}],
 "uver":117503026135040,"reqid":"6ade52d76ade5052000000070001"}
```

字段：`name`=回收站内文件名（`oriName` 由前端直接取它）；`rmUid`/`rmTime` 来自 xattr；
`mtim/btim/size/uid/dir/v` 来自 `lstat`。**没有 oriPath 字段**——前端算的，见 §5.4。

### 5.2 无效形态（也贴出来，避免别人再试）

| 请求 | 结果 |
|---|---|
| `{"path":"vol1/1000"}` | `result:succ`，但内容是**普通 file.ls**（`/vol1/1000` 的内容），无 `rmUid` |
| `{"path":"vol1/1000/1111"}` | 同上，普通 ls |
| `{"path":"vol1/1000/.@#local/trash/1111"}`（ACL 未就绪时） | `{"errno":4352,"result":"fail"}` |
| `{"uid":1000,"path": ...非回收站路径}` | `path` 优先，uid 被忽略 |

`errno 4352` = `0x1100`，是 fnOS 自定义错误码（代码里 `mov w1,#0x1100` @0x18834），语义=权限/路径不合法。

### 5.3 `file.trash.restore`

面板 JS（`rules-DXQv1JLe.js`）构造：

```js
c = { overwrite: n, files: Jn(rows), details: {name,count,dir} };  if (admin) c.uid = Number(uid);
B.file.trashRestore(c)
```

实测可用最小形态（只给 `files`）：

```json
{"req":"file.trash.restore","files":["vol1/1000/.@#local/trash/1111/hand-made.txt"]}
```

效果（实测，板上文件系统验证）：

```
before: /vol1/1000/.@#local/trash/1111/hand-made.txt   (12 B, xattr u:1000,t:1792900000)
after : /vol1/1000/1111/hand-made.txt                 (12 B, 内容 "handcrafted")
```

> 应答帧**不会**回来（客户端 `TimeoutError`），但动作已完成。`file.rm` 的“卡死”与这里的“无应答但已生效”很可能是同一类问题：handler 走完文件操作后等一个不会来的完成事件。见 §6.5。

### 5.4 前端如何拼 path / oriPath（`storageListStore-DYrLjXgi.js` 原文）

```js
Ie=(e,t,n)=>{ n&&Number(n)&&(n=`vol${e.v}/${Number(n)}/.@#local/trash`),
  n = e.path ? `${e.path}/${e.name}` : n ? `${n}/${e.name}`
            : `vol${e.v}/${e.uid}/.@#local/trash/${e.name}`;
  let r = n?.replace(/\/\.@#local\/trash\//,`/`)||``;
  return {...e, oriName:e.name, oriPath:r, rmTime:e.rmTime||e.btim, name:e.name,
          path:n, type:Ce(e), ...} }
```

→ 条目名被原样使用，`oriPath` 只是把 `/.@#local/trash/` 换回 `/`。
这**反证**了镜像路径布局：`trash/1111/hand-made.txt` → `oriPath = vol1/1000/1111/hand-made.txt`。
如果名字用 base64/百分号编码，`oriName`/`oriPath` 都会是垃圾。

### 5.5 命名候选对照实验（证明必须是镜像路径）

在 `trash/` 根下同时放 5 个候选（Lead 并发实验留下的那批，我复用了观测），`{"uid":1000}` 列出的
`name` 全部是**文件名原样**，`oriPath` 会变成 `vol1/1000/<那个名字>`：

```
MTExMS9ybXRlc3QxLnR4dA==      (base64("1111/rmtest1.txt"))
MTExMS9ybXRlc3QxLnR4dA        (base64 无 padding)
313131312f726d74657374312e747874 (hex)
1111_rmtest1.txt
1111%2Frmtest1.txt
```
只有 §5.1/§5.3 的镜像路径 `trash/1111/<name>` 能还原到原位置（已实测）。

---

## 6. 实测记录（按时间，含失败与修正）

1. **02:53 首次 `{"uid":1000}`** 就成功列出了 `trash/` 根下条目，并带出 `rmUid/rmTime` → 格式假设成立。
2. **02:55 手工造条目** `trash/re-flatA.txt`（xattr `u:1000,t:1792953927`）、`trash/re-noattr.txt`（无 xattr）、
   `trash/1111/re-nested.txt`（xattr `u:1000,t:1792954227`）：
   - 根列表：`re-flatA.txt` 带 `rmUid:1000, rmTime:1792953927` ✔；`re-noattr.txt` **无** rmUid/rmTime ✔；
     嵌套的 `re-nested.txt` **不出现**（只出现目录项 `{"name":"1111","dir":1}`）。
3. **03:02 关键修正**：嵌套目录列不出来不是格式问题，是权限问题。`trash/1111` 当时是 `0751 root:root`、无 ACL；
   把原目录 `/vol1/1000/1111` 的 owner/gid(`1000:1001`)+ACL 复制过去后立刻成功：

```json
{"files":[{"name":"re-nested.txt","uid":0,"size":22,"mtim":1792954527,
           "btim":1792954527,"rmUid":1000,"rmTime":1792954227}], ...}
```

   → 与 `trashbin_make_parent_dir` 的 fchown/futimens/trimacl_set_file 行为一致。
   这也是 `trimcompat_trash_move()` 里必须复制 ACL 的原因。
4. **03:02 还原验证**：`file.trash.restore` 把 `trash/1111/re-nested.txt` 还原成 `/vol1/1000/1111/re-nested.txt`（22 B）✔
5. **03:03 `trash-ref.c` 自测**（见 §7）+ 面板 RPC 交叉验证 ✔
6. **03:04 最终闭环**（手工条目，最干净的一组证据，见 §5.1/§5.3）✔
7. **失败项**：`file.trash.clear`（`{"files":[...],"details":{...}}`）45 s 内既无应答也无删除效果；
   `file.trash.restore` 的应答帧始终不回（客户端超时），但文件动作 100% 生效。→ §6.5 未确认。

### 6.5 关于 restore/clear 的“无应答”

- `file.trash.restore`：**动作已执行**（文件确实回到原位），但 WebSocket 上没有 `result:succ` 终帧；
  服务端在 20–150 s 内一帧都不发。用长超时（150 s）的副本复现为 `websocket closed`。
- `file.trash.clear`：连文件系统效果都没观察到。
- trim 进程（pid 16231）在 restore 期间**没有**卡在文件 syscall 上（`/proc/<pid>/task/*/wchan` 全是
  `epoll/nanosleep/futex`），抖动后也没有重启、日志无错误。
- → **未能确认**根因。可能与 `file.rm` 同一类（等厂商内核/trashbind 的完成事件）。
  对本次交付不影响：restore 已把文件放回正确位置，说明“镜像路径 + xattr”就是它读的全部信息。

---

## 7. `trash-ref.c`（交付物）API 与自测

### 7.1 API

```c
int trimcompat_trash_move(const char *path, uid_t uid, int flags);
```

- `path`：待删路径，可带/不带前导 `/`（trim cwd 是 `/`，strace 里是相对形式）
- `uid`：写进 `u:` 的值（删除者 uid）；传 `(uid_t)-1` 则退化为文件 `st_uid`
- `flags`：`unlinkat` 第三参数（`0` / `AT_REMOVEDIR`），当前仅保留语义，动作对文件/目录相同
- 返回：`0` 成功；`<0` = `-errno`（调用方填 `errno`）
- 依赖：仅 libc。xattr 走 `syscall(SYS_getxattr/SYS_setxattr)`，**故意绕开** shim 自己的
  `getxattr/setxattr` 拦截，避免递归与名字重映射互相干扰
- 复杂度：`-O2` 编译 0 warning（只有 `snprintf` 截断 class 的 `-Wextra` 提示，可忽略）

行为（与厂商逐步对应）：`tc_parse()` → `mkdir(trash根,0700)` → `mkdir(条目父目录,0771)`
+ `chown` + `utimensat` + 复制 `system.posix_acl_access/default`、`user.trim_acl`
→ `rename()`（EEXIST/ENOTEMPTY 时用厂商同款 `<主名>_<u64>.<扩展名>` 重试）
→ `setxattr("user.trim-trashbin-record","u:%u,t:%lu")`。
若 xattr 写失败只告警不回滚（文件已在回收站里，宁缺记录不丢文件）。

### 7.2 板端编译 + 运行（实测）

```bash
# 板端
gcc -D_GNU_SOURCE -DTRASH_REF_TEST -O2 -Wall -o /tmp/trashref /tmp/trash-ref.c   # BUILD_OK
echo "refmove-payload" > /vol1/1000/1111/refmove.txt
chown 1000:1001 /vol1/1000/1111/refmove.txt
/tmp/trashref vol1/1000/1111/refmove.txt 1000
# OK moved vol1/1000/1111/refmove.txt   (rc=0)

# 结果
/vol1/1000/.@#local/trash/1111/refmove.txt    16 B, 1000:1001, 0644
xattr user.trim-trashbin-record = b'u:1000,t:1792955017'
trash/1111: 0775(由 ACL mask 决定) 1000:1001
```

### 7.3 面板 RPC 交叉验证（证明我的 C 输出被 fnOS 原生识别）

```jsonc
{"req":"file.trash.list","path":"vol1/1000/.@#local/trash/1111"}
→ {"files":[{"name":"refmove.txt","uid":1000,"size":16,"mtim":1792955017,
             "btim":1792955017,"rmUid":1000,"rmTime":1792955017}], ... succ}

{"req":"file.trash.restore","files":["vol1/1000/.@#local/trash/1111/refmove.txt"]}
→ (无终帧，客户端超时) 但板上: /vol1/1000/1111/refmove.txt 16 B 回来了 ✔
```

### 7.4 接进 `trimcompat.c` 的建议

```c
#include "trash-ref.c"          /* 或直接把内容并进 trimcompat.c */

int unlinkat(int dirfd, const char *path, int flags)
{
    static int (*real)(int, const char *, int);
    if (!real) real = (void *)next_sym("unlinkat");

    if (dirfd == -7125)                       /* 永久删除 */
        return real(AT_FDCWD, path, flags);
    if (dirfd == -7126) {                     /* 入回收站 */
        int r = trimcompat_trash_move(path, (uid_t)-1, flags);
        if (r == 0) return 0;
        errno = -r;
        return -1;
    }
    return real(dirfd, path, flags);
}
```

注意事项：
- **必须同时实现 `-7125` 的转发**，否则“永久删除”也会 EBADF；
- `uid` 若能从 RPC 上下文拿到（面板会话 uid）就传真实值，否则 `-1` 退化用 `st_uid`；
  实测面板只把 `rmUid` 当“删除者”展示，不影响 list/restore；
- 目录删除的 `flags` 带 `AT_REMOVEDIR`，`rename()` 对目录同样有效，不用特殊处理；
- `trash-ref.c` 里 `fprintf(stderr,...)` 只在 xattr 失败时触发，可保留；
- 若在 `fork()` 子进程里 rename 跨设备返回 `EXDEV`，当前实现**不**做 copy 兜底（同卷场景不会遇到）。

---

## 8. 未能确认 / 风险清单

1. **restore/clear RPC 为什么不发终帧**（restore 动作生效、clear 无效果）。根因未定位，可能与
   `file.rm` 同一类“等厂商内核完成事件”。→ 不影响本次格式结论，但影响面板体验（前端会一直转圈）。
2. `file.trash.clear` 的正确参数组合没试出来（试过 `{"files":[...],"details":{...}}`）。
3. `/dev/trim-trashbin` 包结构 +0x10、+0x18..+0x33 字段未知；`-v` 调试串只覆盖 serial/uid/pid/path。
4. `trashbind` 用 `get_path_storid_uid()`（读 DB/挂载缓存）算 `storid`；`trimcompat_trash_move()`
   直接取路径第一段字面量（`vol<N>`）。若某天出现 `vol<N>` 与 storid 不一致的命名，这里会有偏差。
5. ACL 复制到底哪一项在起作用（`system.posix_acl_access` 还是 fnOS 私有 `user.trim_acl`）未分离验证：
   我是 owner+POSIX ACL 一起复制的（`trimcompat_trash_move` 两者都复制），实测生效。
6. `filemanager.hdl` 之外 **其它 handler（storage.hdl 含 `trim-trashbin` 字符串）没有逐一反汇编**；
   `-7125/-7126` 的立即数扫描只覆盖了 `filemanager / filemanager.hdl / libnfile / libnperm / trashbind`。
   （`objdump` 全量扫 `/usr/trim/bin/*` 太慢，跑超时被中止，已 `pkill`。）
7. 面板 UI 端到端（点删除→回收站出现→点还原）没做浏览器验证，只做了 RPC 级验证。
8. `file.trash.list` 根列表**不递归**：只显示 `trash/` 直接子项（子目录显示为 `dir:1`，需再按子目录 path 查）。
   前端是否会自动下钻/是否只显示一层，未确认。

---

## 9. 板端状态变更（可追溯）

- 新建后清理：`/vol1/1000/.@#local/`（trash 根）、`/vol1/1000/.@#local/trash/1111/`。
  **`.@#local` 与 `.@#local/trash` 目录保留**（vendor 也会按需建，属正常状态，当前 root:root 0755/0700）。
- 测试文件全部删除：`/vol1/1000/1111/{refmove,re-nested,hand-made}.txt`、`trash/{re-flatA,re-noattr}.txt`、
  `trash/1111/`（已空则删）。
- **残留**：`trash/` 根下 5 个 Lead 并发实验的候选文件（`MTExMS9ybXRlc3QxLnR4dA==` 等），未动，留给 Lead 处置。
- 未重启任何 trim 服务（仅临时 `strace -p 16231`，已结束）。`/tmp` 临时文件已清。

---

## 10. Lead 补充：端到端验证 + 集成结论（2026-10-26 03:2x）

本节是任务完成后由 Lead 在板上做的最终验证，用来回答 §8 里遗留的问题：

1. **`restore`/`clear` 没有“终态帧”的根因已确认**：fnOS 把**异步任务类 RPC** 的
   `taskInfo` / `taskId` / 最终 `result` 推送到**登录时那条 `type=main` WebSocket**，
   而不是发起请求的 `type=file` socket。浏览器两条 socket 都常开，所以没问题；
   脚本如果像最常见的那样“登录后关掉 main ws、只留 file ws”就会误判为超时。
   保留 main ws 后实测 `file.rm` / `file.trash.restore` 都能收到
   `{"result":"succ","reqid":...}`。复现工具：`tools/fnos-rpc-probe.py`。
2. **集成方式**：`trash-ref.c` 与 `trimcompat.c` 一起编译成 `libtrimcompat.so`
   （`-Wl,--no-undefined`），由 `trimcompat.c` 的 `unlinkat()` 拦截器分发：
   `-7126 → trimcompat_trash_move()`、`-7125 → trimcompat_rm_force()`（本次新增，
   文件 unlink / 目录递归删除）。注意：`file.rm` 由 `trim` **fork/exec 出来的
   `/usr/trim/bin/filemanager` 子进程**执行，LD_PRELOAD 会正常继承（实测子进程
   加载了兼容层）；早期曾因只编译 `trash-ref.c` 漏了 `trimcompat_rm_force` 导致
   子进程 `symbol lookup error` 退出 127 —— 现在用 `--no-undefined` + 安装时
   `LD_PRELOAD ... /bin/true` 自检兜底。
3. **目录删除的落盘形态**：filemanager 删目录时会“先逐个 trash 子项，再 trash 目录本身”，
   直接 rename 会撞上已经建好的同名父目录。兼容层做了合并（把剩余内容并进该目录、
   删掉空壳），因此回收站里是**一条目录条目**、内容仍在里面（实测 `dirdel/`
   含 `c1.txt`、`c2.txt` 一条记录）。
4. **端到端实测**（`tools/fnos-rpc-probe.py`，等价于面板操作）：
   - `file.rm` 文件/目录 + `moveToTrashbin=true` → main ws 收到 `succ`，条目出现在
     `/vol1/1000/.@#local/trash/1111/`，xattr `user.trim-trashbin-record="u:1000,t:..."`；
   - `file.trash.list`（`path=trash/...` 或 `uid=1000`）→ 返回 `rmUid/rmTime`；
   - `file.trash.restore` → `succ`，文件/目录（含内容）回到原路径；
   - `moveToTrashbin=false` → `succ`，文件/目录被递归彻底删除。
5. **`trim_trashbind` 不再需要**：安装脚本会 `systemctl disable --now trim_trashbind`
   （它依赖的 `/dev/trim-trashbin` 是厂商内核字符设备），回收站功能完全由兼容层接管；
   `install.sh --uninstall` 会重新 enable。
