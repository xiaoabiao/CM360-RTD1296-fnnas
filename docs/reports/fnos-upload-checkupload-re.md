# fnOS 面板上传 RE：check_upload / uploadsrv 写路径 / 客户端 errno 映射

- 板卡：CM360 / RTD1296，内核 `Linux 6.6.54-gbe79582cba58-dirty #38`（自编译，无 fnOS 私有 VFS/ACL）
- 对象：fnOS 1.2.0302 用户态 — `/usr/trim/bin/handlers/filemanager.hdl`、`/usr/trim/bin/uploadsrv`、`libnperm/libnfile/libquota`、`/usr/trim/www/assets/*.js`
- 前提：权限判定已由用户态兼容层（LD_PRELOAD 拦截魔数 `faccessat` + `system.trim_acl`→`user.trim_acl`）补齐并端到端验证通过；本文只回答“兼容层之后还剩哪些风险”。
- 证据形式：`nm`/`objdump -d -C` 地址 + 行号 + 板上 ctypes 实测；推测处标注【推测】。

## 1. `filemanager.hdl` 的 `check_upload`：检查顺序与错误码

符号：`check_upload` 0x100c0、`req_check_upload` 0x10610（返回异步标记 0x71257125）、`ioreq_handler_checkupload` 0x10e80（真正干活）、`trimsrv_check_upload` 0x120b0。
错误一律写进响应 JSON 的 `"errno"` 字段（0x15c20）并把 `result` 置 `"fail"`；同步段返回 -1。

### 1.1 同步段（0x100c0，排队前）

| # | 检查 | 实现 | 失败码 | 兼容层后风险 |
|---|---|---|---|---|
| 1 | JSON 必须有 `path` | `PPJson::Value::operator[]` | 返回 -1，**不写 errno** | 无（框架保证） |
| 2 | session uid | 全局函数指针（0x30790）；`req_check_upload` 由框架注入 | 0x21000（135168 无效的凭证） | 无 |
| 3 | token 必须 44 字符 base64→32B | `decode_base64` 0x14a70 | 返回 -1，**不写 errno** | 无 |
| 4 | token 校验/换 uid | 函数指针（0x30808），uid==-1 | 0x21000 | 无 |
| 5 | `is_vol_path()` | libnfile 0x3480：纯字符串校验（`/vol<数字>`、拒绝 `/../`、拒绝以 `/..` 结尾） | 0x1005（4101 无效的文件名或路径） | 无（不碰内核） |
| 6 | `is_vol_path_writeable()` | libnfile 0x3550 = **空桩**：`mov w0,#1; ret`（永远可写） | 0xFF00（65280） | 无（此版本永不失败） |
| 7 | malloc/strdup | — | 0x1002（4098 内存不足） | 无 |
| 8 | 投递 ioqueue | 全局函数指针，参数 `(flag, ioreq_handler_checkupload, req)` | 投递错误码映射：1→0xFF01、2→0x1004、5→0x1020、12→0x1002、13→0x1100、17→0x1006、21→0x1009、28→0x1003、30→0x1019、36→0x1008、95→0xFF00、122→0x1122，其它原值 | 无 |

### 1.2 异步段 `ioreq_handler_checkupload`（0x10e80）— 上传失败的真正位置

按执行顺序：

1. `size < 0`（`tbnz x23,#63` @0x10ee0）→ `result=fail`，**不写 errno**（客户端走通用文案）。
2. `mkdirs_exclude_uiddir_and_access(parent, 0711, uid, 0)` @0x10f0c（libnfile 0x3800）：
   - `/vol…` 路径只做 `access()`+`stat()`（实测返回 1，成功），不走私有 ABI；
   - 非 `/vol` 路径才调用 `trim_access(...,8,...)`（魔数 0xFFFFABAE）→ 兼容层覆盖；
   - 失败时读 `errno` 按下表映射。
3. **`trim_access(uid, parentDir, mode=2(W),0,0)` @0x10f2c** → libnperm `trim_access` 0x2c50 → `faccessat(0xFFFFABAE, &ctx{path,flags,uid,ngids,gids}, mode, flags)`。
   - 失败分支 @0x10f30 → 0x11098：读 `errno`，映射表见下；**EBADF(9) 不在映射表，被原样写入 JSON** → `{"errno":9,"result":"fail"}`。**这正是 Lead 实测到的 broken-kernel 返回值 9。**
   - 板上 ctypes 实测（不加载兼容层的进程）：`trim_access(1000, "/vol1/1000/1111", 2,0,0) -> -1 errno=9 (EBADF)`。
