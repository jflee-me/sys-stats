#!/bin/bash
# install-router-switch.sh — 在 AX3600 上安装线路切换网页（一次搞定）
# 装完后，手机/电脑浏览器打开 http://192.168.5.2/switch.html ，点按钮就能切线路，不用再敲终端。
# 组成：/www/switch.html（按钮页）+ /www/cgi-bin/switch-final（CGI，执行切换）
# 用法：bash /tmp/install-router-switch.sh
set -e
ROUTER="root@192.168.5.2"
BASE="https://cdn.jsdelivr.net/gh/jflee-me/sys-stats@COMMIT_PLACEHOLDER"

echo "1) 下载网页与 CGI ..."
curl -fsSL "$BASE/router-switch.html" -o /tmp/router-switch.html
curl -fsSL "$BASE/switch-final-cgi.sh" -o /tmp/switch-final-cgi.sh

echo "2) 传到路由器 ..."
scp -q /tmp/router-switch.html "$ROUTER:/www/switch.html"
scp -q /tmp/switch-final-cgi.sh "$ROUTER:/www/cgi-bin/switch-final"
ssh "$ROUTER" "chmod +x /www/cgi-bin/switch-final; ls -l /www/switch.html /www/cgi-bin/switch-final"

echo "3) 确认 uhttpd 在跑 ..."
ssh "$ROUTER" "/etc/init.d/uhttpd status || /etc/init.d/uhttpd start"

echo ""
echo "完成。浏览器打开 http://192.168.5.2/switch.html 点按钮切线路。"
echo "注意：这个页面只能在家里局域网打开（192.168.5.x），外网打不开。"
