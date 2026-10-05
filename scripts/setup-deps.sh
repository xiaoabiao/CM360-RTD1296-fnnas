#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# scripts/setup-deps.sh —— 拉取构建依赖（内核源码树）
#
# 本仓库不含内核源码，只含**板级 DTS + 内核补丁 + 配置叠加**。
# 这个脚本把内核树按**锁定的 commit** 拉到 build/kernel，并打好补丁，
# 这样别人 clone 下来就能得到与本项目完全一致的基线。
#
# 用法：
#   ./scripts/setup-deps.sh              # 拉取/更新内核树 + 应用补丁
#   ./scripts/setup-deps.sh --check      # 只检查现有环境够不够
# ─────────────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/env.sh"

# ── 锁定的上游 ──────────────────────────────────────────────────────
KERNEL_REPO="${KERNEL_REPO:-https://github.com/XpressReal/linux.git}"
KERNEL_COMMIT="${KERNEL_COMMIT:-be79582cb}"     # 6.6.54 基线
# ↑ 与产物里的版本串 "-gbe79582cba58" 对应；换 commit 等于换基线，
#   补丁可能打不上，请同步更新 patches/ 与文档。

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

echo "== 环境检查 =="
missing=0
for t in git make flex bison bc; do
	if command -v "$t" >/dev/null 2>&1; then
		printf '  %-8s ✔ %s\n' "$t" "$(command -v "$t")"
	else
		printf '  %-8s ✗ 缺失\n' "$t"
		case "$t" in
			flex|bison|bc) missing=1 ;;
		esac
	fi
done
# dtc 不是必需：内核会自己编 scripts/dtc 里的那份
command -v dtc >/dev/null 2>&1 && printf '  %-8s ✔ %s（内核自带 dtc 亦可）\n' "dtc" "$(command -v dtc)"
if command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
	printf '  %-8s ✔ %s\n' "交叉编译器" "$("${CROSS_COMPILE}gcc" -dumpversion)"
else
	printf '  %-8s ✗ 找不到 %sgcc\n' "交叉编译器" "$CROSS_COMPILE"
	echo "         Debian/Ubuntu: sudo apt install gcc-aarch64-linux-gnu"
	missing=1
fi
[ "$missing" = 1 ] && die "缺依赖，装完再跑（或改 local.conf 指到已有工具链）"

if [ "$CHECK_ONLY" = 1 ]; then
	echo; echo "--check 完成"
	exit 0
fi

echo
echo "== 内核树 =="
echo "  仓库  : $KERNEL_REPO"
echo "  目标  : $KTREE"
echo "  commit: $KERNEL_COMMIT"

if [ ! -d "$KTREE/.git" ]; then
	mkdir -p "$(dirname "$KTREE")"
	# blob:none 浅过滤：只要这个 commit 的文件，省带宽
	git clone --filter=blob:none --no-checkout "$KERNEL_REPO" "$KTREE"
fi
git -C "$KTREE" fetch --filter=blob:none origin "$KERNEL_COMMIT" 2>/dev/null || \
	git -C "$KTREE" fetch origin
git -C "$KTREE" checkout -q "$KERNEL_COMMIT"
echo "  当前 HEAD: $(git -C "$KTREE" log --oneline -1)"

echo
echo "== 应用板级补丁 =="
"$SCRIPTS_DIR/apply-kernel-patches.sh"

cat <<EOF

== 完成 ==
下一步：
  ./scripts/build-kernel.sh          # 编内核 + 板级 DTB（产物在 build/）
  详见 docs/03-build-and-install.md
EOF
