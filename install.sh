#!/bin/bash

# ==================================================================
# 1. 基础准备
# ==================================================================
BASE_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -f "$BASE_DIR/lib/utils.sh" ]; then
    source "$BASE_DIR/lib/utils.sh"
else
    echo "Error: lib/utils.sh not found!"
    exit 1
fi

# ==================================================================
# 2. 预检与交互
# ==================================================================
print_banner
if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: 请使用 root 运行！${PLAIN}"; exit 1; fi

if command -v lock_acquire &> /dev/null; then
    if ! lock_acquire; then echo -e "${RED}脚本已在运行！${PLAIN}"; exit 1; fi
fi

confirm_installation

# ==================================================================
# 3. 核心安装流程 (Core Modules)
# ==================================================================
echo -e "${BLUE}>>> 正在初始化环境...${PLAIN}"

# --- 1. 环境检查 ---
source "$BASE_DIR/core/1_env.sh"
# 显式调用环境检查函数
pre_flight_check
check_net_stack
check_timezone

# --- 2. 安装核心 ---
source "$BASE_DIR/core/2_install.sh"
# 显式调用安装函数
if command -v core_install &>/dev/null; then
    core_install
else
    # 兼容旧写法：如果没封装函数，可能是直接执行的，这里就不报错
    echo -e "${YELLOW}提示: core_install 函数未定义，假设脚本已自动执行。${PLAIN}"
fi

# --- 3. 系统配置 ---
source "$BASE_DIR/core/3_system.sh"
# 调用配置函数
if command -v core_system &>/dev/null; then core_system; fi

# --- 4. 生成配置 ---
source "$BASE_DIR/core/4_config.sh"
# 调用生成配置函数
if command -v core_config &>/dev/null; then core_config; fi

# ==================================================================
# 4. 部署管理工具 (Tools)
# ==================================================================
echo -e "\n${BLUE}>>> 正在部署管理脚本...${PLAIN}"

TOOLS_DIR="$BASE_DIR/tools"
BIN_DIR="/usr/local/bin"

if [ -d "$TOOLS_DIR" ]; then
    # 检查目录下是否有 .sh 文件
    count=$(ls "$TOOLS_DIR"/*.sh 2>/dev/null | wc -l)
    
    if [ "$count" != "0" ]; then
        # 列出所有工具
        for script in "$TOOLS_DIR"/*.sh; do
            if [ -f "$script" ]; then
                filename=$(basename "$script" .sh)
                target="$BIN_DIR/$filename"
                
                cp "$script" "$target"
                chmod +x "$target"
                
                # 简化文案
                echo -e "   ${OK} 部署命令: ${GREEN}${filename}${PLAIN}"
            fi
        done
    else
        echo -e "   ${WARN} tools 目录存在但为空，跳过部署。"
    fi
else
    echo -e "   ${ERR} tools 目录缺失，请检查项目完整性。"
fi

# ==================================================================
# 5. 启动服务与收尾
# ==================================================================
echo -e "\n${GREEN}>>> 正在启动服务...${PLAIN}"

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

if systemctl is-active --quiet xray; then
echo -e "${GREEN}>>> 安装全部完成 (Installation Complete) ${PLAIN}"

    # 自动执行 info
    if [ -f "/usr/local/bin/info" ]; then
        bash /usr/local/bin/info
    else
        echo -e "${YELLOW}提示: info 命令未找到，无法显示节点信息。${PLAIN}"
    fi
else
    echo -e "\n${RED}Error: Xray 服务启动失败！${PLAIN}"
    exit 1
fi
