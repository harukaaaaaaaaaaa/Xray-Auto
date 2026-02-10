# ------------------------------------------------------------------
# 一、全局配置与 UI 定义 (Global Settings & UI)
# ------------------------------------------------------------------

# 1.1 基础颜色配置
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[36m"; PURPLE="\033[35m"; GRAY="\033[90m"; PLAIN="\033[0m"
BOLD="\033[1m"

# 1.2 标准化状态标签 (Standard Tags)
OK="${GREEN}[OK]${PLAIN}"
ERR="${RED}[ERR]${PLAIN}"
WARN="${YELLOW}[WARN]${PLAIN}"
INFO="${BLUE}[INFO]${PLAIN}"
STEP="${PURPLE}==>${PLAIN}"

# 1.3 简单的旋转动画
# Linux 等待动画： | / - \
UI_SPINNER_FRAMES=("|" "/" "-" "\\")
# 截取日志长度
UI_LOG_WIDTH=50

# 1.4 锁文件配置 (Prevent Duplicate Run)
LOCK_DIR="/tmp/xray_installer_lock"
PID_FILE="$LOCK_DIR/pid"

# 1.5 交互超时设置 (Interaction Timeouts)
UI_TIMEOUT_SHORT=30   # 简单询问 (如: BBR, 时区)
UI_TIMEOUT_LONG=30    # 复杂操作 (如: 端口, 选域名)

# ------------------------------------------------------------------
# 二、核心函数定义 (Core Functions Definition)
# ------------------------------------------------------------------

# --- 锁释放与清理 ---
cleanup() {
  rm -f "/tmp/xray_install_step.log"
  # 释放锁：删除目录
  rm -rf "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

# --- 锁获取 (单实例检查) ---
lock_acquire() {
  # 尝试创建目录作为原子锁
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$PID_FILE"
    return 0
  fi

  # 如果锁存在，检查持有锁的进程是否还活着
  if [ -f "$PID_FILE" ]; then
    local old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
      # 进程已死 (Stale Lock)，强制接管
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || return 1
      echo "$$" > "$PID_FILE"
      return 0
    fi
  fi
  
  return 1
}

# --- 日志封装函数 ---
log_info() { echo -e "${INFO} $*"; }
log_warn() { echo -e "${WARN} $*"; }
log_err()  { echo -e "${ERR} $*" >&2; }

# --- 核心：统一倒计时交互函数 ---
# 用法: read_with_timeout "提示语" "默认值" "超时时间"
read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local timeout="$3"
    local input_char=""
    
    # 1. 清空之前的输入残留 (关键修复：防止幽灵回车导致秒过)
    while read -r -t 0; do read -r -n 1; done
    
    USER_INPUT=""
    
    # 2. 设定截止时间戳 (锚定未来时刻)
    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    local current_time
    local remaining

    while true; do
        current_time=$(date +%s)
        remaining=$((end_time - current_time))
        
        # 如果时间到了，退出循环
        if [ "$remaining" -le 0 ]; then
            break
        fi
        
        # 交互 UI： 提示语 [默认: X] [ 10s ] :
        # 这里的 $remaining 是真实剩余秒数，不会忽快忽慢
        echo -ne "\r${YELLOW}${prompt} [默认: ${default}] [ ${RED}${remaining}s${YELLOW} ] : ${PLAIN}"
        
        # -t 1 等待一秒，但我们只关心是否按键
        read -t 1 -n 1 input_char
        if [ $? -eq 0 ]; then
            # 用户按下了键
            echo "" # 换行
            if [ -z "$input_char" ]; then
                USER_INPUT="$default"
            else
                USER_INPUT="$input_char"
            fi
            return 0
        fi
    done

    # 超时处理
    echo -e "\n${INFO} 倒计时结束，使用默认值: ${default}"
    USER_INPUT="$default"
}

# --- 核心：旋转光标监控 (Standard Spinner) ---
monitor_task_inline() {
    local pid=$1
    local logfile=$2
    local desc=$3
    local i=0
    
    # 隐藏光标
    tput civis
    
    while kill -0 $pid 2>/dev/null; do
        # 获取日志摘要
        if [ -f "$logfile" ]; then
            local raw_log=$(tail -n 1 "$logfile" 2>/dev/null)
            # 1. 去除颜色代码
            # 2. 去除 \r 回车符
             local clean_log=$(echo "$raw_log" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' | cut -c 1-$UI_LOG_WIDTH)
        else
            local clean_log=""
        fi

        if [ -z "$clean_log" ]; then clean_log="..."; fi
        
        i=$(( (i+1) % ${#UI_SPINNER_FRAMES[@]} ))
        
        # 打印状态
        printf "\r ${BLUE}[ %s ]${PLAIN} %-35s ${GRAY}(%s)${PLAIN}\033[K" \
            "${UI_SPINNER_FRAMES[$i]}" "$desc" "$clean_log"
            
        sleep 0.1
    done
    
    tput cnorm
}

# --- 核心：任务执行包装器 ---
execute_task() {
    local cmd="$1"
    local desc="$2"
    local current_step=$3 
    local total_steps=$4
    
    local log_file="/tmp/xray_install_step.log"
    local max_retries=3
    local attempt=1

    while true; do
        echo "" > "$log_file"
        bash -c "$cmd" > "$log_file" 2>&1 &
        local pid=$!
        
        monitor_task_inline $pid "$log_file" "$desc"
        
        wait $pid
        local status=$?

        # 清除当前行
        echo -ne "\r\033[K"

        if [ $status -eq 0 ]; then
            # 成功后显示： [OK] 任务描述
            echo -e "${OK}   ${desc}"
            return 0
        fi

        # 失败后显示： [ERR] 任务描述
        echo -e "${ERR}  ${desc}"
        
        echo -e "${RED}=== 错误日志 ===${PLAIN}"
        tail -n 5 "$log_file" | sed "s/^/   /g"
        
        if [ $attempt -ge $max_retries ]; then
            echo -e "${RED}多次重试失败。${PLAIN}"
            while true; do
                read -p "选项: (y=重试 / n=退出 / l=查看日志) [y]: " choice
                choice=${choice:-y}
                case "$choice" in
                    y|Y) echo -e "${INFO} 正在重试..."; attempt=0; break ;;
                    n|N) exit 1 ;;
                    l|L) more "$log_file"; echo ""; ;;
                    *) echo "输入错误";;
                esac
            done
        fi
        ((attempt++))
        sleep 2
    done
}

# ==========================================
# 基础信息配置
# ==========================================
AUTHOR="ISFZY"
PROJECT_URL="https://github.com/ISFZY/Xray-Auto"

# ==========================================
# Banner 打印函数
# ==========================================
print_banner() {
    clear
    echo -e "${BLUE}===============================================================${PLAIN}"
    echo -e "${BLUE}           Xray Auto Installer ${YELLOW}[Modular Edition]${PLAIN}"
    echo -e "${BLUE}===============================================================${PLAIN}"
    echo -e "  ${GREEN}作    者 :${PLAIN} ${AUTHOR}"
    echo -e "  ${GREEN}项目地址 :${PLAIN} ${PROJECT_URL}"
    echo -e "${BLUE}===============================================================${PLAIN}"
    echo ""
}

# ==========================================
# 交互确认函数
# ==========================================
confirm_installation() {
    echo -e "${YELLOW}注意：本脚本将安装 Xray 及相关依赖，并可能修改系统配置。${PLAIN}"
    echo -e "${YELLOW}Note: This script will install Xray and modify system config.${PLAIN}"
    echo ""
    
    # -p 显示提示信息
    read -p "确认继续安装吗? [y/n] (Confirm to install?): " choice
    
    # 判断用户输入
    case "$choice" in
        y|Y) 
            echo -e "${GREEN}>>> 用户确认，开始安装...${PLAIN}"
            echo ""
            ;;
        *) 
            echo -e "${RED}>>> 用户取消，安装已终止。${PLAIN}"
            exit 1
            ;;
    esac
}
