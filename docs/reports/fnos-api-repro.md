# fnOS 面板 API 复现报告：`file.checkUpload` / `/upload`

**目标**：不依赖浏览器，用脚本复现 fnOS 面板文件管理器的上传链路（登录 → 会话 token → WebSocket RPC →
HTTP 上传），以便在 CM360（RTD1296）自编译内核上反复验证上传 bug 及其修复。

**结论（TL;DR）**

- 面板登录**不是** HTTP REST；`POST /v1/accountapi/login` 不存在（404）。真正的登录是
  `ws://<host>/websocket?type=main` 上的一个 **RSA+AES 加密 JSON-RPC 请求**（方法 `user.login`）。
- 已产出纯标准库脚本 [`tools/fnos-api.py`](../../tools/fnos-api.py)（无第三方依赖，Python 3.8+），
  支持 `login` / `list` / `check-upload` / `upload` / `raw`。登录、`file.ls`、`file.checkUpload`、
  `POST /upload` 全部实测通过。
- 断内核（未打 userspace ABI 兼容 shim）时：**`file.checkUpload` 直接失败** ——
  `{"errno":9,"result":"fail"}`（EBADF，fnOS 私有 magic `faccessat` + `system.trim_acl` ABI 在 stock
  6.6.54 上不认）。面板因此显示通用"上传失败"，**不会**发出 `POST /upload`（nginx 日志为空）。
- 打上 Lead 的 `LD_PRELOAD` userspace 兼容 shim 后：`checkUpload` → `{"uploadName":"….~#0","result":"succ"}`，
  `POST /upload` → **HTTP 200**，落盘文件 **md5/sha256 与本地测试文件完全一致**（1 KiB 与 4 KiB 各验一次）。
- 全程只做少量必要写操作（总计 < 12 KiB 测试流量 + 若干 0 字节暂存文件），测试文件已全部删除；
  未修改任何面板设置/服务。

测试环境：板子 `192.168.1.234:5666`（http；5667 https），fnOS 1.2.0302，内核 `6.6.54-gbe79582cba58-dirty`，
面板资源在板子 `/usr/trim/www/`（本次反编译对象：`assets/index-gFv2FLwJ.js`、`rules-DXQv1JLe.js`、
`constants-BTmVL42d.js`、`useTfaLogin-fDbKf3lx.js`、`login-form-Dr6wCFlL.js`、`oauth-CMFXpWZz.js`）。

---

## 1. 端点一览

| 用途 | 端点 / 方法 | 说明 |
|---|---|---|
| WebSocket（控制面） | `ws://<host>/websocket?type=main` | 登录、`user.authToken`、`util.crypto.getRSAPub`、`util.getSI`、桌面/系统 RPC |
| WebSocket（文件面） | `ws://<host>/websocket?type=file` | `file.*` 文件管理 RPC（`file.ls`、`file.checkUpload`、`file.mkdir` …） |
| WebSocket（其它） | `?type=timer` / `?type=ping` | 系统状态、心跳；协议同上 |
| HTTPS 变体 | `wss://<host>/websocket?...` | 面板走 TLS 时（https:5667）自动使用 |
| 上传数据面 | `POST /upload` | nginx `location /upload` → `unix:/run/trim_upload_srv.socket`（`trimsrv.hdl`）；**不是** WS |
| (旧猜测，已排除) | `POST /v1/accountapi/login` | 404，账户子系统 socket 里没有该路由 |

RPC 帧格式（客户端 → 服务端，单条 text frame）：

```json
{"reqid":"<8hex unix秒><16hex backId><4hex 递增序号>","req":"<method>", ...args}
```

- `backId` 初始为 `0000000000000000`；`user.login` 响应会下发新的 `backId`，之后所有 socket 共用。
- 服务端 → 客户端：同一 `reqid` 的**若干**帧；数据帧可没有 `result`，最后一帧带
  `"result":"succ"|"fail"|"cancel"`（`file.ls` 就是"数据帧 + 结束帧"两帧）。
- 心跳：`{"req":"ping"}` → `{"res":"pong"}`（浏览器 15 s 一次；脚本按需）。
- 除加密登录帧外，所有帧在拿到 `secret` 后都要**签名**（见 §3）。

---

