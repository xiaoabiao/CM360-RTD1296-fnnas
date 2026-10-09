# fnOS 用户态如何使用私有 `trimafs` 与私有 ACL（FilesACL / TrimACL）

- 分析对象：fnOS ARM64 官方镜像（`fnnas-official-arm64-image_rockchip_1253.img.xz`）解包后的 rootfs
- rootfs 根：`/home/xiaoabiao/.cache/fnnas/rootfs/`
- 内核版本：`6.18.18-trim`（`usr/lib/modules/6.18.18-trim/`）
- 分析方式：`strings` / `readelf` / `nm` / `aarch64-linux-gnu-objdump -d` / Python 字节级扫描
- 本报告所有结论均给出**命令 + 原始输出片段**；推测一律标注为 **【推测】** 并给理由

---

## 0. 摘要：两条硬结论

### 结论 A — trimafs 的挂载调用形态

`triminit` 里的 `mount_trimafs()`（符号 `_Z13mount_trimafsv`，地址 `0xd2a0`）**不直接调用 `mount(2)`**。
它通过 `system(3)` 执行一条 shell 命令：

```
mount -t trimafs trimafs /fs
```

| 项 | 值 | 证据 |
|---|---|---|
| source | `"trimafs"` | rodata `0x39dc8` |
| target | `"/fs"` | rodata `0x39db8` |
| fstype | `"trimafs"` | rodata `0x39dc8` |
| **`data`（mount options）** | **空 —— 完全没有 `-o` 参数** | 见 §1.3 |
| flags（`MS_*`） | `0`（未传 flags，走 shell 默认） | 见 §1.3 |

原始字节（`triminit` 文件偏移 `0x39dc8`，`.rodata` 的 vaddr == file offset）：

```
hex:   6d 6f 75 6e 74 20 2d 74 20 74 72 69 6d 61 66 73 20 74 72 69 6d 61 66 73 20 2f 66 73 00
ascii: m  o  u  n  t     -  t     t  r  i  m  a  f  s     t  r  i  m  a  f  s     /  f  s  \0
```

**逐字符拆解 mount options：空字符串。既没有 `-o`，也没有任何逗号分隔项。**

挂载点准备流程：`/fs` 若已存在则 `chattr -i /fs` → `remove("/fs")` → `mkdir("/fs", 0)` → `chmod("/fs", 0)` → `chattr +i /fs` → 再 `mount -t trimafs trimafs /fs`。

### 结论 B — ACL v2（FilesACL / TrimACL）的 xattr 命名约定

**命名空间是 `system.`，不是 `trusted.`，也不是 `user.`。**

```
xattr 名 = system.trim_acl
```

- 定义处：`usr/trim/lib/libtrimacl.so`，`.rodata` vaddr `0x3310`
- 全部读写路径：`getxattr` / `fgetxattr` / `lgetxattr` 与 `setxattr` / `fsetxattr` / `lsetxattr`，以及 `removexattr` / `fremovexattr` / `lremovexattr`
- **`libtrimacl.so` 完全没有 `ioctl` 调用**（`.dynsym` 无 `ioctl`），ACL 纯 xattr 实现

**重要更正**：`trimacl -x2` 里的 `2` 是「删除下标为 2 的 ACE」，**不是 ACL 版本号**（见 §5.7）。xattr 二进制头部的格式版本号是 **`1`**（见 §5.5）。

---

## 1. `triminit` 的 trimafs 挂载：精确形态

### 1.1 符号与二进制基本信息

```
$ cd /home/xiaoabiao/.cache/fnnas/rootfs/usr/trim/bin/
$ file triminit
triminit: ELF 64-bit LSB pie executable, ARM aarch64, ... not stripped

$ nm triminit | grep -iE "mount|trimafs"
000000000000ee00 T _Z13mount_storageb
000000000000d2a0 T _Z13mount_trimafsv      <-- mount_trimafs()
000000000000c8e0 T _Z17is_volume_mountedPKcPc
000000000000caf0 T _Z21del_volume_mountpointv
000000000000c9d4 T _Z24del_removable_mountpointv
000000000000cc60 T _Z26fix_volume_mountpoint_permv
000000000000c7b0 T _Z6_mountPKcS0_
```

`triminit` **未 strip**（有 `.symtab`，2301 个符号），所以可以直接用函数名定位。

```
$ readelf -S -W triminit | grep symtab
  [29] .symtab           SYMTAB          0000000000000000  00050858
```

### 1.2 `mount_trimafs()` 完整反汇编

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0xd2a0 --stop-address=0xd3b0 triminit

