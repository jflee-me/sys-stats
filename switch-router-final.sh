#!/bin/bash
# switch-router-final.sh — 切换 AX3600 旁路由的 route.final（出口），并重启 sing-box、补策略路由
# 修复：路由器上没有 python3，JSON 修改改在 Mac 上做（先拉配置、改好、再传回），
#      与 add-hostdare-to-router.sh / add-cn-split-routing.sh 同一路子。
# 用法：
#   bash /tmp/switch-router-final.sh novixlink-vless-via-hostdare   # 切到 HostDare→NovixLink 链路
#   bash /tmp/switch-router-final.sh novixlink-vless               # 切回 NovixLink 直连
#   bash /tmp/switch-router-final.sh hostdare-vless                # 切到 HostDare 直连
# 运行中会要求输路由器 root 密码（终端里输，不会出现在聊天里）。
set -e
TARGET="${1:?用法：bash $0 <出站 tag，如 novixlink-vless-via-hostdare>}"
ROUTER_IP="192.168.5.2"

echo "1) 从路由器拉取当前配置..."
ssh "root@$ROUTER_IP" "cat /etc/sing-box/config.json" > /tmp/router-singbox-live.json
cp /tmp/router-singbox-live.json /tmp/router-singbox-backup-$(date +%Y%m%d-%H%M).json
echo "   已备份到 /tmp/router-singbox-backup-*.json"

echo "2) 把 route.final 改成 $TARGET（在 Mac 上改）..."
TARGET="$TARGET" python3 << 'PYEOF'
import json, os
target = os.environ['TARGET']
cfg = json.load(open('/tmp/router-singbox-live.json'))
tags = [o.get('tag') for o in cfg.get('outbounds', [])]
assert target in tags, f"outbound not found: {target} (现有：{tags})"
cfg.setdefault('route', {})['final'] = target
json.dump(cfg, open('/tmp/router-singbox-patched.json', 'w'), indent=2, ensure_ascii=False)
print(f"   final = {target}")
PYEOF

echo "3) 传回路由器并校验..."
cat /tmp/router-singbox-patched.json | ssh "root@$ROUTER_IP" "cat > /etc/sing-box/config.json"
ssh "root@$ROUTER_IP" "sing-box check -c /etc/sing-box/config.json && echo CHECK-OK"

echo "4) 重启 sing-box，补策略路由..."
ssh "root@$ROUTER_IP" "/etc/init.d/sing-box restart; sleep 5; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo RESTARTED; ip route show table 100"
echo ""
echo "完成。当前 final = $TARGET。"
echo "验证：Mac 改手动网关（192.168.5.2）后 curl https://api.ipify.org（出口 IP 应为 NovixLink 192.220.11.243），再测 YouTube 4K。"
