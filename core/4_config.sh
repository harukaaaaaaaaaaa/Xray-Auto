# --- SNI 优选 ---
echo -e "\n${BLUE}--- 5. SNI 伪装域优选 ---${PLAIN}"
RAW_DOMAINS=("www.icloud.com" "www.apple.com" "itunes.apple.com" "learn.microsoft.com" "www.bing.com" "www.tesla.com")
TEMP_FILE=$(mktemp)

echo -e "${INFO} 正在检测域名延迟..."
tput civis
for domain in "${RAW_DOMAINS[@]}"; do
    printf "\r   Ping: %-25s" "${domain}..."
    time_cost=$(LC_NUMERIC=C curl $CURL_OPT -w "%{time_connect}" -o /dev/null -s --connect-timeout 2 "https://$domain")
    if [ -n "$time_cost" ] && [ "$time_cost" != "0.000" ]; then
        ms=$(LC_NUMERIC=C awk -v t="$time_cost" 'BEGIN { printf "%.0f", t * 1000 }')
        echo "$ms $domain" >> "$TEMP_FILE"
    else
        echo "999999 $domain" >> "$TEMP_FILE"
    fi
done
tput cnorm
echo -ne "\r\033[K"

SORTED_DOMAINS=() 
index=1
echo -e "   结果清单:"

while read ms domain; do
    SORTED_DOMAINS+=("$domain")
    if [ "$ms" == "999999" ]; then d_ms="Fail"; else d_ms="${ms}ms"; fi
    
    # 绿色推荐标签
    if [ "$index" -eq 1 ]; then tag="${GREEN}[推荐]${PLAIN}"; else tag=""; fi
    
    # 格式化对齐输出
    printf "   %-2d. %-28s %-8s %b\n" "$index" "$domain" "$d_ms" "$tag"
    ((index++))
done < <(sort -n "$TEMP_FILE")
rm -f "$TEMP_FILE"

    echo -e "---------------------------------------------------"
    echo -e "   0 . 自定义域名 (Custom Input)"
    echo -e ""

# --- 交互选择 ---
read_with_timeout "请输入序号选择 (0=自定义)" "1" "$UI_TIMEOUT_LONG"
sel="$USER_INPUT"

SNI_HOST=${SORTED_DOMAINS[0]} # 初始化默认值

if [ "$sel" == "0" ]; then
    # 用户选择自定义，需要重新读取完整字符串
    echo ""
    read -p "   请输入自定义域名 (如 www.google.com): " custom_domain
    if [ -n "$custom_domain" ]; then
        SNI_HOST="$custom_domain"
    else
        echo -e "${WARN} 输入为空，已回退到默认推荐域名。"
    fi
elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -le "${#SORTED_DOMAINS[@]}" ] && [ "$sel" -gt 0 ]; then
    # 用户选择了列表中的序号
    SNI_HOST=${SORTED_DOMAINS[$((sel-1))]}
fi

echo -e "${OK}   已选伪装域: ${GREEN}${SNI_HOST}${PLAIN}\n"

# --- 生成最终配置 ---
# 1. 强制创建配置目录 (防止目录不存在导致写入失败)
mkdir -p /usr/local/etc/xray

XRAY_BIN="/usr/local/bin/xray"

# 2. 核心文件熔断检查
if [ ! -f "$XRAY_BIN" ]; then
    echo -e "${RED}==========================================================${PLAIN}"
    echo -e "${RED} [FATAL] 严重错误：Xray 核心文件未安装成功！               ${PLAIN}"
    echo -e "${RED}==========================================================${PLAIN}"
    echo -e "原因分析："
    echo -e "1. GitHub 连接超时，导致安装脚本下载失败。"
    echo -e "2. 纯 IPv6 机器未正确通过代理连接 GitHub。"
    echo -e ""
    echo -e "${YELLOW}建议：请检查服务器网络，或重新运行脚本。${PLAIN}"
    exit 1
fi

UUID=$($XRAY_BIN uuid)
KEYS=$($XRAY_BIN x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -E "Public|Password" | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 8)
XHTTP_PATH="/$(openssl rand -hex 4)"

# 3. 密钥生成失败检查
if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ]; then
    echo -e "${ERR} 密钥生成失败，无法写入配置！"
    exit 1
fi

# 写入 Config
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": [ "localhost" ] },
  "inbounds": [
    {
      "tag": "vision_node", "port": ${PORT_VISION}, "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "${SNI_HOST}:443", "serverNames": [ "${SNI_HOST}" ], "privateKey": "${PRIVATE_KEY}", "shortIds": [ "${SHORT_ID}" ], "fingerprint": "chrome" } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    },
    {
      "tag": "xhttp_node", "port": ${PORT_XHTTP}, "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}", "flow": "" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "reality", "xhttpSettings": { "path": "${XHTTP_PATH}" }, "realitySettings": { "show": false, "dest": "${SNI_HOST}:443", "serverNames": [ "${SNI_HOST}" ], "privateKey": "${PRIVATE_KEY}", "shortIds": [ "${SHORT_ID}" ], "fingerprint": "chrome" } },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ],
  "routing": { "domainStrategy": "${DOMAIN_STRATEGY}", "rules": [ { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }, { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" } ] }
}
EOF

# Systemd 覆盖
mkdir -p /etc/systemd/system/xray.service.d
echo -e "[Service]\nLimitNOFILE=infinity\nLimitNPROC=infinity\nTasksMax=infinity" > /etc/systemd/system/xray.service.d/override.conf
