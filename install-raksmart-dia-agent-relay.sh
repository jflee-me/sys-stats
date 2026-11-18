#!/bin/bash
# RakSmart DIA 机 · VPS 面板统计上报安装器（统计员 + 中转推送，一次装完）
# 统计员：vnstat 记录 ens7 月流量 + 只读 JSON 统计页（39001 端口随机路径）
# 中转：每 5 分钟把统计页 JSON 推到 GitHub 仓库 sys-stats 的 stats-dia.json（独立文件，不动年付机的 stats.json）
# 凭据：/etc/vps-relay/token（细粒度 PAT，仅 sys-stats 仓 Contents 读写），安装前须先放好（从年付机直接管道传过来，不经聊天）
# 不含任何服务器密码；token 文件权限 600，仅 root 可读。
set -e
if [ "$(id -u)" != "0" ]; then echo "请用 root 运行"; exit 1; fi

if [ ! -s /etc/vps-relay/token ]; then
  echo "缺少 /etc/vps-relay/token：请先把 GitHub 细粒度 PAT 放进该文件（chmod 600），再重跑本脚本。"
  exit 1
fi

DIA_PATH="/stats-46bec75c9968d3c471008cb73b20a2f3"

echo "=== 1. 依赖（vnstat / python3 / ping）==="
apt-get update -y
apt-get install -y vnstat python3 iputils-ping
systemctl enable vnstat >/dev/null 2>&1 || true
systemctl restart vnstat || true
vnstat -i ens7 --add >/dev/null 2>&1 || true

echo "=== 2. 写 DIA 统计服务 ==="
cat > /usr/local/bin/vps-agent-dia.py <<PYEOF
#!/usr/bin/env python3
# Read-only stats JSON for the VPS panel (DIA machine). Serves only on a secret path; 404 elsewhere.
# Field names mirror the panel snapshot schema (bytes for traffic).
import json, os, re, shutil, subprocess, time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PATH = "$DIA_PATH"
IFACE = "ens7"
CST = timezone(timedelta(hours=8))
_cache = {"t": 0, "data": None}

def month_bytes():
    try:
        out = subprocess.run(["vnstat", "-i", IFACE, "--json"],
                             capture_output=True, text=True, timeout=10).stdout
        d = json.loads(out)
        now = datetime.now(CST)
        for iface in d.get("interfaces", []):
            for m in iface.get("traffic", {}).get("month", []):
                date = m.get("date", {})
                if date.get("year") == now.year and date.get("month") == now.month:
                    return int(m.get("rx", 0)), int(m.get("tx", 0))
    except Exception:
        pass
    return None, None

def ping_ms():
    try:
        out = subprocess.run(["ping", "-c", "3", "-W", "2", "202.96.128.86"],
                             capture_output=True, text=True, timeout=12).stdout
        m = re.search(r"avg[/ =]*([0-9.]+)", out) or re.search(r"time[=<]([0-9.]+)", out)
        if m:
            return round(float(m.group(1)))
    except Exception:
        pass
    return None

def mem_pct():
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = int(v.split()[0])
        total = info["MemTotal"]
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        return round((total - avail) / total * 100, 1)
    except Exception:
        return None

def cpu_times():
    with open("/proc/stat") as f:
        parts = f.readline().split()[1:]
    vals = [int(x) for x in parts]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return sum(vals), idle

def cpu_pct():
    try:
        t1, i1 = cpu_times()
        time.sleep(0.3)
        t2, i2 = cpu_times()
        dt = t2 - t1
        if dt <= 0:
            return None
        return round((1 - (i2 - i1) / dt) * 100, 1)
    except Exception:
        return None

def uptime_s():
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return None

def collect():
    if time.time() - _cache["t"] < 120 and _cache["data"]:
        return _cache["data"]
    rx, tx = month_bytes()
    du = shutil.disk_usage("/")
    now = datetime.now(CST)
    data = {
        "machine": "raksmart-dia",
        "month": now.strftime("%Y-%m"),
        "monthRxBytes": rx,
        "monthTxBytes": tx,
        "pingMs": ping_ms(),
        "memPct": mem_pct(),
        "diskPct": round(du.used / du.total * 100, 1),
        "cpuPct": cpu_pct(),
        "load": [round(x, 2) for x in os.getloadavg()],
        "uptimeS": uptime_s(),
        "deviceTs": int(time.time()),
        "ts": now.isoformat(),
    }
    _cache.update(t=time.time(), data=data)
    return data

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != PATH:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(collect()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("0.0.0.0", 39001), H).serve_forever()
PYEOF

cat > /etc/systemd/system/vps-agent-dia.service <<'SVCEOF'
[Unit]
Description=VPS panel stats agent (RakSmart DIA)
After=network.target vnstat.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vps-agent-dia.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable vps-agent-dia >/dev/null 2>&1 || true
systemctl restart vps-agent-dia
sleep 1
systemctl is-active vps-agent-dia

echo "=== 3. 写 DIA 中转推送脚本 ==="
cat > /usr/local/bin/vps-relay-push-dia.py <<PYEOF
#!/usr/bin/env python3
# Push DIA machine stats JSON to GitHub repo jflee-me/sys-stats (file stats-dia.json).
# Token read from /etc/vps-relay/token (fine-grained PAT, Contents read+write on sys-stats only).
import base64, json, urllib.request, urllib.error

TOKEN_PATH = "/etc/vps-relay/token"
LOCAL_STATS = "http://127.0.0.1:39001$DIA_PATH"
REPO_API = "https://api.github.com/repos/jflee-me/sys-stats/contents/stats-dia.json"

def gh_call(method, url, token, payload=None):
    raw = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=raw, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "vps-relay-dia")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.status, resp.read()

def main():
    token = open(TOKEN_PATH).read().strip()
    if not token:
        print("DIA RELAY: token file empty")
        return 1
    with urllib.request.urlopen(LOCAL_STATS, timeout=15) as r:
        stats = r.read()
    json.loads(stats)  # must be valid JSON
    try:
        _, body = gh_call("GET", REPO_API, token)
        sha = json.loads(body).get("sha")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            sha = None
        else:
            raise
    payload = {"message": "stats-dia update",
               "content": base64.b64encode(stats).decode()}
    if sha:
        payload["sha"] = sha
    status, _ = gh_call("PUT", REPO_API, token, payload)
    print("DIA RELAY PUSH OK", status)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
chmod 700 /usr/local/bin/vps-relay-push-dia.py

echo "=== 4. 注册中转定时任务（每 5 分钟）==="
cat > /etc/systemd/system/vps-relay-push-dia.service <<'SVCEOF'
[Unit]
Description=Push DIA stats to GitHub relay
After=network.target vps-agent-dia.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/vps-relay-push-dia.py
User=root
SVCEOF
cat > /etc/systemd/system/vps-relay-push-dia.timer <<'TMEOF'
[Unit]
Description=Push DIA stats to GitHub relay every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true
Unit=vps-relay-push-dia.service

[Install]
WantedBy=timers.target
TMEOF

systemctl daemon-reload
systemctl enable vps-relay-push-dia.timer >/dev/null 2>&1 || true
systemctl start vps-relay-push-dia.timer

echo "=== 5. 立即试推一次 ==="
/usr/bin/python3 /usr/local/bin/vps-relay-push-dia.py
echo ""
echo "================ DIA AGENT+RELAY DONE ================"
echo "验证：浏览器开 https://raw.githubusercontent.com/jflee-me/sys-stats/main/stats-dia.json 应看到 JSON"
