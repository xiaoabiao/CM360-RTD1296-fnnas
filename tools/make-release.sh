#!/bin/bash
# make-release.sh —— 一键生成"可刷整合包"并上传到 Releases（GitHub / Gitea）
#
# 生成的整合包里有什么（别人下载解压即可刷）
# ------------------------------------------
#   README-QUICKSTART.md            三步上手
#   firmware/                       全部脚本与文档
#     low-region-38MiB.img.gz       低区镜像（含 bootdelay=3，实测可用）
#     build-images.sh               生成 p1 / p2
#     flash-from-pc.py              电脑端一键刷机（已验证）
#     flash-uboot.cmd               u-boot 手工刷写脚本
#     README.md / RECOVERY.md       指南与灾难恢复
#   tools/tftp-server.py            内置只读 TFTP（u-boot 取镜像用）
#   artifacts/kernel-6.6.54/        现役内核 uImage + DTB + .config + 模块元数据
#   images/p1-256MiB.img.gz         现成的 p1 镜像（省一步生成）
#   MD5SUMS.txt                     包内校验清单
#
# 注意：**p2（fnOS rootfs）不随包分发** —— 那是 fnOS 的版权物，
#       请用 build-images.sh 从官方镜像自行生成（包里的 README 有链接）。
#
# 用法
# ----
#   ./make-release.sh                     # 只生成整合包到 dist/（+ md5）
#   ./make-release.sh --upload-github     # 生成并发布到 GitHub Releases
#   ./make-release.sh --upload-gitea      # 生成并发布到 Gitea Releases（需网络可达）
#   ./make-release.sh --upload-all        # 两个都发
#   TAG=v0.6.0 ./make-release.sh          # 指定 tag/版本
#
# 依赖：tar / gzip / md5sum；上传 GitHub 需要 gh 已登录；上传 Gitea 用 ~/.git-credentials。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DIST="$REPO/dist"
FWMGR="$REPO/firmware"
IMAGES="$FWMGR/images"

FNOS_VER="1.2.0302"
SHA="$(git -C "$REPO" rev-parse --short HEAD)"
TAG="${TAG:-v0.6.0}"
NAME="cm360-fnnos-${FNOS_VER}-${SHA}"
STAGE="$DIST/$NAME"
UPLOAD_GITHUB=0
UPLOAD_GITEA=0

for a in "$@"; do
	case "$a" in
	--upload-github) UPLOAD_GITHUB=1 ;;
	--upload-gitea)  UPLOAD_GITEA=1 ;;
	--upload-all)    UPLOAD_GITHUB=1; UPLOAD_GITEA=1 ;;
	*) echo "未知参数: $a" >&2; exit 1 ;;
	esac
done

say() { echo "$@" ; }

say "=============================================="
say "生成可刷整合包：$NAME"
say "=============================================="

rm -rf "$STAGE"; mkdir -p "$STAGE/firmware" "$STAGE/tools" "$STAGE/artifacts/kernel-6.6.54" "$STAGE/images"

# ── 1) 采集文件 ──────────────────────────────────────────────────────────
say "== 1) 采集内容 =="
cp "$FWMGR/low-region-38MiB.img.gz" "$FWMGR/low-region-38MiB.img.md5" \
   "$FWMGR/build-images.sh" "$FWMGR/flash-from-pc.py" "$FWMGR/flash-uboot.cmd" \
   "$FWMGR/README.md" "$FWMGR/RECOVERY.md" "$STAGE/firmware/"
cp "$REPO/tools/tftp-server.py" "$STAGE/tools/"
cp "$REPO/artifacts/kernel-6.6.54/"* "$STAGE/artifacts/kernel-6.6.54/"
say "   firmware/ + tools/ + artifacts/ ✔"

# p1：没有就用生成器现场做一个才更可靠；有就直接压进来
if [ -f "$IMAGES/p1-256MiB.img" ]; then
	gzip -1 -c "$IMAGES/p1-256MiB.img" >"$STAGE/images/p1-256MiB.img.gz"
	say "   images/p1-256MiB.img.gz（现成镜像）✔"
