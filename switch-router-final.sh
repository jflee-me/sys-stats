#!/bin/bash
# switch-router-final.sh — 切换 AX3600 旁路由的 route.final（出口），并重启 sing-box、补策略路由
# 用法：
#   bash /tmp/switch-router-final.sh novixlink-vless-via-hostdare   # 切到 HostDare→NovixLink 链路
#   bash /tmp/switch-router-final.sh novixlink-vless               # 切回 NovixLink 直连
#   bash /tmp/switch-router-final.sh hostdare-vless                # 切到 HostDare 直连
# 运行中会要求输路由器 root 密码（终端里输，不会出现在聊天里）。
set -e
TARGET="${1:?用法：bash $0 <出站 tag，如 novixlink-vless-via-hostdare>}"
ROUTER_IP="192.168.5.2"

echo "把 route.final 改成 $TARGET ..."
ssh "root@$ROUTER_IP" "python3 -c \"import json; c=json.load(open('/etc/sing-box/config.json')); assert '$TARGET' in [o.get('tag') for o in c.get('outbounds',[])], 'outbound not found: $TARGET'; c['route']['final']='$TARGET'; json.dump(c, open('/etc/sing-box/config.json','w'), indent=2, ensure_ascii=False); print('final =', c['route']['final'])\""
ssh "root@$ROUTER_IP" "sing-box check -c /etc/sing-box/config.json && echo CHECK-OK"
ssh "root@$ROUTER_IP" "/etc/init.d/sing-box restart; sleep 5; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo RESTARTED; ip route show table 100"
echo ""
echo "完成。当前 final = $TARGET。"
echo "验证：Mac 改手动网关（192.168.5.2）后 curl https://api.ipify.org（出口 IP 应为 NovixLink 192.220.11.243），再测 YouTube 4K。"
