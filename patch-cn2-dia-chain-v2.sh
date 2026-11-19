#!/bin/bash
# 年付机(CN2) sing-box 链路补丁 v2：与 v1 相同，但密码优先从文件读，避免手敲抄错。
# 密码文件由 DIA 机直接传过来：/tmp/dia-hy2-pass（600 权限，用后可删）。
# 若文件不存在，则回落到提示输入（与 v1 一样）。
# 在年付机上运行，用法：
#   bash patch-cn2-dia-chain-v2.sh <DIA内网IP>
# 可重复跑：同名出口与规则会先清掉再加，不会重复。
set -e
DIA_IP="${1:?用法: bash $0 <DIA内网IP>}"

PASS_FILE=/tmp/dia-hy2-pass
if [ -f "$PASS_FILE" ]; then
  DIA_PASS="$(tr -d '\r\n' < "$PASS_FILE")"
  echo "密码已从 $PASS_FILE 读取"
else
  read -s -p "请输入 DIA HY2 密码: " DIA_PASS
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
