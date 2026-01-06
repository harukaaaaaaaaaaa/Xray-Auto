#!/bin/bash
# ==============================================================
# Project: Xray Auto Installer
# Author: accforeve
# Repository: https://github.com/accforeve/Xray-Auto
# Version: v0.2 VLESS+reality-Vision/xhttp
# ==============================================================

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root!"
    exit 1
fi

clear
echo "🚀 开始全自动化部署..."

# --- 0. 强制解锁 ---
echo "🔄 检测并清理后台 apt 进程..."
killall apt apt-get 2>/dev/null
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
dpkg --configure -a

# --- 1. 系统初始化 ---
timedatectl set-timezone Asia/Shanghai
export DEBIAN_FRONTEND=noninteractive

echo "📦 更新系统并安装依赖..."
apt-get update -qq
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
DEPENDENCIES="curl wget sudo nano git htop tar unzip socat fail2ban rsyslog chrony iptables qrencode iptables-persistent"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $DEPENDENCIES

if ! command -v fail2ban-client &> /dev/null; then
    echo "软件安装失败，请检查网络源。"
    exit 1
fi

# --- 2. 系统与内核优化 ---
echo "⚙️ 正在执行系统内核优化..."
timedatectl set-timezone Asia/Shanghai

RAM_MB=$(free -m | grep Mem | awk '{print $2}')
if [ "$RAM_MB" -lt 2048 ] && ! grep -q "/swapfile" /etc/fstab; then
    echo "  - 创建 1GB Swap..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

if ! grep -q "SystemMaxUse=200M" /etc/systemd/journald.conf; then
    echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
    systemctl restart systemd-journald
fi

# --- 3. 安装 Xray ---
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
mkdir -p /usr/local/share/xray/
wget -q -O /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
wget -q -O /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

# --- 4. 生成配置 ---
XRAY_BIN="/usr/local/bin/xray"

echo "🔍 正在进行智能 SNI 优选..."
DOMAINS=("www.icloud.com" "www.apple.com" "itunes.apple.com" "learn.microsoft.com" "www.microsoft.com" "www.bing.com")
BEST_MS=9999
BEST_DOMAIN=""

echo -ne "\033[?25l"
for domain in "${DOMAINS[@]}"; do
    echo -ne "  👉 测试: $domain...\r"
    time_cost=$(LC_NUMERIC=C curl -4 -w "%{time_connect}" -o /dev/null -s --connect-timeout 2 "https://$domain")
    if [ -n "$time_cost" ] && [ "$time_cost" != "0.000" ]; then
        ms=$(LC_NUMERIC=C awk -v t="$time_cost" 'BEGIN { printf "%.0f", t * 1000 }')
        if [ "$ms" -lt "$BEST_MS" ]; then
            BEST_MS=$ms
            BEST_DOMAIN=$domain
        fi
    fi
done
echo -ne "\033[?25h"
echo ""

if [ -z "$BEST_DOMAIN" ]; then BEST_DOMAIN="www.icloud.com"; fi
SNI_HOST="$BEST_DOMAIN"
echo "✅ 优选结果: $SNI_HOST (延迟: ${BEST_MS}ms)"

echo "🔑 正在生成身份凭证..."
UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep -E "Public|Password" | awk '{print $2}')
SHORT_ID=$(openssl rand -hex 8)
XHTTP_PATH="/req"

