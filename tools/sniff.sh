#!/bin/bash

# =========================================================
# 定义颜色
# =========================================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
LOG_FILE="/var/log/xray/access.log"

# 检查依赖
if ! command -v jq &> /dev/null; then echo -e "${RED}错误: 缺少 jq 组件。${PLAIN}"; exit 1; fi

# =========================================================
# 核心函数
# =========================================================

# 1. 获取嗅探状态
get_sniff_status() {
    if [ ! -f "$CONFIG_FILE" ]; then echo "Error"; return; fi
    local status=$(jq -r '.inbounds[0].sniffing.enabled // false' "$CONFIG_FILE")
    if [ "$status" == "true" ]; then
        echo -e "${GREEN}已开启 (Enabled)${PLAIN}"
    else
        echo -e "${RED}已关闭 (Disabled)${PLAIN}"
    fi
}

# 2. 获取日志状态
get_log_status() {
    local access_path=$(jq -r '.log.access // ""' "$CONFIG_FILE")
    if [[ "$access_path" != "" ]]; then
        echo -e "${GREEN}已开启${PLAIN}"
    else
        echo -e "${RED}未配置${PLAIN}"
    fi
}

# 3. 切换嗅探开关
toggle_sniffing() {
    local target_state=$1 # true or false
    
    echo -e "${BLUE}>>> 正在修改配置...${PLAIN}"
    
    # 备份防挂
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    tmp=$(mktemp)
    
    # 构造 jq 命令
    if [ "$target_state" == "true" ]; then
        jq '
          .inbounds |= map(
            if .protocol == "vless" then
              .sniffing = {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
              }
            else
              .
            end
          )
        ' "$CONFIG_FILE" > "$tmp"
    else
        jq '
          .inbounds |= map(
            if .protocol == "vless" then
              .sniffing.enabled = false
            else
              .
            end
          )
        ' "$CONFIG_FILE" > "$tmp"
    fi
    
    if [ -s "$tmp" ]; then
        mv "$tmp" "$CONFIG_FILE"
        
        # 权限：mktemp 默认为 600，必须改为 644 让 nobody 用户能读取
        chmod 644 "$CONFIG_FILE"
        
        echo -e "${BLUE}>>> 重启 Xray 服务...${PLAIN}"
        systemctl restart xray
        
        # 增加延时，确保 systemd 状态已更新
        sleep 1
        
        if systemctl is-active --quiet xray; then
            echo -e "${GREEN}设置成功！所有节点已同步更新。${PLAIN}"
            rm -f "${CONFIG_FILE}.bak"
        else
            echo -e "${RED}严重错误：Xray 重启失败！正在自动回滚...${PLAIN}"
            echo -e "${YELLOW}可能原因：配置文件格式错误或权限问题。${PLAIN}"
            
            # 回滚并修复权限
            mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
            chmod 644 "$CONFIG_FILE" 
            
            systemctl restart xray
            
            if systemctl is-active --quiet xray; then
                echo -e "${GREEN}已成功回滚到修改前的状态，服务已恢复。${PLAIN}"
            else
                echo -e "${RED}灾难性错误：回滚后服务依然无法启动！请手动检查日志：${PLAIN}"
                echo -e "journalctl -u xray -n 20 --no-pager"
            fi
        fi
    else
        echo -e "${RED}JSON 处理失败，未做任何修改。${PLAIN}"
        rm -f "$tmp"
    fi
}

# 4. 开启/关闭 访问日志
toggle_logging() {
    local action=$1
    echo -e "${BLUE}>>> 正在配置日志...${PLAIN}"
    
    tmp=$(mktemp)
    if [ "$action" == "on" ]; then
        mkdir -p /var/log/xray
        touch "$LOG_FILE"
        # 确保日志文件权限归属正确
        chown nobody:nogroup "$LOG_FILE" 2>/dev/null || chown nobody:nobody "$LOG_FILE" 2>/dev/null
        chmod 644 "$LOG_FILE"
        
        jq --arg path "$LOG_FILE" '.log.access = $path | .log.loglevel = "info"' "$CONFIG_FILE" > "$tmp"
    else
        jq 'del(.log.access) | .log.loglevel = "warning"' "$CONFIG_FILE" > "$tmp"
        echo "" > "$LOG_FILE"
    fi
    
    if [ -s "$tmp" ]; then
        mv "$tmp" "$CONFIG_FILE"
        # config.json 权限
        chmod 644 "$CONFIG_FILE"
        
        systemctl restart xray
        echo -e "${GREEN}日志配置已更新！${PLAIN}"
    else
         echo -e "${RED}JSON 处理失败。${PLAIN}"
    fi
}

# 5. 实时监视
watch_traffic() {
    local access_path=$(jq -r '.log.access // ""' "$CONFIG_FILE")
    if [[ "$access_path" == "" ]]; then
        echo -e "${YELLOW}提示：检测到未开启访问日志，正在自动开启...${PLAIN}"
        toggle_logging "on"
        sleep 1
    fi
    
    clear
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "${GREEN}        Real-time Traffic Audit (Ctrl+C to Exit)${PLAIN}"
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "Listening: ${YELLOW}$LOG_FILE${PLAIN}"
    echo ""
    
    # === [标题] ===
    # 使用标准格式化
    # %-15s 表示占用15格左对齐，以此类推
    printf "${GRAY}%-15s %-22s %-25s %-63s %s${PLAIN}\n" "[Time]" "[Source IP]" "[Routing]" "[Destination]" "[User]"
    echo -e "${GRAY}---------------------------------------------------------------------------------------------------------------------------------------${PLAIN}"
    
    # === [数据内容] ===
    # 必须与上面的标题宽度完全一致
    tail -f "$LOG_FILE" | awk '{
        if ($5 == "accepted") {
            # 颜色定义: 36=青, 33=黄, 35=紫, 32=绿, 37=白
            
            # 这里的数字 (15, 22, 25, 63) 必须和上面 printf 里的完全一样
            printf "\033[36m%-15s\033[0m \033[33m%-22s\033[0m \033[35m%-25s\033[0m \033[32m%-63s\033[0m \033[37m%s\033[0m\n", substr($2,1,12), $4, $7$8$9, $6, $11
        }
    }'
}

# =========================================================
# 菜单
# =========================================================
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}           Xray 流量嗅探工具 (Traffic Sniff)     ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  配置嗅探: $(get_sniff_status)"
    echo -e "  日志记录: $(get_log_status)"
    echo -e "-------------------------------------------------"
    echo -e "  1. 开启 流量嗅探 (Sniffing) ${GREEN}[推荐]${PLAIN}"
    echo -e "  2. 关闭 流量嗅探"
    echo -e "-------------------------------------------------"
    echo -e "  3. 开启 访问日志"
    echo -e "  4. 关闭 访问日志"
    echo -e "-------------------------------------------------"
    echo -e "  5. ${YELLOW}进入实时流量审计模式${PLAIN}"
    echo -e "-------------------------------------------------"
    echo -e "  0. 退出"
    echo -e ""
    read -p "请输入选项 [0-5]: " choice
    
    case "$choice" in
        1) toggle_sniffing "true"; read -n 1 -s -r -p "按任意键继续..." ;;
        2) toggle_sniffing "false"; read -n 1 -s -r -p "按任意键继续..." ;;
        3) toggle_logging "on"; read -n 1 -s -r -p "按任意键继续..." ;;
        4) toggle_logging "off"; read -n 1 -s -r -p "按任意键继续..." ;;
        5) watch_traffic ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${PLAIN}"; sleep 1 ;;
    esac
done
