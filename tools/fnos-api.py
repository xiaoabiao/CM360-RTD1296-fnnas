#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fnos-api.py — scripted fnOS 1.2.x panel API client (login + file-manager RPC + upload).

Why this exists
---------------
The fnOS panel is a minified SPA; its login and file-manager calls travel over a
private JSON-RPC-over-WebSocket protocol (not plain HTTP REST).  This tool
reproduces exactly what the browser does, so a broken-kernel upload bug can be
reproduced/verified from the command line, without a browser and without the
GUI.  It is pure standard library (Python 3.8+): RSA PKCS#1 v1.5, AES-256-CBC
and a minimal RFC6455 WebSocket client are implemented below.

Protocol summary (reverse-engineered from /usr/trim/www/assets/*.js)
--------------------------------------------------------------------
* Transport:   ws://<host>/websocket?type=<main|file|timer|ping>
               (wss://.../websocket when the panel is served over HTTPS)
* Framing:     client -> server: one text frame per request,
                  {"reqid":"<hex>", "req":"<method>", ...args}
               server -> client: zero or more text frames carrying the same
                  reqid; a terminal frame has "result":"succ"|"fail"|"cancel".
               "ping"/"pong" frames keep the socket alive (15 s in browser).
* reqid:       8 hex chars = unix seconds, then a 16 hex "backId" (all zeros
               for a fresh client), then a 4 hex monotonic counter.
* Auth:        WS `?type=main` login is an RSA+AES envelope:
                 send {"reqid","req":"util.crypto.getRSAPub"} -> {"pub":PEM,"si":...}
                 random 32-char alnum ASCII key -> AES-256-CBC (PKCS#7, random IV)
                 RSA(PKCS#1 v1.5) encrypts those 32 key bytes with `pub`
                 send {"reqid","req":"encrypted","iv":b64,"rsa":b64,"aes":b64}
                 plaintext = {"reqid","req":"user.login","user","password",
                              "stay":false,"deviceType":"Browser",
                              "deviceName":"<os>-<browser>","did":<device-id>,"si":<si>}
               response (flat JSON): {"uid","admin","token","secret","machineId",
                                      "backId","result":"succ","reqid"}
* Token:       `token` = cookie `fnos-token` value (session cookie, sent back
               over RPC as {"req":"user.authToken","token":...} right after the
               file WebSocket opens; server binds the socket to the session).
* Request sign: `secret` is base64(AES-256-CBC(hmac-key)) with the SAME session
               key/IV as the login envelope.  Every further RPC frame is sent as
                 base64(HMAC-SHA256(key=hmac-key, msg=json)) + json
               (the panel's localStorage key is `fnos-Secret`).
* Upload:      file bytes are *not* sent over the WebSocket.  The browser does
               `file.checkUpload({size,path,overwrite})` first, then
                 POST /upload
                   Trim-Path:      encodeURI(target path)
                   Trim-From:      0
                   Trim-Overwrite: 0|1
                   Trim-Mtim:      mtime seconds
                   Trim-Token:     <token>
                   Trim-Sign:      base64(HMAC-SHA256(hmac-key, encodeURI(path)))
                   multipart field: trim-upload-file
               nginx proxies /upload to unix:/run/trim_upload_srv.socket.

Commands (all output is the *raw* JSON/text received from the board)
-------------------------------------------------------------------
  login                          login only, print the login response
  list <path>                    WebSocket file.ls on <path>
  check-upload <path> <size>     WebSocket file.checkUpload
  upload <path> <local-file>     POST /upload (does checkUpload first, like the UI)
  raw '<json>'                   send one raw RPC frame (JSON with "req")

Global options: --host, --user, --password (env FNOS_PASSWORD),
--https (wss), --state <file> (session cache, default ~/.fnos-api-state.json),
--no-cache (force a fresh login), --keep-absolute (do not strip a leading '/'
from RPC paths; the browser sends them relative, e.g. "vol1/1000").
"""
import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.parse

DEFAULT_HOST = os.environ.get("FNOS_HOST", "192.168.1.234:5666")
DEFAULT_USER = os.environ.get("FNOS_USER", "Xiaoabiao")
DEFAULT_PASSWORD = os.environ.get("FNOS_PASSWORD", "Hrb020717..")

# ==========================================================================
# 1. AES-256-CBC (pure python; needed for the login envelope and `secret`)
# ==========================================================================
_SBOX_HEX = (
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
)
SBOX = bytes.fromhex(_SBOX_HEX)
INV_SBOX = bytearray(256)
for _i, _v in enumerate(SBOX):
    INV_SBOX[_v] = _i
INV_SBOX = bytes(INV_SBOX)
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36, 0x6C, 0xD8, 0xAB, 0x4D]


def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) if a & 0x100 else a


def _gmul(a, b):
    p = 0
    while b:
        if b & 1:
            p ^= a
        a = _xtime(a) & 0xFF
        b >>= 1
    return p


def _expand_key(key):
    nk = len(key) // 4
    if nk not in (4, 6, 8):
        raise ValueError("bad AES key length")
    nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [SBOX[b] for b in t]
            t[0] ^= rcon
            rcon = _xtime(rcon) & 0xFF
        elif nk > 6 and i % nk == 4:
            t = [SBOX[b] for b in t]
        w.append([w[i - nk][j] ^ t[j] for j in range(4)])
    return w, nr


def _add_round_key(s, w, rnd):
    for i in range(16):
        s[i] ^= w[rnd * 4 + (i >> 2)][i & 3]


def _shift_rows(s):
    out = [0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = s[((c + r) % 4) * 4 + r]
    return out


def _inv_shift_rows(s):
    out = [0] * 16
    for c in range(4):
        for r in range(4):
            out[((c + r) % 4) * 4 + r] = s[c * 4 + r]
    return out


def _mix_columns(s):
    out = [0] * 16
    for c in range(4):
        a = s[c * 4:c * 4 + 4]
        out[c * 4 + 0] = _gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3]
        out[c * 4 + 1] = a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3]
        out[c * 4 + 2] = a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3)
        out[c * 4 + 3] = _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2)
    return out


def _inv_mix_columns(s):
    out = [0] * 16
    for c in range(4):
        a = s[c * 4:c * 4 + 4]
        out[c * 4 + 0] = _gmul(a[0], 14) ^ _gmul(a[1], 11) ^ _gmul(a[2], 13) ^ _gmul(a[3], 9)
        out[c * 4 + 1] = _gmul(a[0], 9) ^ _gmul(a[1], 14) ^ _gmul(a[2], 11) ^ _gmul(a[3], 13)
        out[c * 4 + 2] = _gmul(a[0], 13) ^ _gmul(a[1], 9) ^ _gmul(a[2], 14) ^ _gmul(a[3], 11)
        out[c * 4 + 3] = _gmul(a[0], 11) ^ _gmul(a[1], 13) ^ _gmul(a[2], 9) ^ _gmul(a[3], 14)
    return out


def _encrypt_block(block, w, nr):
    s = list(block)
    _add_round_key(s, w, 0)
    for rnd in range(1, nr + 1):
        s = [SBOX[b] for b in s]
        s = _shift_rows(s)
        if rnd != nr:
            s = _mix_columns(s)
        _add_round_key(s, w, rnd)
    return bytes(s)


def _decrypt_block(block, w, nr):
    s = list(block)
    _add_round_key(s, w, nr)
    for rnd in range(nr - 1, -1, -1):
        s = _inv_shift_rows(s)
        s = [INV_SBOX[b] for b in s]
        _add_round_key(s, w, rnd)
        if rnd != 0:
            s = _inv_mix_columns(s)
    return bytes(s)


def _pkcs7_pad(data):
    pad = 16 - (len(data) % 16)  # 1..16, always appended (full block when aligned)
    return data + bytes([pad]) * pad


def aes_cbc_encrypt(key, iv, data):
    w, nr = _expand_key(key)
    data = _pkcs7_pad(data)
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        blk = bytes(a ^ b for a, b in zip(data[i:i + 16], prev))
        prev = _encrypt_block(blk, w, nr)
        out += prev
    return bytes(out)


def aes_cbc_decrypt(key, iv, data):
    w, nr = _expand_key(key)
    if len(data) % 16:
        raise ValueError("bad ciphertext length")
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(_decrypt_block(blk, w, nr), prev))
        prev = blk
    pad = out[-1]
    if not 1 <= pad <= 16 or out[-pad:] != bytes([pad]) * pad:
        raise ValueError("bad PKCS#7 padding")
    return bytes(out[:-pad])


# ==========================================================================
# 2. RSA PKCS#1 v1.5 + SPKI PEM parsing (pure python)
# ==========================================================================
def _der_read(buf, pos):
    """Return (tag, value_bytes, next_pos) for one DER TLV."""
    tag = buf[pos]
    pos += 1
    ln = buf[pos]
    pos += 1
    if ln & 0x80:
        n = ln & 0x7F
        ln = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    return tag, buf[pos:pos + ln], pos + ln


def parse_spki_pem(pem):
    """Parse a PEM 'PUBLIC KEY' (SubjectPublicKeyInfo) -> (n, e)."""
    body = pem.strip()
    body = body.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", "")
    der = base64.b64decode("".join(body.split()))
    tag, spki, _ = _der_read(der, 0)
    if tag != 0x30:
        raise ValueError("SPKI: expected SEQUENCE")
    _, _alg, pos = _der_read(spki, 0)
    tag, bitstr, _ = _der_read(spki, pos)
    if tag != 0x03:
        raise ValueError("SPKI: expected BIT STRING")
    rsa_der = bitstr[1:]  # skip unused-bits byte
    tag, rsa_seq, _ = _der_read(rsa_der, 0)
    _, n_bytes, pos = _der_read(rsa_seq, 0)
    _, e_bytes, _ = _der_read(rsa_seq, pos)
    n = int.from_bytes(n_bytes, "big")
    e = int.from_bytes(e_bytes, "big")
    return n, e


def rsa_pkcs1_v15_encrypt(n, e, message):
    k = (n.bit_length() + 7) // 8
    if len(message) > k - 11:
        raise ValueError("message too long for RSA")
    ps = bytearray()
    while len(ps) < k - len(message) - 3:
        b = secrets.randbelow(255) + 1  # 1..255, no zero bytes
        ps.append(b)
    em = b"\x00\x02" + bytes(ps) + b"\x00" + message
    m = int.from_bytes(em, "big")
    c = pow(m, e, n)
    return c.to_bytes(k, "big")


# ==========================================================================
# 3. Minimal RFC6455 WebSocket client
# ==========================================================================
class WebSocket:
    def __init__(self, host, path, tls=False, timeout=15.0):
        self.host = host
        self.path = path
        self.tls = tls
        self.timeout = timeout
        self.sock = None
        self._buf = b""

    def connect(self):
        host_hdr = self.host
        hostname, _, port = self.host.partition(":")
        port = int(port) if port else (443 if self.tls else 80)
        raw = socket.create_connection((hostname, port), timeout=self.timeout)
        if self.tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            raw = ctx.wrap_socket(raw, server_hostname=hostname)
        self.sock = raw
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {host_hdr}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "User-Agent: fnos-api.py\r\n"
            "\r\n"
        )
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake: connection closed")
            head += chunk
        header, _, rest = head.partition(b"\r\n\r\n")
        self._buf = rest
        status = header.split(b"\r\n")[0].decode("latin-1")
        if " 101 " not in status:
            raise ConnectionError("websocket handshake failed: " + status)
        return self

    def _recv_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self._buf += chunk
        data, self._buf = self._buf[:n], self._buf[n:]
        return data

    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        hdr = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack("!H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack("!Q", n)
        hdr += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(hdr) + masked)

    def send_text(self, text):
        self._send_frame(0x1, text.encode())

    def _read_frame(self, timeout=None):
        if timeout is not None:
            self.sock.settimeout(timeout)
        b0, b1 = self._recv_exact(2)
        fin = bool(b0 & 0x80)
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        ln = b1 & 0x7F
        if ln == 126:
            ln = struct.unpack("!H", self._recv_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack("!Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else None
        payload = self._recv_exact(ln)
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def recv_text(self, timeout=None):
        """Return the next data message as text (handles ping/pong/close/fragments)."""
        buf = b""
        while True:
            fin, opcode, payload = self._read_frame(timeout)
            timeout = None  # only the first read is bounded
            if opcode == 0x9:  # ping -> pong
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:  # pong
                continue
            if opcode == 0x8:  # close
                raise ConnectionError("websocket closed by server")
            if opcode in (0x1, 0x2):
                buf = payload
                if fin:
                    return buf.decode("utf-8", "replace")
                continue
            if opcode == 0x0:
                buf += payload
                if fin:
                    return buf.decode("utf-8", "replace")
                continue
            raise ConnectionError("unexpected websocket opcode %d" % opcode)

    def close(self):
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


# ==========================================================================
# 4. fnOS RPC client (login / authToken / signed frames)
# ==========================================================================
ALNUM = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
DEFAULT_STATE = os.path.join(os.path.expanduser("~"), ".fnos-api-state.json")


def _json_dump(obj):
    # The panel uses JSON.stringify (no spaces, keep non-ASCII).
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def _rand_alnum(n):
    return "".join(secrets.choice(ALNUM) for _ in range(n))


class FnosAPI:
    def __init__(self, host, user, password, tls=False, state_path=DEFAULT_STATE, verbose=False):
        self.host = host
        self.user = user
        self.password = password
        self.tls = tls
        self.state_path = state_path
        self.verbose = verbose
        self.token = None
        self.hmac_key = None
        self.secret_b64 = ""
        self.uid = None
        self.machine_id = ""
        self.did = ""
        self.back_id = "0000000000000000"
        self._counter = 0

    # ---- low level -----------------------------------------------------
    def reqid(self):
        self._counter += 1
        return "%08x%s%04x" % (int(time.time()), self.back_id, self._counter)

    def ws_connect(self, kind):
        scheme = "wss" if self.tls else "ws"
        ws = WebSocket(self.host, "/websocket?type=%s" % kind, tls=self.tls)
        return ws.connect()

    def sign(self, body):
        js = _json_dump(body)
        if self.hmac_key:
            mac = hmac.new(self.hmac_key, js.encode(), hashlib.sha256).digest()
            return base64.b64encode(mac).decode() + js
        return js

    def send_raw(self, ws, obj, timeout=20.0, collect_stream=False):
        """Send one frame, print every received frame, return the terminal frame."""
        self.last_frames = []
        rid = obj.get("reqid")
        frame = self.sign(obj)
        if self.verbose:
            sys.stderr.write(">> %s\n" % frame)
        ws.send_text(frame)
        end = time.time() + timeout
        while time.time() < end:
            txt = ws.recv_text(timeout=max(0.05, end - time.time()))
            print(txt)
            sys.stdout.flush()
            try:
                msg = json.loads(txt)
            except ValueError:
                msg = None
            self.last_frames.append(msg)
            if msg and msg.get("reqid") == rid:
                if msg.get("result") in ("succ", "fail", "cancel"):
                    if not collect_stream:
                        return msg
                if collect_stream:
                    if msg.get("result") is not None:
                        return msg
        raise TimeoutError("no terminal response for reqid %s" % rid)

    def rpc(self, req, args=None, ws=None, direct=False):
        """Build a request the way the minified bundle does and send it.

        API wrapper order: {reqid, ...args, req}.  Direct send() order:
        {reqid, req, ...args}.  Only the signed JSON text matters for the
        server, but we reproduce the browser byte-for-byte.
        """
        own = ws is None
        if own:
            ws = self.ws_connect("file")
        try:
            o = {"reqid": self.reqid()}
            args = args or {}
            if direct:
                o["req"] = req
                o.update(args)
            else:
                o.update(args)
                o["req"] = req
            return self.send_raw(ws, o)
        finally:
            if own:
                ws.close()

    # ---- login ---------------------------------------------------------
    def load_state(self):
        try:
            st = json.load(open(self.state_path, encoding="utf-8"))
        except (OSError, ValueError):
            return False
        if st.get("host") != self.host or st.get("user") != self.user:
            return False
        self.token = st.get("token")
        self.secret_b64 = st.get("secret") or ""
        self.hmac_key = base64.b64decode(self.secret_b64) if self.secret_b64 else None
        self.uid = st.get("uid")
        self.machine_id = st.get("machineId") or ""
        self.did = st.get("did") or ""
        self.back_id = st.get("backId") or "0000000000000000"
        return bool(self.token)

    def save_state(self):
        st = {
            "host": self.host,
            "user": self.user,
            "token": self.token,
            "secret": self.secret_b64,
            "uid": self.uid,
            "machineId": self.machine_id,
            "did": self.did,
            "backId": self.back_id,
            "saved_at": int(time.time()),
        }
        try:
            with open(self.state_path, "w", encoding="utf-8") as f:
                json.dump(st, f, indent=2)
            os.chmod(self.state_path, 0o600)
        except OSError as e:
            sys.stderr.write("warn: cannot save session state: %s\n" % e)

    def login(self):
        ws = self.ws_connect("main")
        try:
            o = {"reqid": self.reqid(), "req": "util.crypto.getRSAPub"}
            pub = self.send_raw(ws, o)
            pem = pub["pub"]
            si = str(pub.get("si", ""))
            n, e = parse_spki_pem(pem)
            key_str = _rand_alnum(32)              # AES-256 key = ASCII of 32 chars
            iv = secrets.token_bytes(16)
            payload = {
                "req": "user.login",
                "user": self.user,
                "password": self.password,
                "stay": False,
                "deviceType": "Browser",
                "deviceName": "Windows-Google Chrome",
                "did": self.did or ("fnos-api-" + _rand_alnum(10)),
                "si": si,
            }
            rid = self.reqid()
            payload["reqid"] = rid
            env = {
                "reqid": rid,
                "req": "encrypted",
                "iv": base64.b64encode(iv).decode(),
                "rsa": base64.b64encode(
                    rsa_pkcs1_v15_encrypt(n, e, key_str.encode())).decode(),
                "aes": base64.b64encode(
                    aes_cbc_encrypt(key_str.encode(), iv, _json_dump(payload).encode())).decode(),
            }
            sys.stderr.write(">> user.login (RSA+AES envelope, si=%s)\n" % si)
            resp = self.send_raw(ws, env, timeout=30)
            if not isinstance(resp, dict) or resp.get("result") != "succ":
                return resp
            self.token = resp.get("token") or ""
            self.uid = resp.get("uid")
            self.machine_id = resp.get("machineId") or self.machine_id
            self.back_id = resp.get("backId") or self.back_id
            if not self.did:
                self.did = "fnos-api-" + _rand_alnum(10)
            secret_ct = resp.get("secret")
            if secret_ct:
                # vX(): AES-256-CBC decrypt with the same session key/iv,
                # result is the HMAC key itself (stored as base64 in localStorage).
                raw = aes_cbc_decrypt(key_str.encode(), iv, base64.b64decode(secret_ct))
                self.hmac_key = raw
                self.secret_b64 = base64.b64encode(raw).decode()
            self.save_state()
            return resp
        finally:
            ws.close()

    def ensure_login(self, no_cache=False):
        if not no_cache and self.load_state():
            return True
        r = self.login()
        if not isinstance(r, dict) or r.get("result") != "succ":
            raise RuntimeError("login failed: %s" % _json_dump(r))
        return True

    # ---- file socket ---------------------------------------------------
    def file_socket(self):
        ws = self.ws_connect("file")
        fs = self.rpc("util.getSI", {}, ws=ws)
        si = str((fs or {}).get("si", ""))
        auth = self.rpc("user.authToken", {"token": self.token, "si": si},
                        ws=ws, direct=True)
        if auth and auth.get("errno") == 4224:  # E_NOT_LOGIN
            ws.close()
            self.login()
            ws = self.ws_connect("file")
            fs = self.rpc("util.getSI", {}, ws=ws)
            si = str((fs or {}).get("si", ""))
            self.rpc("user.authToken", {"token": self.token, "si": si}, ws=ws, direct=True)
        return ws

    @staticmethod
    def rpc_path(path, keep_absolute=False):
        if keep_absolute:
            return path
        return path.lstrip("/") or None

    def file_call(self, req, args):
        """One file-manager RPC on a fresh `type=file` socket (login if needed).

        The panel runs every request with a short-lived authToken handshake; if
        the session expired (errno 4224 E_NOT_LOGIN) we log in again once and
        replay the call.
        """
        for attempt in (1, 2):
            ws = self.file_socket()
            try:
                r = self.rpc(req, args, ws=ws)
            finally:
                ws.close()
            if attempt == 1 and r and r.get("errno") == 4224:
                sys.stderr.write("session expired, logging in again\n")
                r2 = self.login()
                if not isinstance(r2, dict) or r2.get("result") != "succ":
                    raise RuntimeError("re-login failed: %s" % _json_dump(r2))
                continue
            return r

    # ---- upload (HTTP) -------------------------------------------------
    def upload(self, remote_path, local_file, overwrite=False, filename=None,
               trim_from=0, mtime=None):
        """POST the file bytes to /upload (the panel's XHR upload).

        `remote_path` is the value of the Trim-Path header (URL-encoded here);
        `filename` is the multipart filename the browser would send (normally
        the local file's basename).  Trim-Sign is HMAC-SHA256 over the *encoded*
        path string, base64 encoded, exactly like the bundle's `jr()`.
        """
        with open(local_file, "rb") as f:
            data = f.read()
        name = filename or os.path.basename(local_file)
        enc_path = urllib.parse.quote(remote_path, safe=";,/?:@&=+$-_.!~*'()#")
        field_name = "trim-upload-file"
        boundary = "----fnos-api-" + secrets.token_hex(12)
        body = bytearray()
        body += ("--%s\r\n" % boundary).encode()
        body += ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n'
                 % (field_name, name)).encode()
        body += b"Content-Type: application/octet-stream\r\n\r\n"
        body += data
        body += ("\r\n--%s--\r\n" % boundary).encode()
        hostname, _, port = self.host.partition(":")
        port = int(port) if port else (443 if self.tls else 80)
        if self.tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            conn = http.client.HTTPSConnection(hostname, port, context=ctx, timeout=30)
        else:
            conn = http.client.HTTPConnection(hostname, port, timeout=30)
        mac = hmac.new(self.hmac_key, enc_path.encode(), hashlib.sha256).digest()
        headers = {
            "Trim-Path": enc_path,
            "Trim-From": str(trim_from),
            "Trim-Overwrite": "1" if overwrite else "0",
            "Trim-Mtim": str(mtime if mtime is not None else int(time.time())),
            "Trim-Token": self.token,
            "Trim-Sign": base64.b64encode(mac).decode(),
            "Cookie": "fnos-token=%s" % self.token,
            "Content-Type": "multipart/form-data; boundary=%s" % boundary,
            "Content-Length": str(len(body)),
        }
        if self.verbose:
            sys.stderr.write(">> POST /upload %s (%d bytes) headers=%s\n"
                             % (enc_path, len(body), {k: v for k, v in headers.items()
                                                      if k.startswith("Trim-")}))
        conn.request("POST", "/upload", bytes(body), headers)
        resp = conn.getresponse()
        text = resp.read().decode("utf-8", "replace")
        # print the raw HTTP status + body (the panel only looks at the status)
        print("HTTP %d %s" % (resp.status, resp.reason))
        if text:
            print(text)
        sys.stdout.flush()
        return resp.status, text


# ==========================================================================
# 5. CLI
# ==========================================================================
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Scripted fnOS panel client: login + file-manager RPC + /upload.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Commands", 1)[1] if "Commands" in __doc__ else "")
    ap.add_argument("--host", default=DEFAULT_HOST, help="host[:port] (default %s)" % DEFAULT_HOST)
    ap.add_argument("--user", default=DEFAULT_USER, help="panel user (default %s)" % DEFAULT_USER)
    ap.add_argument("--password", default=DEFAULT_PASSWORD,
                    help="panel password (default: env FNOS_PASSWORD or built-in)")
    ap.add_argument("--https", action="store_true", help="use https/wss instead of http/ws")
    ap.add_argument("--state", default=DEFAULT_STATE, help="session cache file")
    ap.add_argument("--no-cache", action="store_true", help="force a fresh login")
    ap.add_argument("--keep-absolute", action="store_true",
                    help="send paths with their leading '/' (browser strips it)")
    ap.add_argument("--verbose", action="store_true", help="log outgoing frames to stderr")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("login", help="log in and print the raw login response")

    p = sub.add_parser("list", help="file.ls <path> over the file WebSocket")
    p.add_argument("path")

    p = sub.add_parser("check-upload", help="file.checkUpload <path> <size>")
    p.add_argument("path")
    p.add_argument("size", type=int)
    p.add_argument("--overwrite", action="store_true")

    p = sub.add_parser("upload", help="POST /upload <path> <local-file>")
    p.add_argument("path")
    p.add_argument("file")
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("--skip-check", action="store_true",
                   help="do not call file.checkUpload first")

    p = sub.add_parser("raw", help="send one raw RPC frame (JSON with a \"req\" field)")
    p.add_argument("json")
    p.add_argument("--kind", default="main", help="websocket type (default main)")

    a = ap.parse_args(argv)
    api = FnosAPI(a.host, a.user, a.password, tls=a.https,
                  state_path=a.state, verbose=a.verbose)

    if a.cmd == "login":
        r = api.login()
        sys.exit(0 if (isinstance(r, dict) and r.get("result") == "succ") else 1)

    api.ensure_login(no_cache=a.no_cache)

    if a.cmd == "list":
        r = api.file_call("file.ls",
                          {"path": api.rpc_path(a.path, a.keep_absolute)})
        sys.exit(0 if r and r.get("result") == "succ" else 1)

    if a.cmd == "check-upload":
        r = api.file_call("file.checkUpload",
                          {"size": a.size,
                           "path": api.rpc_path(a.path, a.keep_absolute),
                           "overwrite": a.overwrite})
        sys.exit(0 if r and r.get("result") == "succ" else 1)

    if a.cmd == "upload":
        target = api.rpc_path(a.path, a.keep_absolute) or a.path
        check = None
        if not a.skip_check:
            check = api.file_call("file.checkUpload",
                                  {"size": os.path.getsize(a.file),
                                   "path": target,
                                   "overwrite": a.overwrite})
        # The bundle uploads into the temporary name reserved by checkUpload:
        #   u = uploadName ? dirname(target) + "/" + uploadName : target
        upload_path = target
        if check and check.get("uploadName"):
            parts = [p for p in target.split("/") if p]
            head = "/".join(parts[:-1])
            upload_path = (head + "/" if head else "") + check["uploadName"]
        status, _ = api.upload(upload_path, a.file, overwrite=a.overwrite,
                              filename=os.path.basename(a.file))
        sys.exit(0 if 200 <= status < 300 else 1)

    if a.cmd == "raw":
        obj = json.loads(a.json)
        if "reqid" not in obj:
            obj = dict({"reqid": api.reqid()}, **obj)
        # file sockets need the authToken handshake before any file.* call
        ws = api.file_socket() if a.kind == "file" else api.ws_connect(a.kind)
        try:
            r = api.send_raw(ws, obj)
        finally:
            ws.close()
        sys.exit(0 if r and r.get("result") in ("succ", "fail", "cancel") else 1)


if __name__ == "__main__":
    main()
