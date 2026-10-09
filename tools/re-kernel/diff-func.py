#!/usr/bin/env python3
"""diff-func.py —— 把【fnOS 6.18.18-trim】与【上游自建 v6.18.18】的同一个函数反汇编做差异对比

为什么需要它：`xref.py` 只能抓"调用了厂商符号"的改动；而厂商有些改动**不调用任何新符号**
（直接在原函数里插入逻辑，操作厂商全局表）。这类改动只能靠"同函数二进制对比"抓出来。
两个构建用的是同一份 config、同一 major 的 GCC（官方 12.2.0 / 本机 12.5.0），
所以除厂商插入的代码块之外，指令序列高度一致 —— 差异块即厂商改动。

用法：
  ./diff-func.py path_mount            # 打印 fnOS 侧相对上游【新增】的指令块
  ./diff-func.py generic_permission 40 # 同上，最多显示 40 行上下文
"""
import re
import subprocess
import sys

BASE = 0xFFFF800080000000
import os
DIR = os.environ.get("RE_DIR", "/home/xiaoabiao/.cache/fnnas/re-6.18")
IMG = os.environ.get("RE_IMG", f"{DIR}/vmlinuz-6.18.18-trim")
MAP = os.environ.get("RE_MAP", f"{DIR}/System.map-6.18.18-trim")
REF_VMLINUX = os.environ.get("RE_REF_VMLINUX", "/home/xiaoabiao/.cache/fnnas/upstream/build618/vmlinux")
OBJDUMP = "aarch64-linux-gnu-objdump"

INSN = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$")


def norm(ops):
    """归一化：把绝对地址/立即数里的地址换成 #A，便于跨构建比对"""
    ops = re.sub(r"\b[0-9a-f]{8,16}\b", "#A", ops)
    ops = re.sub(r"<[^>]*>", "", ops)
    return re.sub(r"\s+", " ", ops).strip()


def from_ref(sym):
    out = subprocess.run([OBJDUMP, "-d", f"--disassemble={sym}", REF_VMLINUX],
                         capture_output=True, text=True).stdout
    ins = []
    started = False
    for line in out.splitlines():
        if f"<{sym}>:" in line:
            started = True
            continue
        if started:
            m = INSN.match(line)
            if not m:
                if ins:
                    break
                continue
            ins.append((int(m.group(1), 16), m.group(3)))
    return ins


def from_fnos(sym):
    addr = None
    for line in open(MAP):
        p = line.split()
        if len(p) == 3 and p[2] == sym:
            addr = int(p[0], 16)
            break
    if addr is None:
        print(f"fnOS 侧无此符号: {sym}")
        return []
    off = addr - BASE
    need = 4000
    raw = subprocess.run(
        ["dd", f"if={IMG}", "bs=1M", "iflag=skip_bytes,count_bytes",
         f"skip={off}", f"count={need}", "status=none"], capture_output=True).stdout
    import tempfile, os
    with tempfile.NamedTemporaryFile(delete=False, suffix=".bin") as f:
        f.write(raw)
        path = f.name
    out = subprocess.run([OBJDUMP, "-D", "-b", "binary", "-m", "aarch64",
                          f"--adjust-vma={addr}", path], capture_output=True, text=True).stdout
    os.unlink(path)
    ins = []
    for line in out.splitlines():
        m = INSN.match(line)
        if m:
            ins.append((int(m.group(1), 16), m.group(3)))
    # 截到下一个符号之前
    nxt = None
    for line in open(MAP):
        p = line.split()
        if len(p) == 3:
            a = int(p[0], 16)
            if a > addr and nxt is None:
                nxt = a
                break
    return [(a, o) for a, o in ins if nxt is None or a < nxt]


def main():
    sym = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    A = [(a, norm(o)) for a, o in from_ref(sym)]
    B = [(a, norm(o)) for a, o in from_fnos(sym)]
    print(f"== {sym}: 上游 {len(A)} 条 / fnOS {len(B)} 条（差 {len(B)-len(A):+d} 条）==")
    import difflib
    sm = difflib.SequenceMatcher(None, [o for _, o in A], [o for _, o in B], autojunk=False)
    shown = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag not in ("insert", "replace"):
            continue
        for k in range(j1, j2):
            if shown >= limit:
                print("   ...（截断）")
                return
            print(f"   [fnOS 独有] 0x{B[k][0]:x}: {B[k][1]}")
            shown += 1
        if shown >= limit:
            return
    if shown == 0:
        print("   （指令序列一致，无可识别差异）")


if __name__ == "__main__":
    main()
