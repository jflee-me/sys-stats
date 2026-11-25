# AX3600 旁路由透明代理（OpenWrt + sing-box）

> 状态：2026-11-25 15:32 已验证通过。国外走 NovixLink 代理（192.220.11.243），
> 国内直连广州电信（14.145.29.181），微信正常。
> Mac 日常用小火箭（HostDare-VLESS），不用走 AX3600；AX3600 留给电视等装不了小火箭的设备。

## 硬件与接线

- 路由器：小米 AX3600，OpenWrt 25.12.6 正式版（qualcommax/ipq807x，Kernel 6.12.112）。
- LAN：192.168.5.2/24，网关 192.168.5.1（中兴 BE7200 Pro+），DHCP 已关，Wi-Fi 三频段 disabled。
- 固定放中兴旁边，电源网线常插，24 小时开着；网线：中兴 LAN 口 → AX3600 **LAN 口**。
- 拔电/拔网线会让走它代理的设备断网。
- 防火墙已停并禁自启（`/etc/init.d/firewall stop; disable`），中兴是主防火墙；一开代理就断。
- 小米系统 root 密码 = `b609eda8`（回小米分区时还要用）；OpenWrt root 密码用户自设，存 iPhone「密码」App「OpenWrt AX3600」条目。

## sing-box 部署

- 版本：sing-box 1.14.4（aarch64 cortex-a53）。路由器连不上 downloads.openwrt.org，
  改手动传官方 .apk + 5 个内核模块（kmod-inet-diag、kmod-nft-queue、kmod-tun、
  kmod-nfnetlink-queue、kmod-nfnetlink，均 6.12.112-r1），`apk add --allow-untrusted --no-network`。
- 安装包在 `ax3600-openwrt/`（sing-box_1.14.4_openwrt_aarch64_cortex-a53.apk、ax3600-kmods*.tar.gz）。
- 客户端配置由 `setup-ax3600-singbox.sh` 生成（sing-box 1.14 兼容版；用户 Downloads 里的旧副本勿再用）。
- 出站：novixlink-vless（192.220.11.243:443，flow xtls-rprx-vision，sni www.apple.com，utls chrome，
  Reality 公钥+short_id）、novixlink-hy2（8443，insecure，alpn h3）、direct、block。
- TUN 入站：tun0，172.19.0.1/30，auto_route，stack system。
- sing-box 已 enable 开机自启（/etc/rc.d/S99sing-box 已核实）。

## 策略路由（旁路由核心）

- 设备把网关指到 192.168.5.2 后，流量进 br-lan，策略路由把它送进 tun0：
  - `ip rule add iif br-lan table 100`（优先级 8999）
  - `ip route add default dev tun0 table 100`
- 持久化：写在 `/etc/rc.local`（exit 0 之前），含等 tun0 的循环
  （`for i in $(seq 1 30); do [ -d /sys/class/net/tun0 ] && break; sleep 2; done`），重启不丢。
- 调试教训（2026-11-25 上午）：测旁路由前先在 Mac 本地核实网关
  （`netstat -rn | grep default`）。上午不通的真因就是 Mac 默认网关一直是 192.168.5.1（中兴），
  没指到 AX3600。BusyBox `ip` 不支持 `-s`、不支持 `ip route show table 2022`，
  读接口计数用 `/proc/net/dev`。

## 分流（国内直连、国外走代理）

- 脚本：`add-cn-split-routing.sh`（在 Mac 上运行，拉实时配置再改）。
- 规则集：geoip-cn.srs、geosite-cn.srs，从 SagerNet 仓库的 **rule-set 分支**下载
  （`https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs`、
  `https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs`），
  传到路由器 `/etc/sing-box/`，用 `rule_set`（type local，format binary）注册。
- 路由规则最前面：`{"rule_set": "geosite-cn", "outbound": "direct"}`、
  `{"rule_set": "geoip-cn", "outbound": "direct"}`；final 仍为 novixlink-vless。
- DNS：新增 "local" 服务器（UDP 223.5.5.5），DNS 规则 `{"rule_set": "geosite-cn", "server": "local"}`；
  国外走原来的 remote（DoH 223.5.5.5）。
- `route.default_domain_resolver` 设为 "remote"（sing-box 1.14 强制要求，否则校验 FATAL）。

### 踩过的坑（别重走）

1. **.srs 下 404**：SagerNet 最新 release 不再提供 .srs 文件，只有 .db。改走 rule-set 分支。
2. **.db 方案行不通**：sing-box 1.14 校验报错 `geosite database is deprecated in 1.8.0 and removed in 1.12.0`。
   geosite 数据库已移除，只能用 rule_set（.srs）。
3. **UDP DNS 带 `detour: direct` 会让 sing-box 1.14 崩溃循环重启**
   （`FATAL start dns/udp[local]: detour to an empty direct outbound makes no sense`），
   tun0 起不来、表 100 为空、经 AX3600 的设备完全没网。修复：local DNS 不要加 detour，
   223.5.5.5 是国内 IP，不带 detour 时查询会按路由规则走 geoip-cn -> direct，同样直连。
4. **GitHub raw / jsDelivr 缓存顽固**：推上去的新脚本，下下来还是旧版。绕法：用带提交号的
   jsDelivr 链接（`https://cdn.jsdelivr.net/gh/jflee-me/sys-stats@<commit>/add-cn-split-routing.sh`），
   或 raw 链接加 `?v=N` 参数（不一定管用）。
5. **备份可能本身就是坏的**：脚本每轮都在步骤 1 拉当前配置备份；若上一轮已把坏配置写上路由器，
   下一轮拉下来的备份就是坏的。恢复时用**最早**的备份（分流之前的好配置），不要用最新的。
   2026-11-25 恢复用的是 `/tmp/router-singbox-backup-20261125-1512.json`（1645 字节）。

## 验证（Mac 手动网关时）

- Mac：IP 192.168.5.200，网关 192.168.5.2，DNS 223.5.5.5；先退出小火箭。
- `curl -s https://api.ipify.org` 应返回 192.220.11.243（NovixLink）。
- `curl -s https://myip.ipip.net` 应返回电信 IP（2026-11-25 实测：14.145.29.181，广东广州电信）。
- 微信打开、传一张图，应能正常加载，不再转圈。
- 验完 Mac 改回 DHCP（自动）+ DNS 自动，重开小火箭（代理模式、HostDare-VLESS）。

## 诊断命令

```bash
# 路由器状态（tun0、表 100、规则、sing-box 进程、日志）
ssh root@192.168.5.2 "ps w | grep [s]ing-box | head -1; echo ---RULE---; ip rule | grep 8999; echo ---TABLE---; ip route show table 100; echo ---TUN---; cat /proc/net/dev | grep tun0; echo ---LOG---; logread | grep -i sing-box | tail -8"
# 配置校验
ssh root@192.168.5.2 "sing-box check -c /etc/sing-box/config.json"
# 重启并补策略路由
ssh root@192.168.5.2 "/etc/init.d/sing-box restart; sleep 5; ip route add default dev tun0 table 100 2>/dev/null; ip rule add iif br-lan table 100 2>/dev/null; echo DONE"
```

## 待办

- HostDare traceroute 核实 CN2 GIA 回程（需用户从「密码」App 提供 HostDare SSH 端口和密码）。
- 电视 v2rayNG 节点更新（年付机/DIA/NovixLink 是否加进，未定）。
