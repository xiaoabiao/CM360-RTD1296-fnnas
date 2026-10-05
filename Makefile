# ─────────────────────────────────────────────────────────────────────
# CM360 (Realtek RTD1296) — fnOS 移植工程 / 板级支持
#
# 常用入口：
#   make help          列出全部目标
#   make setup         拉内核树 + 打补丁（首次）
#   make build         编内核 + 板级 DTB
#   make dtb           只重编 DTB（改 DTS 后用，几秒钟）
#   make uimage        把 Image 套成 u-boot 可 bootm 的 legacy uImage
#   make deploy        推到 TFTP 根目录（串口/TFTP 引导用）
#   make modmeta       把模块元数据装到板上 + 板上 depmod（★ 更新内核后必做）
#   make check         环境自检
# ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash
.DEFAULT_GOAL := help

# 所有目标都在同一个 bash 会话里跑，方便共用 env.sh
export SHELL

help:  ## 显示本帮助
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  环境变量来自 scripts/lib/env.sh（本机差异写在 local.conf，见 local.conf.example）"

check:  ## 环境自检（内核树 / 交叉工具链）
	@./scripts/setup-deps.sh --check

setup:  ## 拉取内核树（锁定 commit）并应用板级补丁
	@./scripts/setup-deps.sh

build:  ## 编译内核 + 板级 DTB（产物在 build/）
	@./scripts/build-kernel.sh

dtb:  ## 只重编 DTB（改过 board 里的 DTS 后用）
	@DTB_ONLY=1 ./scripts/build-kernel.sh

uimage:  ## 把 build/Image-<ver> 套成 legacy uImage
	@./scripts/make-uimage.py build/Image-6.6 build/Image-6.6.uimage 0x03000000

initramfs:  ## 生成 initramfs（TFTP 引导验证用）
	@./scripts/build-initramfs.sh

deploy:  ## 推内核/DTB/initramfs 到 TFTP 根目录
	@./scripts/deploy-tftp.sh

modmeta:  ## 装模块元数据到板上并 depmod（换内核后必做，否则 modprobe 全失败）
	@./scripts/deploy-modmeta.sh

emmc-prepare:  ## 生成 eMMC 布局产物（mbr.bin / p1.img）⚠ 会碰闪存，先读文档
	@./scripts/emmc-prepare.sh

emmc-write:  ## 把布局写入板子 eMMC ⚠⚠ 危险操作，先读 docs/04-recovery.md
	@./scripts/emmc-write.sh

board:  ## 上板跑一条命令：make board CMD='uptime'
	@./tools/brd-ssh.sh run "$(CMD)"

board-sudo:  ## 上板跑一条 sudo 命令：make board-sudo CMD='lsblk'
	@./tools/brd-ssh.sh sudo "$(CMD)"

clean-logs:  ## 清掉本地证据日志里的原始二进制流
	@rm -f evidence/logs/*.bin && echo "已清理 evidence/logs/*.bin"

.PHONY: help check setup build dtb uimage initramfs deploy modmeta \
        emmc-prepare emmc-write board board-sudo clean-logs
