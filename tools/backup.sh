#!/bin/bash

# =========================================================
# 定义颜色
# =========================================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

BACKUP_DIR="/usr/local/etc/xray/backup"
CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
# 指定资源文件路径 (geoip.dat/geosite.dat)
ASSET_DIR="/usr/local/share/xray"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# =========================================================
# 核心逻辑
# =========================================================

# 1. 创建备份
create_backup() {
    echo -e "${BLUE}>>> 正在创建备份...${PLAIN}"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误：找不到配置文件，无法备份。${PLAIN}"
        return
    fi

    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/config_$timestamp.json"
    
    cp "$CONFIG_FILE" "$backup_file"
    echo -e "${GREEN}备份成功！${PLAIN}"
    echo -e "备份文件: ${YELLOW}$backup_file${PLAIN}"
    
    # 保留最近10份
    local count=$(ls -1 "$BACKUP_DIR"/config_*.json 2>/dev/null | wc -l)
    if [ "$count" -gt 10 ]; then
        echo -e "${YELLOW}清理旧备份 (保留最近10份)...${PLAIN}"
        cd "$BACKUP_DIR"
        ls -t config_*.json | tail -n +11 | xargs -I {} rm -- {} 2>/dev/null
    fi
}

# 2. 还原备份
restore_backup() {
    local files=($(ls -t "$BACKUP_DIR"/config_*.json 2>/dev/null))
    
    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}没有找到任何备份文件。${PLAIN}"
        return
    fi
    
    echo -e "${BLUE}>>> 请选择要还原的备份点：${PLAIN}"

    echo -e "-------------------------------------------------"
    local i=1
    for file in "${files[@]}"; do
        filename=$(basename "$file")
        filetime=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
        
        # 如果是第一个文件(最新)，添加绿色标签
        local tag=""
        if [ "$i" -eq 1 ]; then
            tag="${GREEN}最新${PLAIN}"
        fi
        
        echo -e "  ${GREEN}$i.${PLAIN} $filename  ${YELLOW}($filetime)${PLAIN} $tag"
        let i++
    done
    
    echo -e "-------------------------------------------------"
    echo -e "  0. 取消"
    echo -e ""
    read -p "请输入选项 [0-${#files[@]}]: " choice
    
    if [ "$choice" == "0" ]; then return; fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#files[@]}" ] && [ "$choice" -gt 0 ]; then
        local target_file="${files[$((choice-1))]}"
        
        echo -e "\n您选择了: ${YELLOW}$(basename "$target_file")${PLAIN}"
        
        # 1. 预检备份文件完整性
        echo -e "正在校验备份文件..."
        
        # 将 -conf 修改为 -c
        if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$target_file" >/dev/null 2>&1; then
            echo -e "${RED}错误：该备份文件校验失败，无法还原！${PLAIN}"
            echo -e "${YELLOW}>>> 错误详情 (Debug Info):${PLAIN}"
            # [修复点] 这里的调试输出也同步修改为 -c
            XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$target_file"
            return
        fi

        echo -ne "确定要覆盖当前配置吗？此操作不可逆！[y/n]: "
        while true; do
            read -n 1 -r key
            case "$key" in
                [yY]) 
                    echo -e "\n${BLUE}>>> 正在还原...${PLAIN}"
                    cp "$target_file" "$CONFIG_FILE"
                    chmod 644 "$CONFIG_FILE"
                    systemctl restart xray
                    sleep 1
                    
                    if systemctl is-active --quiet xray; then
                         echo -e "${GREEN}还原成功！服务已重启。${PLAIN}"
                    else
                         echo -e "${RED}警告：配置已还原，但服务启动失败。${PLAIN}"
                         echo -e "请检查日志: journalctl -u xray -n 10"
                    fi
                    break 
                    ;;
                [nN]) 
                    echo -e "\n操作已取消。"
                    return 
                    ;;
                *) ;;
            esac
        done
    else
        echo -e "${RED}输入无效。${PLAIN}"
    fi
}

# 3. 导出备份
export_backup() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}无配置可导出${PLAIN}"; return; fi
    
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}           配置内容预览 (Copy & Paste)           ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    cat "$CONFIG_FILE"
    echo -e "\n${BLUE}=================================================${PLAIN}"
    echo -e "${YELLOW}提示：你可以复制上方内容保存到本地 config.json${PLAIN}"
}

# =========================================================
# 菜单
# =========================================================
while true; do
    clear
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}           Xray 配置备份与还原 (Backup)          ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "  1. ${GREEN}创建新备份 (Create)${PLAIN}"
    echo -e "  2. ${RED}还原旧配置 (Restore)${PLAIN}"
    echo -e "  3. 查看/导出当前配置"
    echo -e "-------------------------------------------------"
    echo -e "  0. 退出"
    echo -e ""
    read -p "请输入选项 [0-3]: " choice

    case "$choice" in
        1) create_backup; read -n 1 -s -r -p "按任意键继续..." ;;
        2) restore_backup; read -n 1 -s -r -p "按任意键继续..." ;;
        3) export_backup; read -n 1 -s -r -p "按任意键继续..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效${PLAIN}"; sleep 1 ;;
    esac
done
