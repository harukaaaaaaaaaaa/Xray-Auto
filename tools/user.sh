#!/bin/bash

# =========================================================
# 定义颜色
# =========================================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"
GRAY="\033[90m"

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

# 检查依赖
if ! command -v jq &> /dev/null; then echo -e "${RED}Error: 缺少 jq 组件。${PLAIN}"; exit 1; fi
if ! [ -x "$XRAY_BIN" ]; then echo -e "${RED}Error: 缺少 xray 核心。${PLAIN}"; exit 1; fi

# =========================================================
# 核心逻辑
# =========================================================

# 1. 列表展示 (Admin 显示为 #, 用户从 1 开始)
_print_list() {
    echo -e "${BLUE}>>> 当前用户列表 (User List)${PLAIN}"
    echo -e "${GRAY}-----------------------------------------------------------------------${PLAIN}"
    printf "${YELLOW}%-5s %-31s %-40s${PLAIN}\n" "ID" "备注 (Email)" "UUID"
    echo -e "${GRAY}-----------------------------------------------------------------------${PLAIN}"
    
    # 使用 jq to_entries 获取真实索引 (key=0,1,2...)
    jq -r '.inbounds[0].settings.clients | to_entries[] | "\(.key) \(.value.email // "无备注") \(.value.id)"' "$CONFIG_FILE" | while read idx email uuid; do
        if [ "$idx" -eq 0 ]; then
            # 索引 0 (管理员) -> 显示为红色的 #
            printf "${RED}%-5s %-29s %-40s${PLAIN}\n" "#" "$email" "$uuid"
        else
            # 其他索引 -> 直接显示数字 (如 1, 2, 3...)
            printf "${GREEN}%-5s${PLAIN} %-29s %-40s\n" "$idx" "$email" "$uuid"
        fi
    done
    echo -e "${GRAY}-----------------------------------------------------------------------${PLAIN}"
}

