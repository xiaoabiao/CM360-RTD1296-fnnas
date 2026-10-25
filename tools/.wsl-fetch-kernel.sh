#!/bin/bash
# 临时：WSL 内 shallow fetch 单个内核 commit 并 checkout
set -x
mkdir -p /root/cm360-build/kernel
cd /root/cm360-build/kernel || exit 1
rm -rf .git * 2>/dev/null
git init -q
git remote add origin https://github.com/XpressReal/linux.git
git fetch --depth 1 origin be79582cba58b749c4f03cfeff3ad18d1a0b3ac9 || exit 2
git checkout -q FETCH_HEAD || exit 3
echo "=== KERNEL TREE OK ==="
git log --oneline -1
du -sh /root/cm360-build/kernel