## 2. 登录流程（实测原始报文）

1. 建立 `type=main` WebSocket。
2. 取 RSA 公钥和本连接 `si`（session id，明文请求）：

```json
>> {"reqid":"6ade434900000000000000000001","req":"util.crypto.getRSAPub"}
<< {"pub":"-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuv5N0ZW0TO9q...\n-----END PUBLIC KEY-----\n",
    "si":"72057762645016586","result":"succ","reqid":"6ade434900000000000000000001"}
```

3. 客户端生成随机 32 字符字母数字串作为 **AES-256 密钥**（UTF-8 字节即密钥），随机 16 字节 IV，
   AES-256-CBC + PKCS#7 加密登录 JSON；再用公钥 **RSA PKCS#1 v1.5** 加密那 32 字节密钥串。
4. 发送加密信封（`si` 在密文 JSON 里，`v` 字段只在 https/secure context 下出现）：

```json
>> {"reqid":"...0002","req":"encrypted",
    "iv":"<b64 16B>","rsa":"<b64 256B>","aes":"<b64 AES-CBC 密文>"}
```

其中密文 JSON 明文为：

```json
{"req":"user.login","user":"Xiaoabiao","password":"<redacted>","stay":false,
 "deviceType":"Browser","deviceName":"Windows-Google Chrome","did":"<device-id>",
 "si":"72057762645016586","reqid":"...0002"}
```

5. 响应是**扁平 JSON**（不是嵌套 `data`；`token`/`secret` 等字段与 `reqid`/`result` 同级）：

```json
<< {"uid":1000,"admin":true,
    "secret":"<b64, 已脱敏>","token":"<b64, 已脱敏>",
    "backId":"6ade434900000001","machineId":"07e662dc70bfe152e05b1d191f9f4b24dccf9cfe",
    "result":"succ","reqid":"...0002"}
```

- 本账号**无 TFA**（响应里没有 `isTwofaEnforced`/`isBindTwofaSecret`/`accessToken`），登录一次即完成；
  若启用 TFA，后续走 `user.2fa.loginVerify`（同一 WS，同样加密信封）。
- `stay:false` → 不下发 `longToken`；`fnos-token` 是会话 cookie（`expires:undefined`），
  `fnos-long-token` 是"保持登录"的 30 天 token（本流程未用）。

---

## 3. 会话 / token 机制（3 行）

1. **登录 token**：`user.login` 返回的 `token` = 面板 cookie `fnos-token`；打开文件 socket 后必须立刻发
   `{"req":"user.authToken","token":<token>,"si":<本连接 util.getSI 返回的 si>}`，服务端据此把这条 WS 绑定到会话。
2. **签名密钥**：响应里的 `secret` = 用登录信封同一 AES key/IV 加密的 HMAC 密钥（AES-256-CBC 解密后
   得到原始字节；浏览器把它以 base64 存 `localStorage["fnos-Secret"]`，公钥存 `localStorage["fnos-RSAPub"]`）。
3. **请求签名**：拿到 secret 后所有 RPC 帧（除 `getRSAPub`/`getSI`/加密类请求）发送形式为
   `base64(HMAC-SHA256(secret, json)) + json`（同一个 text frame）；`POST /upload` 的签名是对
   **URL 编码后的 `Trim-Path`** 做同样的 HMAC，放在 `Trim-Sign` 头，token 放 `Trim-Token` 头
   （并附带 `Cookie: fnos-token=<token>`）。设备标识 `did` 存在浏览器 `localStorage["os-device"]`
   （`<ts36>-<rand36>-<rand36>`），脚本持久化到状态文件。

对应的桌面端/RPC 常量（来自 `index-gFv2FLwJ.js`）：
`user.login`、`user.loginIntl`、`user.authToken`、`user.tokenLogin`、`util.crypto.getRSAPub`、`util.getSI`、
`file.ls`、`file.checkUpload`、`file.mkdir`、`file.rm`…（`file.ls` 即任务里说的 `file.list`。）

---

## 4. 文件管理 RPC（实测）

文件 RPC 会把路径**去掉开头 `/`**（浏览器 `path.replace(/^\//,'')`），即 `/vol1/1000` → `vol1/1000`。
`tools/fnos-api.py` 默认行为一致；加 `--keep-absolute` 可保留 `/`。

