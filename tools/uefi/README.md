# tools/uefi —— UEFI / 低区布局研究工具

这里放"如果要把 U-Boot 换成 UEFI 固件"时**只读、可复核**的工具。
结论与路线评估见 [`docs/12-uefi-and-install-media.md`](../../docs/12-uefi-and-install-media.md)。

## lowregion.py

解析 / 校验 `firmware/low-region-38MiB.img.gz` 的低区布局。**不写任何设备、不改镜像**（`plan` 只输出纸面推演）。

```sh
python3 tools/uefi/lowregion.py info       # 布局表：hwsetting / bootcode / FSBL / TEE / BL31 / env
python3 tools/uefi/lowregion.py check      # 校验模型（20 项，全绿才算本文件所述布局成立）
python3 tools/uefi/lowregion.py selftest   # 用解析出的四段镜像原地重排，逐字节比对 → PASS
python3 tools/uefi/lowregion.py extract --name bootcode --out /tmp/bootcode.bin
python3 tools/uefi/lowregion.py plan --bootcode /tmp/new-bootcode.bin   # 换 bootcode 的尺寸/位移推演
```

已验证的模型（`check`/`selftest` 通过，2026-10-22）：

| 段 | eMMC 偏移 | 长度 | 结束 |
|---|---|---|---|
| hwsetting | `0x20000` | 3200 B（+0xFF 到 `0x20E00`） | `0x20E00` |
| bootcode（Realtek 容器，内含 U-Boot） | `0x20E00` | `0x7DC20` | `0x9EA20` |
| FSBL | `0x9EC00` | `0x11920` | `0xB0520` |
| TEE / BL32 | `0xB0600` | `0x7BDA0` | `0x12C3A0` |
| BL31 | `0x12C400` | `0x62A0` | `0x1326A0` |
| 未知固件块（≈972 KiB，含 mbedTLS/SHA256 字符串） | `0x132800` | 未定 | — |
| u-boot env（生效 / 旧） | `0x220000` / `0x420000` | `0x20A00` | — |

规则：四段镜像按 hwsetting 的 4 个长度字段（`+0x04..+0x10`）**顺序排布、0x200 对齐、0xFF 填充**；
`hwsetting[0]=0xC00` 是寄存器脚本长度（3200 = 128 B 头 + 3072 B 脚本）。

## 已知边界（别把它当"能刷"的工具）

- `plan` 只算"如果换一个 bootcode 会怎样"，**不打包容器、不生成可刷镜像**。
  bootcode 不是裸 `u-boot.bin`：`0x28` 头 + 载荷 + 尾部的字段语义尚未完全逆向，
  必须用 Realtek BSP 的打包工具（BPI-W2 BSP `u-boot-rtk` 2015.07 里有 flash_writer/dvrboot）
  或补齐逆向后再动。
- `0x132800` 起的未知固件块：偏移由谁计算未确认 → **"bootcode 能加长多少"目前没有安全答案**，
  最坏情况余量为 0（链尾正贴着它）。
- 动低区 = 全板唯一砖区。任何写盘之前先读 [`firmware/RECOVERY.md`](../../firmware/RECOVERY.md)
  与 [`docs/04-recovery.md`](../../docs/04-recovery.md)。
