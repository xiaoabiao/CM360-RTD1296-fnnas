# `tools/re-kernel/` —— 内核二进制逆向工具集

为**逆向 fnOS 6.18.18-trim 内核**而写，但工具本身与具体内核无关，任何 arm64 内核 Image +
`System.map` 都能用（同一套方法也被用来核对 `build/` 下自编译内核的改动面）。

分析报告见 [`../../docs/reports/fnos-6.18-kernel-reverse-engineering.md`](../../docs/reports/fnos-6.18-kernel-reverse-engineering.md)。

## 前置约定（重要，否则工具用不对）

1. **输入是"未压缩的 arm64 Image"**（不是 `vmlinux` ELF，也不是 `Image.gz`）。
   素材目录下需要有 `vmlinuz-<版本>` 与 `System.map-<版本>`。
   **路径都不用改脚本**，用环境变量覆盖即可（默认指向本项目用的 cache 目录）：

   | 变量 | 默认值 | 含义 |
   |---|---|---|
   | `RE_DIR` | `~/.cache/fnnas/re-6.18` | 素材目录（fnOS 内核 Image + System.map） |
   | `RE_IMG` | `$RE_DIR/vmlinuz-6.18.18-trim` | 目标内核 Image |
   | `RE_MAP` | `$RE_DIR/System.map-6.18.18-trim` | 目标内核符号表 |
   | `RE_REF_VMLINUX` / `RE_REF_DIR` | `~/.cache/fnnas/upstream/build618/vmlinux` / `…/build618` | **上游对照构建**（`calldiff.py`/`diff-func.py`/`cmp-syms.py` 需要） |

   ```bash
   # 例：分析自编译的 6.6 内核
   RE_DIR=~/WorkBuddy/…/rtd1296-fnnas/build RE_IMG=$RE_DIR/Image-6.6 RE_MAP=$RE_DIR/System.map ./xref.py callers-re '^trim_'
   ```
   > 上游对照构建怎么来：`bash ~/.cache/fnnas/upstream/build-ref.sh`
   > （免 root 取 GCC 12 交叉工具链 → 用 fnOS 官方 config 构建上游 v6.18.18 的 `vmlinux`）。
   > **没有它时**：`xref.py`/`strxref2.py`/`rela.py`/`vtab.py` 仍可用，只有
   > `calldiff.py`/`diff-func.py`/`cmp-syms.py` 这三个"对照类"工具会失败。
2. **地址标定**：arm64 Image 的文件偏移 `0` 对应 `_text`，典型为 `0xffff800080000000`
   （4K pages、`CONFIG_RELOCATABLE` 下的标准布局）。先算一遍再动手：
   ```
   awk '$3=="_text"{print $1}' System.map     # 取 _text
   ```
   校准是否成立用一个已知锚点验：`__start_rodata` 的 VA 减去 `_text` 应等于该地址处的文件内容看起来像 rodata
   （字符串/常量表）。**本项目实测该映射是线性的、精确的**。
3. **指针不在原地**：内核开了 `CONFIG_RELOCATABLE` 时，所有指针以 `Elf64_Rela` 记录存在 `.rela.dyn`：
   `{ r_offset(槽位 VA), r_info(类型 1027 = R_AARCH64_RELATIVE), r_addend(指针值) }`。
   **直接按 8 字节读结构体字段会读到 0**，必须查 RELA —— 这是解开 `file_system_type`、
   `*_operations` 等一切结构体的前提。

## 工具

| 工具 | 作用 | 典型用法 |
|---|---|---|
| `va.sh` | 地址↔文件偏移换算、按符号/地址反汇编、找字符串 VA、看原始字节 | `./va.sh disas trim_check_acl 60`、`./va.sh anchors` |
| `rela.py` | RELA 感知的结构体解码器（含抬头注释里的字段布局说明） | `./rela.py fields 0xffff800081e35a68 0x40`、`./rela.py fs-params <va>` |
| `xref.py` | 扫全 `.text` 解码 `BL/B` 相对偏移 → **谁调用了某符号**（调用点级证据） | `./xref.py callers trim_check_acl`、`./xref.py callers-re '^trim_'` |
| `strxref2.py` | 扫 `ADRP+ADD`/`ADRP+LDR`/`ADR`/`LDR-literal` → **谁引用了某字符串**（抓"没有新符号"的改动） | `./strxref2.py find 'unrecognized mount option'` |
| `vtab.py` | RELA 反查"谁指向了某函数" → 枚举 `*_operations` 等**接口表逐字段** | `./vtab.py tables`、`./vtab.py table trimafs_dir_inode_operations` |

## 两个必须记住的坑（第一版工具因此**全漏报**）

1. **`ADRP` 之后的 `ADD/LDR` 要比对 `Rn`（基址寄存器），不是 `Rd`。**
   写成 `(insn & 0x1F) == adrp_rd` 会漏掉绝大多数引用；正确是 `((insn >> 5) & 0x1F) == adrp_rd`。
2. **`printk` 格式串在内存里的真实起点前面还有控制前缀**（`\001` + loglevel 数字，如 `"\0013unrecognized…"`）。
   用正则捞字符串得到的是**去掉前缀后的地址**，直接拿它精确等值查引用必然落空
   —— 必须按"字符串区间"反查（`strxref2.py` 的 `refs_of()`）。

## 其它经验

- 二进制里出现的源码路径串（`__FILE__`）与上游文件清单做差集，可以找出**厂商新增的源文件**，
  但这是**下界**：只有用 `WARN`/`BUG`/显式打印的文件才会留名。
- 符号名差集（`System.map` 减去上游全源码标识符集合）能找厂商新增函数，但**宏 token-paste 生成的名字**
  （`bql_show_limit` 这类）会造成大量假阳性 → 必须再用显式命名族过滤。
- 想确认"某选项到底认不认"，别只看有没有字符串，要看**代码返回什么**：
  例如 btrfs 未知选项分支 `mov w0, #0xffffffea` = `-EINVAL`。