# 2. 生成链接并显示 (复用 info.sh 逻辑)
_show_connection_info() {
    local target_uuid=$1
    local target_email=$2

    echo -e "\n${BLUE}>>> 正在获取连接信息...${PLAIN}"

    # --- 1. 提取基础配置 (与 info.sh 保持一致) ---
    # 提取密钥与 SNI (通常在第一个 inbound)
    local PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
    local SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
    local SNI_HOST=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
    
    # 按 tag 提取端口和路径 (确保精准)
    local PORT_VISION=$(jq -r '.inbounds[] | select(.tag=="vision_node") | .port' "$CONFIG_FILE")
    local PORT_XHTTP=$(jq -r '.inbounds[] | select(.tag=="xhttp_node") | .port' "$CONFIG_FILE")
    local XHTTP_PATH=$(jq -r '.inbounds[] | select(.tag=="xhttp_node") | .streamSettings.xhttpSettings.path' "$CONFIG_FILE")

    # 计算公钥
    local PUBLIC_KEY=""
    if [ -n "$PRIVATE_KEY" ]; then
        local RAW_OUTPUT=$($XRAY_BIN x25519 -i "$PRIVATE_KEY")
        # 兼容不同版本的 grep 输出
        PUBLIC_KEY=$(echo "$RAW_OUTPUT" | grep -iE "Public|Password" | head -n 1 | awk -F':' '{print $2}' | tr -d ' \r\n')
    fi
    
    if [ -z "$PUBLIC_KEY" ]; then 
        echo -e "${RED}严重错误：无法计算公钥，请检查 config.json。${PLAIN}"
        return
    fi

    # --- 2. IP 检测 ---
    local IPV4=$(curl -s4m 1 https://api.ipify.org || echo "N/A")
    local IPV6=$(curl -s6m 1 https://api64.ipify.org || echo "N/A")

    # --- 3. 生成并输出链接 ---
    echo -e "\n${YELLOW}=== 用户 [${target_email}] 连接配置 ===${PLAIN}"

    # >> IPv4 Links
    if [[ "$IPV4" != "N/A" ]]; then
        echo -e "${GREEN}>> IPv4 节点 (通用):${PLAIN}"
        
        # Vision Link
        if [ -n "$PORT_VISION" ]; then
            local link="vless://${target_uuid}@${IPV4}:${PORT_VISION}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI_HOST}&sid=${SHORT_ID}#${target_email}_Vision"
            echo -e "${YELLOW}Vision:${PLAIN} ${GRAY}${link}${PLAIN}"
        fi
        
        # XHTTP Link
        if [ -n "$PORT_XHTTP" ]; then
            local link="vless://${target_uuid}@${IPV4}:${PORT_XHTTP}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=${XHTTP_PATH}&sni=${SNI_HOST}&sid=${SHORT_ID}#${target_email}_XHTTP"
            echo -e "${YELLOW}XHTTP :${PLAIN} ${GRAY}${link}${PLAIN}"
        fi
        echo ""
    fi

    # >> IPv6 Links
    if [[ "$IPV6" != "N/A" ]]; then
        echo -e "${GREEN}>> IPv6 节点 (专用):${PLAIN}"
        
        # Vision Link
        if [ -n "$PORT_VISION" ]; then
            local link="vless://${target_uuid}@[${IPV6}]:${PORT_VISION}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI_HOST}&sid=${SHORT_ID}#${target_email}_Vision_v6"
            echo -e "${YELLOW}Vision:${PLAIN} ${GRAY}${link}${PLAIN}"
        fi
        
        # XHTTP Link
        if [ -n "$PORT_XHTTP" ]; then
            local link="vless://${target_uuid}@[${IPV6}]:${PORT_XHTTP}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=${XHTTP_PATH}&sni=${SNI_HOST}&sid=${SHORT_ID}#${target_email}_XHTTP_v6"
            echo -e "${YELLOW}XHTTP :${PLAIN} ${GRAY}${link}${PLAIN}"
        fi
        echo ""
    fi
}

# 3. 查看用户详情
view_user_details() {
    _print_list
    echo -e "${YELLOW}提示：输入序号(ID)查看详细连接信息${PLAIN} ${GREEN}[回车 或 0 返回]${PLAIN}"
    read -p "序号(ID): " idx
    
    if [[ -z "$idx" || "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then echo -e "${RED}输入无效${PLAIN}"; return; fi
    
    local len=$(jq '.inbounds[0].settings.clients | length' "$CONFIG_FILE")
    
    # 范围检查：必须 >= 1 (因为 0 是 Admin #，且被用作返回键，故无法在此查看 Admin，需用 info 命令)
    if [ "$idx" -lt 1 ] || [ "$idx" -ge "$len" ]; then
        echo -e "${RED}序号超出范围${PLAIN}"; return; fi

    # 直接使用输入的 idx 作为数组索引，无需 -1
    local array_idx=$idx
    local email=$(jq -r ".inbounds[0].settings.clients[$array_idx].email // \"无备注\"" "$CONFIG_FILE")
    local uuid=$(jq -r ".inbounds[0].settings.clients[$array_idx].id" "$CONFIG_FILE")
    
    _show_connection_info "$uuid" "$email"
    
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 4. 重启服务与自动回滚
restart_service() {
    local success_msg=$1
    local backup_file="${CONFIG_FILE}.bak"

    chmod 644 "$CONFIG_FILE"
    echo -e "${BLUE}>>> 正在重启服务...${PLAIN}"
    systemctl restart xray
    sleep 2
    
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}${success_msg}${PLAIN}"
        rm -f "$backup_file"
    else
        echo -e "${RED}严重错误：Xray 服务启动失败！正在尝试回滚...${PLAIN}"
        journalctl -u xray --no-pager -n 10 | tail -n 5
        if [ -f "$backup_file" ]; then
            echo -e "${YELLOW}>>> 正在触发自动回滚机制...${PLAIN}"
            cp "$backup_file" "$CONFIG_FILE"
            chmod 644 "$CONFIG_FILE"
            systemctl restart xray
            if systemctl is-active --quiet xray; then
                echo -e "${GREEN}回滚成功！${PLAIN}"
                rm -f "$backup_file"
            else
                echo -e "${RED}灾难性错误：回滚后服务依然无法启动！${PLAIN}"
            fi
        else
            echo -e "${RED}未找到备份文件！${PLAIN}"
        fi
    fi
}

# 5. 添加用户 (全协议同步)
add_user() {
    echo -e "${BLUE}>>> 添加新用户${PLAIN}"
    read -p "请输入用户备注 (例如: friend_bob): " email
    if [ -z "$email" ]; then echo -e "${RED}备注不能为空${PLAIN}"; return; fi
    
    if grep -q "$email" "$CONFIG_FILE"; then echo -e "${RED}错误: 该备注已存在！${PLAIN}"; return; fi
    
    local new_uuid=$(xray uuid)
    echo -e "正在添加: ${GREEN}$email${PLAIN} (UUID: $new_uuid)"
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # 全局添加 (同时写入 Vision 和 XHTTP 节点)
    tmp=$(mktemp)
    jq --arg uuid "$new_uuid" --arg email "$email" '
      .inbounds |= map(
        if .settings.clients then
          .settings.clients += [{
            "id": $uuid,
            "email": $email,
            "flow": (.settings.clients[0].flow // "")
          }]
        else
          .
        end
      )' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
       
    restart_service "添加成功！"
    
    _show_connection_info "$new_uuid" "$email"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 6. 删除用户
del_user() {
    _print_list
    
    local len=$(jq '.inbounds[0].settings.clients | length' "$CONFIG_FILE")
    
    # === 提前检测：如果只有管理员，直接提示并返回 ===
    if [ "$len" -le 1 ]; then
         echo -e "\n${YELLOW}提示：当前仅剩管理员 (#)，无可删除的用户。${PLAIN}"
         read -n 1 -s -r -p "按任意键返回菜单..."
         return
    fi

    local idx=""

    while true; do
        echo -e "${YELLOW}提示：请输入要删除的用户序号(ID)${PLAIN} ${GREEN}[回车 或 0 返回]${PLAIN}"
        read -p "序号(ID): " idx
        
        # 返回逻辑
        if [[ -z "$idx" || "$idx" == "0" ]]; then return; fi

        local error_msg=""
        
        # 校验逻辑
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then 
            error_msg="输入无效，请输入数字！"
        # 范围校验 (1 到 len-1)
        elif [ "$idx" -lt 1 ] || [ "$idx" -ge "$len" ]; then
            local max_id=$((len - 1))
            error_msg="序号无效 (不能删除 # 管理员，请输入 1-${max_id})！"
        fi

        # 错误处理 (防刷屏)
        if [ -n "$error_msg" ]; then
            echo -e "${RED}${error_msg}${PLAIN}"
            sleep 1
            echo -ne "\033[1A\033[K\033[1A\033[K\033[1A\033[K"
            continue 
        fi

        break
    done

    # 执行删除
    local array_idx=$idx
    local email=$(jq -r ".inbounds[0].settings.clients[$array_idx].email // \"无备注\"" "$CONFIG_FILE")

    echo -ne "确认删除用户: ${RED}$email${PLAIN} ? [y/n]: "
    while true; do
        read -n 1 -r key
        case "$key" in
            [yY]) echo -e "\n${GREEN}>>> 已确认，正在删除...${PLAIN}"; break ;;
            [nN]) echo -e "\n${YELLOW}>>> 操作已取消。${PLAIN}"; return ;;
            *) ;;
        esac
    done

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    tmp=$(mktemp)
    jq "del(.inbounds[].settings.clients[$array_idx])" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    
    restart_service "用户已删除。"
}

# =========================================================
# 菜单
# =========================================================
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}           Xray 多用户管理 (User Manager)        ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  1. 查看列表 & 连接信息 (List & Details)"
    echo -e "  2. ${GREEN}添加新用户 (Add)${PLAIN}"
    echo -e "  3. ${RED}删除旧用户 (Delete)${PLAIN}"
    echo -e "-------------------------------------------------"
    echo -e "  0. 退出"
    echo -e ""
    read -p "请输入选项 [0-3]: " choice

    case "$choice" in
        1) view_user_details ;; 
        2) add_user ;;
        3) del_user ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${PLAIN}"; sleep 1 ;;
    esac
done
