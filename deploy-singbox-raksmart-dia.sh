#!/bin/bash
# RakSmart 双ISP DIA 新机 (Ubuntu 24.04) sing-box 一键部署：
# VLESS + Reality (TCP 443) + Hysteria2 (UDP 8443)
# 与年付机脚本相同，仅节点名改为 -DIA，避免小火箭里重名。
# 运行后会打印两条客户端链接，把 DEPLOY DONE 那段发回给 Muse 即可。
set -e

echo "=== 1. 依赖 ==="
apt-get update -y
apt-get install -y curl openssl

echo "=== 2. 安装 sing-box ==="
if ! command -v sing-box >/dev/null 2>&1; then
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi
sing-box version

echo "=== 3. 生成密钥 ==="
UUID=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
HY_PASS=$(openssl rand -hex 12)
KP=$(sing-box generate reality-keypair)
PRIV=$(echo "$KP" | grep -i private | awk '{print $NF}')
PUB=$(echo "$KP" | grep -i public | awk '{print $NF}')
SID=$(openssl rand -hex 4)
if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
  echo "Reality 密钥生成失败，输出为："; echo "$KP"; exit 1
fi

mkdir -p /etc/sing-box
openssl req -x509 -newkey rsa:2048 \
  -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem \
  -days 3650 -nodes -subj "/CN=www.apple.com" 2>/dev/null

cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "www.apple.com", "server_port": 443},
          "private_key": "$PRIV",
          "short_id": ["$SID"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{"password": "$HY_PASS"}],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

sing-box check -c /etc/sing-box/config.json
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 2
systemctl is-active sing-box

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 443/tcp >/dev/null
  ufw allow 8443/udp >/dev/null
fi

IP=$(curl -fsSL -4 --max-time 10 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "================ DEPLOY DONE ================"
echo "VLESS:"
echo "vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#RakSmart-DIA-VLESS"
echo ""
echo "HY2:"
echo "hysteria2://${HY_PASS}@${IP}:8443?insecure=1&sni=www.apple.com#RakSmart-DIA-HY2"
echo "=============================================="
