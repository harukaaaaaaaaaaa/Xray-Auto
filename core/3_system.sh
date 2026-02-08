# --- 3. 安全与防火墙配置 ---
_add_fw_rule() {
    local port=$1; local v4=$2; local v6=$3
    if [ "$v4" = true ]; then
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport $port -j ACCEPT
    fi
    if [ "$v6" = true ] && [ -f /proc/net/if_inet6 ]; then
        ip6tables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
        ip6tables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p udp --dport $port -j ACCEPT
    fi
}

setup_firewall_and_security() {
    echo -e "${BLUE}--- 3. 端口与安全配置 (Security) ---${PLAIN}"
    
    # 自动检测 SSH 端口
    local current_ssh_port=$(grep "^Port" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}' | tr -d '\r')
    if [ -z "$current_ssh_port" ]; then current_ssh_port=22; fi
    
    SSH_PORT=$current_ssh_port
    PORT_VISION=443
    PORT_XHTTP=8443

    echo -e "   SSH    端口 : ${GREEN}$SSH_PORT${PLAIN}"
    echo -e "   Vision 端口 : ${GREEN}$PORT_VISION${PLAIN}"
    echo -e "   XHTTP  端口 : ${GREEN}$PORT_XHTTP${PLAIN}"

    # 交互询问
    read_with_timeout "是否自定义端口? (y/n)" "n" "$UI_TIMEOUT_LONG"
    local port_choice="$USER_INPUT"

    if [[ "$port_choice" =~ ^[yY]$ ]]; then
        
        # === 1. SSH 端口配置 ===
        clear
        echo -e "${RED}################################################################${PLAIN}"
        echo -e "${RED}#                      高风险操作警告 (WARNING)                #${PLAIN}"
        echo -e "${RED}################################################################${PLAIN}"
        echo -e "${RED}#${PLAIN}                                                              ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}  1. 云服务器用户 (阿里云/腾讯云/AWS等)：                     ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}     即将配置 SSH 端口。如果修改端口，必须先在                ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}     网页控制台的【安全组/防火墙】放行新端口！                ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}                                                              ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}  2. 此时修改端口后，【绝对不要】关闭当前窗口！               ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}     请新开一个 SSH 窗口测试连接。如果失败，                  ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}     你需要通过云控制台 VNC 救砖或重装系统。                  ${RED}#${PLAIN}"
        echo -e "${RED}#${PLAIN}                                                              ${RED}#${PLAIN}"
        echo -e "${RED}################################################################${PLAIN}"
        echo ""

        # 强制确认
        read -p "我已知晓风险，是否修改 SSH 端口? (y=修改 / n=保持默认 $SSH_PORT): " ssh_confirm
        
        if [[ "$ssh_confirm" =~ ^[yY]$ ]]; then
            while true; do
                read -p "请输入新的 SSH 端口: " input_ssh
                # 校验数字
                if [[ ! "$input_ssh" =~ ^[0-9]+$ ]] || [ "$input_ssh" -lt 1 ] || [ "$input_ssh" -gt 65535 ]; then
                    echo -e "${RED}错误: 端口必须是 1-65535 之间的数字！${PLAIN}"
                    continue
                fi
                # 确认修改
                SSH_PORT="$input_ssh"
                break
            done
        else
            echo -e "${INFO} SSH 端口保持默认: ${GREEN}$SSH_PORT${PLAIN}"
        fi

        # === 2. Vision / XHTTP 端口设置 ===
        echo -e "\n${BLUE}--- 继续配置 Xray 端口 ---${PLAIN}"
        read -p "请输入 Vision 端口 [443]: " input_vision
        PORT_VISION=${input_vision:-443}
        
        read -p "请输入 XHTTP  端口 [8443]: " input_xhttp
        PORT_XHTTP=${input_xhttp:-8443}
        
        # === 3. 应用 SSH 修改 ===
        if [ "$SSH_PORT" != "$current_ssh_port" ]; then
            sed -i "s/^Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
            if ! grep -q "^Port" /etc/ssh/sshd_config; then echo "Port $SSH_PORT" >> /etc/ssh/sshd_config; fi
            
            echo -e "${WARN} 正在重启 SSH 服务，请务必放行端口 $SSH_PORT !"
            systemctl restart ssh || systemctl restart sshd
        fi
    fi

    # --- 最终配置回显 ---
    echo -e "\n${INFO} 端口配置确认 (Configuration Confirmed):"
    echo -e "${OK} SSH    端口 : ${GREEN}$SSH_PORT${PLAIN}"
    echo -e "${OK} Vision 端口 : ${GREEN}$PORT_VISION${PLAIN}"
    echo -e "${OK} XHTTP  端口 : ${GREEN}$PORT_XHTTP${PLAIN}\n"

    # Fail2ban 配置 (开启指数封禁)
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 30d
findtime = 7d
maxretry = 3
# 改为 auto，让它自动兼容日志文件和systemd，防止崩溃
backend = auto

[sshd]
enabled = true
port = $SSH_PORT,22
# 如果 aggressive 模式导致无法启动，可改为 normal
mode = aggressive
EOF
    execute_task "systemctl restart rsyslog && systemctl enable fail2ban && systemctl restart fail2ban" "配置 Fail2ban 防护(开启指数封禁)"

    # 防火墙规则
    _add_fw_rule $SSH_PORT $HAS_V4 $HAS_V6
    _add_fw_rule $PORT_VISION $HAS_V4 $HAS_V6
    _add_fw_rule $PORT_XHTTP $HAS_V4 $HAS_V6
    execute_task "netfilter-persistent save" "持久化防火墙规则"
}

setup_kernel_optimization() {
    echo -e "\n${BLUE}--- 4. 内核优化 (Kernel Opt) ---${PLAIN}"
    
    # --- 1. BBR 配置 ---
    read_with_timeout "是否启用 BBR 加速? (y/n)" "y" "$UI_TIMEOUT_SHORT"
    local bbr_choice="$USER_INPUT"
    
    if [[ "${bbr_choice:-y}" =~ ^[yY]$ ]]; then
        execute_task 'echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-xray-bbr.conf && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-xray-bbr.conf && sysctl --system' "启用 BBR"
    else
        echo -e "${INFO} 跳过 BBR 配置。"
    fi

    # --- 2. Swap 智能配置 ---
    local ram_size=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$ram_size" -lt 2048 ]; then
        # 先检查 Swap 是否已经启用
        if grep -q "/swapfile" /proc/swaps; then
            echo -e "${OK}   检测到 Swap 已启用，跳过创建。"
        else
            echo -e "${WARN} 内存少于 2GB，正在自动配置 Swap..."
            
            # 使用 dd 作为 fallocate 的备用方案（兼容性更好），并包裹在复合命令中
            # 逻辑：先删残余 -> 尝试 fallocate -> 失败则用 dd -> 设置权限 -> 格式化 -> 挂载 -> 写入 fstab
            local cmd_swap='
                swapoff /swapfile 2>/dev/null; rm -f /swapfile;
                if ! fallocate -l 1024M /swapfile 2>/dev/null; then
                    dd if=/dev/zero of=/swapfile bs=1M count=1024;
                fi;
                chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && 
                if ! grep -q "/swapfile" /etc/fstab; then echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi
            '
            execute_task "$cmd_swap" "启用 1GB Swap"
        fi
    fi
}

# --- 执行配置 ---
setup_firewall_and_security
setup_kernel_optimization
