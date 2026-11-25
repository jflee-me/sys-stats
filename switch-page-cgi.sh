#!/bin/sh
# switch-page (CGI) — 旁路由线路切换页（动态版，当前出口的按钮会亮灯）
# 用法：浏览器打开 /cgi-bin/switch-page（或 http://192.168.5.2/switch.html，会跳转过来）
# 动作：读 /etc/sing-box/config.json 的 route.final，给对应的按钮加绿色亮色 +「当前」标记，
#      并在按钮上方用文字写明当前出口。
CFG="/etc/sing-box/config.json"

# 读当前 final（route 的那一个，取最后一个 final）
CUR=$(grep -o '"final": "[^"]*"' "$CFG" 2>/dev/null | tail -1 | sed 's/"final": "//; s/"//')
[ -z "$CUR" ] && CUR=""

# 友好名字
case "$CUR" in
  hostdare-vless) CURLABEL="HostDare（CN2 GIA）" ;;
  novixlink-vless) CURLABEL="NovixLink（直连）" ;;
  novixlink-vless-via-hostdare) CURLABEL="链路 HostDare → NovixLink" ;;
  novixlink-vless-via-raksmart) CURLABEL="链路 年付机 → NovixLink" ;;
  *) CURLABEL="$CUR" ;;
esac

btn() {
  # $1=final 值，$2=按钮文字；当前出口的按钮加 class="on"（绿底白字）+「当前」标记
  if [ "$1" = "$CUR" ]; then
    printf '<button type="submit" name="final" value="%s" class="on">%s（当前）</button>\n' "$1" "$2"
  else
    printf '<button type="submit" name="final" value="%s">%s</button>\n' "$1" "$2"
  fi
}

echo "Content-type: text/html; charset=utf-8"
echo ""
cat <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>旁路由线路切换</title>
<style>
body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;max-width:480px;margin:40px auto;padding:0 20px;color:#222}
h1{font-size:22px;margin-bottom:8px}
p{color:#666;font-size:14px;line-height:1.6}
button{display:block;width:100%;padding:16px;margin:12px 0;font-size:17px;color:#1a1a1a;border:1px solid #999;border-radius:10px;background:#e9e9e9;cursor:pointer}
button.on{background:#2e7d32;color:#fff;border-color:#2e7d32}
button:active{background:#e8e8e8}
button.on:active{background:#27682b}
.note{font-size:13px;color:#888;margin-top:20px}
.cur{font-size:15px;color:#2e7d32;margin:10px 0}
</style>
</head>
<body>
<h1>旁路由线路切换</h1>
<p>点一个按钮就切换出口，路由器会自动重启 sing-box 并补好策略路由。切完后在手机上开 YouTube / ip.sb 验证。</p>
HTMLEOF
printf '<p class="cur">当前出口：<b>%s</b></p>\n' "$CURLABEL"
echo '<form action="/cgi-bin/switch-final" method="get">'
btn "hostdare-vless" "HostDare（CN2 GIA，推荐）"
btn "novixlink-vless" "NovixLink（直连）"
btn "novixlink-vless-via-hostdare" "链路 HostDare → NovixLink"
btn "novixlink-vless-via-raksmart" "链路 年付机 → NovixLink"
cat <<'HTMLEOF'
</form>
<p class="note">当前出口可在手机上开 ip.sb 查看：202.91.33.126 是 HostDare，192.220.11.243 是 NovixLink。</p>
</body>
</html>
HTMLEOF
