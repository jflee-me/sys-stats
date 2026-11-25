#!/bin/bash
# add-cn-split-routing.sh — AX3600 旁路由 sing-box 加分流（国内直连、国外走 NovixLink）
# 背景（2026-11-25 上午实测）：
#   - 透明代理 09:46 验证通过一次（ip.sb 显示 NovixLink 192.220.11.243），之后又不稳：
#     ip.sb 回到电信 IP，终端 curl https://api.ipify.org 无返回。
#   - Mac 全流量走美国代理时微信连不上国内服务器；临时办法是 Mac 改回 DHCP。
#   - 防火墙已停并禁自启（中兴是主防火墙，AX3600 防火墙不用开）。
#   - 当前路由只有 ip_is_private -> direct，其余全走 novixlink-vless（final）。
# 2026-11-25 15:08 修正一：SagerNet 最新 release 已不再提供 .srs 规则集文件
# （geoip-cn.srs / geosite-cn.srs 下 404），改用 .db 数据库文件——
# 但 sing-box 1.14 校验报错：geosite 数据库在 1.8.0 弃用、1.12.0 已移除，
# 所以 .db 方案行不通。
# 2026-11-25 15:11 修正二：改用 rule_set（.srs）方案，.srs 文件在
# SagerNet 仓库的 rule-set 分支上（不在 release 里）：
#   https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs
#   https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs
# 并在打补丁时先清除旧的 geosite/geoip 数据库字段和规则（若上一版已把坏配置写上去了）。
# 本脚本在 Mac 上运行：先从路由器上拉取“当前正在跑”的配置再改（不套用旧脚本生成的版本，
# 上午调试时 DNS 写法已在路由器上改过两轮），改完校验、重启、补策略路由、验证。
# 用法：bash /tmp/add-cn-split-routing.sh
# 运行中会要求输路由器 root 密码（「密码」App「OpenWrt AX3600」条目），在终端里输，不会出现在聊天里。
set -e

ROUTER_IP="192.168.5.2"
RULE_DIR="/etc/sing-box"
GEOIP_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
GEOSITE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"

echo "1) 从路由器拉取当前配置..."
ssh "root@$ROUTER_IP" "cat /etc/sing-box/config.json" > /tmp/router-singbox-live.json
cp /tmp/router-singbox-live.json /tmp/router-singbox-backup-$(date +%Y%m%d-%H%M).json
echo "   已备份到 /tmp/router-singbox-backup-*.json"

echo "2) 下载 geoip-cn.srs / geosite-cn.srs（Mac 上下载，路由器不一定能直连 GitHub）..."
cd /tmp
curl -fL -o geoip-cn.srs "$GEOIP_URL"
curl -fL -o geosite-cn.srs "$GEOSITE_URL"
ls -l geoip-cn.srs geosite-cn.srs

echo "3) 传规则集到路由器..."
cat geoip-cn.srs | ssh "root@$ROUTER_IP" "cat > $RULE_DIR/geoip-cn.srs"
cat geosite-cn.srs | ssh "root@$ROUTER_IP" "cat > $RULE_DIR/geosite-cn.srs"

echo "4) 给配置加分流（只改 route/dns，不动出站节点和已修好的 DNS 写法）..."
python3 << 'PYEOF'
import json
cfg = json.load(open('/tmp/router-singbox-live.json'))

# --- 先清掉已弃用的 geosite/geoip 数据库字段和规则（上一版若写坏了配置，这里修掉）---
route = cfg.setdefault('route', {})
route.pop('geoip', None)
route.pop('geosite', None)

rules = route.setdefault('rules', [])
# 删掉含已弃用 geosite/geoip 字段的规则，以及旧的 cn 规则集条目（下面会重新加）
rules = [r for r in rules
         if 'geosite' not in r and 'geoip' not in r
         and r.get('rule_set') not in ('geosite-cn', 'geoip-cn')]
route['rules'] = rules

# --- 注册本地规则集，国内域名/IP 走 direct ---
rs = route.setdefault('rule_set', [])
rs = [r for r in rs if r.get('tag') not in ('geoip-cn', 'geosite-cn')]
route['rule_set'] = rs
rs.append({"tag": "geoip-cn", "type": "local", "format": "binary", "path": "/etc/sing-box/geoip-cn.srs"})
rs.append({"tag": "geosite-cn", "type": "local", "format": "binary", "path": "/etc/sing-box/geosite-cn.srs"})

# 插到最前面（private 规则之后、final 之前都行；放最前面最稳）
new_rules = [
    {"rule_set": "geosite-cn", "outbound": "direct"},
    {"rule_set": "geoip-cn", "outbound": "direct"},
]
for r in reversed(new_rules):
    if r not in rules:
        rules.insert(0, r)
# final 保持走代理（应为 novixlink-vless）
assert route.get('final', 'novixlink-vless') == 'novixlink-vless', route.get('final')

# --- dns: 国内域名用本地 UDP 直连解析，国外走原来的 remote ---
dns = cfg.setdefault('dns', {})
servers = dns.setdefault('servers', [])
tags = {s.get('tag') for s in servers}
if 'local' not in tags:
    servers.insert(0, {"tag": "local", "type": "udp", "server": "223.5.5.5", "detour": "direct"})
dns_rules = dns.setdefault('rules', [])
dns_rules = [r for r in dns_rules
             if 'geosite' not in r and 'geoip' not in r
             and r.get('rule_set') != 'geosite-cn']
dns['rules'] = dns_rules
if not any(r.get('rule_set') == 'geosite-cn' for r in dns_rules):
    dns_rules.insert(0, {"rule_set": "geosite-cn", "server": "local"})
# final 保持原来的 remote（若原来没写 final，默认就是最后一条 server；这里不强制改）

json.dump(cfg, open('/tmp/router-singbox-patched.json', 'w'), indent=2, ensure_ascii=False)
print("   已生成 /tmp/router-singbox-patched.json")
PYEOF

echo "5) 传回路由器并校验..."
cat /tmp/router-singbox-patched.json | ssh "root@$ROUTER_IP" "cat > /etc/sing-box/config.json"
ssh "root@$ROUTER_IP" "sing-box check -c /etc/sing-box/config.json && echo CHECK-OK"

echo "6) 重启 sing-box，补策略路由..."
ssh "root@$ROUTER_IP" "/etc/init.d/sing-box restart; sleep 3; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo RESTARTED"

echo ""
echo "7) 验证（Mac 网关先改回 192.168.5.2，IP 192.168.5.200，DNS 223.5.5.5）："
echo "   curl -s https://api.ipify.org; echo        # 应返回 192.220.11.243（NovixLink）"
echo "   curl -s https://myip.ipip.net; echo        # 国内站，应返回电信 IP（直连）"
echo "   微信打开、传一张图                         # 应能正常加载，不再转圈"
echo "   若仍不通：ssh root@192.168.5.2 \"logread -e sing-box | tail -20\" 看报错发我。"
