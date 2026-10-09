# fnOS 6.18.18-trim 内核 `trim_trashbin` 回收站模块协议重建

**分析对象**：fnOS 官方 arm64 内核 `vmlinuz-6.18.18-trim`（未压缩裸 Image）。
**核心目标**：重建回收站模块 `trim_trashbin` 的设备形态与 `read`/`write` 消息字节级格式，
并还原两个私有 xattr 与删除判定逻辑。

**素材**：`~/.cache/fnnas/re-6.18/`（`vmlinuz-6.18.18-trim`、`System.map-6.18.18-trim`、`config-6.18.18-trim`）。
**工具**：`tools/re-kernel/`（`va.sh`/`rela.py`/`xref.py`/`strxref2.py`/`vtab.py`）。
**标定**：Image 文件偏移 0 ↔ `_text = 0xffff800080000000`（线性，已验证）；指针在 `.rela.dyn`（type 1027），必须 `rela.py`。
**交叉印证**：`docs/reports/fnos-6.18-kernel-re/USERSPACE-trimafs.md`（用户态 `trashbind` 调用 `/dev/trim-trashbin`）。

---

## 1. 设备形态（trim_trashbin_init）—— 分析中

## 2. open/release 校验逻辑 —— 分析中

## 3. read 内核→用户态消息格式 —— 分析中

## 4. write 用户态→内核完成回执 —— 分析中

## 5. 核心下发函数 trim_trashbin —— 分析中

## 6. 两个私有 xattr 的值格式 —— 分析中

## 7. 删除判定路径（is_move_to_trash / whitelist / trim_do_trashbin）—— 分析中

## 8. 协议总表与未解点 —— 分析中

---

*本文全部为静态逆向结论，区分【实测】/【推断】；未确定处写"未能确定"，禁止编造。*
