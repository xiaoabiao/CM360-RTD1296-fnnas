#!/usr/bin/env python3
"""fnos-rpc-probe.py —— 发一条任意 file-manager RPC，并同时监听 main/file 两条 WebSocket。

为什么需要它：fnOS 的**异步任务类** RPC（file.rm / file.trash.restore / file.trash.clear …）
的 taskId/终态帧是推送到**登录时那条 main WebSocket**上的；普通同步 RPC（file.ls /
file.checkUpload）才走 file socket。所以复现面板行为必须像浏览器一样把 main ws 一直开着，
否则会误以为“没有响应”（实测：动作其实已经完成）。

用法（Windows/仓库根目录）：
  export PYTHONIOENCODING=utf-8 MSYS_NO_PATHCONV=1
  python tools/fnos-rpc-probe.py '{"req":"file.rm","files":["vol1/1000/1111/a.txt"],"moveToTrashbin":true}'
  python tools/fnos-rpc-probe.py '{"req":"file.trash.restore","files":["vol1/1000/.@#local/trash/1111/a.txt"],"overwrite":0,"uid":1000}'
"""
import base64, json, sys, time, os, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fnosapi", os.path.join(HERE, "fnos-api.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

api = m.FnosAPI("192.168.1.234:5666", "Xiaoabiao", "Hrb020717..")

main_ws = api.ws_connect("main")
try:
    pub = api.send_raw(main_ws, {"reqid": api.reqid(), "req": "util.crypto.getRSAPub"})
    si = str(pub.get("si", ""))
    n, e = m.parse_spki_pem(pub["pub"])
    key_str = m._rand_alnum(32)
    iv = os.urandom(16)
    rid = api.reqid()
    payload = {"req": "user.login", "user": api.user, "password": api.password,
               "stay": False, "deviceType": "Browser",
               "deviceName": "Windows-Google Chrome",
               "did": "fnos-rpc-probe", "si": si, "reqid": rid}
    env = {"reqid": rid, "req": "encrypted",
           "iv": base64.b64encode(iv).decode(),
           "rsa": base64.b64encode(m.rsa_pkcs1_v15_encrypt(n, e, key_str.encode())).decode(),
           "aes": base64.b64encode(m.aes_cbc_encrypt(key_str.encode(), iv, m._json_dump(payload).encode())).decode()}
    resp = api.send_raw(main_ws, env, timeout=30)
    api.token = resp["token"]
    api.uid = resp.get("uid")
    api.back_id = resp.get("backId") or api.back_id
    api.hmac_key = m.aes_cbc_decrypt(key_str.encode(), iv, base64.b64decode(resp["secret"]))
    si2 = str((api.rpc("util.getSI", {}, ws=main_ws) or {}).get("si", ""))
    api.rpc("user.authToken", {"token": api.token, "si": si2}, ws=main_ws, direct=True)

    file_ws = api.file_socket()
    obj = json.loads(sys.argv[1])
    obj.setdefault("reqid", api.reqid())
    file_ws.send_text(api.sign(obj))
    print(">> %s" % json.dumps(obj, ensure_ascii=False))
    end = time.time() + float(os.environ.get("PROBE_TIMEOUT", "20"))
    while time.time() < end:
        for name, ws in (("file", file_ws), ("main", main_ws)):
            try:
                txt = ws.recv_text(timeout=1.0)
            except TimeoutError:
                continue
            print("[%s] %s" % (name, txt))
            try:
                msg = json.loads(txt)
            except ValueError:
                continue
            if msg.get("reqid") == obj["reqid"] and msg.get("result") in ("succ", "fail", "cancel"):
                print("TERMINAL on %s" % name)
                end = 0
    print("done")
finally:
    try:
        main_ws.close()
    except Exception:
        pass
