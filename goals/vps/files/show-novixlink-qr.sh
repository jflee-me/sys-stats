#!/bin/bash
# 从 /etc/sing-box/config.json 读取现成密钥，推导 Reality 公钥，
# 拼出 VLESS / HY2 链接并用 qrencode 直接在终端打出二维码，
# 手机小火箭扫码即可，无需人工抄链接。
set -e

apt-get install -y qrencode python3-pip >/dev/null 2>&1 || true
pip install --break-system-packages -q cryptography 2>/dev/null || pip3 install --break-system-packages -q cryptography 2>/dev/null || true

python3 << 'PYEOF'
import json, base64, subprocess

cfg = json.load(open('/etc/sing-box/config.json'))
vless_in = [i for i in cfg['inbounds'] if i['type'] == 'vless'][0]
hy2_in = [i for i in cfg['inbounds'] if i['type'] == 'hysteria2'][0]

uuid = vless_in['users'][0]['uuid']
priv_b64 = vless_in['tls']['reality']['private_key']
sid = vless_in['tls']['reality']['short_id'][0]
hy_pass = hy2_in['users'][0]['password']

# X25519 私钥 -> 公钥
def b64url_decode(s):
    s += '=' * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)

def b64url_encode(b):
    return base64.urlsafe_b64encode(b).decode().rstrip('=')

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
priv = X25519PrivateKey.from_private_bytes(b64url_decode(priv_b64))
pub = priv.public_key().public_bytes_raw()
pub_b64 = b64url_encode(pub)

import urllib.request
ip = urllib.request.urlopen('https://ifconfig.me', timeout=10).read().decode().strip()

vless = f"vless://{uuid}@{ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk={pub_b64}&sid={sid}&type=tcp#NovixLink-VLESS"
hy2 = f"hysteria2://{hy_pass}@{ip}:8443?insecure=1&sni=www.apple.com#NovixLink-HY2"

open('/tmp/novixlink-vless.txt', 'w').write(vless)
open('/tmp/novixlink-hy2.txt', 'w').write(hy2)
print("VLESS link saved, HY2 link saved.")
PYEOF

echo ""
echo "================ VLESS QR ================"
qrencode -t ANSIUTF8 "$(cat /tmp/novixlink-vless.txt)"
echo ""
echo "================ HY2 QR ================"
qrencode -t ANSIUTF8 "$(cat /tmp/novixlink-hy2.txt)"
echo ""
echo "扫上面两个二维码，先扫 VLESS。"