else
	say "   ! 未找到 firmware/images/p1-256MiB.img —— 包里不含现成 p1，"
	say "     使用者可用 build-images.sh p1 生成（几秒）"
fi

# ── 2) 快速上手文档 ──────────────────────────────────────────────────────
cat >"$STAGE/README-QUICKSTART.md" <<EOF
# CM360 刷机整合包（fnOS $FNOS_VER + 自编译 Linux 6.6.54）

版本：\`$NAME\`（仓库提交 \`$SHA\`）

## 三步上手

\`\`\`sh
# ① 解压并校验
gunzip -k firmware/low-region-38MiB.img.gz
md5sum low-region-38MiB.img        # 与 firmware/low-region-38MiB.img.md5 对比

# ② 生成 p1（内核+DTB，几秒）与 p2（rootfs，需官方镜像）
cd firmware
./build-images.sh p1
./build-images.sh p2 ~/下载/fnos_arm_${FNOS_VER}_*.img.gz   # 官方镜像请自行下载（不随包分发）

# ③ 电脑端一键刷机（自动备份低区 → 起 TFTP → 进 u-boot → 刷入 → 复核）
sudo apt install python3-serial
python3 flash-from-pc.py --layers low,p1,p2 --ssh-user <板子用户>
\`\`\`

## 没有串口 / 想手工刷

见 \`firmware/README.md\` 第 3 节（u-boot + TFTP，附**本板实测的命令差异**：
网络加载是 \`tftp\` 而非 \`tftpboot\`、没有 \`boot\` 要用 \`run bootcmd\`、没有 \`crc32\`）。

## 出问题了

* 起不来 → \`firmware/RECOVERY.md\`（低区布局 / 串口 ROM Monitor 救砖）
* 存储空间建不了 → \`firmware/README.md\` 第 6 节（fnOS 1.2 在 6.6 上的三处坑）

## 校验

本包内所有文件的 md5 见 \`MD5SUMS.txt\`：
\`cd <解压目录> && md5sum -c MD5SUMS.txt\`
EOF
say "   README-QUICKSTART.md ✔"

# ── 3) 包内校验清单 ─────────────────────────────────────────────────────
( cd "$STAGE" && find . -type f ! -name MD5SUMS.txt -print0 | sort -z | xargs -0 md5sum >MD5SUMS.txt )
say "== 2) 包内 MD5SUMS.txt（$(grep -c '^[0-9a-f]' "$STAGE/MD5SUMS.txt") 个文件）=="

# ── 4) 打包 ──────────────────────────────────────────────────────────────
say "== 3) 打包 =="
( cd "$DIST" && tar czf "$NAME.tar.gz" "$NAME" )
( cd "$DIST" && md5sum "$NAME.tar.gz" >"$NAME.tar.gz.md5" )
say "   $(du -h "$DIST/$NAME.tar.gz" | cut -f1)  $DIST/$NAME.tar.gz"
say "   md5: $(cut -d' ' -f1 "$DIST/$NAME.tar.gz.md5")"

# ── 5) 发布到 GitHub ─────────────────────────────────────────────────────
if [ "$UPLOAD_GITHUB" = 1 ]; then
	say "== 4) 发布到 GitHub Releases（tag $TAG）=="
	NOTES="$DIST/release-notes.md"
	cat >"$NOTES" <<EOF
## CM360 刷机整合包 $TAG

fnOS **$FNOS_VER** + 自编译 **Linux 6.6.54**（内核含 fnOS 1.2 兼容补丁）。

**下载 \`$NAME.tar.gz\`，解压后看 \`README-QUICKSTART.md\`，三步即可刷机。**

### 包含
- \`firmware/low-region-38MiB.img.gz\` —— 低区镜像（hwsetting+bootcode+FSBL+BL31+u-boot+env，
  已写入 \`bootdelay=3\`，开机有 3 秒窗口可进 u-boot）
- \`firmware/build-images.sh\` —— 生成 p1（内核+DTB）与 p2（rootfs）
- \`firmware/flash-from-pc.py\` —— **电脑端一键刷机**（内置 TFTP + 串口，含写后回读校验）
- \`tools/tftp-server.py\` —— 纯标准库只读 TFTP
- \`artifacts/kernel-6.6.54/\` —— 现役内核 uImage + 板级 DTB + 完整 .config + 模块元数据
- \`images/p1-256MiB.img.gz\` —— 现成的 p1 镜像

> **不含 p2（fnOS rootfs）**：那是 fnOS 的版权物，请用 \`build-images.sh p2\` 从官方镜像自行生成。

### 已验证
- 电脑端一键刷机**端到端演练通过**：自动进 u-boot → TFTP 载入 → \`mmc write\` →
  \`run bootcmd\` 启动 → 系统正常（存储 \`/vol2\`、面板 200）→ **板上低区 md5 与镜像完全一致**
- 生成器产出的 p1 内核 md5 与仓库 \`artifacts/\` 逐字节一致

### 注意
- 低区镜像**仅适用于同型号板**（CM360 / ds218-cm360 同方案）
- 刷低区前脚本会自动备份；串口救砖流程见 \`firmware/RECOVERY.md\`
EOF
	if gh release view "$TAG" >/dev/null 2>&1; then
		gh release upload "$TAG" "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.md5" --clobber
		say "   已上传到已有 release $TAG ✔"
	else
		gh release create "$TAG" "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.md5" \
			--title "CM360 刷机整合包 $TAG（fnOS $FNOS_VER + 内核 6.6.54）" \
			--notes-file "$NOTES"
		say "   已创建 release $TAG ✔"
	fi
fi

# ── 6) 发布到 Gitea ──────────────────────────────────────────────────────
if [ "$UPLOAD_GITEA" = 1 ]; then
	say "== 5) 发布到 Gitea Releases =="
	CRED="$HOME/.git-credentials"
	API="$(python3 - "$CRED" <<'PY'
import sys, urllib.parse, re
path = sys.argv[1]
try:
    lines = open(path).read().splitlines()
except Exception:
    sys.exit(0)
for ln in lines:
    m = re.match(r"(https?)://([^:]+):([^@]+)@(.+)", ln)
    if not m:
        continue
    scheme, user, pw, host = m.groups()
    host = host.replace("%3a", ":").replace("%3A", ":")
    if "f3322" in host or "192.168.0.53" in host:
        print("%s://%s:%s@%s/api/v1/repos/Xiaoabiao/rtd1296-fnnas" %
              (scheme, urllib.parse.quote(user, safe=""), urllib.parse.quote(pw, safe=""), host))
        break
PY
)"
	if [ -z "$API" ]; then
		say "   ! ~/.git-credentials 里没有 Gitea 凭据，跳过（可在 Gitea 网页手工上传）"
	else
		SAFE_API="$(printf '%s' "$API" | sed 's#://[^@]*@#://***@#')"
		BODY="$(python3 -c "
import json,sys
print(json.dumps({'tag_name':sys.argv[1],'name':'CM360 刷机整合包 '+sys.argv[1],'body':open(sys.argv[2]).read(),'draft':False,'prerelease':False}))" "$TAG" "$DIST/release-notes.md")"
		if timeout 60 curl -s -o /tmp/gitea-rel.json -w '%{http_code}' --noproxy '*' \
			-X POST -H 'Content-Type: application/json' -d "$BODY" "$API/releases" | grep -qE '20[01]'; then
			RID="$(python3 -c "import json;print(json.load(open('/tmp/gitea-rel.json')).get('id',''))" 2>/dev/null)"
			timeout 300 curl -s --noproxy '*' -X POST -H 'Content-Type: multipart/form-data' \
				-F "attachment=@$DIST/$NAME.tar.gz" "$API/releases/$RID/assets?name=$NAME.tar.gz" \
				-o /dev/null -w '   上传附件 HTTP %{http_code}\n'
			say "   Gitea release $TAG 已创建 ✔"
		else
			say "   ! 连接 Gitea 失败（$SAFE_API）—— 多半是宿主机不在 192.168.0.x 网段；"
			say "     等网络可达后重跑：$0 --upload-gitea"
		fi
	fi
fi

say ""
say "完成。产物：$DIST/$NAME.tar.gz"
say "上传 GitHub：$0 --upload-github     上传 Gitea：$0 --upload-gitea"
