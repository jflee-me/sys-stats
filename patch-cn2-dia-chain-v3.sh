#!/bin/bash
# 年付机(CN2) sing-box 链路补丁 v3：密码来源三选一，优先从小火箭分享链接提取。
# 用法（在年付机上）：
#   1) 在 Mac 小火箭里右键 RakSmart-DIA-HY2 节点 → 分享/拷贝链接（hysteria2://...）
#   2) 在年付机终端：cat > /tmp/dia-hy2-url ，粘贴链接后按 Ctrl+D
#   3) bash patch-cn2-dia-chain-v3.sh <DIA内网IP>
# 脚本会从链接里取密码（自动 URL 解码），不用手敲、不用手选。
# 若无链接文件，则回落到 /tmp/dia-hy2-pass 文件，再回落到提示输入。
# 可重复跑：同名出口与规则会先清掉再加，不会重复。
set -e
DIA_IP="${1:?用法: bash $0 <DIA内网IP>}"

DIA_PASS=""
if [ -f /tmp/dia-hy2-url ]; then
  DIA_PASS="$(python3 -c "
import sys
from urllib.parse import urlparse, unquote
url = open('/tmp/dia-hy2-url').read().strip()
p = urlparse(url)
pw = unquote(p.password or '')
print(pw)
")"
  echo "密码已从 /tmp/dia-hy2-url 链接提取"
elif [ -f /tmp/dia-hy2-pass ]; then
  DIA_PASS="$(tr -d '\r\n' < /tmp/dia-hy2-pass)"
  echo "密码已从 /tmp/dia-hy2-pass 读取"
else
  read -r -s -p "请输入 DIA HY2 密码: " DIA_PASS
  echo ""
fi
[ -n "$DIA_PASS" ] || { echo "密码不能为空"; exit 1; }

CFG=/etc/sing-box/config.json
cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"
echo "已备份原配置"

python3 - "$DIA_IP" "$DIA_PASS" <<'PYEOF'
import json, sys
dia_ip, dia_pass = sys.argv[1], sys.argv[2]
cfg = json.load(open('/etc/sing-box/config.json'))

# 1. 加 HY2 出口（先清同名，避免重复）
cfg['outbounds'] = [o for o in cfg.get('outbounds', []) if o.get('tag') != 'dia-hy2']
cfg['outbounds'].append({
    "type": "hysteria2",
    "tag": "dia-hy2",
    "server": dia_ip,
    "server_port": 8443,
    "password": dia_pass,
    "tls": {
        "enabled": True,
        "server_name": "www.apple.com",
        "insecure": True,
        "alpn": ["h3"]
    }
})

# 2. 加路由规则（先清同出口旧规则，再插到最前面）
route = cfg.get('route') or {}
rules = [r for r in route.get('rules', []) if r.get('outbound') != 'dia-hy2']
rules.insert(0, {"domain_keyword": ["google", "youtube"], "outbound": "dia-hy2"})
rules.insert(1, {"domain_suffix": ["youtu.be"], "outbound": "dia-hy2"})
route['rules'] = rules
route['final'] = route.get('final', 'direct')
cfg['route'] = route

json.dump(cfg, open('/etc/sing-box/config.json', 'w'), indent=2, ensure_ascii=False)
print("config patched: dia-hy2 -> " + dia_ip + ":8443")
PYEOF

sing-box check -c "$CFG"
systemctl restart sing-box
sleep 2
systemctl is-active sing-box
echo "=== CHAIN PATCH DONE ==="
echo "google/youtube/youtu.be 现走 DIA 内网出口，其余仍直连。"
