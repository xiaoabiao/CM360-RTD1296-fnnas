#!/usr/bin/env python3
"""cm360-panel.py —— CM360 本地控制面板（浏览器里点按钮：生成整合包 / 发布 Release / 刷机检查）

为什么是"网页面板"而不是 harness 窗口内的插件
---------------------------------------------
harness 的客户端插件需要把界面代码打成 `lib/client.js` 才能被 Web 端加载，
而那条构建链只存在于 **dsh 源码 checkout**（`pnpm run dev:web`）里；
这台机器上只装了打包好的应用，没有源码 checkout —— 硬写 bundle 无法验证
（看不到界面、也没有 HMR 可对照）。所以这里给一个**等效**方案：
一个只监听 127.0.0.1 的本地网页，按钮直接调用仓库里的真实脚本，
输出实时回显，你点一下就知道结果。

用法
----
    python3 tools/cm360-panel.py                 # 打开 http://127.0.0.1:8799
    python3 tools/cm360-panel.py --port 8899     # 换端口
依赖：纯标准库 + 仓库里的脚本（gh / git / python3）。
"""
import argparse
import json
import os
import secrets
import shlex
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(REPO, "tools", "make-release.sh")
BUILD_IMAGES = os.path.join(REPO, "firmware", "build-images.sh")
FLASHER = os.path.join(REPO, "firmware", "flash-from-pc.py")
BRD_SSH = os.path.join(REPO, "tools", "brd-ssh.sh")

JOBS = {}          # id -> {cmd, out, rc, started, title}
TOKEN = secrets.token_urlsafe(12)


def run_job(job_id, cmd, cwd):
    job = JOBS[job_id]
    try:
        p = subprocess.Popen(cmd, cwd=cwd, shell=isinstance(cmd, str),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1)
        for chunk in iter(lambda: p.stdout.readline(), ""):
            # curl/wget 的进度用 \r 刷新，这里规范成多行，界面上才看得见进度
            for line in chunk.replace("\r", "\n").split("\n"):
                if line.strip():
                    job["out"].append(line.rstrip())
            if len(job["out"]) > 800:
                del job["out"][:200]
        job["rc"] = p.wait()
    except Exception as e:
        job["out"].append("!! 执行异常: %s" % e)
        job["rc"] = -1
    job["done"] = True


def start(title, cmd, cwd=REPO):
    job_id = secrets.token_hex(6)
    JOBS[job_id] = {"title": title, "cmd": cmd, "out": ["$ " + (cmd if isinstance(cmd, str) else " ".join(cmd))],
                    "rc": None, "done": False, "started": time.time()}
    threading.Thread(target=run_job, args=(job_id, cmd, cwd), daemon=True).start()
    return job_id


