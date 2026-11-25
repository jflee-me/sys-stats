#!/bin/bash
# add-raksmart-novixlink-chain.sh — 在 AX3600 旁路由上加一条 年付机→NovixLink 链路
# 链路：用户 → 年付机（RakSmart CN2 进，107.149.65.118）→ NovixLink（干净出口）→ 外网
# 原理：sing-box 出站的 detour 字段——novixlink-vless-via-raksmart 连 NovixLink 服务器时，
#      先走 raksmart-vless-new 隧道，出口 IP 是 NovixLink（192.220.11.243）。
# 对比对象：现有的 HostDare→NovixLink 链路（novixlink-vless-via-hostdare），
#      两条链路出口都是 NovixLink，区别只在入口（年付机 CN2 vs HostDare CN2 GIA），
#      挨个切过去测，看哪个稳。
# 注意：这条链只给路由器/电视用。Muse、手机继续 HostDare 直连，不走链（出口 IP 会变）。
# 本脚本在 Mac 上运行：
#   1) SSH 进年付机（107.149.65.118:34252，输 root 密码），读 /etc/sing-box/config.json，
#      推导 Reality 公钥，生成 VLESS + HY2 分享链接（只在 Mac 本地处理，不进聊天）。
#   2) 从路由器拉取当前配置，加入 raksmart-vless-new / raksmart-hy2，
#      再加链路出站 novixlink-vless-via-raksmart（detour=raksmart-vless-new），
#      final 保持不变（现在是 novixlink-vless-via-hostdare，链路只当备选）。
#   3) 校验、重启 sing-box、补策略路由。
# 用法：bash /tmp/add-raksmart-novixlink-chain.sh
# 运行中会要求输年付机 root 密码和路由器 root 密码（终端里输，不会出现在聊天里）。
set -e

RAKSMART_IP="107.149.65.118"
RAKSMART_SSH_PORT="34252"
ROUTER_IP="192.168.5.2"

