#!/bin/bash

# =========================================================
# 定义颜色
# =========================================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# =========================================================
# 卸载逻辑
# =========================================================

# 1. 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: 请使用 sudo 或 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 2. 确认交互
clear
echo -e "${RED}=============================================================${PLAIN}"
echo -e "${RED}               Xray 一键卸载 (Uninstall Xray)               ${PLAIN}"
echo -e "${RED}=============================================================${PLAIN}"
echo -e "${YELLOW}警告：此操作将执行以下清理：${PLAIN}"
echo -e "  1. 停止并移除 Xray 服务"
echo -e "  2. 删除 Xray 核心文件、配置文件、日志"
echo -e "  3. 删除所有管理脚本 (info, net...)"
echo -e "  4. 清理残留的安装目录"
echo -e "${RED}=============================================================${PLAIN}"
echo ""
echo ""
echo -ne "确认要彻底卸载吗？[y/n]: "
while true; do
    read -n 1 -r key
    case "$key" in
        [yY]) 
            echo -e "\n${GREEN}>>> 操作已确认，开始卸载...${PLAIN}"
            break 
            ;;
        [nN]) 
            echo -e "\n${YELLOW}>>> 操作已取消。${PLAIN}"
            exit 0 
            ;;
        *) ;;
    esac
done

echo -e "\n${GREEN}>>> 正在停止服务...${PLAIN}"

# 3. 停止服务
systemctl stop xray >/dev/null 2>&1
systemctl disable xray >/dev/null 2>&1

# 4. 删除文件
echo -e "${GREEN}>>> 正在删除文件...${PLAIN}"

# 删除服务文件
rm -f /etc/systemd/system/xray.service
rm -f /lib/systemd/system/xray.service

# 删除核心与配置
# 注意：这里会连同 config.json 和备份目录一起删除
if [ -d "/usr/local/etc/xray" ]; then
    rm -rf "/usr/local/etc/xray"
    echo -e "   [OK] 已删除配置目录 (/usr/local/etc/xray)"
fi

if [ -f "/usr/local/bin/xray" ]; then
    rm -f "/usr/local/bin/xray"
    echo -e "   [OK] 已删除核心程序"
fi

rm -rf /usr/local/share/xray
rm -rf /var/log/xray

# 5. 删除工具脚本 (新增 user 和 backup)
# 这一步非常关键，确保把 /usr/local/bin 下的快捷命令清理干净
TOOLS=(
    "user"      # 多用户管理
    "backup"    # 备份与还原
    "info"      # 信息查看
    "net"       # 网络管理
    "bbr"       # BBR 管理
    "bt"        # BT 流量
    "f2b"       # Fail2ban防火墙
    "ports"     # 端口管理
    "sni"       # SNI 域名
    "swap"      # Swap 管理
    "xw"        # WARP 管理
    "remove"    # 本脚本
    "uninstall" # 别名
)

echo -e "${GREEN}>>> 正在清理快捷指令...${PLAIN}"
for tool in "${TOOLS[@]}"; do
    if [ -f "/usr/local/bin/$tool" ]; then
        rm -f "/usr/local/bin/$tool"
        echo -e "   [OK] 已删除命令: ${tool}"
    fi
done

# 6. 重载系统守护进程
systemctl daemon-reload
systemctl reset-failed

# 7. (可选) 清理安装源码目录
# 尝试删除标准的安装路径 /root/xray-install
if [ -d "/root/xray-install" ]; then
    rm -rf "/root/xray-install"
    echo -e "   [OK] 已删除安装源码目录"
fi

echo -e "\n${GREEN}=============================================${PLAIN}"
echo -e "${GREEN}      卸载完成 (Uninstallation Complete)      ${PLAIN}"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "提示: 系统 BBR 设置与已安装的依赖 (如 git, curl, jq) 未移除，"
echo -e "      以免影响系统其他服务。"
echo ""