### 4.1 `file.ls`（命令：`list /vol1/1000`）

```
>> {"reqid":"6ade449b6ade4495000000000001","req":"util.getSI"}
<< {"si":"72057672497430532","result":"succ","reqid":"6ade449b6ade4495000000000001"}
>> {"reqid":"6ade449b6ade4495000000000002","req":"user.authToken","token":"<token>","si":"72057672497430532"}
<< {"result":"succ","reqid":"6ade449b6ade4495000000000002"}
>> {"reqid":"6ade449b6ade4495000000000003","path":"vol1/1000","req":"file.ls"}
<< {"files":[{"name":"1111","uid":1000,"mtim":1792951445,"btim":1792948290,"dir":1}],
    "uver":117502865375232,"reqid":"6ade449b6ade4495000000000003"}
<< {"uver":117502865375232,"reqid":"6ade449b6ade4495000000000003","result":"succ"}
```

注意：先来一条带 `files` 但没有 `result` 的数据帧，再来一条 `result:"succ"` 的结束帧（同一 `reqid`）。

### 4.2 `file.checkUpload`（命令：`check-upload /vol1/1000/1111/<name>.bin 1024`）

**坏内核（无 shim）** —— 由 Lead 做的受控 A/B 抓取（脚本同一条命令，仅 shim 开/关不同）：

```
>> {"reqid":"...","size":1024,"path":"vol1/1000/1111/pre-shim-probe.bin",
    "overwrite":false,"req":"file.checkUpload"}
<< {"errno":9,"result":"fail"}                    # EBADF：magic faccessat / trim_acl 在 stock 6.6.54 上不认
```

`errno:9`（EBADF）来自 fnOS 私有内核 ABI：`faccessat(dirfd=0xFFFFABAE..0xFFFFABB8, ...)` +
`system.trim_acl` xattr 在 stock 6.6.54 上直接失败，`filemanager.hdl` 把该失败作为 checkUpload 的失败
返回。客户端 `Qr()` 映射不到具体文案 → 面板显示通用"上传失败"，并且**不会**发出 `POST /upload`
（与坏内核时 nginx 访问日志里没有 `POST /upload` 一致）。

**打上 shim 后（shim 于 01:51 安装，本报告 01:53 之后抓到的都是 shim 生效状态）**：

```
>> {"reqid":"6ade449b6ade4495000000000003","size":1024,"path":"vol1/1000/1111/probe.bin",
    "overwrite":false,"req":"file.checkUpload"}
<< {"uploadName":"probe.bin.~#0","result":"succ","reqid":"6ade449b6ade4495000000000003"}
```

同一请求用绝对路径 `/vol1/1000/1111/probe.bin` 形状相同（`probe.bin.~#1`/`~#2`，因暂存名递增）。
成功时服务端会在目标目录预分配 **0 字节**暂存文件 `probe.bin.~#N`（`filemanager.hdl` 里
`"%s.~#%llu"` 的断点续传名）。

> `uploadName` 语义（浏览器 `rules-*.js` 的 `vd()`）：拿到 `uploadName` 后，实际上传目标 =
> `dirname(path) + "/" + uploadName`（如 `vol1/1000/1111/probe.bin.~#0`），`Trim-Path` 用这个暂存名；
> 上传完成后 uploadsrv 把它改名为 multipart 里的最终文件名。所以直接用最终路径 POST 是**错的**。
> 如果 `checkUpload` 失败（坏内核的 `errno:9`），`vd()` 直接走错误回调，**根本不会进入 POST 阶段**。

---

## 5. `POST /upload`（实测，打 shim 后）

request headers（脚本实际发送，`Trim-Sign` 为对 `Trim-Path` 的 HMAC）：

```
POST /upload HTTP/1.1
Trim-Path: vol1/1000/1111/probe.txt.~#0
Trim-From: 0
Trim-Overwrite: 0
Trim-Mtim: 1792951452
Trim-Token: <token>
Trim-Sign: <base64(HMAC-SHA256(secret, "vol1/1000/1111/probe.txt.~#0"))>
Cookie: fnos-token=<token>
Content-Type: multipart/form-data; boundary=----fnos-api-...
（multipart 字段名：trim-upload-file，filename=probe.txt）
```