mkdir -p /usr/local/etc/xray/
cat > /usr/local/etc/xray/config.json <<CONFIG_EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": [ "1.1.1.1", "8.8.8.8", "localhost" ] },
  "inbounds": [
    {
      "tag": "vision_node",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI_HOST}:443",
          "serverNames": [ "${SNI_HOST}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    },
    {
      "tag": "xhttp_node",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": { "path": "${XHTTP_PATH}" },
        "realitySettings": {
          "show": false,
          "dest": "${SNI_HOST}:443",
          "serverNames": [ "${SNI_HOST}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": [ "geoip:private", "geoip:cn" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
CONFIG_EOF

# --- 5. 部署工具 ---
mkdir -p /etc/systemd/system/xray.service.d
echo -e "[Service]\nLimitNOFILE=infinity\nLimitNPROC=infinity\nTasksMax=infinity\nRestart=on-failure\nRestartSec=5" > /etc/systemd/system/xray.service.d/override.conf
systemctl daemon-reload
sed -i 's/^#SystemMaxUse=/SystemMaxUse=200M/g' /etc/systemd/journald.conf
systemctl restart systemd-journald

echo -e "#!/bin/bash\nwget -q -O /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat\nwget -q -O /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat\nsystemctl restart xray" > /usr/local/bin/update_geoip.sh && chmod +x /usr/local/bin/update_geoip.sh
(crontab -l 2>/dev/null; echo "0 4 * * 2 /usr/local/bin/update_geoip.sh >/dev/null 2>&1") | sort -u | crontab -

# --- 5. 安全与防火墙配置 ---
echo "🛡️ 配置高级防火墙与安全策略..."
SSH_PORT=$(ss -tlnp | grep sshd | grep LISTEN | awk '{print $4}' | sed 's/.*://' | head -n 1)
[ -z "$SSH_PORT" ] && SSH_PORT=22

iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p tcp -m multiport --dports 443,8443 -j ACCEPT
iptables -A INPUT -p udp -m multiport --dports 443,8443 -j ACCEPT
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
netfilter-persistent save >/dev/null 2>&1

mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local << FAIL2BAN_EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
findtime  = 1d
maxretry = 3
bantime  = 24h
bantime.increment = true
backend = systemd
banaction = iptables-multiport
[sshd]
enabled = true
port    = $SSH_PORT
mode    = aggressive
FAIL2BAN_EOF
systemctl restart rsyslog >/dev/null 2>&1
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# 生成 mode 配置文件
cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config_block.json
sed '/geoip:cn/d' /usr/local/etc/xray/config.json > /usr/local/etc/xray/config_allow.json
sed -i 's/"geoip:private",/"geoip:private"/g' /usr/local/etc/xray/config_allow.json

# 生成 mode 命令
cat > /usr/local/bin/mode << 'MODE_EOF'
#!/bin/bash
GREEN='\033[32m'
WHITE='\033[37m'
YELLOW='\033[33m'
PLAIN='\033[0m'
CONFIG="/usr/local/etc/xray/config.json"
BLOCK_CFG="/usr/local/etc/xray/config_block.json"
ALLOW_CFG="/usr/local/etc/xray/config_allow.json"

if grep -q "geoip:cn" "$CONFIG"; then 
    M1_ICON="${GREEN}●${PLAIN}"; M1_TXT="${GREEN}1. 阻断回国 (Block CN) [当前]${PLAIN}"
    M2_ICON="${WHITE}○${PLAIN}"; M2_TXT="${WHITE}2. 允许回国 (Allow CN)${PLAIN}"
else 
    M1_ICON="${WHITE}○${PLAIN}"; M1_TXT="${WHITE}1. 阻断回国 (Block CN)${PLAIN}"
    M2_ICON="${GREEN}●${PLAIN}"; M2_TXT="${GREEN}2. 允许回国 (Allow CN) [当前]${PLAIN}"
fi

if [ "$1" == "c" ]; then
    echo "🔄 正在切换模式..."
    if grep -q "geoip:cn" "$CONFIG"; then
        cp "$ALLOW_CFG" "$CONFIG"; MSG=">> 已切换为: 允许回国"
    else
        cp "$BLOCK_CFG" "$CONFIG"; MSG=">> 已切换为: 阻断回国"
    fi
    systemctl restart xray && echo -e "${GREEN}${MSG}${PLAIN}"
    exit 0
fi

echo -e "\n模式列表:"
echo -e "  $M1_ICON $M1_TXT"
echo -e "  $M2_ICON $M2_TXT\n"
echo -e "👉 切换指令: ${YELLOW}mode c${PLAIN}\n"
MODE_EOF
chmod +x /usr/local/bin/mode
systemctl enable xray && systemctl restart xray

# --- 6. 结果输出 ---
IPV4=$(curl -s4m 5 https://1.1.1.1/cdn-cgi/trace | grep "ip=" | cut -d= -f2)
if [ -z "$IPV4" ]; then IPV4=$(curl -s4m 5 https://api.ipify.org); fi
HOST_TAG=$(hostname | tr ' ' '.')
[ -z "$HOST_TAG" ] && HOST_TAG="XrayServer"

LINK_VISION="vless://${UUID}@${IPV4}:443?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI_HOST}&sid=${SHORT_ID}#${HOST_TAG}_Vision"
LINK_XHTTP="vless://${UUID}@${IPV4}:8443?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=${XHTTP_PATH}&sni=${SNI_HOST}&sid=${SHORT_ID}#${HOST_TAG}_xhttp"

# 定义颜色变量
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

echo ""
echo "=========================================================="
echo -e "${GREEN}      🚀 部署完成 (v0.2)${PLAIN}"
echo "=========================================================="
echo "服务器详细配置:"
echo "----------------------------------------------------------"
echo -e "地址 (IP)   : ${BLUE}${IPV4}${PLAIN}"
echo -e "优选 SNI    : ${YELLOW}${SNI_HOST}${PLAIN}"
echo -e "UUID        : ${BLUE}${UUID}${PLAIN}"
echo -e "ShortId     : ${BLUE}${SHORT_ID}${PLAIN}"
echo -e "Public Key  : ${BLUE}${PUBLIC_KEY}${PLAIN} (客户端用)"
echo -e "Private Key : ${RED}${PRIVATE_KEY}${PLAIN} (服务端用)"
echo "----------------------------------------------------------"
echo -e "节点 1 (主力): 端口 ${BLUE}443${PLAIN}  流控: ${BLUE}xtls-rprx-vision${PLAIN}"
echo -e "节点 2 (备用): 端口 ${BLUE}8443${PLAIN} 协议: ${BLUE}xhttp${PLAIN} 路径: ${BLUE}${XHTTP_PATH}${PLAIN}"
echo "----------------------------------------------------------"
echo "当前状态与指令:"
echo -e "当前模式    : ${GREEN}阻断回国 (Block CN)${PLAIN}"
echo -e "切换模式    : ${YELLOW}mode c${PLAIN}"
echo -e "查看状态    : ${YELLOW}mode${PLAIN}"
echo "----------------------------------------------------------"
echo ""
echo -e "${YELLOW}👇 节点1 链接 (复制导入 - 推荐):${PLAIN}"
echo -e "${GREEN}${LINK_VISION}${PLAIN}"
echo ""
echo -e "${YELLOW}👇 节点2 链接 (复制导入 - 备用):${PLAIN}"
echo -e "${GREEN}${LINK_XHTTP}${PLAIN}"
echo ""
echo -e "${YELLOW}👇 节点1 二维码:${PLAIN}"
qrencode -t ANSIUTF8 "${LINK_VISION}"
echo ""
echo -e "${YELLOW}👇 节点2 二维码:${PLAIN}"
qrencode -t ANSIUTF8 "${LINK_XHTTP}"
echo ""
