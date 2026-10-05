#!/usr/bin/env bash
# TFTP 服务器自测 —— 读（RRQ，给 u-boot 抓内核用）与写（WRQ，给 tftpput 备份用）双向往返校验。
#
# 用法：bash selftest_tftp.sh
# 全部在 127.0.0.1 上跑，不碰真实网卡，不需要 root。
#
# 注意两个曾经踩过的坑，测试里已经修掉：
#   1. curl 对 TFTP 错误返回的是 68（TFTP protocol error），不是 0。
#      所以"应该被拒绝"的用例断言的是"退出码非 0"，不是"=0"。
#   2. 服务器是异步线程：不能 curl 一返回就立刻 md5sum。现在服务器是
#      "先落盘 + 改名，再发最终 ACK"，curl 返回时文件必然已完整，
#      但旧版本不是——那正是当初 md5 对不上的原因（结尾几块还在缓冲区里）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRV_PY="$HERE/tftp_server.py"
D=$(mktemp -d /tmp/tftpst.XXXXXX); R="$D/root"; mkdir -p "$R"
PORT=1069; PORT_RO=1067
LOG="$D/srv.log"; LOG_RO="$D/srv_ro.log"

cleanup(){ [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${SRV_RO:-}" ] && kill "$SRV_RO" 2>/dev/null; }
trap cleanup EXIT

python3 "$SRV_PY" --bind 127.0.0.1 --port $PORT   --root "$R" --writable --log "$LOG"    >/dev/null 2>&1 & SRV=$!
python3 "$SRV_PY" --bind 127.0.0.1 --port $PORT_RO --root "$R"             --log "$LOG_RO" >/dev/null 2>&1 & SRV_RO=$!
sleep 1

P=0; F=0
ck(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; P=$((P+1)); else echo "  FAIL  $1  (期望 [$3] 得到 [$2])"; F=$((F+1)); fi; }
ck_ne(){ if [ "$2" != "$3" ]; then echo "  PASS  $1"; P=$((P+1)); else echo "  FAIL  $1  (期望不等于 [$3]，实际相同)"; F=$((F+1)); fi; }
md5(){ md5sum < "$1" | cut -d' ' -f1; }

# ---------- 造用例文件，覆盖 TFTP 的边界尺寸 ----------
for n in 0 1 511 512 513 1024 1536 100000; do
  head -c "$n" /dev/urandom > "$R/f$n.bin"
done
printf 'hello tftp\n' > "$R/small.txt"

echo "=== 1. RRQ 下载（默认 512 块）==="
for n in 0 1 511 512 513 1024 1536 100000; do
  curl -s -o "$D/out" "tftp://127.0.0.1:$PORT/f$n.bin"
  ck "下载 f$n.bin ($n 字节)" "$(md5 "$D/out")" "$(md5 "$R/f$n.bin")"
done

echo "=== 2. RRQ 下载（协商 blksize=1468，模拟 u-boot tftpblocksize）==="
for n in 512 1536 100000; do
  curl -s --tftp-blksize 1468 -o "$D/out" "tftp://127.0.0.1:$PORT/f$n.bin"
  ck "blksize=1468 下载 f$n.bin ($n 字节)" "$(md5 "$D/out")" "$(md5 "$R/f$n.bin")"
done

echo "=== 3. RRQ 文本文件 ==="
curl -s -o "$D/out" "tftp://127.0.0.1:$PORT/small.txt"
ck "下载 small.txt 内容" "$(cat "$D/out")" "hello tftp"

echo "=== 4. 安全性：不存在的文件 / 路径穿越，都必须被拒 ==="
curl -s -o "$D/out" "tftp://127.0.0.1:$PORT/nope.bin" 2>/dev/null
ck_ne "不存在的文件被拒（curl 退出码非 0）" "$?" "0"
curl -s -o "$D/out" "tftp://127.0.0.1:$PORT/../etc/passwd" 2>/dev/null
ck_ne "拒绝 ../etc/passwd" "$?" "0"
curl -s -o "$D/out" "tftp://127.0.0.1:$PORT/sub/../../etc/passwd" 2>/dev/null
ck_ne "拒绝 sub/../../etc/passwd" "$?" "0"

echo "=== 5. WRQ 上传往返校验（模拟 tftpput 备份）==="
for n in 0 1 512 513 70000; do
  head -c "$n" /dev/urandom > "$D/up$n.bin"
  rm -f "$R/u$n.bin" "$R"/u$n.bin.part-*
  curl -s -T "$D/up$n.bin" "tftp://127.0.0.1:$PORT/u$n.bin"
  if [ -f "$R/u$n.bin" ]; then
    ck "上传 $n 字节并校验" "$(md5 "$R/u$n.bin")" "$(md5 "$D/up$n.bin")"
  else
    ck "上传 $n 字节并校验" "文件未生成" "$(md5 "$D/up$n.bin")"
  fi
done

echo "=== 6. WRQ 上传（协商 blksize=1468）==="
head -c 70000 /dev/urandom > "$D/up1468.bin"
rm -f "$R/u1468.bin" "$R"/u1468.bin.part-*
curl -s --tftp-blksize 1468 -T "$D/up1468.bin" "tftp://127.0.0.1:$PORT/u1468.bin"
ck "blksize=1468 上传 70000 字节" "$(md5 "$R/u1468.bin" 2>/dev/null)" "$(md5 "$D/up1468.bin")"

echo "=== 6b. ★ 回归：多个内容不同的并发上传打同一个文件名 ==="
# 背景：u-boot 的 tftp/tftpput 会把同一请求重发一次，服务器为每条流各起一个线程。
# 若临时文件路径不含唯一标识，多条流会同时 truncate + 交叉写同一个 .part，
# 最终文件是几份数据的混合体（md5 与任何源都不匹配），且 rename 会撞 ENOENT。
#
# 判别力校准：这个形状用旧实现实测 6/6 轮全部损坏（并发度低时可能侥幸不触发，
# 所以这里刻意用 8 路并发 × 1MB；用 2 路小文件是测不出来的）。
CONC=8
head -c 1048576 /dev/urandom > "$D/race0.bin"     # 先造一份，下面复制成多份再各改几个字节
rm -f "$R/race.bin" "$R"/race.bin.part-*
SRC_MD5S=""
PIDS=""
for i in $(seq 1 $CONC); do
  # 每份都不同：复制后把第 i 个字节翻掉
  cp "$D/race0.bin" "$D/race$i.bin"
  printf "\\x$(printf '%02x' $(( (i * 37) % 256 )))" | dd of="$D/race$i.bin" bs=1 seek=$((i * 977)) conv=notrunc status=none
  SRC_MD5S="$SRC_MD5S $(md5 "$D/race$i.bin")"
  curl -s -T "$D/race$i.bin" "tftp://127.0.0.1:$PORT/race.bin" &
  PIDS="$PIDS $!"
done
wait $PIDS
RG=$(md5 "$R/race.bin" 2>/dev/null || echo none)
RACE_HIT=no
for m in $SRC_MD5S; do [ "$RG" = "$m" ] && RACE_HIT=yes; done
if [ "$RACE_HIT" = yes ]; then
  ck "$CONC 路并发同名上传，结果与某一源逐字节一致" "匹配" "匹配"
else
  ck "$CONC 路并发同名上传，结果与某一源逐字节一致" "混合体 $RG" "应等于其中一个源"
fi

echo "=== 7. 成功的传输不应残留 .part 残片 ==="
ck "无 .part 残留" "$(ls "$R"/*.part* 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "=== 8. 未开 --writable 时必须拒绝上传 ==="
rm -f "$R/denied.bin"
curl -s -T "$D/up512.bin" "tftp://127.0.0.1:$PORT_RO/denied.bin" 2>/dev/null
ck_ne "只读实例拒绝上传" "$?" "0"
ck "只读实例未落盘" "$([ -e "$R/denied.bin" ] && echo yes || echo no)" "no"

echo
echo "=== 服务器日志（可写实例）==="; sed 's/^/  /' "$LOG"
echo
echo "结果：PASS=$P  FAIL=$F"
if [ "$F" -eq 0 ]; then echo "全部通过 ✅"; else echo "存在失败 ❌"; exit 1; fi
