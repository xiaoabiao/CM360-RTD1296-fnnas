#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""serial_agent 自检：用 socketpair 冒充串口，验证收发、节流与控制文件解析。

不需要真实串口，沙箱内也能跑。
"""
import importlib.util
import os
import socket
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

spec = importlib.util.spec_from_file_location("serial_agent", os.path.join(HERE, "serial_agent.py"))
sa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sa)

from serial_capture import Recorder  # noqa: E402

TEST_GAP = 0.05

tmp = tempfile.mkdtemp(prefix="agent_selftest_")
prefix = os.path.join(tmp, "s")
ctl = prefix + ".ctl"
open(ctl, "w").close()

dev_end, agent_end = socket.socketpair()

rec = Recorder(prefix)
agent = sa.Agent(agent_end.fileno(), rec, ctl, quiet=True, gap=TEST_GAP)

checks = []


def drain_device(timeout=0.5):
    """把代理写往'串口'的字节读出来。"""
    dev_end.setblocking(False)
    out = b""
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            chunk = dev_end.recv(4096)
        except BlockingIOError:
            time.sleep(0.02)
            continue
        if not chunk:
            break
        out += chunk
        time.sleep(0.02)
    return out


def pump_until(timeout=1.0):
    """模拟 run() 主循环：边刷新待发队列边收字节，直到静默。"""
    out = b""
    t0 = time.time()
    while time.time() - t0 < timeout:
        agent.poll_ctl()
        agent.flush_pending()
        out += drain_device(0.05)
    return out


def reset_cursor():
    agent.cursor = time.time()


# --- 1) 普通文本 → 自动补回车 ---
with open(ctl, "a") as f:
    f.write("help\n")
agent.poll_ctl()
agent.flush_pending()
checks.append(("普通文本自动补回车", drain_device() == b"help\r"))

# --- 2) @key:TAB ---
with open(ctl, "a") as f:
    f.write("@key:TAB\n")
agent.poll_ctl()
agent.flush_pending()
checks.append(("@key:TAB 映射为 0x09", drain_device() == b"\x09"))

# --- 3) 两条命令按序投递（有 gap，要跑主循环）---
with open(ctl, "a") as f:
    f.write("@key:ESC\n")
    f.write("printenv\n")
checks.append(("多行按序投递", pump_until(0.8) == b"\x1b" + b"printenv\r"))

# --- 4) @raw 十六进制 ---
with open(ctl, "a") as f:
    f.write("@raw:1b 09\n")
agent.poll_ctl()
agent.flush_pending()
checks.append(("@raw 十六进制解析", drain_device() == b"\x1b\x09"))

# --- 5) 非法指令不崩、不发送 ---
with open(ctl, "a") as f:
    f.write("@sleep:abc\n")
    f.write("@nonsense:x\n")
    f.write("@raw:zz\n")
agent.poll_ctl()
agent.flush_pending()
checks.append(("非法指令被忽略且无输出", drain_device() == b""))

# --- 6) 回归①：同一批里 @sleep 之后的命令也必须等（这正是踩过的坑）---
reset_cursor()
with open(ctl, "a") as f:
    f.write("@sleep:0.4\n")
    f.write("bdinfo\n")
agent.poll_ctl()
agent.flush_pending()
early = drain_device(0.15)
time.sleep(0.5)
agent.flush_pending()
late = drain_device(0.3)
checks.append(("同批 @sleep 前不发送", early == b""))
checks.append(("同批 @sleep 后正确发送", late == b"bdinfo\r"))

# --- 7) 回归②：同批多条命令必须被 gap 拉开，不能一口气灌下去 ---
reset_cursor()
agent.gap = 0.4
with open(ctl, "a") as f:
    f.write("cmdA\n")
    f.write("cmdB\n")
agent.poll_ctl()
agent.flush_pending()
first = drain_device(0.1)
time.sleep(0.5)
agent.flush_pending()
second = drain_device(0.2)
agent.gap = TEST_GAP
checks.append(("节流：第一条立即可发", first == b"cmdA\r"))
checks.append(("节流：第二条等到 gap 之后", second == b"cmdB\r"))

# --- 8) @burst 连打（分时投递）---
reset_cursor()
with open(ctl, "a") as f:
    f.write("@burst:0.6 esc tab\n")
b = pump_until(1.0)
checks.append(("@burst 发出 Esc/Tab 交替", len(b) > 0 and set(b) == {0x1b, 0x09}))
checks.append(("@burst 次数符合 0.6s/0.15s", len(b) == 4))

# --- 9) 部分写入的控制行要等换行才生效 ---
reset_cursor()
with open(ctl, "a") as f:
    f.write("pri")            # 没换行
agent.poll_ctl()
agent.flush_pending()
checks.append(("半行不发送", drain_device(0.1) == b""))
with open(ctl, "a") as f:
    f.write("ntenv\n")
agent.poll_ctl()
agent.flush_pending()
checks.append(("补齐换行后发送完整命令", drain_device() == b"printenv\r"))

# --- 10) 串口 -> 日志（含分片与 CR/LF 规范化）---
dev_end.sendall(b"CM360_DS218> ")
dev_end.sendall(b"help\r\n")
agent.poll_serial()
dev_end.sendall(b"bootm\r\n")
agent.poll_serial()

# --- 11) @quit 让 run() 退出 ---
with open(ctl, "a") as f:
    f.write("@quit\n")
checks.append(("@quit 触发退出", agent.poll_ctl() is False))

rec.close()

with open(prefix + ".log", encoding="utf-8", errors="replace") as f:
    log = f.read()
with open(prefix + ".raw", "rb") as f:
    raw = f.read()

checks += [
    ("串口数据已落盘 .log", "help" in log and "bootm" in log),
    ("提示符被完整记录", "CM360_DS218>" in log),
    ("CR 已规范成 LF", "\r" not in log),
    (".raw 保留原始 CR", b"\r" in raw),
    ("日志带时间戳", log.lstrip().startswith("[")),
]

# --- 12) 控制文件从头读：旧命令不会被重放 ---
prefix2 = os.path.join(tmp, "s2")
ctl2 = prefix2 + ".ctl"
with open(ctl2, "w") as f:
    f.write("should_not_replay\n")
rec2 = Recorder(prefix2)
a2 = sa.Agent(dev_end.fileno(), rec2, ctl2, quiet=True)
a2.poll_ctl()
a2.flush_pending()
checks.append(("旧控制命令不重放", drain_device(0.2) == b""))
rec2.close()

print("=== serial_agent 自检 ===")
ok = True
for name, passed in checks:
    print(("  PASS  " if passed else "  FAIL  ") + name)
    ok = ok and passed
print("\n结果：" + ("全部通过（%d 项）" % len(checks) if ok else "存在失败项"))
sys.exit(0 if ok else 1)
