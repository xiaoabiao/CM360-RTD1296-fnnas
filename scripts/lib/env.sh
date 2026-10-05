#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# scripts/lib/env.sh —— 全仓库脚本共用的环境定义
#
# 设计原则（为了"别人 pull 下来就能编"）：
#   1. 仓库内**不写死任何绝对路径**（尤其是家目录/用户名）；
#   2. 本机差异全部走 `local.conf`（仓库根，已 gitignore）或同名环境变量；
#   3. 构建产物统一落在 `build/`（gitignore），源码/文档/板级文件才入库。
#
# 覆盖顺序：环境变量 > local.conf > 这里的默认值
#
# local.conf 可写的项（示例见 local.conf.example）：
#   KTREE           内核源码树路径（默认 <repo>/build/kernel）
#   CROSS_COMPILE   交叉工具链前缀（默认 aarch64-linux-gnu-）
#   JOBS            并行编译任务数（默认 留 1 核）
#   BOARD           板名（默认 rtd1296-cm360）
#   SERIAL_DEV      串口设备（默认 /dev/ttyUSB0）
# ─────────────────────────────────────────────────────────────────────
set -o pipefail

# 仓库根 = 本文件往上两级
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT

# 本机配置（可选）
if [ -f "$ROOT/local.conf" ]; then
	# shellcheck disable=SC1091
	. "$ROOT/local.conf"
fi

# ── 板级 ────────────────────────────────────────────────────────────
: "${BOARD:=rtd1296-cm360}"
: "${BOARD_DIR:=$ROOT/boards/$BOARD}"
: "${DTB_NAME:=rtd1296-cm360.dtb}"
: "${DTS_NAME:=rtd1296-cm360.dts}"
export BOARD BOARD_DIR DTB_NAME DTS_NAME

# ── 源码 / 补丁 / 脚本 / 工具 ───────────────────────────────────────
: "${PATCH_DIR:=$ROOT/patches}"
: "${SCRIPTS_DIR:=$ROOT/scripts}"
: "${TOOLS_DIR:=$ROOT/tools}"
: "${EVIDENCE_DIR:=$ROOT/evidence}"
export PATCH_DIR SCRIPTS_DIR TOOLS_DIR EVIDENCE_DIR

# ── 内核树与工具链（★ 本机差异最大的两项）────────────────────────────
# 内核树由 scripts/setup-deps.sh 按锁定的 commit 拉到 build/kernel；
# 也可以把 KTREE 指到自己已有的那棵树（local.conf 里改）。
: "${KTREE:=$ROOT/build/kernel}"
# 交叉工具链前缀：发行版装的写 aarch64-linux-gnu-；
# 用独立打包的工具链时直接给全前缀，例如
#   CROSS_COMPILE=/opt/gcc-aarch64/bin/aarch64-linux-
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
export KTREE CROSS_COMPILE

# ── 构建产物（全部 gitignore）───────────────────────────────────────
: "${BUILD_DIR:=$ROOT/build}"
: "${OUT:=$BUILD_DIR}"
: "${TFTPROOT:=$BUILD_DIR/tftproot}"
: "${LOG_DIR:=$EVIDENCE_DIR/logs}"
export BUILD_DIR OUT TFTPROOT LOG_DIR

# ── 串口（上板 / 救砖用）────────────────────────────────────────────
: "${SERIAL_DEV:=/dev/ttyUSB0}"
: "${SERIAL_BAUD:=115200}"
: "${SERIAL_SESSION:=session02}"
export SERIAL_DEV SERIAL_BAUD SERIAL_SESSION

# ── 交叉编译相关 ────────────────────────────────────────────────────
export ARCH=arm64
: "${JOBS:=$(( $(nproc) > 2 ? $(nproc) - 1 : 1 ))}"
export JOBS

# ── 内核 make 统一入口 ──────────────────────────────────────────────
kmake() { make -C "$KTREE" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE "$@"; }
k66()   { kmake "$@"; }   # 历史别名（早期脚本用 k66 指同一棵树）

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 环境自检 ────────────────────────────────────────────────────────
env_check() {
	[ -d "$KTREE" ] || die "内核树不存在: $KTREE
    → 先跑 scripts/setup-deps.sh 拉取，或在 local.conf 里把 KTREE 指到已有内核树"
	command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || die "找不到交叉编译器 ${CROSS_COMPILE}gcc
    → 装一个（Debian/Ubuntu: apt install gcc-aarch64-linux-gnu），
      或在 local.conf 里把 CROSS_COMPILE 指到自己的工具链"
	mkdir -p "$OUT" "$LOG_DIR"
}

# 内核版本串（给产物命名/校验用）
kernel_release() { make -s -C "$KTREE" ARCH=$ARCH kernelrelease 2>/dev/null | tail -1; }