响应：`HTTP 200 OK`，**空 body**（面板只看 HTTP 状态；非 2xx 时按 403/497/498/499/500/596/597/598/599 映射 toast）。

nginx 访问日志（板子 `/usr/trim/nginx/logs/access.log`）：

```
192.168.1.39 - - [26/Oct/2026:02:04:12 +0800] "GET /websocket?type=file HTTP/1.1" 101 222 "-" "fnos-api.py"
192.168.1.39 - - [26/Oct/2026:02:04:12 +0800] "POST /upload HTTP/1.1" 200 0 "-" "-"
```

落盘验证（板子端）：

```
$ stat -c "%n size=%s mtime=%y" /vol1/1000/1111/probe.txt
/vol1/1000/1111/probe.txt size=1024 mtime=2026-10-26 02:04:12.000000000 +0800
$ md5sum    /vol1/1000/1111/probe.txt
46c686658064b84d022cc841831e056b  /vol1/1000/1111/probe.txt
$ sha256sum /vol1/1000/1111/probe.txt
49b2e9cd88b467f0151e53360c85849a187b1d3d63bce2017dcbae14f5c602a8  /vol1/1000/1111/probe.txt
$ head -3 /vol1/1000/1111/probe.txt
fnos-api upload probe line 00 -- 0123456789abcdef
fnos-api upload probe line 01 -- 0123456789abcdef
fnos-api upload probe line 02 -- 0123456789abcdef
```

本地文件 `C:/tmp/fnos/probe.txt`（1024 B）：md5 `46c686658064b84d022cc841831e056b`、
sha256 `49b2e9cd88b467f0151e53360c85849a187b1d3d63bce2017dcbae14f5c602a8` —— **大小、md5、sha256 全部一致**。

测试文件已删除（`probe.txt`、`probe.bin.~#0..2`、`probe-api.bin`）；目录事后为初始状态。

---

## 6. 复现命令（Windows 主机，repo 根目录）

> ⚠️ 在 git-bash/MSYS 下，以 `/` 开头的参数会被自动改写成 Windows 路径（`/vol1/...` →
> `C:/Users/.../vol1/...`），表现为服务端 `errno:4101`。**必须** `export MSYS_NO_PATHCONV=1`；
> 同时本地文件参数要用 Windows 形式（`C:/tmp/fnos/probe.txt`）。

```bash
export PYTHONIOENCODING=utf-8 MSYS_NO_PATHCONV=1

# 0) 登录（结果缓存在 ~/.fnos-api-state.json，0600；--no-cache 强制重新登录）
python tools/fnos-api.py login
# 或直接登录 http-s 版：
python tools/fnos-api.py --https login

# 1) file.list（file.ls）：DEMO 用 /vol1/1000
python tools/fnos-api.py list /vol1/1000

# 2) file.checkUpload（1024 字节目标；会在 1111 目录留下 0 字节暂存文件）
python tools/fnos-api.py check-upload /vol1/1000/1111/probe.bin 1024

# 3) 完整上传（先 checkUpload，再自动按 uploadName 暂存名 POST /upload）
python tools/fnos-api.py upload /vol1/1000/1111/probe.txt C:/tmp/fnos/probe.txt

# 4) 任意原始 RPC（诊断用；自动附加 reqid 并签名）
python tools/fnos-api.py raw '{"req":"util.getSI"}'
python tools/fnos-api.py raw '{"req":"file.ls","path":"vol1/1000"}' --kind file

# 板子上核对
python tools/brd.py sudo 'stat -c "%s" /vol1/1000/1111/probe.txt; md5sum /vol1/1000/1111/probe.txt'
```

脚本要点：

- 纯标准库实现（未 `pip install` 任何东西）：`socket`/`ssl` 手写 RFC6455 WS 客户端、RSA PKCS#1 v1.5、
  AES-256-CBC（PKCS#7）、`hmac`/`hashlib`、`http.client` 上传；Windows 与板子上 python3 均可运行。
- 会话缓存 `${HOME}/.fnos-api-state.json`：`{token, secret, did, machineId, backId}`，避免反复登录
  （面板有 IP 封禁 `errno:131089` / 登录错误计数；本次全程只用了 **2 次**登录）。