4. 文件名长度：`strlen(name) > 0xfb(251)` @0x111b4 → 0x1008（4104 文件名或文件路径长度超过限制）。
5. 目标已存在且 `overwrite==0` @0x111bc → 成功返回 `{"skip":1}`；目标是目录（`S_ISDIR`）@0x112bc → 0x1009（4105 目的路径是目录）。
6. **空间/配额 `is_not_enough_space(size, old, path)` @0xfd40**：
   - `/vol<id>/<uid>/…` → 拼 `"/vol%u/%u"`，`trim_get_quota(path, uid, out1, out2)` @0xfeb0（libquota 0x4d04 → btrfs qgroup ioctl）：limit>0 且 `limit-used < new-old` → **0x1122（4386 可用容量不足）**；
   - 否则逐级 `statfs64()`：可用空间不足 → 0x1003（4099 磁盘空间不足）；
   - `@team` 路径才用 `trim_project_id_get`（当前 EINVAL → 回退到 statfs，不阻塞）。
7. 占位文件：`build_unused_filename` + `"%s.~#%llu"` 循环 `open(O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0666)` @0x11244；EEXIST 重试，其它 errno → 0x1008；成功 `fchown(uid,-1)`、flock、返回 `{"result":"succ", ...}`。

**errno→协议码映射（0x110a0–0x1119c）**：1→0xFF01，2→0x1004，5→0x1020，12→0x1002，13→0x1100(4352)，17→0x1006，21→0x1009，28→0x1003，30→0x1019，36→0x1008，95→0xFF00，122→0x1122，**其它原样透传（含 9/EBADF、13 之外的值）**。

> 兼容层覆盖情况：ABE/ABB7 等“结构体指针”命令原生必然 EBADF（内核把它们当相对路径名处理，负 dirfd 被使用）；兼容层已拦下。`is_support_trimacl`(ABB2)/`is_mountpoint`(ABB3)/`trim_realpath`(ABAF) 在原生内核上会“假成功”（首参是绝对路径字符串时内核忽略 dirfd 直接按当前进程权限判定），这是为何部分 ACL 调用看似可用。

## 2. `uploadsrv` 写路径：兼容层之后仍可能失败的检查

`begin_upload` 0x37dd0，`do_upload_failed` 0x36cc0，`post_aio_write` 0x37414；导入 `trim_access`、`mkdirs_exclude_uiddir_and_access`、`trimacl_get_file/set_file`、`tokensrv_query1/connect`、`is_vol_path_writeable`。**未导入 `trim_get_quota` / `statfs/statvfs` / `quotactl`，即没有预检配额或剩余空间。**

顺序与 HTTP status（`send_http_status` @0xd9b0；字符串 vaddr 0x3f090/0x3f0d8/0x3f3e0/0x3f430/0x3f480/0x3f4c8）：

1. `Trim-Path` 解析（iconv UTF-8）失败/path 为空 → **400**。
2. `Trim-Token` 必须 base64→32B（0x37f6c）→ 否则 **403**；`tokensrv_query1` 失败/uid==-1 → **403**（token 服务不可达分支 → **599**）。
3. `is_vol_path` 失败、`is_on_root_partition` 为真、`is_vol_path_writeable` 失败（会先 `errno=0xFF00`）→ **497**。
4. 路径非 `/vol<id>/<uid>` 规范形态时仅跳过归属校验，不报错。
5. `access()` + `mkdirs(parent,0711,uid,0)`；mkdirs 失败按 errno：**122 EDQUOT→596**、**28 ENOSPC→597**、13/1→403、36 ENAMETOOLONG→**499**、其它→**598**。
6. **`trim_access(uid, parentDir, 2(W),0,0)`** @0x38500 → 失败统一 **403**（不看 errno）。
7. 路径长度 >4095 或 open 临时名超长 → **499**。
8. `open(O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0666)`（`"%s.~#%llu"` 重试）；EEXIST 重试，其它 errno 同上按 596/597/403/499/598 映射。
9. `trimacl_get_file` + `get_entry_count`（仅新文件的 ACL 继承）：返回 NULL/0 时**静默跳过**，不判失败。
10. 实际写 `aio_thread`：ENOSPC→**597**、EDQUOT→**596**、EACCES→**403**、其它→**598**；成功 **200**。

结论：兼容层之后 uploadsrv 不会因“权限/配额预检”失败；**596/597 只可能来自内核在 open/write/mkdir 时真的返回 EDQUOT/ENOSPC**（btrfs 配额用尽或磁盘满）。当前 `/vol1` 配额实测 `trim_get_quota` 返回 limit=-1（不限），不会触发。

## 3. 客户端 `Qr(errno)` 映射

`Qr` = index bundle 导出的 `AK`：`AK(errno,t,默认="Request failed, please try again later")`；内部先用 `OK`（errno→E_* 名称）查表，命中 → `t("error.E_*")`，未命中 → `t("error.default")`，errno 为 undefined → 直接返回英文默认串。

