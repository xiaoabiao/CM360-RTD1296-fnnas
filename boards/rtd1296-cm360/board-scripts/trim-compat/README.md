# trim-compat —— fnOS 私有内核 ABI 的用户态兼容层

CM360（RTD1296）上跑的是**自编译 6.6.54 内核**，而 fnOS 1.2.x 的用户态依赖
厂商内核里一整套私有接口。缺了它们表现为：面板上传失败、共享文件夹建不出来、
FTP 共享目录进不去、面板删除文件一直转圈、`trim_trashbind` 无限重启。

本目录把这几类接口在**用户态**补齐，不重编内核、不改 fnOS 二进制：

| 组件 | 解决的私有接口 | 修的毛病 |
|---|---|---|
| `trimcompat.c` → `libtrimcompat.so`（LD_PRELOAD） | 魔数 `faccessat(-21586..-21576)` + xattr `system.trim_acl` | 面板上传失败（`file.checkUpload` 返回 errno 9）、共享文件夹建不出来 |
| `cm360-fake-fs.sh` + `cm360-fake-fs.service` | `/fs`（trimafs 伪文件系统） | FTP/WebDAV 共享视图：`[TrimAFS] failed to create '/fs/...'`、FTP 进共享目录失败 |
| `trash-ref.c`（编进同一个 .so） | 魔数 `unlinkat(-7126/-7125)`（回收站/彻底删除） | 面板删除挂死、回收站不可用；`trim_trashbind` 不再需要（安装时 disable） |

原理与证据：`docs/reports/fnos-acl-compat-layer.md`、
`docs/reports/fnos-upload-checkupload-re.md`、
`docs/reports/fnos-trashbin-re.md`，以及 `docs/reports/fnos-6.18-kernel-re/`。

## 安装 / 卸载（板端 root）

```sh
sudo ./install.sh              # 编译（无 gcc 用预编译 .so）+ 安装 + 重启服务 + 自检
sudo ./install.sh --log        # 额外写调试日志 /tmp/trimcompat.log
sudo ./install.sh --uninstall  # 卸载：删 drop-in / 服务 / .so，并恢复服务
```

安装会做这些事：

1. `libtrimcompat.so` 装到 `/usr/local/lib/`，并给
   `trim_main` / `trim_upload` / `filestor_service` / `trim_http_cgi` /
   `share_service` / `trim_app_center` / `trim_trashbind` 等所有链接私有库
   （`libtrimacl`/`libnperm`/`libnfile`/`libquota`）的 fnOS 服务加 systemd
   drop-in `Environment=LD_PRELOAD=...`（应用中心的「推荐存储空间权限」也依赖它）；
2. `cm360-fake-fs.sh` 装到 `/usr/local/lib/`，`cm360-fake-fs.service` 装到
   `/etc/systemd/system/` 并 enable；给 `share_service` 加
   `ExecStartPre=…/cm360-fake-fs.sh once`；
3. 重启相关服务。

## 自检

```sh
# 权限判定（应输出 = 0；不装兼容层是 -1/errno=9 EBADF）
LD_LIBRARY_PATH=/usr/trim/lib ./trim-access-test 1000 /vol1

# /fs 视图与挂载
/usr/local/lib/cm360-fake-fs.sh status

# 面板/上传（在仓库根目录、Windows 上跑；注意 MSYS 路径转换）
export PYTHONIOENCODING=utf-8 MSYS_NO_PATHCONV=1
python tools/fnos-api.py list /vol1/1000
python tools/fnos-api.py check-upload /vol1/1000/1111/probe.bin 1024
python tools/fnos-api.py upload /vol1/1000/1111/probe.bin <本地文件>
```

## 已知限制

- 权限判定已读取 TrimACL（allow/deny 按 user/group/everyone/owner 叠加，命中则优先），但未实现继承位、项目配额与 a:/e: 等高级位语义
  （单用户/家庭够用，多用户细粒度授权需谨慎）。
- `/fs` 兼容层会让 FTP 根目录多一个不可进入的 `vol1` 名字（只给 x 权限）；
  WebDAV/NFS 未实测。
- 回收站/删除由兼容层在用户态完成（目录在 `/vol<v>/<uid>/.@#local/trash/`），
  `trim_trashbind` 依赖 `/dev/trim-trashbin`（厂商内核才有），安装时会被
  `disable`；`--uninstall` 会恢复它。
- **异步 RPC 的终态帧在登录的 main WebSocket 上**：`file.rm` / `file.trash.restore`
  / `file.trash.clear` 的 `taskId`、`result` 推送到 `type=main`；只在 `type=file`
  上等会误判“没有响应”（用 `tools/fnos-rpc-probe.py` 复现）。
- 这是用户态补丁：**重刷 p2 / fnOS 升级后要重新跑 `install.sh`**。