000000000000d2a0 <mount_trimafs()>:
    d2a0: a9bc7bfd  stp  x29, x30, [sp, #-64]!
    d2a4: d2800001  mov  x1, #0x0                    // #0
    d2a8: 910003fd  mov  x29, sp
    d2ac: a90153f3  stp  x19, x20, [sp, #16]
    d2b0: 90000173  adrp x19, 39000
    d2b4: 9136e274  add  x20, x19, #0xdb8            ; x20 = 0x39db8 = "/fs"
    d2b8: aa1403e0  mov  x0, x20
    d2bc: 97fffd89  bl   c8e0 <is_volume_mounted(char const*, char*)>
    d2c0: 72001c1f  tst  w0, #0xff
    d2c4: 54000080  b.eq d2d4 <mount_trimafs()+0x34>  // 已挂载则直接返回
    d2c8: a94153f3  ldp  x19, x20, [sp, #16]
    d2cc: a8c47bfd  ldp  x29, x30, [sp], #64
    d2d0: d65f03c0  ret
    d2d4: aa1403e0  mov  x0, x20                    ; x0 = "/fs"
    d2d8: 52800001  mov  w1, #0x0                    ; F_OK
    d2dc: 97fff6bd  bl   add0 <access@plt>           ; access("/fs", F_OK)
    d2e0: 35000180  cbnz w0, d310                    ; 不存在 -> 跳到 mkdir
    d2e4: 910083e1  add  x1, sp, #0x20
    d2e8: 90000160  adrp x0, 39000
    d2ec: 90000162  adrp x2, 39000
    d2f0: 91242000  add  x0, x0, #0x908              ; x0 = 0x39908 = "chattr"
    d2f4: 91244042  add  x2, x2, #0x910              ; x2 = 0x39910 = "-i"
    d2f8: f90013e0  str  x0, [sp, #32]               ; argv[0] = "chattr"
    d2fc: a900d022  stp  x2, x20, [x1, #8]           ; argv[1] = "-i", argv[2] = "/fs"
    d300: f9000c3f  str  xzr, [x1, #24]              ; argv[3] = NULL
    d304: 9400ad40  bl   38804 <util::fork_execvp(char const*, char**)>
    d308: aa1403e0  mov  x0, x20
    d30c: 97fff76d  bl   b0c0 <remove@plt>           ; remove("/fs")
    d310: 9136e274  add  x20, x19, #0xdb8            ; x20 = "/fs"
    d314: 52800001  mov  w1, #0x0
    d318: aa1403e0  mov  x0, x20
    d31c: 97fff5a5  bl   a9b0 <mkdir@plt>            ; mkdir("/fs", 0)
    d320: 340002c0  cbz  w0, d378                    ; mkdir 成功 -> d378
    d324: 90000160  adrp x0, 39000
    d328: 91372000  add  x0, x0, #0xdc8              ; x0 = 0x39dc8 = "mount -t trimafs trimafs /fs"
    d32c: 97fff4b5  bl   a600 <system@plt>           ; ★★★ 真正的挂载 ★★★
    d330: 34fffcc0  cbz  w0, d2c8                    ; 成功则返回
    d334: 9136e273  add  x19, x19, #0xdb8            ; "/fs"
    d338: 52800001  mov  w1, #0x0
    d33c: aa1303e0  mov  x0, x19
    d340: 97fff6a4  bl   add0 <access@plt>           ; access("/fs", F_OK)
    d344: 35fffc20  cbnz w0, d2c8
    d348: 910083e1  add  x1, sp, #0x20
    ...
    d354: 91242000  add  x0, x0, #0x908              ; "chattr"
    d358: 91244042  add  x2, x2, #0x910              ; "-i"  <-- 见下方说明
    d35c: f90013e0  str  x0, [sp, #32]
    d360: a900cc22  stp  x2, x19, [x1, #8]
    d364: f9000c3f  str  xzr, [x1, #24]
    d368: 9400ad27  bl   38804 <util::fork_execvp(char const*, char**)>
    d36c: aa1303e0  mov  x0, x19
    d370: 97fff754  bl   b0c0 <remove@plt>
    d374: 17ffffd5  b    d2c8
    d378: 52800001  mov  w1, #0x0
    d37c: aa1403e0  mov  x0, x20
    d380: 97fff6a8  bl   ae20 <chmod@plt>            ; chmod("/fs", 0)
    d384: 910083e1  add  x1, sp, #0x20
    d388: 90000160  adrp x0, 39000
    d38c: 90000162  adrp x2, 39000
    d390: 91242000  add  x0, x0, #0x908              ; "chattr"
    d394: 91370042  add  x2, x2, #0xdc0              ; x2 = 0x39dc0 = "+i"
    d398: f90013e0  str  x0, [sp, #32]               ; argv[0] = "chattr"
    d39c: a900d022  stp  x2, x20, [x1, #8]           ; argv[1] = "+i", argv[2] = "/fs"
    d3a0: f9000c3f  str  xzr, [x1, #24]
    d3a4: 9400ad18  bl   38804 <util::fork_execvp(char const*, char**)>
    d3a8: 17ffffdf  b    d324                          ; -> system("mount ...")
```

（`d358` 处 `x2` 由 `adrp x2,39000` + `add x2,x2,#0x910` 得到 `0x39910` = `"-i"`；该分支用于「`/fs` 存在但挂载失败」的回滚清理。）

### 1.3 mount options = 空 / flags = 0：证据

**证据 1**：唯一一处 `system()` 调用的参数是 `0x39dc8`，该字符串已在 §0 逐字节给出：`"mount -t trimafs trimafs /fs"`。字符串里没有 `-o` 子串。

```
$ strings -a -t x triminit | grep -iE "\bmount|trimafs|/fs\b"
  398a0 mount
  39dc8 mount -t trimafs trimafs /fs          <-- 唯一的 trimafs 挂载命令
  3a0a0 SELECT id from mount WHERE id<>0 and id is not NULL
  ...
  69d02 _Z13mount_trimafsv
```

**证据 2**：全二进制范围内搜索 `-o` / `-t` 组合没有其他 trimafs 相关行：

```
$ strings -a triminit | grep -E '^-[a-z]' | sort -u
-i
+i
```

只有 `-i` 与 `+i`（都是 `chattr` 的参数），**没有 `-o`**。

**证据 3**：`triminit` 从未导入 `mount`/`umount` 符号：

```
$ nm -D triminit | grep -E "mount|umount"
(无输出)
```

对比全 trim 树（§8 会用到）：

```
$ for f in bin/* lib/*.so*; do s=$(nm -D "$f" | grep -E "U (mount|umount2)@"); [ -n "$s" ] && echo "$f: $s"; done
bin/share_service: U umount2@GLIBC_2.17
bin/sysdiag: U mount@GLIBC_2.17  U umount@GLIBC_2.17
bin/sysrestore_service: U mount@GLIBC_2.17  U umount@GLIBC_2.17
bin/trim_curlftpfs: U mount@GLIBC_2.17  U umount2@GLIBC_2.17
bin/trim_nfusr: U mount@GLIBC_2.17  U umount2@GLIBC_2.17
```

→ 结论：**挂载 trimafs 完全走 `/bin/mount`（util-linux）外部命令**，因此 mount options 字符串在 `triminit` 里不存在；如果将来要加 options，等价于改这条命令行。

**证据 4 — flags**：由于走 `system()`，`mount(2)` 的 `MS_*` flags 由 `util-linux` 的 `mount` 命令按默认行为决定（不指定 `-o` 时既无 `MS_RDONLY` 也无 `MS_NOSUID` 等，实际 flags 值需另查 util-linux，本报告不推测具体数值）。
**【推测】** util-linux 在未给 `-o` 时会自行决定是否补 `MS_NODEV|MS_NOSUID`（取决于它读到的 fstab/源）。**这一点未能从 `triminit` 二进制证实**，因为 flags 不在 `triminit` 里。

### 1.4 挂载点准备流程（逐字符逻辑）

按反汇编还原的伪代码：

```c
void mount_trimafs(void) {
    if (is_volume_mounted("/fs", NULL))          // 读 /etc/mtab
        return;
    if (access("/fs", F_OK) == 0) {              // 已存在
        fork_execvp("chattr", {"chattr", "-i", "/fs", NULL});   // 清 immutable
        remove("/fs");                            // 删掉旧挂载点
    }
    if (mkdir("/fs", 0) == 0) {                  // 注意 mode = 0
        chmod("/fs", 0);                          // 权限 0000
        fork_execvp("chattr", {"chattr", "+i", "/fs", NULL});   // 置 immutable
        /* fallthrough */
    }
    if (system("mount -t trimafs trimafs /fs") == 0)
        return;
    if (access("/fs", F_OK) == 0) {              // 失败回滚
        fork_execvp("chattr", {"chattr", "-i", "/fs", NULL});
        remove("/fs");
    }
}
```

注意：`mkdir("/fs", 0)` 与 `chmod("/fs", 0)` 的 **mode 都是 0**（`mov w1, #0x0`）。因为挂载点由内核 trimafs 接管，用户态先把宿主目录权限压到 `0000` 再 `chattr +i` 锁定。

**证据 — `is_volume_mounted` 读的是 `/etc/mtab`**：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0xc8e0 --stop-address=0xc9d4 triminit
000000000000c8e0 <is_volume_mounted(char const*, char*)>:
    ...
    c8fc: adrp x0, 39000
    c900: add  x0, x0, #0x8e8        ; 0x398e8 = "/etc/mtab"
    c90c: adrp x1, 39000
    c910: add  x1, x1, #0x8e0        ; fopen mode
    c914: bl   a430 <fopen@plt>
    ...
    c928: mov  w1, #0x2000           ; fgets(buf, 8192, fp)
    ...
    c948: bl   a960 <strchr@plt>     ; 找第一个空格 -> 字段1结束
    c958: strb wzr, [x19], #1
    c960: bl   a960 <strchr@plt>     ; 找第二个空格
    c970: strb wzr, [x3]             ; 字段2 = 挂载点
    c978: bl   acd0 <strcmp@plt>     ; strcmp(字段2, "/fs")
```

```
$ strings -a -t x triminit | grep -E "proc/mounts|mountinfo|/etc/mtab"
  398e8 /etc/mtab
```

```
$ ls -la /home/xiaoabiao/.cache/fnnas/rootfs/etc/mtab
lrwxrwxrwx 1 ... etc/mtab -> ../proc/self/mounts
```

→ `/etc/mtab` 是 `../proc/self/mounts` 的符号链接，所以实际解析的是 `/proc/self/mounts` 的第 2 字段。

### 1.5 挂载时机：调用链与 systemd 单元

`mount_trimafs()` 在 `triminit` 全二进制中**只有一个调用点**：

```
$ aarch64-linux-gnu-objdump -d -C triminit | grep -B40 "bl.*d2a0 <mount_trimafs"
    b700: 940006e8  bl  d2a0 <mount_trimafs()>
```

`0xb700` 落在 `main` 内（`main` 起始 `0xb2e0`）。`main` 的初始化序列：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0xb6d4 --stop-address=0xb730 triminit
    b6d4: f94002a0  ldr  x0, [x21]
    b6d8: 97fffd2e  bl   ab90 <basename@plt>
    b6dc: adrp x1, 3a000
    b6e0: add  x1, x1, #0x3e0              ; x1 = 0x3a3e0 = "triminit"
    b6e4: bl   acd0 <strcmp@plt>           ; strcmp(basename(argv[0]), "triminit")
    b6e8: mov  w23, w0
    b6ec: cbnz w0, b9ec                    ; 不是 triminit -> 走别的子命令
    b6f0: bl   ea70 <init_trim_machine_id()>
    b6f4: mov  w20, #0x86a0
    b6f8: bl   da60 <kernel_set_external_disk_access()>
    b6fc: mov  w22, #0x78
    b700: bl   d2a0 <mount_trimafs()>      ; ★ 挂载 trimafs
    b704: mov  x19, #0x0
    b708: bl   d060 <init_nginx_key()>
    b70c: movk w20, #0x1, lsl #16
    b710: bl   ce04 <init_sshd_key()>
    b714: bl   ece0 <init_downloadkey()>
    b718: bl   d140 <init_rsa_key()>
    b71c: bl   cdb0 <init_trim_key_enc_file()>
    b720: bl   d3b0 <fix_file_perm()>
```

**所以挂载时机 = `triminit` 启动时、`init_trim_machine_id()` 与 `kernel_set_external_disk_access()` 之后、所有密钥初始化之前。**

systemd 单元（驱动 `triminit` 的唯一入口）：

```
$ grep -rl "triminit" etc/systemd lib/systemd usr/lib/systemd
etc/systemd/system/getty@tty1.service.d/override.conf
etc/systemd/system/trim_init.service

$ cat etc/systemd/system/trim_init.service
[Unit]
Description=trim init service
After=rc-local.service

[Service]
Type=oneshot
ExecStart=/usr/trim/bin/triminit
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

$ cat etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStartPre=-/usr/trim/bin/wait_trim_init.sh triminit /dev/tty1
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear - $TERM
```

时序：`multi-user.target` → `rc-local.service` 之后启动 `trim_init.service`（oneshot）→ `triminit` 在 `main` 里挂载 `/fs`。
`getty@tty1` 用 `wait_trim_init.sh` 阻塞等待 `triminit` 进程就绪（说明 `/fs` 在登录 shell 出现前必须已就绪）。

---

## 2. trimafs 的 inode 语义

### 2.1 核心机制：**用户态用 `symlink(2)` 往 trimafs 里写目录项**

`usr/trim/bin/share_service` 里有一个 C++ 类 `sharing::TrimAFS`（符号在 `.dynsym` 里，带完整 mangled 名）：

```
$ nm -D share_service | grep -E "_ZN7sharing7TrimAFS" | sed 's/@@.*//'
... T _ZN7sharing7TrimAFS10RemoveLinkEjRKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE
... T _ZN7sharing7TrimAFS13AddLinkForUidEjPKcS2_
... T _ZN7sharing7TrimAFS13CreateTrimDirEjPKci
... T _ZN7sharing7TrimAFS13ClearAllLinksEj
... T _ZN7sharing7TrimAFS15RebuildWithMapsEjRSt3mapI...
... T _ZN7sharing7TrimAFS16ListFoldersAsSetB5cxx11Ejb
... T _ZN7sharing7TrimAFS17CreateShareFolderEjPKcS2_
... T _ZN7sharing7TrimAFS19IsOtherSharesFolderEPKc
... T _ZN7sharing7TrimAFS20RemoveLinkWithChildsEPKc
... T _ZN7sharing7TrimAFS22GetExistedSharingNamesB5cxx11Ej
... T _ZN7sharing7TrimAFS22RemoveLinkWithRealPathEPKc
... T _ZN7sharing7TrimAFSC1EPKc
... T _ZN7sharing7TrimAFSC2EPKc
```

关键函数 `CreateShareFolder(uid, target, linkpath)` 的反汇编：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x18ea74 --stop-address=0x18eaf0 share_service
000000000018ea74 <sharing::TrimAFS::CreateShareFolder(unsigned int, char const*, char const*)>:
  18ea74: stp  x29, x30, [sp, #-48]!
  18ea80: mov  x20, x0
  18ea84: mov  x19, x3                 ; x19 = 第3参数 = linkpath
  18ea88: ldrb w0, [x2]                ; *target
  18ea8c: cbz  w0, 18eaa4              ; target 为空 -> 走 mkdir 分支
  18ea90: ldp  x19, x20, [sp, #16]
  18ea94: mov  x1, x3                  ; linkpath
  18ea98: ldp  x29, x30, [sp], #48
  18ea9c: mov  x0, x2                  ; target
  18eaa0: b    59cf0 <symlink@plt>     ; ★★★ symlink(target, linkpath) ★★★
  18eaa4: mov  x0, x3                  ; linkpath
  18eab0: mov  w1, #0x0
  18eab4: bl   5a890 <access@plt>      ; access(linkpath, F_OK)
  18eab8: cbz  w0, 18ead8
  18eabc: mov  x2, x19
  18eac0: mov  w1, w21                 ; uid
  18eac4: mov  x0, x20
  18eac8: mov  w3, #0x1ed              ; 0755
  18eacc: bl   18e3a0 <sharing::TrimAFS::CreateTrimDir(unsigned int, char const*, int)>
```

**结论（实测确定）：`trimafs` 上的「共享目录」条目就是用普通 `symlink(2)` 创建的符号链接**，指向真实存储路径（`/vol<N>/...`）。
`CreateTrimDir` 则负责真实目录：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x18e3a0 --stop-address=0x18e3fc share_service
000000000018e3a0 <sharing::TrimAFS::CreateTrimDir(unsigned int, char const*, int)>:
  18e3c8: bl   5a2c0 <mkdir@plt>       ; mkdir(path, mode)
  18e3d8: bl   5a8f0 <chmod@plt>       ; chmod(path, mode)
  18e3e0: mov  w1, w21                 ; uid
  18e3e4: mov  x0, x19
  18e3e8: mov  w2, #0x3e9              ; ★ gid = 1001 (0x3e9) 硬编码
  18e3ec: bl   5ace0 <chown@plt>       ; chown(path, uid, 1001)
```

`TrimAFS` 构造函数的参数是一个 `const char*`（根路径），成员里存了：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x18b1e0 --stop-address=0x18b290 share_service
000000000018b1e0 <sharing::TrimAFS::TrimAFS(char const*)>:
  18b1f0: add  x22, x0, #0x10          ; std::string SSO 缓冲
  18b1f4: str  x22, [x0]
  ...
  18b228: adrp x0, 1aa000
  18b230: add  x0, x0, #0xb40          ; 0x1aab40 = "/fs/"
  18b238: str  x0, [x19, #32]          ; 该类第 2 个成员 = "/fs/"
```

`0x1aab40` 处字符串（用 readelf 段表换算后读取）：

```
0x1aab40 [.rodata] b'/fs/'
```

→ **`TrimAFS` 的挂载根就是 `/fs/`。**

### 2.2 路径模板（全部实测字符串）

`share_service`（64 位 PIE，段表 → 文件偏移已换算）：

```
$ python3 - (readelf -S + 偏移换算) 读取指定 vaddr
0x1aab40 [.rodata] b'/fs/'
0x1a16c0 [.rodata] b'/fs/'
0x1a17b0 [.rodata] b'/vol%u/'
0x1a0498 [.rodata] b'/vol%u'
0x1a1790 [.rodata] b'/vol%u/%s'
0x1a6c48 [.rodata] b'/vol%u/%u'
0x1a91b0 [.rodata] b'/vol%u/@snapshot/%d'
0x1a3db8 / 0x1a4268 / 0x1a58e0 [.rodata] b'/vol00/'
0x1a0740 / 0x1a58d8 / 0x1a6f... [.rodata] b'/vol01/'
0x1a0f10 / 0x1a8368 [.rodata] b'/vol02/'
0x1a7080 [.rodata] b'/vol'
0x1a0868 [.rodata] b'/vol01/%u/%s'
0x1a0260 [.rodata] b'/fs/%u/nfs  *(rw,async,insecure,all_squash,no_subtree_check,insecure_locks,sec=sys,anonuid=%u,anongid=%u,fsid=%u)'
0x1aa808 [.rodata] b'[TrimAFS] remove {} failed, error:{}, ret:{}'
0x1aa838 [.rodata] b'[TrimAFS] Failed to open {}'
0x1aa858 [.rodata] b'  [TrimAFS] Try to ClearFolder {} ret {}'
0x1aa888 [.rodata] b'[TrimAFS] {} Clear all links for {}'
0x1a32a0 [.rodata] b'trimafs'
```

`trim_file_monitor`：

```
  64cb0 /vol0
  64cb8 /fs/
  65150 trimafs
  65588 ^/vol[1-9]{1}\d*$
  65e10 /vol
```

**解读（实测 + 少量推测）**：
- 真实存储卷挂载点形如 `/vol00`、`/vol01`、`/vol02`（**两位补零**），模板 `/vol%u`、`/vol%u/%s`、`/vol%u/%u`、`/vol%u/@snapshot/%d`。
- `trim_file_monitor` 里的正则 `^/vol[1-9]{1}\d*$` 用来匹配 `/vol1`…`/vol99` 形式的挂载点（不补零），说明**同时存在补零与不补零两种写法**，读取处需按上下文区分。
- `trimafs` 呈现的是 `/fs/<uid>/...` 的**每用户命名空间**：`/fs/%u/nfs` 是 NFS 导出路径模板，`/fs/` 是根。
- **【推测】** `/fs/<uid>/<sharename>` 是 symlink → `/vol<nn>/<real_path>`，从而让每个用户看到的顶层目录是 TA 自己的共享集合；`GetExistedSharingNames` / `RebuildWithMaps` / `ListFoldersAsSet` 用来枚举和重建这些链接。理由：`CreateShareFolder` 直接调 `symlink()`，而 `RemoveLinkWithRealPath` / `RemoveLinkWithChilds` / `ClearAllLinks` / `RebuildWithMaps` 这套 API 语义正是「以链接为条目的目录」的管理原语。**具体 link 文本格式未能从二进制中直接读出**（未见 `readlink` 后拼接的格式化字符串）。

### 2.3 与 trimafs 交互的系统调用面

`libtrimacl.so` 只用 xattr 类调用（无 ioctl）。`share_service` 对 trimafs 的交互：

```
$ nm -D share_service | grep -E "U (symlink|readlink|link|mkdir|chown|access|lstat|stat|faccessat|fgetxattr|ioctl|umount)"
                 U faccessat@GLIBC_2.17
                 U fgetxattr@GLIBC_2.17
                 U ioctl@GLIBC_2.17
                 U umount2@GLIBC_2.17
```

即：目录项创建/删除用 `symlink`/`unlink`/`remove`（`ClearFolder`、`RemoveLink*`），属性用 `chmod`/`chown`，ACL 用 xattr，权限判定用 `faccessat` 魔数（§4）。
`ioctl` 在 `share_service` 中存在，但**未找到任何 ACL/文件系统相关的立即数 request**（见 §4.6）。

### 2.4 `trim_file_monitor` 刻意**忽略** trimafs

`trim_file_monitor` 内置一个被忽略的 fstype / 挂载点集合：

```
$ python3 -c "d=open('trim_file_monitor','rb').read(); print(repr(d[0x65140:0x651c0]))"
b'ramfs\x00\x00\x00sysfs\x00\x00\x00trimafs\x00devtmpfs\x00...bpf\x00...efivarfs\x00...mqueue\x00debugfs\x00rpc_pipefs\x00...configfs\x00...Cannot access proc mounts!!!\x00...'
```

`MountsMonitor::MountShouldBeIgnored(source, target)`（`0x34880`）逻辑：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x34880 --stop-address=0x34930 trim_file_monitor
   34890: ldp  x1, x0, [x1]
   348a0: ldrb w1, [x1]
   348a4: cmp  w1, #0x2f                ; '/' 开头？
   348a8: b.ne 348e4
   348ac: sub  x0, x0, #0x1
   348b8: b.gt 348e4
   348c8: cbnz w0, 348e4
   348d0: mov  w0, #0x1                 ; 挂载点恰好是 "/" -> 忽略
   348d4: ...
   348e4: adrp x20, 90000
   348e8: add  x20, x20, #0xa40         ; 全局 std::set<std::string>
   348f4: bl   _Rb_tree<...>::find      ; source ∈ set ?
   34904: b.ne 348d0                    ; 命中 -> 忽略
   34910: bl   _Rb_tree<...>::find      ; target ∈ set ?
   3491c: b.ne 348d0                    ; 命中 -> 忽略
```

→ **`trimafs` 被登记进忽略集合**，`trim_file_monitor` 不会对 trimafs 挂载点做 inotify/fanotify 监听。这是语义上重要的一点：trimafs 是合成的命名空间视图，真实事件要监听 `/vol<n>`。

---

## 3. xattr 命名约定（核心结论）

### 3.1 全量 xattr 名清单（实测）

对 trim 树做精确匹配 `^(user|trusted|system|security)\.[A-Za-z0-9_.:-]+$`：

```
$ cd /home/xiaoabiao/.cache/fnnas/rootfs/
$ for f in usr/trim/bin/* usr/trim/lib/*.so*; do o=$(strings -a "$f" | grep -E "^(user|trusted|system|security)\.[A-Za-z0-9_.:-]+$" | sort -u); [ -n "$o" ] && { echo "--- $f"; echo "$o"; }; done
--- usr/trim/bin/filemanager
system.posix_acl_access
system.posix_acl_default
user.is_trimacl
user.quota
user.trashbin
user.trim-share
user.trim-team-trashbin-access
user.trim-trashbin-record
--- usr/trim/bin/filestor_service
user.trim-file-share-protocol-allowed
--- usr/trim/bin/resmon_service
system.inited
system.power_button
system.reset_button
system.update
--- usr/trim/bin/share_service
user.trim-file-share-protocol-allowed
user.trim-share
--- usr/trim/bin/smbftpd
security.capability
--- usr/trim/bin/trashbind
user.trim-trashbin-record
--- usr/trim/bin/trim_app_center
user.trim-share
--- usr/trim/bin/trim-aria2c
system.listMethods
system.listNotifications
system.multicall
--- usr/trim/lib/libquota.so.0.2
system.c
system.h
trusted.trim_team_id
--- usr/trim/lib/libtrimacl.so
system.trim_acl
```

> 说明：`system.listMethods` / `system.listNotifications` / `system.multicall` 来自 `trim-aria2c` 的 XML-RPC，`system.c` / `system.h` 来自 `libquota` 的调试信息，**都不是 xattr 名**，只是恰好匹配正则，此处保留以示甄别过程。

### 3.2 ACL v2 = `system.trim_acl`

```
$ readelf -p .rodata usr/trim/lib/libtrimacl.so
String dump of section '.rodata':
  [    f0]  system.trim_acl
```

`.rodata` 的 vaddr = 0x3220，故该字符串 vaddr = **0x3310**。

读写点（全部实测，`libtrimacl.so` 未 strip）：

| 函数 | 地址 | xattr 调用 | xattr 名地址 | 证据 |
|---|---|---|---|---|
| `trimacl_get_fd` | `0x2b50` | `fgetxattr(fd, name, buf, 0x40000)` | `0x3000+0x310 = 0x3310` | 见下 |
| `trimacl_get_file` | `0x2be0` | `getxattr(path, name, buf, 0x40000)` | `0x3310` | 见下 |
| `l_trimacl_get_file` | `0x2c70` | `lgetxattr(path, ...)` | `0x3310` | 见下 |
| `trimacl_set_fd` | `0x2fe0` | `fsetxattr(fd, name, buf, len, 0)` / `fremovexattr` | `0x3000+0x310` | 见下 |
| `trimacl_set_file` | `0x3080` | `setxattr(path, ...)` / `removexattr` | `0x3310` | 见下 |
| `l_trimacl_set_file` | `0x3120` | `lsetxattr(path, ...)` / `lremovexattr` | `0x3310` | 见下 |

原始反汇编（`trimacl_get_fd`）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2b50 --stop-address=0x2bdc libtrimacl.so
0000000000002b50 <trimacl_get_fd>:
    2b50: sub  sp, sp, #0x30
    2b54: sub  sp, sp, #0x40, lsl #12       ; 栈缓冲 0x40000 = 262144 字节
    2b6c: bl   15f0 <__errno_location@plt>
    2b74: add  x21, sp, #0x30               ; buf
    2b78: adrp x1, 3000
    2b84: add  x1, x1, #0x310              ; ★ 0x3310 = "system.trim_acl"
    2b88: str  w0, [x19]                    ; *errno = 0
    2b8c: mov  x3, #0x40000                ; size = 262144
    2b90: bl   1480 <fgetxattr@plt>         ; fgetxattr(fd, "system.trim_acl", buf, 0x40000)
    2b94: tbnz w0, #31, 2bbc               ; <0 -> 错误路径
    2b98: mov  w1, w0
    2b9c: mov  x0, x21
    2ba0: bl   2a70 <trimacl_from_xattr(void*, int)>
    ...
    2bbc: ldr  w0, [x19]
    2bc0: cmp  w0, #0x3d                    ; ENODATA(61) -> 返回 NULL 但不置错误
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x3024 --stop-address=0x3044 libtrimacl.so
   3024: adrp x1, 3000
   302c: add  x1, x1, #0x310              ; "system.trim_acl"
   3030: mov  w4, #0x0                     ; flags = 0（既非 XATTR_CREATE 也非 XATTR_REPLACE）
   3034: mov  w0, w20                      ; fd
   3038: mov  x2, x21                      ; buf
   303c: bl   1640 <fsetxattr@plt>         ; fsetxattr(fd, "system.trim_acl", buf, len, 0)
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x3060 --stop-address=0x3078 libtrimacl.so
   3060: mov  w0, w20                      ; fd
   3064: adrp x1, 3000
   306c: add  x1, x1, #0x310
   3070: ...
   3074: b    15a0 <fremovexattr@plt>      ; acl == NULL -> 删除 xattr
```

**关键点**：`acl == NULL` 时走 `removexattr` 系列 —— 这就是「清空 ACL」的语义。

### 3.3 `system.` 命名空间的含义（对自编译内核的影响）

**【重要】** `system.*` 是 VFS 保留前缀。标准 Linux 中 `system.` 由 VFS 自己处理（`system.posix_acl_access`、`system.posix_acl_default`、`system.nfs4_acl`），普通文件系统**不能**注册 `system.` 开头的 xattr handler。
`libtrimacl.so` 硬编码 `system.trim_acl`，而 `filemanager` 同时引用 `system.posix_acl_access` / `system.posix_acl_default`，说明：

**【推测，理由充分】** fnOS 的内核在 `xattr_handler` 层额外注册了一个 `system.trim_acl` handler（很可能是在 VFS 的 `system.` 分支里加白名单，或直接挂在 trimafs + 各真实卷 fstype 的 xattr handler 表上）。
**验证方式（留给内核侧）**：在 `vmlinuz-6.18.18-trim` / `System.map-6.18.18-trim` 里找 `system.trim_acl` 字符串及其 xattr handler 结构 —— 本报告只做用户态，不做此断言。

对自编译内核的实际影响：**要么补一个接受 `system.trim_acl` 的 xattr handler，要么把用户态的 xattr 名改掉（`libtrimacl.so` 里只有一个字符串常量，patch 成本极低）**。

### 3.4 `user.is_trimacl`：另一个「ACL 是否启用」标记

`filemanager` 里同时存在：

```
$ strings -a -t x usr/trim/bin/filemanager | grep -E "user.is_trimacl|user.trashbin|user.quota|user.trim-share|system.posix_acl"
  244f8 user.trim-share
  25248 user.quota
  25278 user.trashbin
  25988 user.is_trimacl          <-- 注意：user. 命名空间
  259e8 system.posix_acl_access
  25a00 system.posix_acl_default
```

**【推测】** `user.is_trimacl` 是「该对象已迁移到 TrimACL 体系」的**迁移标记**（配合 `getxattr`/`setxattr`/`removexattr` 三个 PLT 调用以及 `lsetxattr`/`lgetxattr`/`lremovexattr` 变体使用）。
理由：`filemanager` 同时使用完整的 `trimacl_*` API（见下）与 POSIX ACL xattr 名，且日志串为 `[0;31m%s setxattr ERROR: %d %s` / `removexattr ERROR`，明显在做「两种 ACL 表示之间的转换与标记」。
**未找到**任何直接说明 `user.is_trimacl` 取值含义的字符串，故不给出具体取值断言。

```
$ for f in usr/trim/bin/*; do s=$(nm -D "$f" 2>/dev/null | grep -E "U trimacl_"); [ -n "$s" ] && { echo "--- $f"; echo "$s"; }; done
```
`filemanager` 导入的 `trimacl_*`（节选）：

```
$ nm -D usr/trim/bin/filemanager | grep -E "trimacl"
                 U trimacl_create_entry
                 U trimacl_delete_entry
                 U trimacl_free
                 U trimacl_from_text
                 U trimacl_get_entry
                 U trimacl_get_entry_count
                 U trimacl_get_file_all
                 U trimacl_get_inherit
                 U trimacl_get_level
                 U trimacl_get_permset
                 (…以及 set_file / to_text / is_support_trimacl 等)
```

→ `filemanager`（WebDAV/SMB 文件管理后端）是 TrimACL 的主要消费方。

### 3.5 其它 xattr 的属主

| xattr 名 | 命名空间 | 引用者 | 用途（实测/推测） |
|---|---|---|---|
| `system.trim_acl` | system | `libtrimacl.so` | **TrimACL/FilesACL 主存储** |
| `user.is_trimacl` | user | `filemanager` | 【推测】TrimACL 迁移标记 |
| `user.trim-share` | user | `filemanager`, `share_service`, `trim_app_center` | 共享元数据 |
| `user.trim-file-share-protocol-allowed` | user | `share_service`, `filestor_service` | 共享协议白名单 |
| `user.quota` | user | `filemanager` | 配额 |
| `user.trashbin` | user | `filemanager` | 回收站标记 |
| `user.trim-trashbin-record` | user | `filemanager`, `trashbind` | 回收站记录 |
| `user.trim-team-trashbin-access` | user | `filemanager` | 团队空间回收站访问控制 |
| `trusted.trim_team_id` | trusted | `libquota.so.0.2` | 团队空间 project id |
| `system.posix_acl_access` / `_default` | system | `filemanager` | 标准 POSIX ACL（兼容层） |
| `security.capability` | security | `smbftpd` | 标准（SMB 权限映射，非 fnOS 私有） |

**配额相关（`libquota.so.0.2`）**：

```
$ strings -a -t x usr/trim/lib/libquota.so.0.2 | grep -iE "trusted\.|project|quota"
   109c btrfs_get_project_id
   112d set_project_id
   113c apply_project_id_rescursive
   1465 trim_team_project_id_generate
   14cb trim_project_id_get
   5c68 trusted.trim_team_id
   5c88 projectquota@%u
   5c98 projectused@%u
   1cfbd ZFS_PROP_PROJECTQUOTA
   1d178 ZFS_PROP_PROJECTUSED
```

→ 配额走 **btrfs project quota ioctl / ZFS user property**，并发写 `trusted.trim_team_id` xattr。

---

## 4. ioctl 约定与「魔数 faccessat」私有 ABI

### 4.1 最关键的发现：TrimACL **不用 ioctl**，而是用魔数 dirfd 的 `faccessat()`

`libtrimacl.so` 的 `.dynsym` **没有 `ioctl`**：

```
$ nm -D usr/trim/lib/libtrimacl.so | grep -c ioctl
0
```

但它用 `faccessat` 做了 3 件私有的事。`faccessat` 的第一个参数（dirfd）被当作**命令号**，取值在一个刻意划出的负数区间：

```
$ python3 - (扫描 movn wN,#imm16，值落在 0xFFFFAB00..0xFFFFABFF)
usr/trim/lib/libtrimacl.so  [('w0','0xffffabb2',-21582), ('w0','0xffffabb8',-21576)]
usr/trim/lib/libndev.so     [('w0','0xffffabb0',-21584), ('w0','0xffffabb1',-21583)]
usr/trim/lib/libnfile.so    [('w0','0xffffabaf',-21585), ('w0','0xffffabb3',-21581)]
usr/trim/lib/libnperm.so    [('w0','0xffffabae',-21586), ('w0','0xffffabb5',-21579), ('w0','0xffffabb7',-21577)]
usr/trim/bin/trimtools      [('w0','0xffffabb6',-21578)]
```

完整命令表：**`0xFFFFABAE … 0xFFFFABB8`（十进制 −21586 … −21576）**，共 11 个连续值。

### 4.2 为什么这能工作：glibc 2.36 不过滤 dirfd，且会把正值透传给调用者

```
$ strings -a usr/lib/aarch64-linux-gnu/libc.so.6 | grep "GNU C Library"
GNU C Library (Debian GLIBC 2.36-9+deb12u13) stable release version 2.36.
```

```
$ aarch64-linux-gnu-objdump -d --start-address=0xddea0 --stop-address=0xddf00 libc.so.6
00000000000ddea0 <faccessat@@GLIBC_2.17>:
   ddea4: sxtw x7, w0                     ; dirfd -> x7（原样）
   ddeb0: sxtw x2, w2                     ; mode
   ddebc: sxtw x3, w3                     ; flags（原样）
   ddec0: mov  x5, x7
   ddec8: mov  x0, x7
   dded8: mov  x8, #0x1b7                 ; ★ syscall 439 = faccessat2
   ddeec: svc  #0x0
   ddef0: cmn  x0, #0x1, lsl #12          ; 是否落在 [-4095,-1] 错误区间
   ddef4: b.hi ddff0                      ; 是 -> 错误路径
```

返回路径（`0xddf98`）**完全不做变换**：

```
$ aarch64-linux-gnu-objdump -d --start-address=0xddf98 --stop-address=0xddfc8 libc.so.6
00000000000ddf98 <faccessat@@GLIBC_2.17+0xf8>:
   ddf98: adrp x1, 19f000
   ddfa0: ldr  x3, [sp, #136]             ; stack canary 校验
   ddfb4: ldp  x29, x30, [sp, #144]
   ddfbc: ldp  x21, x22, [sp, #176]
   ddfc0: add  sp, sp, #0xd0
   ddfc4: ret                             ; ★ 直接返回 w0（内核给的正值原样返回）
```

并且 `faccessat` 只在 **syscall 失败且 `errno == ENOSYS(0x26)`** 时才进兼容模拟分支（`ddf08: cmp w4,#0x26`），模拟分支才校验 flags（`ddf14: tst w19,#0xfffffcff`）。因此：

- 魔数 dirfd 不会被 glibc 拦下；
- 高位 flags（如 `0x40000000`）在 faccessat2 成功时也不会被 glibc 校验；
- 自定义内核在 `faccessat2` 入口按 dirfd 分发，把结果放进 `x0` 返回；
- 负返回值即 `-errno`（调用方自行 `neg` 后写 `errno`）。

**glibc 与 ld.so 内都不含这些魔数**（排除「glibc 被 patch」的假设）：

```
$ python3 - (同样扫描 libc.so.6 与 ld-linux-aarch64.so.1)
glibc magics: ['0xffffabff']        <-- 编译器巧合常量，不构成 ABI
ld-linux-aarch64.so.1: NONE
```

调用方把负返回值转 errno 的固定写法（`is_support_trimacl`）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x31c0 --stop-address=0x320c libtrimacl.so
00000000000031c0 <is_support_trimacl>:
    31c0: stp  x29, x30, [sp, #-32]!
    31c4: mov  w3, w1                     ; flags = 第2参数
    31c8: mov  w2, #0x0                   ; mode = 0
    31cc: mov  x1, x0                     ; pathname = 第1参数
    31d4: mov  w0, #0xffffabb2            ; ★ cmd = -21582
    31dc: bl   16b0 <faccessat@plt>
    31e0: mov  w19, w0
    31e4: tbnz w0, #31, 31f8              ; <0 -> 错误
    31e8: ... ret                         ; >=0 -> 原样返回
    31f8: bl   15f0 <__errno_location@plt>
    31fc: neg  w1, w19
    3200: mov  w19, #0xffffffff
    3204: str  w1, [x0]                   ; errno = -ret
    3208: b    31e8
```

### 4.3 命令表（实测 + 语义推断）

调用约定统一为：`faccessat(cmd, arg1, arg2, arg3)`。

| cmd | 十进制 | 属主库 | 关联 API | 实测参数形态 | 语义 |
|---|---|---|---|---|---|
| `0xFFFFABAE` | −21586 | `libnperm.so` | `internal_check_perm` | `(cmd, &perm_ctx, 4↑/2↑/1↑, 0)` | **ACL 感知的单权限位检查**，返回 0=允许 |
| `0xFFFFABAF` | −21585 | `libnfile.so` | `trim_realpath` | `(cmd, &{path,out,outlen}, 0, flags)` | **trimafs 感知的 realpath** |
| `0xFFFFABB0` | −21584 | `libndev.so` | `set_external_disk_access` | `(cmd, "", value, 0)` | 设置「外部磁盘访问」开关 |
| `0xFFFFABB1` | −21583 | `libndev.so` | `get_external_disk_access` | `(cmd, "", 0, 0)` | 读取上述开关（返回值） |
| `0xFFFFABB2` | −21582 | `libtrimacl.so` | `is_support_trimacl` | `(cmd, path, 0, flags)` | **路径所在 fs 是否支持 TrimACL** |
| `0xFFFFABB3` | −21581 | `libnfile.so` | `is_mountpoint` | `(cmd, path, 0, flags)` | **trimafs 感知的 is-mountpoint** |
| `0xFFFFABB5` | −21579 | `libnperm.so` | `trim_get_perm` | `(cmd, &ctx, 0, mode)` | 取 uid 对 path 的有效权限 |
| `0xFFFFABB6` | −21578 | `trimtools` | `trimacl_to_mode` | `(cmd, path, 0, 0)` | **把 TrimACL 折算成 POSIX mode** |
| `0xFFFFABB7` | −21577 | `libnperm.so` | `trim_may_delete` | `(cmd, &ctx, 0, mode)` | **ACL 感知的「能否删除」** |
| `0xFFFFABB8` | −21576 | `libtrimacl.so` | `__trimacl_get_file_all` | `(cmd, &getall_ctx, 0, flags)` | **批量取（原始 xattr 字节）** |
| `0xFFFFABB4` | −21580 | **未在任何 trim 二进制中出现** | — | — | **未找到** |

> `0xFFFFABB4` 在 `usr/trim` 全树中未出现。全 rootfs 扫描出的其它 `0xFFFFABxx` 命中（`usr/lib/gcc/.../cc1`、`docker-buildx`、内核 `.ko` 等）**是编译器产生的巧合常量**，与 fnOS ABI 无关，已甄别排除。

### 4.4 `0xFFFFABB8` 的请求结构体（32 字节）

`__trimacl_get_file_all` 在栈上装配结构体并两次调用（先取长度、再取数据）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2d00 --stop-address=0x2dd4 libtrimacl.so
0000000000002d00 <__trimacl_get_file_all(int, char const*, int, unsigned int)>:
    2d2c: add  x23, sp, #0x40              ; ctx = sp+0x40
    2d30: mov  w3, w21                     ; arg3 = 第3参数
    2d34: mov  x1, x23                     ; arg1 = &ctx
    2d38: mov  w2, #0x0                    ; arg2 = 0
    2d3c: mov  w0, #0xffffabb8             ; cmd
    2d44: stp  x24, xzr, [sp, #64]         ; ctx+0x00 = path ; ctx+0x08 = NULL
    2d48: stp  w20, w19, [sp, #88]         ; ctx+0x18 = w20 ; ctx+0x1C = w19
    2d4c: bl   16b0 <faccessat@plt>        ; 第一次：返回所需字节数
    2d50: cmp  w0, #0x0
    2d54: b.le 2dbc                       ; <=0 -> 失败
    2d58: sxtw x19, w0
    2d5c: mov  x0, x19
    2d60: bl   1630 <malloc@plt>           ; 按返回长度分配
    2d6c: mov  x1, x23
    2d70: mov  w3, w21
    2d74: mov  w2, #0x0
    2d78: mov  w0, #0xffffabb8
    2d7c: stp  x20, x19, [sp, #72]         ; ctx+0x08 = buf ; ctx+0x10 = size
    2d80: bl   16b0 <faccessat@plt>        ; 第二次：填充数据
    2d90: bl   2a70 <trimacl_from_xattr(void*, int)>
```

实测（来自存储偏移，**字段名是推断的**）请求结构体布局：

```c
struct trimacl_getall_ctx {   // 大小 0x20 = 32 字节
    const char *path;         // +0x00   第1次调用入参
    void       *buf;          // +0x08   第2次调用入参（第1次为 NULL）
    size_t      size;         // +0x10   第2次调用入参
    int         at_fd;        // +0x18   AT_FDCWD(-1) 或真实 fd
    unsigned    flags;        // +0x1C
};
```

三个入口函数的参数映射（实测）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2dd4 --stop-address=0x2e14 libtrimacl.so
0000000000002dd4 <trimacl_get_fd_all>:
    2dd4: orr  w3, w1, #0x40000000       ; ★ flags |= 0x40000000  => "按 fd 模式"
    2dd8: mov  w2, #0x0
    2ddc: mov  x1, #0x0                  ; path = NULL
    2de0: b    1660 <__trimacl_get_file_all@plt>   ; (fd, NULL, 0, flags|0x40000000)

0000000000002de4 <trimacl_get_file_all>:
    2de4: mov  w3, w1                    ; flags
    2de8: mov  w2, #0x0
    2dec: mov  x1, x0                    ; path
    2df0: mov  w0, #0xffffffff           ; at_fd = AT_FDCWD
    2df4: b    1660 <__trimacl_get_file_all@plt>

0000000000002e00 <l_trimacl_get_file_all>:
    2e00: mov  w3, w1                    ; flags
    2e04: mov  w2, #0x100                ; ★ AT_SYMLINK_NOFOLLOW = 0x100
    2e08: mov  x1, x0
    2e0c: mov  w0, #0xffffffff
    2e10: b    1660 <__trimacl_get_file_all@plt>
```

**所以第 3 参数（最终落到 `faccessat` 的 `flags` 槽）承载 `AT_SYMLINK_NOFOLLOW`（0x100）**，而 `0x40000000` 是「第 1 参数是 fd 而非 dirfd」的自定义标志位。

### 4.5 `0xFFFFABAE` 的请求结构体（32 字节）与 rwx 位探针

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2090 --stop-address=0x2110 libnperm.so
    2090: mov  w2, #0x4                    ; ★ arg2 = 4
    2094: mov  w0, #0xffffabae
    2098: str  x24, [sp, #64]              ; ctx+0x00 = path
    209c: stp  w23, w22, [sp, #72]         ; ctx+0x08 = w23 ; ctx+0x0C = w22
    20a0: str  w4, [sp, #80]               ; ctx+0x10 = w4  (gid 个数)
    20a4: str  x21, [sp, #88]              ; ctx+0x18 = x21 (gid 数组)
    20a8: bl   1cb0 <faccessat@plt>
    20ac: cmp  w0, #0x0
    20b4: cset w19, eq                     ; w19 = (ret == 0)
    20b8: mov  w3, #0x0
    20bc: mov  w2, #0x2                    ; ★ arg2 = 2
    20c0: mov  w0, #0xffffabae
    20c4: bl   1cb0 <faccessat@plt>
    20cc: lsl  w19, w19, #2
    20d4: orr  w2, w19, #0x2
    20dc: csel w19, w2, w19, eq
    20e0: mov  w0, #0xffffabae
    20e4: mov  w2, #0x1                    ; ★ arg2 = 1
    20e8: bl   1cb0 <faccessat@plt>
    20f0: orr  w0, w19, #0x1
    20f8: csel w0, w0, w19, eq             ; 返回 rwx 位掩码
```

函数签名（实测，符号未 strip）：

```
$ nm libnperm.so | grep -iE "internal_check_perm|check_perm|trim_access"
0000000000002010 t _Z19internal_check_permjPKcj
0000000000002170 T check_perm_ignore_administrators
0000000000002180 T check_perm
0000000000002190 T trim_access
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2170 --stop-address=0x2190 libnperm.so
0000000000002170 <check_perm_ignore_administrators>:
    2170: mov  w2, #0x1                    ; mode = 1
    2174: b    2010 <internal_check_perm(unsigned int, char const*, unsigned int)>

0000000000002180 <check_perm>:
    2180: mov  w2, #0x0                    ; mode = 0
    2184: b    2010 <internal_check_perm(unsigned int, char const*, unsigned int)>
```

结果为 rwx 位掩码（4=R, 2=W, 1=X）；`mode` 的第 0 位是「忽略管理员」开关。

**请求结构体（实测偏移，字段名推断）**：

```c
struct trim_perm_ctx {        // 0x20 = 32 字节
    const char  *path;        // +0x00
    unsigned     flags;       // +0x08  ← internal_check_perm 的第3参数 (0/1)
    unsigned     uid;         // +0x0C
    unsigned     ngids;       // +0x10
    const unsigned *gids;     // +0x18
};
```

`trim_may_delete`（cmd `0xFFFFABB7`）与 `trim_get_perm`（cmd `0xFFFFABB5`）用同一结构体，且把 `faccessat` 的 `arg2` 置 0、`arg3` 置 mode：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x23a8 --stop-address=0x23cc libnperm.so
    23a8: mov  w3, w23                     ; arg3 = 第3参数
    23ac: add  x1, sp, #0x40               ; &ctx
    23b0: mov  w2, #0x0                    ; arg2 = 0
    23b4: mov  w0, #0xffffabb7             ; cmd = trim_may_delete
    23b8: str  x22, [sp, #64]              ; ctx+0x00 = path
    23bc: stp  w19, w21, [sp, #72]         ; ctx+0x08 = w19(flags), ctx+0x0C = w21(uid)
    23c0: str  w4, [sp, #80]               ; ctx+0x10 = ngids
    23c4: str  x20, [sp, #88]              ; ctx+0x18 = gids
    23c8: bl   1cb0 <faccessat@plt>
```

### 4.6 ioctl 请求号：实测结果

对 `usr/trim/bin` 与 `usr/trim/lib` 中 `ioctl` 的调用点做立即数扫描，**唯一找到的文件系统相关 ioctl 是标准 `FS_IOC_*`，非 fnOS 私有**：

```
$ aarch64-linux-gnu-objdump -d -C trashbind | grep -B14 "bl.*<ioctl@plt>"
0000000000004220 <util::chattr_remove_i_a(char const*)>:
  4220: stp  x29, x30, [sp, #-64]!
  4224: mov  w1, #0x0                    ; O_RDONLY
  4230: bl   1860 <open@plt>
  4238: mov  x1, #0x6601                 ; #26113
  423c: ...
  424c: movk x1, #0x8008, lsl #16        ; x1 = 0x80086601
  4250: bl   1970 <ioctl@plt>            ; ioctl(fd, FS_IOC_GETFLAGS=0x80086601, &flags)
  4250: ...
  4284: and  w3, w0, #0xffffffcf         ; 清 FS_IMMUTABLE_FL|FS_APPEND_FL (0x30)
  4288: mov  x1, #0x6602
  4294: movk x1, #0x4008, lsh #16        ; x1 = 0x40086602
  429c: bl   1970 <ioctl@plt>            ; ioctl(fd, FS_IOC_SETFLAGS=0x40086602, &flags)
```

| request | 名称 | 来源 | 参数 |
|---|---|---|---|
| `0x80086601` | `FS_IOC_GETFLAGS` | 标准 Linux | `int*` (4 字节) |
| `0x40086602` | `FS_IOC_SETFLAGS` | 标准 Linux | `int` (4 字节) |

**两个 ioctl 都是上游通用定义，不是 fnOS 私有。** `trashbind` 用它来实现 `chattr -i -a` 的等价功能（因为 `chattr` 命令未必存在于精简 rootfs）。

**未找到**：任何 ACL / trimafs / trim_trashbin 相关的私有 ioctl 立即数。
**【重要】** 私有内核接口不是通过 ioctl，而是通过 §4.1 的**魔数 `faccessat`**；`/dev/trim-trashbin` 则是**字符设备的 `read()` 流**（§6.3）。**唯一未能穷尽的是通过寄存器间接传入的 request（非立即数）**，本报告不对其做断言。

---

## 5. TrimACL 的二进制格式（`system.trim_acl` 内容）

### 5.1 权威依据：`trimacl` 自带的帮助文本

`usr/trim/bin/trimacl` **未 strip**（有 `.symtab`，`main` 在 `0x22c0`）。其 `.rodata` 偏移 `0xd8` 起是完整文档：

```
$ readelf -p .rodata usr/trim/bin/trimacl
  [    d8]  TrimACL v0.8.3\n
            Usage:\n
              trimacl file\n
              trimacl -b file\n
              trimacl -x2 file\n
              trimacl -m a:u:1000:rwx:sfd file\n
              trimacl -m d:o:rwxpdDaAeEcCo:df file\n
              trimacl -m e file\n
            -b: remove all aces\n
            -x: remove an ace by index\n
            -m: add/modify an ace.\n
            type:\n
                a: allow\n
                d: deny\n
                e: exclude inheritance permissions\n
            tag:\n
                u: user\n
                g: group\n
                e: everyone\n
                o: owner\n
            permission sets (classical RWX or...):\n
                r: (r)ead data (list dir)\n
                w: (w)rite data (create file)\n
                x: e(x)ecute (cd dir)\n
                p: a(p)pend data (create dir)\n
                d: (d)elete self\n
                D: (D)elete child\n
                a: read (a)ttribute\n
                A: write (A)ttribute\n
                e: read (e)xt-attr\n
                E: write (E)xt-attr\n
                c: read a(c)l\n
                C: write a(C)l\n
                o: get (o)wnership\n
            inherit:\n
                s: self only\n
                f: file\n
                d: dir\n
                n: no propagate\n
  [   400]  invalid option: %s\n
  [   418]  bx:m:\n            <-- getopt optstring
  [   420]  Error: miss file path\n
  [   4a0]  <exclude inheritance permissions>\n
  [   4d0]  <allow> \n
  [   4e0]  uid:\n
  [   4e8]  gid:\n
  [   4f0]  everyone\n
  [   500]  owner\n
  [   508]   permset:\n
  [   518]   inherit:\n
```

### 5.2 xattr 整体布局

`trimacl_to_xattr(trim_acl*, void**)` 与 `trimacl_from_xattr(void*, int)` 给出**实测**布局：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2e38 --stop-address=0x2e6c libtrimacl.so
    2e30: ldr  w20, [x19]                  ; w20 = acl->count
    2e34: tbnz w20, #31, 2fa8              ; count<0 -> 失败
    2e3c: mov  x21, #0x4                   ; x21 = 4
    2e48: mov  w23, #0x14                  ; 每条记录 20 字节
    2e4c: umaddl x21, w20, w23, x21        ; x21 = 4 + count*20
    2e50: mov  x0, x21
    2e54: bl   1630 <malloc@plt>
    2e64: mov  w0, #0x1
    2e68: str  w0, [x9], #4                ; ★ 头部 u32 = 1，随后指针 +4
```

解码端校验 `(size-4) % 20 == 0`：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2a70 --stop-address=0x2ac0 libtrimacl.so
0000000000002a70 <trimacl_from_xattr(void*, int)>:
    2a74: cmp  x1, #0x3                    ; size <= 3 -> 失败
    2a78: b.ls 2b44
    2a80: sub  x1, x1, #0x4                ; size - 4
    2a84: mov  x2, #0xcccccccccccccccc
    2a88: movk x2, #0xcccd                 ; x2 = 0xCCCCCCCCCCCCCCCD (÷20 的倒数)
    2a9c: mul  x0, x1, x2
    2aa4: ror  x0, x0, #2
    2aa8: cmp  x0, x3                      ; 0x0CCCCCCCCCCCCCCC
    2aac: b.hi 2b34                        ; 不整除 -> 失败
    2ab0: umulh x1, x1, x2
    2ab4: lsr  x20, x1, #4                 ; x20 = (size-4)/20 = count
    2abc: mov  w0, w20
    2ac0: bl   1540 <trimacl_init@plt>
```

```c
// system.trim_acl xattr 内容
struct trim_acl_xattr {
    uint32_t     format;     // +0x00  实测恒为 1（写侧硬编码 1，读侧不校验）
    struct trim_ace ace[];   // +0x04  每条恰好 20 (0x14) 字节
};
// 总长度 = 4 + n*20；n = (xattr_len - 4) / 20
```

读侧对 `format` **不做任何校验**（直接 `sub x1, x1, #4` 跳过）。

### 5.3 单条 ACE 的 20 字节布局（由存取器精确确定）

```
$ nm libtrimacl.so | grep -E "trimacl_(get|set)_(type|tag_type|permset|qualifier|inherit|level)"
0000000000001b40 T trimacl_get_permset
0000000000001b50 T trimacl_set_permset
0000000000001b60 T trimacl_get_qualifier
0000000000001b70 T trimacl_set_qualifier
0000000000001b80 T trimacl_get_tag_type
0000000000001b90 T trimacl_set_tag_type
0000000000001bb0 T trimacl_get_type
0000000000001bc0 T trimacl_set_type
0000000000001be0 T trimacl_get_inherit
0000000000001d20 T trimacl_set_inherit
0000000000001d30 T trimacl_get_level
0000000000001d40 T trimacl_is_ace_excluded
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1b40 --stop-address=0x1be8 libtrimacl.so
0000000000001b40 <trimacl_get_permset>:     1b40: ldr  w0, [x0, #4]        ; +0x04 u32
0000000000001b50 <trimacl_set_permset>:     1b58: str  w1, [x2, #4]
0000000000001b60 <trimacl_get_qualifier>:   1b60: ldr  w0, [x0, #12]       ; +0x0C u32
0000000000001b70 <trimacl_set_qualifier>:   1b78: str  w1, [x2, #12]
0000000000001b80 <trimacl_get_tag_type>:    1b80: ldrh w0, [x0]
                                            1b84: ubfx x0, x0, #2, #16  ; tag = (+0x00 >> 2)
0000000000001b90 <trimacl_set_tag_type>:    1b94: ubfiz w1, w1, #2, #16
                                            1b9c: ldrh w2, [x3]
                                            1ba0: and  w2, w2, #0x3     ; 保留低 2 位
                                            1ba8: strh w2, [x3]
0000000000001bb0 <trimacl_get_type>:        1bb0: ldrh w0, [x0]
                                            1bb4: and  w0, w0, #0x3     ; type = (+0x00 & 3)
0000000000001bc0 <trimacl_set_type>:        1bc4: and  w1, w1, #0x3
                                            1bd0: and  w2, w2, #0x3c    ; 保留 bit2..5
                                            1bd8: strh w2, [x3]
0000000000001be0 <trimacl_get_inherit>:     1be0: ldrh w0, [x0, #8]     ; +0x08 u16
0000000000001d20 <trimacl_set_inherit>:     1d28: strh w1, [x2, #8]
0000000000001d30 <trimacl_get_level>:       1d30: ldr  w0, [x0, #16]      ; +0x10 i32
                                            1d38: cneg w0, w0, lt        ; 返回 |level|
0000000000001d40 <trimacl_is_ace_excluded>: 1d40: ldr  w0, [x0, #16]
                                            1d44: lsr  w0, w0, #31       ; 返回符号位
```

```c
struct trim_ace {                    // 20 (0x14) 字节
    uint16_t tag_and_type;  // +0x00   [bit1:0]=type(0..3)  [bit5:2]=tag(0..15)
    uint16_t reserved;      // +0x02   实测被写入 0（规范化过程中的临时标记）
    uint32_t permset;       // +0x04
    uint16_t inherit;       // +0x08
    uint16_t reserved2;     // +0x0A   未知
    uint32_t qualifier;     // +0x0C   uid 或 gid
    int32_t  level;         // +0x10   负值 = 该 ACE 为 "excluded"
};                                    // 合计 0x14 = 20 ✓
```

**`+0x10` 的语义已实测确定**：`trimacl_get_level` 返回其绝对值，`trimacl_is_ace_excluded` 返回其符号位 → 它是一个**有符号等级**，**符号位表示「被排除」**。
`+0x02` / `+0x0A` 的字段名**未知**，本报告不编造。

### 5.4 tag / type 取值表（帮助文本 + 反汇编双向验证）

`parse_ace` 把文本写进内存结构体 `trim_ace_t`（**与磁盘上的 20 字节记录布局不同**），再由 `trimacl_from_text` 通过 `trimacl_set_*` 映射过去。

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2270 --stop-address=0x22d0 libtrimacl.so
0000000000002210 <trimacl_from_text>:
    ...
    2284: mov  x1, x24                      ; &entry_out
    2288: mov  x0, x22                      ; &acl
    228c: bl   1690 <trimacl_create_entry@plt>
    2294: ldr  x0, [sp, #88]                ; 新 entry 指针
    2298: ldrh w1, [sp, #98]                ; trim_ace_t + 0x02   ★
    229c: bl   1620 <trimacl_set_type@plt>
    22a0: ldr  x0, [sp, #88]
    22a4: ldrh w1, [sp, #96]                ; trim_ace_t + 0x00   ★
    22a8: bl   1440 <trimacl_set_tag_type@plt>
    22ac: ldr  x0, [sp, #88]
    22b0: ldr  w1, [sp, #108]               ; trim_ace_t + 0x0C
    22b4: bl   16e0 <trimacl_set_qualifier@plt>
    22b8: ldr  x0, [sp, #88]
    22bc: ldr  w1, [sp, #100]               ; trim_ace_t + 0x04
    22c0: bl   1460 <trimacl_set_permset@plt>
    22c4: ldr  x0, [sp, #88]
    22c8: ldrh w1, [sp, #104]               ; trim_ace_t + 0x08
    22cc: bl   1430 <trimacl_set_inherit@plt>
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x20f8 --stop-address=0x220c trimacl... (实为 libtrimacl.so parse_ace)
    20f8: mov  w0, #0x1                    ; type 'a' (allow)
    20fc: strh w0, [x23, #2]               ; trim_ace_t + 0x02
    ...
    2178: mov  w0, #0x2                    ; type 'd' (deny)
    217c: b    20fc
    ...
    21dc: mov  w0, #0x1                    ; tag 'u' (user)
    21e4: b.ne 218c
    ...
    2180: mov  w0, #0x2                    ; tag 'g' (group)
    218c: strh w0, [x23]                   ; trim_ace_t + 0x00
    ...
    212c: mov  w0, #0x4                    ; tag 'e' (everyone)
    2138: strh w0, [x23]
    ...
    2208: mov  w0, #0x8                    ; tag 'o' (owner)
    220c: b    2130
```

| 字段 | 字母 | 值 | 证据 |
|---|---|---|---|
| **type** | `a` | `1` | `parse_ace 0x20f8`；帮助文本 "a: allow" |
| | `d` | `2` | `parse_ace 0x2178`；帮助文本 "d: deny" |
| | `e` | 特殊（type=0 + inherit=0x4000） | `parse_ace 0x2140`；帮助文本 "e: exclude inheritance permissions" |
| **tag** | `u` | `1` (bit0) | `parse_ace 0x21dc`；帮助文本 "u: user" |
| | `g` | `2` (bit1) | `parse_ace 0x2180`；帮助文本 "g: group" |
| | `e` | `4` (bit2) | `parse_ace 0x212c`；帮助文本 "e: everyone" |
| | `o` | `8` (bit3) | `parse_ace 0x2208`；帮助文本 "o: owner" |

**双向验证**：`trimacl_to_text` 按同样的位顺序渲染：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x23c4 --stop-address=0x2410 libtrimacl.so
    23c4: bl   1580 <trimacl_get_type@plt>
    23cc: tbz  w0, #0, 2818            ; type bit0 清 -> 用 0x32e8
    23d0: adrp x0, 3000
    23d8: ...                          ; 0x32e0 = "a:"
    ...
    2818: adrp x0, 3000
    281c: add  x0, x0, #0x2e8          ; 0x32e8 = "d:"
    23ec: bl   14a0 <trimacl_get_tag_type@plt>
    23f4: tbz  w0, #0, 26bc            ; tag bit0 清
    2404: add  x1, x1, #0x2f0          ; 0x32f0 = "u:"
    26bc: bl   14a0 <trimacl_get_tag_type@plt>
    26c4: tbz  w0, #1, 28b4            ; tag bit1 清
    26d0: ldr  x1, [sp, #104]          ; 0x32f8 = "g:"
    28b4: bl   14a0 <trimacl_get_tag_type@plt>
    28bc: tbz  w0, #2, 2920            ; tag bit2 清
    28c8: ldr  x1, [sp, #112]          ; 0x3300 = "e:"
    2920: bl   14a0 <trimacl_get_tag_type@plt>
    292c: tbz  w0, #3, 2588            ; tag bit3 清
    293c: add  x1, x1, #0x308          ; 0x3308 = "o:"
```

`.rodata` 里对应的 6 个字符串（vaddr 已换算）：

```
0x32e0  b'a:'      0x32e8  b'd:'
0x32f0  b'u:'      0x32f8  b'g:'      0x3300  b'e:'      0x3308  b'o:'
```

### 5.5 permset 位表（帮助文本 + jump table 双向验证）

`parse_permset` 用一张跳转表（`.rodata` vaddr `0x3320`，索引 = `ch - 'A'`，项为相对 `0x1d84` 的 4 字节指令偏移）：

```
$ python3 - (解码 libtrimacl.so .rodata:0x3320 跳转表)
  'A' -> target 0x1e0c  orr #0x200
  'C' -> target 0x1e04  orr #0x800
  'D' -> target 0x1dfc  orr #0x2000
  'E' -> target 0x1df4  orr #0x400
  'R' -> target 0x1de8  orr #0x1c4      <-- 组合简写
  'W' -> target 0x1ddc  orr #0x260a     <-- 组合简写
  'X' -> target 0x1d8c  orr #0x1
  'a' -> target 0x1dd4  orr #0x100
  'c' -> target 0x1dc4  orr #0x80
  'd' -> target 0x1dbc  orr #0x1000
  'e' -> target 0x1db4  orr #0x40
  'o' -> target 0x1dac  orr #0x4000
  'p' -> target 0x1da4  orr #0x8
  'r' -> target 0x1d9c  orr #0x4
  'w' -> target 0x1dcc  orr #0x2
  'x' -> target 0x1d8c  orr #0x1
  (其余字母 -> 0x1d84 返回 -1 = 非法)
```

`explain_permset` 的输出顺序与位映射：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1e20 --stop-address=0x1fb0 libtrimacl.so
    1fa0: mov  w0, #0x72   ; 'r'   (bit2  0x4)
    1f88: mov  w1, #0x77   ; 'w'   (bit1  0x2)
    1f70: mov  w1, #0x78   ; 'x'   (bit0  0x1)
    1f58: mov  w1, #0x70   ; 'p'   (bit3  0x8)
    1f40: mov  w1, #0x64   ; 'd'   (bit12 0x1000)
    1f28: mov  w1, #0x44   ; 'D'   (bit13 0x2000)
    1f10: mov  w1, #0x61   ; 'a'   (bit8  0x100)
    1ef8: mov  w1, #0x41   ; 'A'   (bit9  0x200)
    1ee0: mov  w1, #0x65   ; 'e'   (bit6  0x40)
    1ec8: mov  w1, #0x45   ; 'E'   (bit10 0x400)
    1eb0: mov  w1, #0x63   ; 'c'   (bit7  0x80)
    1e7c: mov  w1, #0x43   ; 'C'   (bit11 0x800)
    1e90: mov  w1, #0x6f   ; 'o'   (bit14 0x4000)
```

（输出顺序 r w x p d D a A e E c C o，与帮助文本、CLI 示例 `rwxpdDaAeEcCo` 完全一致。）

**`permset`（ACE +0x04，u32）位表：**

| 字母 | bit | 值 | 含义（来自帮助文本） |
|---|---|---|---|
| `x` | 0 | `0x0001` | execute (cd dir) |
| `w` | 1 | `0x0002` | write data (create file) |
| `r` | 2 | `0x0004` | read data (list dir) |
| `p` | 3 | `0x0008` | append data (create dir) |
| `e` | 6 | `0x0040` | read ext-attr |
| `c` | 7 | `0x0080` | read acl |
| `a` | 8 | `0x0100` | read attribute |
| `A` | 9 | `0x0200` | write attribute |
| `E` | 10 | `0x0400` | write ext-attr |
| `C` | 11 | `0x0800` | write acl |
| `d` | 12 | `0x1000` | delete self |
| `D` | 13 | `0x2000` | delete child |
| `o` | 14 | `0x4000` | get ownership |
| `R` | — | `0x01C4` | 组合简写 = `r`+`e`+`c`+`a` (0x4\|0x40\|0x80\|0x100) |
| `W` | — | `0x260A` | 组合简写 = `w`+`p`+`A`+`E`+`D` (0x2\|0x8\|0x200\|0x400\|0x2000) |

（`R`/`W` 的组合值直接来自反汇编立即数；帮助文本未解释它们，此处按位拆分给出。）

### 5.6 inherit 位表

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1fb0 --stop-address=0x2028 libtrimacl.so
0000000000001fb0 <parse_inherit(char const*)>:
    1fc4: orr  w0, w0, #0x1                ; 'S'/'s' -> 0x1  (self only)
    1fdc: b.eq 1fc4                        ;   (与 0x53 'S' 比较，大小写不敏感)
    1fe8: orr  w0, w0, #0x2                ; 'F'/'f' -> 0x2  (file)
    2000: orr  w0, w0, #0x4                ; 'D'/'d' -> 0x4  (dir)
    2010: orr  w0, w0, #0x1000             ; 'N'/'n' -> 0x1000 (no propagate)
    2018: cmp  w1, #0x2d                   ; '-' -> 忽略
    2020: mov  w0, #0xffffffff             ; 其他 -> -1 非法
```

`trimacl_valid` 对 inherit 的合法掩码：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1c20 --stop-address=0x1c80 libtrimacl.so
    1c20: mov  w23, #0xffff8030
    1c24: mov  w24, #0xffffaff8
    1c60: tst  w1, w24                     ; ~0xffffaff8 = 0x00005007
    1c64: b.ne 1ce0                        ; 有越界位 -> 非法
    1c74: cmp  w1, #0x4, lsl #12           ; inherit == 0x4000 ?
    1c78: b.eq 1cac                        ; 是 -> 跳过 "permset != 0" 检查
```

| 字母 | bit | 值 | 含义 |
|---|---|---|---|
| `s` | 0 | `0x0001` | self only |
| `f` | 1 | `0x0002` | file |
| `d` | 2 | `0x0004` | dir |
| `n` | 12 | `0x1000` | no propagate |
| — | 14 | `0x4000` | **exclude（ACE 被排除）标记**；`valid()` 特例放行 |

合法 inherit 掩码 = `0x5007`（bit 0,1,2,12,14）。bit14 单独被 `valid()` 特殊对待，也是 `to_text` 判定 exclude ACE 的依据：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x23bc --stop-address=0x23d0 libtrimacl.so
    23bc: bl   1700 <trimacl_get_inherit@plt>
    23c0: tbnz w0, #14, 2688               ; inherit & 0x4000 -> exclude 渲染分支
```

### 5.7 「exclude ACE」的精确构造

`trimacl -m e file` 与 `parse_ace` 的 `e` 分支产生完全相同的值：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x3144 --stop-address=0x3180 trimacl
0000000000003144 <parse_modify_params(char*, trim_ace_t&)+0x144>:
    3144: mov  x2, #0x4
    3148: mov  w0, #0xffffffff             ; qualifier = -1
    314c: movk x2, #0x1, lsl #16           ; x2 = 0x0000000100000004
    3150: mov  w1, #0x4000                 ; inherit = 0x4000
    3154: str  x2, [x23]                   ; trim_ace_t+0x00 = 4 (tag=everyone) ; +0x04 = 1 (permset)
    3158: strh w1, [x23, #8]               ; inherit
    315c: str  w0, [x23, #12]              ; qualifier = 0xFFFFFFFF
```

（`libtrimacl.so` 的 `parse_ace 0x2140` 是同一份代码。）

→ **exclude ACE** = `tag=4 (everyone)`, `type=0`, `permset=1`, `inherit=0x4000`, `qualifier=0xFFFFFFFF`，
再由 `trimacl_set_*` 打包成 20 字节记录。渲染为 `<exclude inheritance permissions>`（`.rodata` `0x4a0`）。

### 5.8 CLI 语义（`-b` / `-x` / `-m`）

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2310 --stop-address=0x23d4 trimacl
    2310: mov  x2, x23                     ; optstring = 0x5c80 = "bx:m:"
    231c: bl   1fe0 <getopt@plt>
    2320: cmn  w0, #0x1                    ; 结束
    2324: b.eq 23fc
    2328: cmp  w0, #0x6d                   ; 'm'
    232c: b.eq 2394                        ; -> parse_modify_params
    2330: cmp  w0, #0x78                   ; 'x'
    2334: b.eq 23b4
    2338: mov  w22, #0xffffffff            ; ★ 默认 -1
    233c: cmp  w0, #0x62                   ; 'b'
    2340: b.eq 2310                        ; -b: 回到 getopt（w22 保持 -1）
    ...
    23b4: ldr  x0, [x0]
    23c8: bl   20c0 <strtoul@plt>
    23cc: mov  w22, w0                     ; -x <n>: w22 = n
```

分支消费点（实测）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x23fc --stop-address=0x2430 trimacl
    23fc: adrp x23, 1f000
    2400: ldr  x23, [x23, #4024]          ; &optind
    2404: ldr  w0, [x23]                  ; w0 = optind
    2408: cmn  w22, #0x1                  ; w22 == -1 ?
    240c: b.eq 244c                       ; -> -b 分支
    2410: cmp  w22, #0x0
    2414: b.le 24a0                       ; w22 <= 0 -> 打印/无修改分支
    2418: cmp  w20, w0
    241c: b.le 247c                       ; 缺文件参数 -> 报错
    2420: ldr  x0, [x21, w0, sxtw #3]
    2424: bl   1f10 <trimacl_get_file@plt> ; -x: 先读出现有 ACL
    242c: cbnz x0, 25e4
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x244c --stop-address=0x2474 trimacl
    244c: cmp  w20, w0                     ; -b 分支
    2454: ldr  x0, [x21, w0, sxtw #3]
    2458: mov  x1, #0x0                    ; ★ acl = NULL
    245c: bl   20e0 <trimacl_set_file@plt> ; set_file(path, NULL) -> removexattr
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x25e4 --stop-address=0x2608 trimacl
    25e4: sub  w1, w22, #0x1               ; ★ 1-based -> 0-based
    25e8: bl   1f90 <trimacl_get_entry@plt>
    25f4: bl   1ff0 <trimacl_delete_entry@plt>
    2604: bl   20e0 <trimacl_set_file@plt> ; 写回
```

- `-b` = 删除**全部** ACE：`w22` 保持 `-1` → `trimacl_set_file(path, NULL)` → `removexattr("system.trim_acl")`
- `-x <N>` = 按**下标（1-based）**删除第 N 条 ACE：`index = N - 1`，先 `trimacl_get_file` 读出现有 ACL，`trimacl_delete_entry` 后 `trimacl_set_file` 写回
- `-m <spec>` = 增改一条 ACE
- 无选项 = 打印现有 ACL

**「打印」路径走的是内核魔数接口，不是 `getxattr`**（重要）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x265c --stop-address=0x26b0 trimacl
    265c: ldr  x0, [x21, w0, sxtw #3]      ; argv[optind]
    266c: bl   2200 <realpath@plt>         ; ★ 先 realpath 成绝对路径
    267c: bl   21e0 <trimacl_get_file_all@plt>  ; ★ 走 cmd 0xFFFFABB8（见 §4.4）
    26b0: bl   1df0 <trimacl_get_entry_count@plt>
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x2688 --stop-address=0x26ac trimacl
    2694: bl   21a0 <stat64@plt>
    269c: ldr  w0, [sp, #208]              ; st_mode
    26a0: and  w0, w0, #0xf000             ; S_IFMT
    26a4: cmp  w0, #0x4, lsl #12           ; S_IFDIR
    26a8: cset w28, eq                     ; 是目录 -> 展示 default ACE
```

→ 即：**「列出现有 ACL」用 `faccessat(0xFFFFABB8, ...)` 取「完整/有效 ACL」，而不是 `getxattr("system.trim_acl")`**；只有 `-b` / `-x` / `-m` 三个写路径才用 `getxattr`/`setxattr`/`removexattr`。
**【推测】** `*_all` 变体返回的是「含继承展开的有效 ACL」，而 xattr 只是「本对象直接存储的 ACL 条目」。理由：`trimacl_get_file_all` 走独立的内核命令，且 `trimacl_get_inherit` 的存在说明条目带继承属性、需要在读取侧展开。**两者的确切差异需内核侧确认。**

---

## 6. 回收站（trashbin）

> 本节是**独立验证**，与并行的 `TRASHBIN-notes.md` 子任务互补。

### 6.1 `#recycle` 目录名

```
$ grep -rl --binary-files=text "#recycle" /home/xiaoabiao/.cache/fnnas/rootfs/usr/trim
usr/trim/bin/trim_app_center
```

**`#recycle` 在 `usr/trim` 树中只出现于 `trim_app_center`**。`filemanager` / `trashbind` / `share_service` **未找到** `#recycle`。
**未找到** `.@trash`、`.trim_trashbin`、`@Recycle` 等其它回收站目录名。

### 6.2 回收站相关 xattr

```
$ strings -a -t x usr/trim/bin/trashbind | grep -E "^ *[0-9a-f]+ (user|/dev)"
   5440 user.trim-trashbin-record
   5468 /dev/trim-trashbin
```

`filemanager` 另外有 `user.trashbin`（`0x25278`）与 `user.trim-team-trashbin-access`（在 `0x25xxx`）。

### 6.3 内核侧访问方式：字符设备 + `read()` 流（**不是 ioctl**）

`trashbind`（**未 strip**，`main` 在 `0x1c40`）的关键函数：

```
$ nm trashbind | grep -E " T _Z" | head
0000000000001c40 T main
0000000000001fe0 T _Z8do_writeiPKcm
0000000000002060 T _Z28get_trash_file_relative_pathPKci
00000000000020b0 T _Z16parse_trash_pathPKcPcS1_S1_S1_
0000000000002240 T _Z11rename_selfPKc
00000000000022f0 T _Z16set_trash_recordPKcj
0000000000002360 T _Z24trashbin_make_parent_dirPKcS0_S0_j
00000000000025e0 T _Z14process_packetiP21trim_trashbin_request
0000000000005204 T _Z13decode_base64PKciPh
0000000000005110 T _Z13encode_base64PKhiPc
```

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1c74 --stop-address=0x1d20 trashbind
0000000000001c40 <main>:
    1c74: adrp x0, 5000
    1c78: add  x0, x0, #0x460              ; 0x5460 = "/"
    1c7c: bl   1a30 <chdir@plt>            ; chdir("/")
    1ca4: mov  w1, #0x2                    ; O_RDWR
    1ca8: adrp x0, 5000
    1cac: movk w1, #0x8, lsl #16           ; w1 = 0x00080002 = O_RDWR | O_CLOEXEC
    1cb0: add  x0, x0, #0x468              ; 0x5468 = "/dev/trim-trashbin"
    1cb8: bl   1860 <open@plt>
    1cbc: mov  w23, w0
    1cc0: tbnz w0, #31, 1e84               ; 打开失败 -> 退出
    ...
    1cf0: mov  x2, #0x40000                ; 每次最多读 256 KiB
    1cf4: add  x1, x21, x19
    1cf8: sub  x2, x2, x19
    1cfc: mov  w0, w23
    1d00: bl   1910 <read@plt>             ; ★ read(fd, buf+consumed, 256K-consumed)
    1d04: cmp  w0, #0x0
    1d08: b.le 1e08
    1d0c: add  w20, w20, w0                ; 累计已读字节
    1d1c: cmp  w20, #0x4
    1d20: b.gt 1d34                        ; < 5 字节 -> 继续读
```

**包分帧（实测）**：`read()` 返回的是一串长度前缀帧，首 4 字节即整包长度：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1d34 --stop-address=0x1d58 trashbind
    1d34: ldr  w3, [x21, w28, sxtw]        ; ★ req->size @ +0x00
    1d38: add  x19, x21, w28, sxtw
    1d3c: sub  w2, w20, w28
    1d48: cmp  w2, w3                      ; 剩余字节 < 包长 ?
    1d4c: b.cc 1dd8                        ; 是 -> 等下一次 read
    1d50: add  w28, w28, w3                ; 前进 size 字节
    1d54: bl   25e0 <process_packet(int, trim_trashbin_request*)>
```

`process_packet` 里对请求字段的访问（实测偏移）：

```
$ aarch64-linux-gnu-objdump -d -C --start-address=0x1d58 --stop-address=0x1dc4 trashbind
    1d60: ldr  w3, [x19, #20]              ; ★ req+0x14 u32
    1d68: add  x2, x2, #0x480              ; 0x5480 = "/proc/%u/comm"
    ...
    1da8: ldur x3, [x19, #4]               ; ★ req+0x04 u64
    1db0: ldr  w4, [x19, #12]              ; ★ req+0x0C u32
    1db4: add  x7, x19, #0x34              ; ★ req+0x34 (内联字符串?)
    1db8: ldr  w5, [x19, #20]              ; ★ req+0x14 u32
```

**实测可见的 `trim_trashbin_request` 字段偏移**（**字段名一律未知，不编造**）：

```c
struct trim_trashbin_request {   // 大小未测出
    uint32_t size;      // +0x00  整包长度（用于分帧），实测
    uint64_t unknown04; // +0x04  
    uint32_t unknown0c; // +0x0C
    uint32_t unknown14; // +0x14  （用于 /proc/%u/comm）
    /* ... */
    char     unknown34[]; // +0x34  （疑似路径字符串，作为指针/内联使用）
};
```

`/proc/%u/comm` 说明内核推送的请求会带 **pid/uid**，`trashbind` 据此把文件移入发起者自己的回收站。

**结论**：`trim_trashbin` 的**内核→用户态**通道是字符设备 `/dev/trim-trashbin`（**注意是连字符，与内核模块名 `trim_trashbin` 的下划线不同**）的 `read()` 字节流，采用 4 字节长度前缀分帧；用户态 `trashbind` 负责真正搬文件并写 `user.trim-trashbin-record` xattr。
**未找到** `/proc/trim*`、`/sys/module/trim_trashbin/*`、`/sys/fs/trimafs/*` 等 procfs/sysfs 接口。

### 6.4 trim_trashbin 是编入内核的（无 .ko 文件）

```
$ grep -i trim usr/lib/modules/6.18.18-trim/modules.builtin
kernel/fs/trim_trashbin/trim_trashbin.ko

$ find . -name "*trimafs*" -o -name "*trashbin*.ko"
(无 .ko 文件)
```

→ `trim_trashbin` **内建（built-in）**：设备节点必须由内核在启动时创建，或由 udev 按 `modules.devname` 创建。
**注意**：`usr/lib/modules/6.18.18-trim/modules.builtin` 中**没有** `trimafs` 条目，且全 rootfs 找不到 `trimafs.ko` → **trimafs 也没有独立模块，同样编入内核 vmlinuz**。
**【推测】** trimafs 是编进 `vmlinuz-6.18.18-trim` 的（`modules.builtin` 只列了 `trim_trashbin`，说明 trimafs 可能是 vmlinuz 里直接编译进去而非走 `fs/` 的 Kbuild 条目，或整棵树都是 vendor 补丁）。**需由内核侧报告确认。**

---

## 7. 其它内核接口依赖（私有面清单）

### 7.1 已实测确认的私有面

| 接口 | 形态 | 引用者 | 证据 |
|---|---|---|---|
| fstype `trimafs` | `mount -t trimafs trimafs /fs` | `triminit` | §1.2 / §1.3 |
| 挂载点 `/fs` | 目录，mode 0000 + immutable | `triminit`, `share_service` | §1.4, §2.1 |
| 存储卷 `/vol<n>` | 目录（`/vol00`…`/vol02`, `/vol1`…`/vol99`） | `share_service`, `trim_file_monitor` | §2.2 |
| xattr `system.trim_acl` | VFS xattr（`system.` 命名空间） | `libtrimacl.so` | §3.2 |
| xattr `user.is_trimacl` | xattr | `filemanager` | §3.4 |
| xattr `user.trim-share` 等 | xattr | 多个 | §3.5 |
| xattr `trusted.trim_team_id` | xattr | `libquota.so.0.2` | §3.5 |
| 字符设备 `/dev/trim-trashbin` | `open(O_RDWR\|O_CLOEXEC)` + `read()` 流 | `trashbind` | §6.3 |
| 魔数 `faccessat` ABI | `0xFFFFABAE`…`0xFFFFABB8` | `libtrimacl/libnperm/libnfile/libndev`, `trimtools` | §4.1–4.5 |
| `/sys/fs/bpf/trim/fw` | bpffs 路径 | `usr/trim/bin/bpf/`（fnOS eBPF 防火墙） | 见下 |

```
$ grep -rhoE "/(dev|proc|sys)/[A-Za-z0-9_/*.-]*trim[A-Za-z0-9_/*.-]*" usr/trim --binary-files=text | sort -u
/dev/trim-trashbin
/sys/fs/bpf/trim/fw
```

`/sys/fs/bpf/trim/fw` 是 fnOS 自建 eBPF 防火墙 pin 点（`usr/trim/bin/bpf/` 目录 + `usr/trim/bin/sysdiag`）。
**注意**：`/sys/module/...` 形式的 fnOS 私有模块参数**未找到**；
`/proc/trim*` **未找到**。

### 7.2 标准接口（非私有，列出以免误判）

| 接口 | 引用者 | 说明 |
|---|---|---|
| `FS_IOC_GETFLAGS` `0x80086601` / `FS_IOC_SETFLAGS` `0x40086602` | `trashbind` (`util::chattr_remove_i_a`) | 上游通用 ioctl |
| `system.posix_acl_access` / `_default` | `filemanager` | 上游 POSIX ACL xattr |
| `security.capability` | `smbftpd` | 上游 capability xattr |
| `acl_get_file` / `acl_set_file` / `acl_free` (libacl) | `trashbind` | 上游 POSIX ACL 库 |
| `/sys/block/%s/%s`, `/sys/class/pci_bus/...` | `libndev.so` | 上游 sysfs |
| `/etc/mtab` → `/proc/self/mounts` | `triminit` | 上游 |
| `/run/trim_disk_power_state.sock`, `/run/trim_liveupdate.pid` | `libndev.so` | fnOS 私有**用户态** IPC（不是内核接口） |

### 7.3 需要在自编译内核上补齐的最小集合

1. **`trimafs` 文件系统**：支持 `mount -t trimafs trimafs /fs`，且**不需要任何 mount options**。这是最容易的一环 —— 可以先用一个最小的 `kern_mount`/ramfs 风格实现顶住。
   （内核已实现 `trimafs_fs_parameters`/`parse_param`，说明**选项是支持的，只是 fnOS 不传**。）
2. **`system.trim_acl` xattr handler**：内核必须接受在 trimafs 与各真实卷（btrfs/xfs/ext4）上读写 `system.trim_acl`。
   *备选绕过*：patch `libtrimacl.so` 里的单个字符串常量 `system.trim_acl` → `user.trim_acl`，即可在标准内核上用 `user.` 命名空间跑（成本极低，但要同步 patch 所有硬编码该名的二进制，目前只有 `libtrimacl.so` 引用它）。
3. **魔数 `faccessat` 分发**：`0xFFFFABAE`…`0xFFFFABB8` 共 10 个在用命令。
   *绕过难度*：高 —— 需要 hook `faccessat2`(439) 入口按 dirfd 分发。**但** 只有 4 个库 + 1 个二进制用 `libtrimacl/libnperm` 的封装，如果选择不用这些权限 API，可以整体绕开。
4. **`/dev/trim-trashbin` 字符设备** + `trim_trashbin_request` 分帧协议：缺失时 `trashbind` 直接 `open()` 失败退出，**回收站功能整体失效但系统可启动**。
5. `trimafs` 的 **symlink 语义**：`share_service` 用普通 `symlink(2)` 在 `/fs/<uid>/` 下建链接，因此 trimafs 必须把它当普通符号链接处理并能被内核正确解析（**不要求 trimafs 实现 symlink —— 若无 trimafs，直接用 `/fs` 当普通目录 + 真 symlink 大概率也能让共享视图工作**，这是最省事的替代方案）。

---

## 9. 内核侧交叉验证（使用同项目已有的内核产物）

> 本节使用 `/home/xiaoabiao/.cache/fnnas/re-6.18/` 下**已存在**的 `vmlinuz-6.18.18-trim` / `System.map-6.18.18-trim` / `config-6.18.18-trim`
> 做交叉验证，**不是**我自己的二进制分析结论，但能强力佐证上文用户态发现。已明确标注。

### 9.1 trimafs 确实编入 vmlinuz，且**原生支持 symlink**（佐证 §2.1）

```
$ grep -oE "trimafs[a-z_0-9]*" System.map-6.18.18-trim | sort -u
trimafs_alloc_inode          trimafs_free_inode           trimafs_readdir
trimafs_create               trimafs_gen                  trimafs_readlink      ★
trimafs_dentry_delete        trimafs_get_ancestor_mnt  ★  trimafs_rename
trimafs_dentry_operations    trimafs_get_inode            trimafs_rmdir
trimafs_dentry_release       trimafs_get_inode_acl        trimafs_set_acl
trimafs_destroy_cachep       trimafs_get_link          ★  trimafs_setattr
trimafs_destroy_inode        trimafs_get_tree             trimafs_show_options
trimafs_dir_close            trimafs_getattr              trimafs_statfs
trimafs_dir_inode_operations trimafs_init_cachep          trimafs_symlink       ★
trimafs_dir_lseek            trimafs_init_fs_context      trimafs_unlink
trimafs_dir_open             trimafs_inode_cachep         trimafs_fill_super
trimafs_dir_operations       trimafs_kill_sb              trimafs_lookup
trimafs_drop_inode           trimafs_listxattr            trimafs_lookup_dentry
trimafs_encode_fh            trimafs_mkdir                trimafs_mknod
trimafs_enable_debug_info    trimafs_mnt_want_write    ★  trimafs_mmu_get_unmapped_area
trimafs_export_ops           trimafs_page_symlink_inode_operations  ★
trimafs_fh_to_dentry         trimafs_parse_param          trimafs_permission
trimafs_file_inode_operations trimafs_fs_parameters       trimafs_fs_type
```

**三条关键佐证**：

1. **`trimafs_symlink` / `trimafs_readlink` / `trimafs_get_link` / `trimafs_page_symlink_inode_operations` 全部存在**
   → 证实 §2.1 的用户态发现（`share_service` 用普通 `symlink(2)` 往 trimafs 写目录项）。trimafs 的目录项**就是 symlink**。
2. **`trimafs_get_ancestor_mnt` / `trimafs_mnt_want_write`**
   → trimafs 会访问「祖辈挂载」的 `vfsmount`，即它**把自己解析/委派到底层真实卷的挂载上**。这正是 `/fs/...` 能透出 `/vol<n>/...` 内容的机制。
3. **`trimafs_fs_parameters` / `trimafs_parse_param` / `trimafs_show_options`**
   → trimafs 使用**新版 mount API（`fs_context`）**，并且**实现了参数解析**。
   **即内核支持挂载选项，但 fnOS 用户态一个都不传**（§1.3 的硬结论得到呼应）。

### 9.2 `/dev/trim-trashbin` 确实是字符设备 + `read()` 流（佐证 §6.3）

```
$ grep -iE "trim_trashbin" System.map-6.18.18-trim
ffff80008072c5d8 t trim_trashbin_open
ffff80008072c640 t trim_trashbin_release
ffff80008072c6e8 T trim_trashbin_processing_set_comp
ffff80008072c7a4 t trim_trashbin_write
ffff80008072ca64 t trim_trashbin_read          ★
ffff80008072cce8 T trim_trashbin_processing_set_comp_all
ffff80008072cd74 T trim_trashbin
ffff800081200110 d trim_trashbin_fops          ★ 字符设备 file_operations
ffff80008174a7f0 t trim_trashbin_init
ffff8000817896bc t trim_trashbin_cleanup
ffff80008188f018 d __initcall__kmod_trim_trashbin__757_343_trim_trashbin_init6
ffff800081fdc9e0 b trim_trashbin_cdev
ffff800081fdca48 b trim_trashbin_devid
ffff800081fdca50 b trim_trashbin_class
ffff800081fdce60 B trim_trashbin_request_serial   ★ 请求序号计数器
```

- `trim_trashbin_fops` 带 `_read`/`_write`/`open`/`release` → **字符设备**，与 §6.3 中 `trashbind` 的 `read()` 循环完全吻合。
- `trim_trashbin_cdev` / `trim_trashbin_devid` / `trim_trashbin_class` → 用 `cdev_add` + `class_create` 建 `/dev/trim-trashbin`。
- `trim_trashbin_request_serial` → **确认 `trim_trashbin_request` 里有 serial 字段**（与 §6.3 里 `+0x04 u64` 的用法一致，但**该 8 字节是否就是 serial 未被证实**，此处只是命名上的呼应）。
- `trim_trashbin_processing_set_comp[_all]` → 用户态处理完后要**回写完成状态**（`do_write` / `trim_trashbin_write`）。

### 9.3 ⚠️ 关键未解问题：**`system.trim_acl` 这个字符串不在内核镜像里**

```
$ python3 -c "
d=open('vmlinuz-6.18.18-trim','rb').read()
for p in [b'system.trim_acl',b'trim_acl',b'trimacl',b'trimafs']:
    i=d.find(p); print(p,'->', i if i>=0 else 'NOT FOUND')
"
b'system.trim_acl' -> NOT FOUND
b'trim_acl'        -> NOT FOUND
b'trimacl'         -> NOT FOUND
b'trimafs'         -> 18874048
```

```
$ python3 - (遍历 usr/lib/modules/6.18.18-trim 全部 .ko 与元数据，字节级搜索)
./modules.builtin.modinfo ['trim_trashbin']
./modules.builtin        ['trim_trashbin']
```

→ **`trim_acl` 这个字面量既不在 `vmlinuz`，也不在任何 `.ko` 里。**

而内核确实有 ACL/权限钩子（但命名不同）：

```
$ grep -iE "trim.*acl|acl.*trim" System.map-6.18.18-trim
ffff8000803fe028 t trim_check_acl
ffff8000803fe138 t trim_access_check_acl
ffff800080480adc T trim_access_posix_acl_permission
ffff800080480c60 T trim_access_acl_permission
ffff800080480d80 T trim_acl_permission
ffff80008072a85c T trimafs_set_acl
ffff80008072b620 T trimafs_get_inode_acl
```

`vmlinuz` 里 ACL 相关的字符串只有标准那套：

```
$ python3 - (提取所有含 'acl' 的字符串)
b'system.posix_acl_access'
b'system.posix_acl_default'
b'6  trimafs_get_inode_acl, ret: %p'      ← trimafs 调试日志
b'6trimafs_get_inode_acl, ino: %lu'
b'6trimafs_set_acl, ino: %lu'
b', acl'   b',acl'   b',noacl'
b'ACLock'  b'aclk_av1' ...                ← 无关（Rockchip 时钟）
```

以及 VFS 的标准前缀宏实例：

```
$ python3 - (取 'system.\x00' 的上下文)
offset 21957792
b'...seq_file\x00fs/seq_file.c\x00\x00system.posix_acl_access\x00system.posix_acl_default\x00\x00\x00\x00\x00\x00\x00\x00system.\x00security.capability\x00...'
```

（这个裸 `"system."` 是上游 `XATTR_SYSTEM_PREFIX` 宏的实例，**不是** trimafs 的 handler 前缀。）

**这带来三种可能，本报告无法从用户态证据判定，必须由内核侧解决：**

| # | 假设 | 说明 |
|---|---|---|
| A | fnOS **patch 了 VFS 的 xattr 名字解析**（`xattr_resolve_name` / `__vfs_getxattr`），对 `system.trim_acl` 特判后转给 trimafs 的 ACL 代码 | 与「内核里没有该字面量」相容，但需要在反汇编里找到特判点 |
| B | trimafs 的 `s_xattr` 注册了一个**空前缀 handler**，内部按后缀分派；`trim_acl` 字面量被优化/合并掉了 | 需要读 `trimafs_fs_type` → `s_xattr` 指针指向的 handler 表 |
| C | **`system.trim_acl` 这条 xattr 路径在 fnOS 上根本不生效**，ACL 读写实际全部走**魔数 `faccessat` `0xFFFFABB8`**（§4.4） | 佐证：`trimacl file`（唯一的「读」命令）**就是走 `0xFFFFABB8`**，而不是 `getxattr`（§5.8 实测）；`getxattr("system.trim_acl")` 只在 `-x`/`-m` 写路径与 `trimacl_get_fd` 里出现 |

**我给内核侧的建议排查顺序**：
1. 读 `trimafs_fs_type`（`0xffff800081e35a68`，`d` 段）→ `struct file_system_type` → 找到 `trimafs_init_fs_context`（`0xffff800080729efc`）→ 看 `fs_context_operations`（`trimafs_context_ops`，`0xffff8000811ff960`）→ `get_tree` 里注册的 `s_xattr`。
2. 反汇编 `trimafs_get_inode_acl`（`0xffff80008072b620`）/ `trimafs_set_acl`（`0xffff80008072a85c`），确认它们操作的是 `struct posix_acl` 还是 fnOS 自定义的 20 字节记录（§5.3 的格式）。
   - 若为 `struct posix_acl` → 它们服务 `system.posix_acl_access/default`（SMB/NFS 兼容层），与 `system.trim_acl` 无关 → 支持假设 A/B。
   - 若为 20 字节记录 → 它们就是 TrimACL 本体 → 支持假设 C（xattr 名只是壳）。
3. 在 vmlinuz 里找 `xattr_resolve_name` 或其内联点，看是否被 patch。

**无论哪种假设成立，对自编译内核的工程含义都是**：`libtrimacl.so` 的 `system.` xattr 路径（5 个函数）与魔数 `faccessat` 路径（3 个命令）是**两套可独立取舍的接口**；魔数路径是「读」的主路径。

---

## 10. 未找到 / 不确定项（明确声明）

| 项 | 状态 |
|---|---|
| `mount(2)` 的 `flags` 具体数值 | **未测出**。挂载走 `system("mount ...")`，flags 由 util-linux 决定，不在 `triminit` 中。 |
| trimafs 的 `data`/options | **实测为空**（没有 `-o`）。这是硬结论，非「未找到」。 |
| `trimafs.ko` | **不存在**（全 rootfs 无该文件）。已由 §9.1 用 `System.map-6.18.18-trim` 证实 **trimafs 符号在 vmlinuz 内**，即编入内核。`modules.builtin` **只列了** `trim_trashbin`，未列 `trimafs`。 |
| **`system.trim_acl` 的内核侧接线** | **未解**。该字面量**不在 vmlinuz 也不在任何 .ko**（§9.3 字节级搜索）。三种竞争假设已列出，需内核侧判定。 |
| `0xFFFFABB4`（−21580） | **在 `usr/trim` 全树中未出现**，用途未知。 |
| `/proc/trim*`、`/sys/module/trim*/parameters/*` | **未找到**。 |
| `trusted.trimacl` / `user.trimacl` | **不存在**。实际名是 `system.trim_acl`。 |
| ACL v2 与 v1 的区别 | **不存在版本差异**：xattr 头部 u32 实测恒为 `1`，读侧不校验；`trimacl -x2` 的 `2` 是**ACE 下标（1-based）**而非版本号。 |
| `trim_ace` 的 `+0x02` / `+0x0A` 字段 | 偏移与大小**实测确定**，语义**未知**，未编造字段名。 |
| `trim_trashbin_request` 完整布局 | 仅测出 `+0x00 size`、`+0x04`、`+0x0C`、`+0x14`、`+0x34`，其余未知。内核侧有 `trim_trashbin_request_serial`，但**未证实它就是 `+0x04`**。 |
| 通过寄存器间接传入的 ioctl request | **未穷尽**（本报告只断言立即数常量）。 |
| trimafs 中 symlink 的目标文本格式 | **未直接读出**（未见 `readlink` + 拼接的格式化串）。`CreateShareFolder` 的 `target` 实参由上层传入。 |
| `user.is_trimacl` 的取值语义 | **未找到**取值说明字符串。 |
| `/fs/<uid>/` 的确切目录层级 | **【推测】**为 `/fs/<uid>/<sharename>` → symlink 到 `/vol<nn>/<real>`。理由：`/fs/%u/nfs` 模板 + `CreateShareFolder` 用 symlink（已由 §9.1 的 `trimafs_symlink`/`readlink` 佐证）+ `GetUidFromMountedPath`/`GetUserMountMap` 的存在。 |

---

## 11. 附录：关键地址速查

### `triminit`（未 strip）

| 符号 | 地址 | 说明 |
|---|---|---|
| `main` | `0xb2e0` | 入口，含 `mount_trimafs()` 调用点 `0xb700` |
| `mount_trimafs()` | `0xd2a0` | trimafs 挂载 |
| `is_volume_mounted` | `0xc8e0` | 解析 `/etc/mtab` |
| `kernel_set_external_disk_access` | `0xda60` | 调 `libndev.so` 的 `set_external_disk_access` |
| `util::fork_execvp` | `0x38804` | 实为 `popen_read2` 包装 |
| `init_core` | `0xdaf0` | 建 `/coredumps`，写 core_pattern |
| 字符串 `mount -t trimafs trimafs /fs` | `0x39dc8` | **核心** |
| 字符串 `/fs` | `0x39db8` | 挂载点 |
| 字符串 `chattr` / `-i` / `+i` | `0x39908` / `0x39910` / `0x39dc0` | immutable 控制 |
| 字符串 `/etc/mtab` | `0x398e8` | |
| 字符串 `triminit` | `0x3a3e0` | `basename(argv[0])` 比对 |
| 字符串 `/usr/trim/etc/removable_permit` | `0x39f58` | external disk access 开关 |

### `libtrimacl.so`（未 strip）

| 符号 | 地址 |
|---|---|
| `is_support_trimacl` | `0x31c0`（cmd `0xFFFFABB2`） |
| `trimacl_get_fd` / `_file` / `l_..._file` | `0x2b50` / `0x2be0` / `0x2c70` |
| `trimacl_set_fd` / `_file` / `l_..._file` | `0x2fe0` / `0x3080` / `0x3120` |
| `__trimacl_get_file_all` | `0x2d00`（cmd `0xFFFFABB8`） |
| `trimacl_from_xattr` / `trimacl_to_xattr` | `0x2a70` / `0x2e14` |
| `trimacl_get_type/tag_type/permset/qualifier/inherit/level` | `0x1bb0/0x1b80/0x1b40/0x1b60/0x1be0/0x1d30` |
| `trimacl_is_ace_excluded` | `0x1d40` |
| `parse_ace` / `trimacl_from_text` / `trimacl_to_text` | `0x2030` / `0x2210` / `0x2340` |
| `parse_permset` / `explain_permset` / `parse_inherit` | `0x1d50` / `0x1e20` / `0x1fb0` |
| 字符串 `system.trim_acl` | vaddr `0x3310` |
| 跳转表（permset 字符） | `.rodata` `0x3320` |
| 字符串 `a:` `d:` `u:` `g:` `e:` `o:` | `0x32e0` `0x32e8` `0x32f0` `0x32f8` `0x3300` `0x3308` |
| strtok 分隔符 `:` | `0x32a0` |

### `libnperm.so`（未 strip）

| 符号 / cmd | 地址 |
|---|---|
| `internal_check_perm` | `0x2010`（cmd `0xFFFFABAE`） |
| `check_perm` / `check_perm_ignore_administrators` | `0x2180` / `0x2170` |
| `trim_access` | `0x2190` |
| `trim_may_delete` | `0x2324`（cmd `0xFFFFABB7`） |
| `trim_get_perm` | `0x24b4`（cmd `0xFFFFABB5`） |

### `share_service`（符号在 `.dynsym`，未 strip）

| 符号 | 地址 |
|---|---|
| `sharing::TrimAFS::TrimAFS(char const*)` | `0x18b1e0` |
| `sharing::TrimAFS::CreateTrimDir(uid, path, mode)` | `0x18e3a0`（`mkdir`+`chmod`+`chown(uid,1001)`） |
| `sharing::TrimAFS::CreateShareFolder(uid, target, link)` | `0x18ea74`（**`symlink`**） |
| `sharing::TrimAFS::AddLinkForUid(uid, ...)` | `0x18eaf0` |
| `sharing::TrimAFS::RemoveLink(uid, ...)` | `0x18e194` |
| 字符串 `/fs/` | vaddr `0x1aab40`（构造器 `+32` 成员） |

### `trimacl` CLI（未 strip）

| 项 | 地址 |
|---|---|
| `main` | `0x22c0` |
| `parse_modify_params` | `0x3000` |
| optstring `bx:m:` | `.rodata` `0x418` |
| 帮助文本（含 type/tag/perm/inherit 全表） | `.rodata` `0xd8` |

### `trashbind`（未 strip）

| 符号 / 项 | 地址 |
|---|---|
| `main` | `0x1c40` |
| `process_packet(int, trim_trashbin_request*)` | `0x25e0` |
| `set_trash_record(const char*, unsigned int)` | `0x22f0` |
| `trashbin_make_parent_dir(...)` | `0x2360` |
| `parse_trash_path(...)` | `0x20b0` |
| `util::chattr_remove_i_a` | `0x4220`（`FS_IOC_GETFLAGS`/`SETFLAGS`） |
| 字符串 `/dev/trim-trashbin` | `0x5468` |
| 字符串 `user.trim-trashbin-record` | `0x5440` |
| 字符串 `/proc/%u/comm` | `0x5480` |

---

*报告生成：基于 `/home/xiaoabiao/.cache/fnnas/rootfs/` 的只读分析；未修改任何 rootfs 文件；未访问网络。*