- **errno=9（EBADF）不在 `OK` 表中**（枚举值只有 4096/4097/…/4352 等；实测 9/13/28/122 均不存在）→ 落到 `error.default`，zh-CN 文案为 **“失败出错”**（`locales/zh-CN/os.json:785`）。即：**9 没有专门 toast，不会显示“权限不足”**。
- 有专门文案的例子：4352→权限不足、4099→存储空间不足、4386→可用容量不足、4104→文件名或文件路径长度超过限制、4105→目的路径是目录、4100→文件或目录不存在、4101→无效的文件名或路径、0xFF00→无效的操作、0xFF01→无权限操作、4098→内存不足、4128→I/O错误。
- 字面量 `file.upload.failed`（“上传失败”）只出现在 XHR 失败分支与 `Qr(...)||errmsg||...` 的最后兜底；**checkUpload 返回 errno=9 时不会走到它（显示“失败出错”）**。因此“权限失败→权限不足、ABI 失败→通用错误”可区分，Lead 实测 before=9 / after=succ 与此一致。

## 4. 残余风险 / 还需在板子上验证什么

1. **用户配额真正生效时**：`trim_get_quota` 走标准 btrfs qgroup ioctl，本板返回 0/limit=-1；需在设置 quota 后验证 is_not_enough_space 能返回 4386（客户端“可用容量不足”），以及写时 EDQUOT 是否映射成 HTTP 596。
2. **team 空间配额**：`trim_project_id_get("/vol1/1000/1111")` 本板实测 `-1 errno=22(EINVAL)`，只会让 `@team` 配额路径回退到 statfs ⇒ team 配额可能被静默绕过（是“少拦”，不是上传失败）。
3. **磁盘真满**：uploadsrv 无预检，唯一路径是内核 ENOSPC→597（客户端“存储空间不足”）；需近乎写满 btrfs 实测一次 596/597 的真实性。
4. **token 服务**：uploadsrv 用 `tokensrv_connect/query1`；不可达→599（客户端 tokenServerError 文案）。当前 `/run/trim_token_counter` 存在且 POST /upload 已 200，但 599 文案与 locale key 未在板上逐字核对（**未能确认**具体中文）。
5. 客户端 switch 里 498/500 两个 status 在当前 uploadsrv 中**无对应字符串**（uploadsrv 只产出 400/403/497/499/596/597/598/599/200），应为历史/他路径。
6. 文件名/路径规则（251B、255B、4096）与 6.6 内核无关，但建议用 251/252 字节文件名与 4095/4096 路径各测一次，确认 4104/499 的客户端文案。

## 5. 关键命令（均为只读；板端临时文件在 /tmp）

```
python tools/brd.py sudo 'nm -n -C /usr/trim/bin/handlers/filemanager.hdl'          # 0x100c0/0x10610/0x10e80/0x120b0
python tools/brd.py sudo 'objdump -d -C --start-address=0x100c0 --stop-address=0x10610 /usr/trim/bin/handlers/filemanager.hdl'
python tools/brd.py sudo 'objdump -d -C --start-address=0x10e80 --stop-address=0x11680 /usr/trim/bin/handlers/filemanager.hdl'
python tools/brd.py sudo 'objdump -d -C --start-address=0xfd40 --stop-address=0x100c0 /usr/trim/bin/handlers/filemanager.hdl'  # is_not_enough_space
python tools/brd.py sudo 'nm -D /usr/trim/lib/libnfile.so; objdump -d -C --start-address=0x3480 --stop-address=0x3a60 /usr/trim/lib/libnfile.so'
python tools/brd.py sudo 'objdump -d -C --start-address=0x2c50 --stop-address=0x2d90 /usr/trim/lib/libnperm.so'   # trim_access -> faccessat(0xFFFFABAE)
python tools/brd.py sudo 'objdump -d -C --start-address=0x4d04 --stop-address=0x4fb0 /usr/trim/lib/libquota.so.0.2' # trim_get_quota / trim_project_id_get
python tools/brd.py sudo 'nm -D /usr/trim/bin/uploadsrv; objdump -d -C /usr/trim/bin/uploadsrv > /tmp/upl.asm'
python tools/brd.py sudo 'python3 /tmp/abi_probe.py'    # ctypes: trim_access -> ret=-1 errno=9; trim_get_quota ret=0 limit=-1; trim_project_id_get EINVAL; mkdirs -> 1
python tools/brd.py sudo 'grep -oE "AK=\\(e,t,n=kK\\)..." /usr/trim/www/assets/index-gFv2FLwJ.js; grep -n "失败出错" /usr/trim/www/locales/zh-CN/os.json'
python tools/brd.py sudo 'tail /tmp/trimcompat.log; grep "/upload" /usr/trim/nginx/logs/access.log | tail'
```

板上旁证（本次会话观察，非本任务写入）：`/tmp/trimcompat.log` 曾记录 4 条 `check_perm(/vol1/1000/1111,uid=1000,...) ret=0`（兼容层生效）；`/usr/trim/nginx/logs/access.log` 见 `POST /upload` 先 497、后多次 **200**（02:01/02:04，UA `fnos-api.py`）。该 log 后被其它会话清理，故只作旁证。
