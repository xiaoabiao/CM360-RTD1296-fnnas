#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""fdt-dump.py —— 离线核对 .dtb 内容的极简 FDT 解析器（只依赖 Python 标准库）。

为什么需要它
------------
排查"某个外设为什么没起来"时，第一步永远是**确认现役 .dtb 里到底有什么**：
节点在不在、status 是 okay 还是 disabled、reg/interrupts 写的是什么。
常规做法是 `dtc -I dtb -O dts`，但 dtc 不一定在手边（本仓库的构建环境才自带），
而这个解析器**零依赖**，任何装了 python3 的机器都能跑 —— 包括只有 .dtb 产物、
没有内核源码树和交叉工具链的场景。

用法
----
    # 列出所有节点路径 + status
    python3 tools/fdt-dump.py artifacts/kernel-6.6.54/rtd1296-cm360.dtb --paths

    # 按关键字搜节点（节点名 / 属性名 / 属性值都参与匹配）
    python3 tools/fdt-dump.py <file.dtb> --grep usb

    # 打印某个节点的全部属性
    python3 tools/fdt-dump.py <file.dtb> --node sdmmc

    # 打印整棵树
    python3 tools/fdt-dump.py <file.dtb>

实测用途（2026-10-11）
----------------------
    python3 tools/fdt-dump.py artifacts/kernel-6.6.54/rtd1296-cm360.dtb --paths
    → 确认 sdmmc@10400 是 disabled、sdio/USB 节点完全不存在、没有 gpio-leds
    python3 tools/fdt-dump.py boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dtb --grep usb
    → 从原厂 DTB 取 USB3 控制器树的金坐标（详见 docs/reports/cm360-peripheral-gold-coordinates.md）
"""
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9

# 按字符串解码的属性
STR_PROPS = {
    "compatible", "status", "device_type", "model", "clock-names",
    "pinctrl-names", "dr_mode", "function", "pins", "interrupt-names",
    "reset-names", "dma-names", "phy-names", "power-domain-names",
    "clock-output-names", "label", "name",
}
# 按单个 u32 显示的属性
U32_PROPS = {
    "#address-cells", "#size-cells", "#gpio-cells", "#clock-cells",
    "#pwm-cells", "#phy-cells", "#reset-cells", "#interrupt-cells",
    "#thermal-sensor-cells", "#dma-cells", "#iommu-cells", "phandle",
    "linux,phandle", "interrupt-parent", "timer_target", "fan_debounce",
}


def be32(b, o):
    return struct.unpack_from(">I", b, o)[0]


class Node:
    __slots__ = ("name", "props", "children", "parent", "path")

    def __init__(self, name, parent):
        self.name = name
        self.props = {}
        self.children = []
        self.parent = parent
        if parent is None:
            self.path = "/"
        elif parent.path == "/":
            self.path = "/" + name
        else:
            self.path = parent.path + "/" + name


def parse(path):
    data = open(path, "rb").read()
    if len(data) < 40:
        raise SystemExit("文件太小，不是 FDT")
    magic = be32(data, 0)
    if magic != FDT_MAGIC:
        raise SystemExit(f"魔数不符: 0x{magic:08x}（期望 0xd00dfeed）")
    totalsize = be32(data, 4)
    off_struct = be32(data, 8)
    off_strings = be32(data, 12)
    version = be32(data, 20)

    root = Node("", None)
    cur = root
    off = off_struct
    while True:
        tok = be32(data, off)
        off += 4
        if tok == FDT_BEGIN_NODE:
            end = data.index(b"\x00", off)
            name = data[off:end].decode("utf-8", "replace")
            off = (end + 1 + 3) & ~3
            node = Node(name, cur)
            cur.children.append(node)
            cur = node
        elif tok == FDT_END_NODE:
            cur = cur.parent
        elif tok == FDT_PROP:
            length = be32(data, off)
            nameoff = be32(data, off + 4)
            off += 8
            value = data[off:off + length]
            off = (off + length + 3) & ~3
            send = data.index(b"\x00", off_strings + nameoff)
            pname = data[off_strings + nameoff:send].decode("utf-8", "replace")
            cur.props[pname] = value
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise SystemExit(f"结构块损坏: token={tok} @0x{off - 4:x}")
    return root, totalsize, version


def fmt_prop(name, value):
    if name in STR_PROPS or name.startswith("rtk119x,"):
        parts = [p for p in value.split(b"\x00") if p]
        try:
            return " , ".join(p.decode("utf-8") for p in parts)
        except UnicodeDecodeError:
            pass
    if name in U32_PROPS and len(value) == 4:
        return f"0x{be32(value, 0):x}"
    if len(value) % 4 == 0 and 0 < len(value) <= 64:
        words = [be32(value, i) for i in range(0, len(value), 4)]
        if all(w < 0x10000000 for w in words):
            return "<" + " ".join(f"0x{w:x}" for w in words) + ">"
    if value and all(32 <= c < 127 for c in value):
        return f'"{value.decode()}"'
    return f"<{len(value)} 字节: {value[:32].hex()}{'...' if len(value) > 32 else ''}>"


def walk(node, out):
    out.append(node)
    for c in node.children:
        walk(c, out)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    dtb = sys.argv[1]
    args = sys.argv[2:]
    grep = show_paths = node_filter = None
    i = 0
    while i < len(args):
        if args[i] == "--grep":
            grep = args[i + 1]
            i += 2
        elif args[i] == "--paths":
            show_paths = True
            i += 1
        elif args[i] == "--node":
            node_filter = args[i + 1]
            i += 2
        else:
            i += 1

    root, totalsize, version = parse(dtb)
    nodes = []
    walk(root, nodes)
    print(f"# {dtb}")
    print(f"# totalsize={totalsize} version={version} 节点数={len(nodes)}")
    print()

    if node_filter:
        hits = [n for n in nodes if node_filter in n.name or node_filter == n.path]
        if not hits:
            print(f"未找到节点: {node_filter}")
            return 1
        for n in hits:
            print(f"{n.path} {{")
            for k, v in n.props.items():
                print(f"    {k} = {fmt_prop(k, v)};")
            kids = ", ".join(c.name for c in n.children) or "无"
            print(f"    /* 子节点 {len(n.children)} 个: {kids} */")
            print("};")
            print()
        return 0

    if grep:
        for n in nodes:
            blob = n.path + " " + " ".join(n.props.keys())
            for k, v in n.props.items():
                blob += " " + fmt_prop(k, v)
            if grep.lower() in blob.lower():
                status = n.props.get("status")
                st = f'  status={fmt_prop("status", status)}' if status else ""
                print(f"{n.path}{st}")
        return 0

    if show_paths:
        for n in nodes:
            status = n.props.get("status")
            st = f'   [{fmt_prop("status", status)}]' if status else ""
            print(f"{n.path}{st}")
        return 0

    def dump(n, depth):
        if n.parent is not None:
            status = n.props.get("status")
            st = f'  status={fmt_prop("status", status)}' if status else ""
            print("  " * depth + n.name + st)
        for k, v in n.props.items():
            if k in ("status", "phandle", "linux,phandle"):
                continue
            print("  " * (depth + 1) + f"{k} = {fmt_prop(k, v)}")
        for c in n.children:
            dump(c, depth + 1)

    dump(root, -1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
