#!/bin/sh
# switch-final (CGI) — 旁路由线路切换，供 /www/switch.html 调用
# 用法：浏览器打开 /cgi-bin/switch-final?final=<tag>
# 只允许三个值：hostdare-vless / novixlink-vless / novixlink-vless-via-hostdare
# 动作：sed 替换 route.final（只换三个出口值，不动 DNS 的 "remote"），校验，重启 sing-box，补表 100
CFG="/etc/sing-box/config.json"

urldecode() {
  # 最小 urldecode：只处理 %XX 与 +
  printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs -0 printf '%b' 2>/dev/null
}

# 取 final 参数
FINAL=""
OLD_IFS="$IFS"; IFS='&'
for kv in $QUERY_STRING; do
  case "$kv" in
    final=*) FINAL=$(urldecode "${kv#final=}") ;;
  esac
done
IFS="$OLD_IFS"

echo "Content-type: text/html; charset=utf-8"
echo ""

# 校验
case "$FINAL" in
  hostdare-vless|novixlink-vless|novixlink-vless-via-hostdare) ;;
  *)
    echo "<html><body><h2>参数不对</h2><p>final 只能是 hostdare-vless / novixlink-vless / novixlink-vless-via-hostdare，收到：$(printf '%s' "$FINAL" | sed 's/[<>&]//g')</p><p><a href=\"/switch.html\">返回</a></p></body></html>"
    exit 0
    ;;
esac

# 备份
cp "$CFG" "/tmp/router-singbox-backup-cgi-$(date +%s).json"

# 只替换 route.final（三个出口值之一），不动 DNS 的 "remote"
sed -i -E "s/\"final\": \"(novixlink-vless|hostdare-vless|novixlink-vless-via-hostdare)\"/\"final\": \"$FINAL\"/" "$CFG"

# 校验
if ! sing-box check -c "$CFG" >/tmp/singbox-check.log 2>&1; then
  echo "<html><body><h2>校验失败，已恢复备份</h2><pre>$(cat /tmp/singbox-check.log | sed 's/[<>&]//g')</pre><p><a href=\"/switch.html\">返回</a></p></body></html>"
  # 恢复最近的备份
  LATEST=$(ls -t /tmp/router-singbox-backup-cgi-*.json 2>/dev/null | head -1)
  [ -n "$LATEST" ] && cp "$LATEST" "$CFG"
  exit 0
fi

# 重启并补策略路由
/etc/init.d/sing-box restart
sleep 5
ip route add default dev tun0 table 100 2>/dev/null
ip rule add iif br-lan table 100 2>/dev/null

# 读回当前 final（route 的那一个）
CUR=$(grep -o '"final": "[^"]*"' "$CFG" | tail -1)

echo "<html><body><h2>已切换</h2><p>当前出口：<b>$CUR</b></p><p>手机上开 YouTube / ip.sb 验证一下。</p><p><a href=\"/switch.html\">返回切换页</a></p></body></html>"
