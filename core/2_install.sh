# --- 2. 安装流程 ---
echo -e "\n${BLUE}--- 2. 开始安装核心组件 (core) ---${PLAIN}"

export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-xray-auto.conf

# === 1. 系统级更新 ===
# 修复潜在的包管理锁问题
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
execute_task "apt-get update -qq"  "刷新软件源"
execute_task "DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade" "系统升级"

# === 2. 依赖安装 (安装后立即验证) ===
DEPENDENCIES=("curl" "tar" "unzip" "fail2ban" "rsyslog" "chrony" "iptables" "iptables-persistent" "qrencode" "jq" "cron" "python3-systemd")

echo -e "${INFO} 正在检查并安装依赖..."
for pkg in "${DEPENDENCIES[@]}"; do
    # 预检查：如果 dpkg 数据库里已经有了，就不浪费时间apt了
    if dpkg -s "$pkg" &>/dev/null; then
        echo -e "${OK}   依赖已就绪: $pkg"
        continue
    fi

    # 初次安装
    execute_task "apt-get install -y $pkg" "安装依赖: $pkg"
    
    # [关键步骤] 安装后验证：apt 虽然返回0，但可能包坏了
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo -e "${WARN} 依赖 $pkg 校验失败！尝试修复源并重试..."
        apt-get update -qq --fix-missing
        execute_task "apt-get install -y $pkg" "重试安装: $pkg"
        
        # 熔断机制：二次重试还不行，直接报错退出
        if ! dpkg -s "$pkg" &>/dev/null; then
            echo -e "${ERR} [FATAL] 无法安装系统依赖: $pkg"
            echo -e "${YELLOW}请手动运行 'apt-get install $pkg' 查看具体报错。${PLAIN}"
            exit 1
        fi
    fi
done

# === 3. Xray 核心安装 (支持版本锁定) ===
install_xray_robust() {
    local max_tries=3
    local count=0
    local bin_path="/usr/local/bin/xray"
    
    # [设置] 版本锁定
    # 留空 "" = 始终安装最新版 (Latest)
    # 填值 "v00.00.00" = 锁定特定版本
    # 目前 XHTTP 需要较新版本，暂时不锁
    local FIXED_VER="" 
    
    # 构造版本参数
    local VER_ARG=""
    if [ -n "$FIXED_VER" ]; then
        VER_ARG="--version $FIXED_VER"
        echo -e "${INFO} 已启用版本锁定: ${YELLOW}${FIXED_VER}${PLAIN}"
    fi
    
    mkdir -p /usr/local/share/xray/

    while [ $count -lt $max_tries ]; do
        # 注：在 install 后面加上了 $VER_ARG
        CMD_XRAY='bash -c "$(curl -L -o /dev/null -s -w %{url_effective} https://github.com/XTLS/Xray-install/raw/main/install-release.sh | xargs curl -L)" @ install --without-geodata '"$VER_ARG"
        
        if [ $count -gt 0 ]; then
            desc="安装 Xray Core (第 $((count+1)) 次尝试)"
        else
            desc="安装 Xray Core"
        fi
        
        # 执行安装
        execute_task "$CMD_XRAY" "$desc"
        
        # 验证
        if [ -f "$bin_path" ] && "$bin_path" version &>/dev/null; then
            local ver=$("$bin_path" version | head -n 1 | awk '{print $2}')
            echo -e "${OK}   Xray 核心校验通过: ${GREEN}${ver}${PLAIN}"
            return 0
        fi
        
        echo -e "${WARN} 安装校验失败，清理重试..."
        rm -rf "$bin_path" "/usr/local/share/xray/"
        ((count++))
        sleep 2
    done
    
    echo -e "${ERR} [FATAL] Xray Core 安装最终失败！"
    exit 1
}

install_xray_robust

# === 4. GeoData 核心数据库安装 (IP + 域名) ===
install_geodata_robust() {
    local share_dir="/usr/local/share/xray"
    local bin_dir="/usr/local/bin"
    mkdir -p "$share_dir"
    
    # 定义下载目标
    declare -A files
    files["geoip.dat"]="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    files["geosite.dat"]="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    echo -e "${INFO} 开始下载核心数据库 (GeoIP + Geosite)..."

    for name in "${!files[@]}"; do
        local url="${files[$name]}"
        local file_path="$share_dir/$name"
        local link_path="$bin_dir/$name"

        # 1. 下载
        execute_task "curl -L -o $file_path $url" "下载 $name"

        # 2. 校验 (必须存在且大于 500KB)
        local fsize=$(du -k "$file_path" 2>/dev/null | awk '{print $1}')
        if [ ! -f "$file_path" ] || [ "$fsize" -lt 500 ]; then
            echo -e "${WARN} $name 文件校验失败 (Size: ${fsize}KB)，尝试重试..."
            rm -f "$file_path"
            execute_task "curl -L -o $file_path $url" "重试下载 $name"
            
            # 二次校验
            if [ ! -f "$file_path" ]; then
                echo -e "${ERR} [FATAL] $name 下载失败，分流功能将无法使用！"
            fi
        fi

        # 3. 建立软链接 (关键修复：解决 Xray 找不到文件的问题)
        # Xray 默认会在运行目录(/usr/local/bin)查找 dat 文件
        ln -sf "$file_path" "$link_path"
        echo -e "${OK}   已建立链接: $link_path"
    done

    # --- 4. 配置双库自动更新 (Crontab) ---
    # 每周日 4:00 同时更新 geoip 和 geosite，并重启 Xray
    local update_cmd="curl -L -o $share_dir/geoip.dat ${files[geoip.dat]} && curl -L -o $share_dir/geosite.dat ${files[geosite.dat]} && systemctl restart xray"
    local cron_job="0 4 * * 0 $update_cmd >/dev/null 2>&1"

    if ! command -v crontab &>/dev/null; then apt-get install -y cron &>/dev/null; fi
    
    # 写入任务 (先清理旧的 geoip/geosite 任务，再写入新的)
    (crontab -l 2>/dev/null | grep -v 'geoip.dat' | grep -v 'geosite.dat'; echo "$cron_job") | crontab -
    
    echo -e "${OK}   已添加 GeoData 自动更新任务 (每周日 4:00)"
}

install_geodata_robust

echo -e "${OK}   基础组件安装完毕 (已通过完整性自检)。\n"
