#!/bin/bash
# add-hostdare-novixlink-chain.sh — 在 AX3600 旁路由上加一条 HostDare→NovixLink 链路
# 链路：用户 → HostDare（CN2 GIA 进，59.43 段已实测）→ NovixLink（干净出口）→ 外网
# 原理：sing-box 出站的 detour 字段——novixlink-vless-via-hostdare 连 NovixLink 服务器时，
#      先走 hostdare-vless 隧道，出口 IP 是 NovixLink（192.220.11.243）。
# 注意：这条链只给路由器/电视用。Muse、手机继续 HostDare 直连，不走链（出口 IP 会变）。
# 本脚本在 Mac 上运行：拉路由器配置 → 读 novixlink-vless 参数 → 生成带 detour 的链路出站
#   → 加进配置 → 校验 → 重启 → 补策略路由。final 保持 novixlink-vless（直连）不变，
#   链路加进去当备选，测好再切。
# 用法：bash /tmp/add-hostdare-novixlink-chain.sh
# 运行中会要求输路由器 root 密码（终端里输，不会出现在聊天里）。
set -e

ROUTER_IP="192.168.5.2"

echo "1) 从路由器拉取当前配置..."
ssh "root@$ROUTER_IP" "cat /etc/sing-box/config.json" > /tmp/router-singbox-live.json
cp /tmp/router-singbox-live.json /tmp/router-singbox-backup-$(date +%Y%m%d-%H%M).json
echo "   已备份到 /tmp/router-singbox-backup-*.json"

echo "2) 生成 HostDare→NovixLink 链路出站（detour=hostdare-vless）..."
python3 << 'PYEOF'
import json, copy

cfg = json.load(open('/tmp/router-singbox-live.json'))
outs = cfg.setdefault('outbounds', [])
by_tag = {o.get('tag'): o for o in outs}

nv = by_tag.get('novixlink-vless')
hd = by_tag.get('hostdare-vless')
assert nv is not None, "novixlink-vless not found in router config"
assert hd is not None, "hostdare-vless not found in router config"

# 链路出站：复用 novixlink-vless 的全部参数，只加 detour 指向 hostdare-vless
chain = copy.deepcopy(nv)
chain['tag'] = 'novixlink-vless-via-hostdare'
chain['detour'] = 'hostdare-vless'

# 删掉旧的链路出站（若有），再加新的
outs = [o for o in outs if o.get('tag') != 'novixlink-vless-via-hostdare']
cfg['outbounds'] = outs
# 插到 novixlink-vless 之后
idx = 0
for i, o in enumerate(outs):
    if o.get('tag') == 'novixlink-vless':
        idx = i + 1
        break
outs[idx:idx] = [chain]
# final 保持 novixlink-vless（直连），链路只当备选
assert cfg.get('route', {}).get('final', 'novixlink-vless') == 'novixlink-vless', cfg.get('route', {}).get('final')
json.dump(cfg, open('/tmp/router-singbox-patched.json', 'w'), indent=2, ensure_ascii=False)
print("   已生成 /tmp/router-singbox-patched.json（含 novixlink-vless-via-hostdare，detour=hostdare-vless）")
PYEOF

echo "3) 传回路由器并校验..."
cat /tmp/router-singbox-patched.json | ssh "root@$ROUTER_IP" "cat > /etc/sing-box/config.json"
ssh "root@$ROUTER_IP" "sing-box check -c /etc/sing-box/config.json && echo CHECK-OK"

echo "4) 重启 sing-box，补策略路由..."
ssh "root@$ROUTER_IP" "/etc/init.d/sing-box restart; sleep 5; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo RESTARTED; ip route show table 100"

echo ""
echo "完成。链路 novixlink-vless-via-hostdare 已加进路由器（HostDare→NovixLink），"
echo "当前 final 仍为 novixlink-vless（直连），链路只当备选。"
echo "要切到链路测速时：在路由器上把 route.final 改成 novixlink-vless-via-hostdare 再重启 sing-box，"
echo "或告诉我，我写一条切换命令。切过去后出口 IP 仍是 NovixLink（192.220.11.243），"
echo "但回程走 HostDare 的 CN2。验证：Mac 手动网关后 curl api.ipify.org + 测 YouTube 4K。"