echo "1) 从年付机拉取节点配置（输年付机 root 密码）..."
# 把推导脚本通过管道送到服务器上跑，不在服务器留文件；输出两行 vless:// 与 hysteria2:// 链接
ssh -p "$RAKSMART_SSH_PORT" "root@$RAKSMART_IP" "python3 -" > /tmp/raksmart-links.txt << 'PYEOF'
import base64, json, sys
IP = "107.149.65.118"
cfg = json.load(open("/etc/sing-box/config.json"))
def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
def b64e(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")
uuid = priv = sid = hy = None
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless":
        uuid = ib["users"][0]["uuid"]
        r = ib["tls"]["reality"]
        priv = r["private_key"]
        sid = r["short_id"][0]
    elif ib.get("type") == "hysteria2":
        hy = ib["users"][0]["password"]
if not (uuid and priv and sid and hy):
    print("config parse failed", file=sys.stderr)
    raise SystemExit(1)
# X25519 public key derivation (RFC 7748 Montgomery ladder)
p = 2**255 - 19
a24 = 121665
kb = bytearray(b64d(priv))
kb[0] &= 248
kb[31] &= 127
kb[31] |= 64
n = int.from_bytes(kb, "little")
x1 = 9
x2, z2 = 1, 0
x3, z3 = 9, 1
swap = 0
for t in range(254, -1, -1):
    k_t = (n >> t) & 1
    swap ^= k_t
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    swap = k_t
    A = (x2 + z2) % p
    AA = A * A % p
    B = (x2 - z2) % p
    BB = B * B % p
    E = (AA - BB) % p
    C = (x3 + z3) % p
    D = (x3 - z3) % p
    DA = D * A % p
    CB = C * B % p
    x3 = (DA + CB) % p
    x3 = x3 * x3 % p
    z3 = (DA - CB) % p
    z3 = z3 * z3 % p
    z3 = z3 * x1 % p
    x2 = AA * BB % p
    z2 = E * (AA + a24 * E) % p
if swap:
    x2, x3 = x3, x2
    z2, z3 = z3, z2
pub = (x2 * pow(z2, p - 2, p)) % p
pubkey = b64e(pub.to_bytes(32, "little"))
print(f"vless://{uuid}@{IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk={pubkey}&sid={sid}&type=tcp#RakSmart-VLESS-New")
print(f"hysteria2://{hy}@{IP}:8443?insecure=1&alpn=h3#RakSmart-HY2")
PYEOF
echo "   已取到年付机节点链接（只存 Mac /tmp，不进聊天）"
wc -l /tmp/raksmart-links.txt

echo "2) 从路由器拉取当前配置..."
ssh "root@$ROUTER_IP" "cat /etc/sing-box/config.json" > /tmp/router-singbox-live.json
cp /tmp/router-singbox-live.json /tmp/router-singbox-backup-$(date +%Y%m%d-%H%M).json
echo "   已备份到 /tmp/router-singbox-backup-*.json"

echo "3) 把年付机出站 + 链路出站加进配置（final 保持不变）..."
python3 << 'PYEOF'
import json, re, copy
from urllib.parse import parse_qs, unquote

links = open('/tmp/raksmart-links.txt').read().strip().splitlines()
vl = [l for l in links if l.startswith('vless://')][0]
hy = [l for l in links if l.startswith('hysteria2://')][0]

# 解析 VLESS 链接
m = re.match(r'vless://([^@]+)@([^:]+):(\d+)\?(.*)#(.*)', vl)
uuid, server, port, qs = m.group(1), m.group(2), int(m.group(3)), m.group(4)
q = parse_qs(qs)
vless_out = {
    "type": "vless",
    "tag": "raksmart-vless-new",
    "server": server,
    "server_port": port,
    "uuid": uuid,
    "flow": q.get("flow", [""])[0] or "xtls-rprx-vision",
    "tls": {
        "enabled": True,
        "server_name": q.get("sni", ["www.apple.com"])[0],
        "utls": {"enabled": True, "fingerprint": q.get("fp", ["chrome"])[0]},
        "reality": {
            "enabled": True,
            "public_key": q.get("pbk", [""])[0],
            "short_id": q.get("sid", [""])[0],
        },
    },
}
# 解析 HY2 链接
m2 = re.match(r'hysteria2://([^@]+)@([^:]+):(\d+)\?(.*)#(.*)', hy)
pw, hserver, hport, hqs = m2.group(1), m2.group(2), int(m2.group(3)), m2.group(4)
hq = parse_qs(hqs)
hy2_out = {
    "type": "hysteria2",
    "tag": "raksmart-hy2",
    "server": hserver,
    "server_port": hport,
    "password": unquote(pw),
    "tls": {"enabled": True, "insecure": True, "alpn": ["h3"]},
}

cfg = json.load(open('/tmp/router-singbox-live.json'))
outs = cfg.setdefault('outbounds', [])
by_tag = {o.get('tag'): o for o in outs}
nv = by_tag.get('novixlink-vless')
assert nv is not None, "novixlink-vless not found in router config"

# 链路出站：复用 novixlink-vless 的全部参数，只加 detour 指向 raksmart-vless-new
chain = copy.deepcopy(nv)
chain['tag'] = 'novixlink-vless-via-raksmart'
chain['detour'] = 'raksmart-vless-new'

# 删掉旧的同名出站（若有），再加新的
outs = [o for o in outs if o.get('tag') not in ('raksmart-vless-new', 'raksmart-hy2', 'novixlink-vless-via-raksmart')]
cfg['outbounds'] = outs
# 年付机出站插到 novixlink 出站之后
idx = 0
for i, o in enumerate(outs):
    if o.get('tag', '').startswith('novixlink'):
        idx = i + 1
outs[idx:idx] = [vless_out, hy2_out]
# 链路出站插到 novixlink-vless 之后
idx2 = 0
for i, o in enumerate(outs):
    if o.get('tag') == 'novixlink-vless':
        idx2 = i + 1
        break
outs[idx2:idx2] = [chain]
# final 保持不变（现在是 novixlink-vless-via-hostdare），只当备选
print("   当前 final 保持为：", cfg.get('route', {}).get('final'))
json.dump(cfg, open('/tmp/router-singbox-patched.json', 'w'), indent=2, ensure_ascii=False)
print("   已生成 /tmp/router-singbox-patched.json（含 raksmart-vless-new / raksmart-hy2 / novixlink-vless-via-raksmart）")
PYEOF

echo "4) 传回路由器并校验..."
cat /tmp/router-singbox-patched.json | ssh "root@$ROUTER_IP" "cat > /etc/sing-box/config.json"
ssh "root@$ROUTER_IP" "sing-box check -c /etc/sing-box/config.json && echo CHECK-OK"

echo "5) 重启 sing-box，补策略路由..."
ssh "root@$ROUTER_IP" "/etc/init.d/sing-box restart; sleep 5; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo RESTARTED; ip route show table 100"

echo ""
echo "完成。年付机→NovixLink 链路已加进路由器，当前 final 保持不变。"
echo "要切到新链路测速时：打开 http://192.168.5.2/switch.html 点「链路 年付机 → NovixLink」，"
echo "或在终端把 route.final 改成 novixlink-vless-via-raksmart 再重启 sing-box。"
echo "切过去后出口 IP 仍是 NovixLink（192.220.11.243），但回程走年付机的 CN2。"
echo "验证：Mac 手动网关后 curl api.ipify.org + 测 YouTube 4K，对比 HostDare 那条链路。"
echo "注意：/tmp/raksmart-links.txt 存有节点链接，用完可删：rm /tmp/raksmart-links.txt"