- `file_call()` 在收到 `errno:4224`（E_NOT_LOGIN）时会自动重新登录并重放一次。
- 不修改任何配置；`login` 的 `deviceName/did` 只影响"设备列表"里的会话记录。

---

## 7. 断内核 vs 修复后（A/B 对照，给后续修复验证用）

**A/B 对照（Lead 受控实验：卸载 shim → 重启服务 → 跑脚本 → 重装 shim → 再跑）**

| # | shim | 命令 | 原始响应 |
|---|---|---|---|
| 1 | 关 | `--no-cache list /vol1/1000` | `{"files":[{"name":"1111",...}],"result":"succ"}` |
| 2 | 关 | `--no-cache check-upload /vol1/1000/1111/pre-shim-probe.bin 1024` | `{"errno":9,"result":"fail"}` ★ |
| 3 | 关 | （面板/脚本不会继续）`POST /upload` | 未发出（nginx 日志无 `POST /upload`） |
| 4 | 开 | `check-upload /vol1/1000/1111/post-shim-probe.bin 1024` | `{"uploadName":"post-shim-probe.bin.~#0","result":"succ"}` |
| 5 | 开 | `upload … 4096B 文件` | `HTTP 200 OK`（nginx: `"POST /upload HTTP/1.1" 200 0`） |
| 6 | 开 | 板子 `md5sum` 落盘文件 | 与本地 4096B 源文件一致 |

**结论**：

- 坏内核（stock 6.6.54）下失败点是 **`file.checkUpload`**：`errno:9`（EBADF，magic `faccessat`/`trim_acl`
  私有 ABI 不被识别）→ 面板显示通用"上传失败"，客户端**不会**发 `POST /upload`（所以 nginx 日志为空）。
- shim（userspace 模拟该 ABI）装上后：`checkUpload` → `succ`（返回暂存名），`POST /upload` → `200`，
  落盘字节与源文件 **md5/sha256 一致**。
- 注意：本报告 §2–§6 的抓包（01:53 之后）**全部是 shim 已生效状态**；坏内核的 `errno:9` 证据来自
  Lead 的受控 A/B（上表第 2 行）。
- 后续"上传已修复"的回归验证建议直接跑 `upload` 命令并对比 `md5sum`，这是最贴近浏览器行为的判据；
  若只想快速判定内核 ABI 是否兼容，跑 `check-upload` 看是否 `errno:9` 即可（不产生数据面写入）。

---

## 8. 安全 / 清理说明

- 登录 2 次（1 次手工探针 + 1 次脚本，其余复用缓存 token），未触发封禁；未更改账户/面板配置，
  未重启/停止任何服务（shim 装卸与 service 重启均由 Lead 执行）。
- 写入板子的内容仅测试文件（总计 < 12 KiB 数据 + 若干 0 字节暂存文件），均已删除：
  `/vol1/1000/1111/probe.txt`、`probe-api.bin`、`probe.bin.~#0..2`；
  Lead 的 A/B 测试文件也已不在 `/vol1/1000` 下（复核 `find /vol1/1000 -name 'probe*'` 为空）。
- 报告中 `token`/`secret` 已脱敏；实际值在脚本缓存 `~/.fnos-api-state.json`（0600）。
- 反编译用的 JS 与临时脚本只落在 Windows 主机（`C:/tmp/fnos/`），不在仓库里。

---

## 9. 原始抓包文件（Windows 主机 `C:/tmp/fnos/`，非仓库内容）

| 文件 | 内容 |
|---|---|
| `probe1.py` | WS 握手 + `getRSAPub`/`getSI` 探针 |
| `probe2.py` | 手工 RSA+AES `user.login`（第一次成功登录） |
| `probe3.py` | 文件 socket：getSI → authToken → `file.ls` → `file.checkUpload` |
| `login_resp.json` | 登录响应 + 信封 AES key/IV（用于推导 secret） |
| `final_list.txt` / `final_checkupload.txt` / `final_upload.txt` / `final_disk.txt` | §4/§5 的终端原始输出 |
| `index.js` / `rules.js` / `useTfaLogin-*.js` 等 | 从板子 `base64 -w0` 下拉的面板 bundle |
