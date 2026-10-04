#!/usr/bin/env python3
"""抓取逻辑自检：验证 CR/LF 处理、串口分片拼接、控制字符过滤、尾行补出。"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "serial_capture", os.path.join(HERE, "serial_capture.py")
)
mod = importlib.util.module_from_spec(spec)
sys.argv = ["selftest"]
spec.loader.exec_module(mod)

tmp = tempfile.mkdtemp(prefix="serial_selftest_")
rec = mod.Recorder(os.path.join(tmp, "t"))

# 1) 典型 u-boot 行：\r\n 结尾
rec.feed(b"U-Boot 2016.11 (Jan 01 2016)\r\n")
# 2) 一行被串口分片切成两半，应正确拼接
rec.feed(b"SoC: Realtek RTD12")
rec.feed(b"96 (saola)\r\n")
# 3) autoboot 倒计时那种带退格符的写法
rec.feed(b"autoboot: 3\x082\x081\r\n")
# 4) 只有 \n 的情况（部分内核日志）
rec.feed(b"Booting Linux\n")
# 5) 混入控制字符与 NUL，应被过滤掉
rec.feed(b"DRAM:\x00\x07\x1b 2 GiB\r\n")
# 6) 收尾时最后一段不完整，close() 应补出
rec.feed(b"Machine model: CM360")
rec.close()

log_path = os.path.join(tmp, "t.log")
raw_path = os.path.join(tmp, "t.raw")

print("=== .log（带时间戳、给人看）===")
with open(log_path, encoding="utf-8", errors="replace") as f:
    print(f.read())

print("=== .raw（原始字节，应完全保留 \\r \\x08 \\x00）===")
with open(raw_path, "rb") as f:
    print(repr(f.read()))

# 断言
with open(log_path, encoding="utf-8", errors="replace") as f:
    text = f.read()

checks = [
    ("u-boot 首行完整", "U-Boot 2016.11 (Jan 01 2016)" in text),
    ("分片行已拼接", "SoC: Realtek RTD1296 (saola)" in text),
    ("退格行保留", "autoboot: 3\x082\x081" in text),
    ("单独 \\n 行正常", "Booting Linux" in text),
    ("控制字符已过滤", "\x00" not in text and "\x07" not in text),
    ("尾行已补出", "Machine model: CM360" in text),
    ("时间戳已加", text.lstrip().startswith("[")),
]

# --- 按键计划相关 ---
ub = mod.build_uboot_plan(burst_until=8.0, gap=0.15, key="both", cmd="printenv")
burst = [p for p in ub if p[0] < 8.0]
payloads = {p[1] for p in burst}
ub_cmds = [p for p in ub if p[2] == "printenv"]

checks += [
    ("uboot 计划含 Esc 与 Tab", b"\x1b" in payloads and b"\x09" in payloads),
    ("uboot 计划未用回车打断", b"\r" not in payloads),
    ("uboot 计划含 printenv", len(ub_cmds) == 1 and ub_cmds[0][1] == b"printenv\r"),
    ("uboot 计划时间递增", [p[0] for p in ub] == sorted(p[0] for p in ub)),
]

pl = mod.parse_plan("1:ESC,2:TAB,10:printenv,12:help version")
checks += [
    ("计划解析条数", len(pl) == 4),
    ("ESC 映射为 0x1b", pl[0][1] == b"\x1b"),
    ("TAB 映射为 0x09", pl[1][1] == b"\x09"),
    ("文本自动补回车", pl[2][1] == b"printenv\r"),
    ("含空格文本可用", pl[3][1] == b"help version\r"),
    ("计划已按时间排序", [p[0] for p in pl] == sorted(p[0] for p in pl)),
]

# --- probe 模式 ---
probe = mod.build_probe_plan(burst_until=8.0)
probe_payloads = [p[1] for p in probe]
probe_notes = [p[2] for p in probe]
checks += [
    ("probe 计划按时间递增", [p[0] for p in probe] == sorted(p[0] for p in probe)),
    ("probe 计划含 Esc/Tab 打断", b"\x1b" in probe_payloads and b"\x09" in probe_payloads),
    ("probe 计划含全部探查命令",
     all((c + "\r").encode() in probe_payloads for c in mod.PROBE_CMDS)),
    ("probe 打断段在 8s 前结束",
     max(p[0] for p in probe if p[2] is None and p[1] in (b"\x1b", b"\x09")) < 8.0),
    ("probe 首条命令在打断之后",
     min(p[0] for p in probe if p[2] in mod.PROBE_CMDS) > 8.0),
    ("probe 命令顺序正确",
     [n for n in probe_notes if n in mod.PROBE_CMDS] == mod.PROBE_CMDS),
    ("probe 不含任何写/擦命令",
     not any(w in " ".join(str(n) for n in probe_notes)
             for w in ("erase", "write", "sf ", "nand", "update", "saveenv"))),
]

# --- prepend_burst：命令时间早于 burst 时应自动收尾 ---
late = mod.prepend_burst(mod.parse_plan("20:help"), burst_until=8.0)
early = mod.prepend_burst(mod.parse_plan("3:help"), burst_until=8.0)
checks += [
    ("prepend_burst 保留原命令", [p[2] for p in late if p[2] == "help"] == ["help"]),
    ("prepend_burst 时间递增", [p[0] for p in late] == sorted(p[0] for p in late)),
    ("prepend_burst 打断不撞命令",
     max(p[0] for p in early if p[1] in (b"\x1b", b"\x09")) < 3.0),
    ("prepend_burst 命令晚于打断",
     min(p[0] for p in late if p[2] == "help") > 8.0),
]

print("=== 断言 ===")
ok = True
for name, passed in checks:
    print(("  PASS  " if passed else "  FAIL  ") + name)
    ok = ok and passed
print("\n结果：" + ("全部通过" if ok else "存在失败项"))
sys.exit(0 if ok else 1)
