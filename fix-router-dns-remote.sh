#!/bin/bash
# fix-router-dns-remote.sh — 把 AX3600 路由器 sing-box 的远程 DNS 从阿里 223.5.5.5 改成 Cloudflare 1.1.1.1 (DoH)
# 背景：本地 DNS（223.5.5.5 UDP）管国内域名没问题，但远程 DNS 也是 223.5.5.5 (DoH)，
# 国外域名（youtube.com / google.com）经阿里 DNS 解析到的 IP 从美国出口连不上，
# 两台手机都打不开 Google/YouTube。改成 1.1.1.1 后国外域名解析走 Cloudflare，返回美国适用的 IP。
# 用法：bash /tmp/fix-router-dns-remote.sh
# 步骤：1) 拉路由器当前配置备份  2) 在 Mac 上用 python3 改 remote DNS server 为 1.1.1.1
#       3) 传回路由器并校验  4) 重启 sing-box，补策略路由
set -e
ROUTER="root@192.168.5.2"
CFG="/etc/sing-box/config.json"
BACKUP="/tmp/router-singbox-backup-$(date +%s).json"
PATCHED="/tmp/router-singbox-dns-patched.json"

echo "1) 从路由器拉取当前配置..."
scp -q "$ROUTER:$CFG" "$BACKUP" 2>/dev/null || ssh "$ROUTER" "cat $CFG" > "$BACKUP"
echo "已备份到 $BACKUP"

echo "2) 把 DNS remote server 改成 1.1.1.1 (在 Mac 上改) ..."
python3 - "$BACKUP" "$PATCHED" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
dns = cfg.get('dns', {})
servers = dns.get('servers', [])
changed = False
for s in servers:
    if s.get('tag') == 'remote':
        old = s.get('server')
        s['server'] = '1.1.1.1'
        print(f"remote DNS: {old} -> 1.1.1.1 (type={s.get('type')})")
        changed = True
if not changed:
    print("ERROR: 没找到 tag=remote 的 DNS server", file=sys.stderr)
    sys.exit(1)
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("已写 " + dst)
PYEOF

echo "3) 传回路由器并校验..."
cat "$PATCHED" | ssh "$ROUTER" "cat > $CFG"
ssh "$ROUTER" "sing-box check -c $CFG"
echo "CHECK-OK"

echo "4) 重启 sing-box，补策略路由..."
ssh "$ROUTER" "/etc/init.d/sing-box restart; sleep 5; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo DONE"
echo ""
echo "完成。远程 DNS 已改成 1.1.1.1 (Cloudflare DoH)。"
echo "验证：手机上开 YouTube / accounts.google.com，看能不能打开。"