PAGE = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>CM360 控制面板</title><style>
 body{font:14px/1.6 system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;margin:0;background:#0f1115;color:#e6e6e6}
 header{padding:14px 20px;background:#171a21;border-bottom:1px solid #262b36;display:flex;align-items:center;gap:12px}
 h1{font-size:16px;margin:0;font-weight:600}
 .sub{color:#8b93a7;font-size:12px}
 main{padding:18px 20px;max-width:1100px}
 .row{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:16px}
 button{background:#1f6feb;color:#fff;border:0;border-radius:6px;padding:9px 14px;font-size:13px;cursor:pointer}
 button.g{background:#2ea043}button.y{background:#9e6a03}button.r{background:#a13c3c}button.s{background:#30363d}
 button:disabled{opacity:.5;cursor:default}
 #out{background:#0b0d11;border:1px solid #262b36;border-radius:8px;padding:12px;white-space:pre-wrap;
      font:12px/1.5 ui-monospace,Menlo,Consolas,monospace;height:60vh;overflow:auto}
 #stat{color:#8b93a7;font-size:12px;margin-bottom:8px}
 .ok{color:#3fb950}.bad{color:#f85149}.warn{color:#d29922}
</style></head><body>
<header><h1>CM360 控制面板</h1>
 <span class="sub">生成整合包 · 发布 Release · 刷机检查（本地 127.0.0.1，仅本机可用）</span></header>
<main>
 <div class="row">
  <button class="s" onclick="go('status','查看仓库与板子状态')">① 查看状态</button>
  <button onclick="go('bundle','生成整合包（不发布）')">② 生成整合包</button>
  <button class="g" onclick="go('release-github','发布到 GitHub Releases')">③ 发布到 GitHub</button>
  <button class="y" onclick="go('release-gitea','发布到 Gitea Releases')">④ 发布到 Gitea</button>
  <button class="r" onclick="go('flash-dry','刷机前检查（不写盘）')">⑤ 刷机前检查</button>
 </div>
 <div class="row" style="align-items:center">
  <input id="src" placeholder="官方 fnOS ARM 镜像：本地路径 或 下载直链" style="flex:1;min-width:420px;
    background:#0b0d11;border:1px solid #262b36;color:#e6e6e6;border-radius:6px;padding:8px 10px">
  <button class="s" onclick="go('download', '下载官方包')">⑥ 下载</button>
  <button onclick="go('build-p2', '提取 fnOS rootfs 生成 p2')">⑦ 提取 rootfs → p2</button>
  <button class="s" onclick="go('list-images','查看已生成的镜像')">⑧ 查看镜像</button>
 </div>
 <div id="stat">就绪。所有动作都会先在下方回显实际执行的命令。第 ⑥⑦ 步用上面的输入框（路径或直链）。</div>
 <div id="out">（输出会显示在这里）</div>
</main>
<script>
const TOKEN = "__TOKEN__";
let cur = null, timer = null;
async function go(action, title){
  document.querySelectorAll('button').forEach(b=>b.disabled=true);
  document.getElementById('stat').textContent = '执行中：' + title;
  const src = encodeURIComponent((document.getElementById('src')||{}).value||'');
  const r = await fetch('/api/run?token='+TOKEN+'&action='+action+'&src='+src, {method:'POST'});
  const j = await r.json();
  if (j.error){ document.getElementById('out').textContent = j.error; done(title+' 失败'); return; }
  cur = j.id; poll(title);
}
function poll(title){
  clearInterval(timer);
  timer = setInterval(async ()=>{
    const r = await fetch('/api/log?token='+TOKEN+'&id='+cur);
    const j = await r.json();
    document.getElementById('out').textContent = (j.out||[]).join('\\n');
    document.getElementById('out').scrollTop = 1e9;
    if (j.done){ clearInterval(timer); done(title, j.rc); }
  }, 700);
}
function done(title, rc){
  document.querySelectorAll('button').forEach(b=>b.disabled=false);
  const s = document.getElementById('stat');
  if (rc === 0 || rc === undefined){ s.innerHTML = '<span class="ok">✔ '+title+' 完成</span>'; }
  else { s.innerHTML = '<span class="bad">✗ '+title+' 结束（退出码 '+rc+'）—— 看上面的输出</span>'; }
}
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _auth(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        return q.get("token", [""])[0] == TOKEN

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            body = PAGE.replace("__TOKEN__", TOKEN).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/log":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if not self._auth():
                return self._json({"error": "token 无效"}, 403)
            job = JOBS.get(q.get("id", [""])[0])
            if not job:
                return self._json({"error": "任务不存在"}, 404)
            return self._json({"out": job["out"][-400:], "done": job["done"], "rc": job["rc"]})
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path != "/api/run" or not self._auth():
            return self._json({"error": "token 无效"}, 403)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        action = q.get("action", [""])[0]
        src = (q.get("src", [""])[0] or "").strip()
        acts = {
            "status": ("查看状态", "git -C %s log --oneline -1; echo; ls -la %s/dist 2>/dev/null | tail -4; "
                       "echo; %s sudo 'cat /usr/trim/etc/version; findmnt -no TARGET /vol2; "
                       "curl -s -o /dev/null -w \"panel=%%{http_code}\\n\" --max-time 4 http://127.0.0.1:5666/'"
                       % (REPO, REPO, BRD_SSH)),
            "bundle": ("生成整合包", "bash %s" % RELEASE),
            "release-github": ("发布 GitHub", "bash %s --upload-github" % RELEASE),
            "release-gitea": ("发布 Gitea", "bash %s --upload-gitea" % RELEASE),
            "flash-dry": ("刷机前检查", "python3 %s --dry-run --layers low,p1" % FLASHER),
            "list-images": ("查看镜像", "ls -la %s | awk '{print $5, $9}'" % os.path.join(REPO, "firmware", "images")),
            "download": ("下载官方包", "curl -L --progress-bar -o %s %s"
                         % (shlex.quote(os.path.join(REPO, "build", "fnos-images",
                                                     "fnos_arm_official.img.gz")), shlex.quote(src))),
            "build-p2": ("提取 rootfs → p2", "bash %s p2 %s" % (RELEASE and BUILD_IMAGES, shlex.quote(src))),
        }
        if action not in acts:
            return self._json({"error": "未知动作"}, 400)
        if action in ("download", "build-p2"):
            if not src:
                return self._json({"error": "请先在上面的输入框填官方包路径或直链"}, 400)
            if action == "download" and not (src.startswith("http://") or src.startswith("https://")):
                return self._json({"error": "下载需要 http(s) 直链"}, 400)
            if action == "build-p2" and not os.path.isfile(src):
                return self._json({"error": "本地找不到该文件：%s" % src}, 400)
        title, cmd = acts[action]
        return self._json({"id": start(title, cmd), "title": title})


def main():
    ap = argparse.ArgumentParser(description="CM360 本地控制面板")
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--host", default="127.0.0.1", help="只建议绑本地；绑 0.0.0.0 会暴露到局域网")
    args = ap.parse_args()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("CM360 控制面板已启动：", flush=True)
    print("   http://%s:%d/?token=%s" % (args.host, args.port, TOKEN), flush=True)
    print("   （token 一次性生成，防止局域网里别人乱点；Ctrl+C 停止）", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
