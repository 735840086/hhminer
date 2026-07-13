#!/bin/bash
# 精简版hhminer管理脚本，仅保留指定基础功能
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[34m'
bold='\033[1m'
plain='\033[0m'

# 基础路径配置（原版不变）
installPath=/opt/hhminer
updatePath=${installPath}/update
serviceName=hhminer
APP_ID="hhminer"
SYSCTL_TAG="${APP_ID}"
PATH_NOHUP="${installPath}/nohup.out"
PATH_ERR="${installPath}/err.log"

# ===================== 系统OS检测 =====================
check_os() {
    if [[ -f /etc/redhat-release ]]; then
        os="centos"
    elif cat /etc/issue | grep -Eqi "debian"; then
        os="debian"
    elif cat /etc/issue | grep -Eqi "ubuntu"; then
        os="ubuntu"
    elif cat /proc/version | grep -Eqi "debian"; then
        os="debian"
    elif cat /proc/version | grep -Eqi "ubuntu"; then
        os="ubuntu"
    elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
        os="centos"
    fi
}

# 获取公网IP
get_ip(){
    local IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    [ ! -z ${IP} ] && echo ${IP} || echo
}

# ===================== 系统依赖/权限检测 =====================
require_root() {
    [ "$(id -u)" != "0" ] && { echo -e "[${red}错误${plain}] 需要root权限执行脚本"; exit 1; }
}

is_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

check_dependencies() {
    local missing=""
    local cmd
    for cmd in pgrep sed grep mkdir chmod touch tail awk find ip wget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done
    if [ -n "$missing" ]; then
        echo -e "[${red}错误${plain}] 缺失依赖命令:$missing"
        return 1
    fi
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo -e "[${red}错误${plain}] 缺少下载工具wget/curl"
        return 1
    fi
}

# ===================== 进程操作工具 =====================
check_process() {
    pgrep -x "$serviceName" >/dev/null 2>&1
}

wait_for_process_started() {
    local timeout="${2:-10}"
    local interval="1"
    local max_attempts="$timeout"
    local attempts=0
    if check_process; then
        return 0
    fi
    while [ "$attempts" -lt "$max_attempts" ]; do
        if check_process; then
            return 0
        fi
        sleep "$interval"
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_process_stopped() {
    local timeout="${2:-10}"
    local interval="1"
    local max_attempts="$timeout"
    local attempts=0
    if ! check_process; then
        return 0
    fi
    while [ "$attempts" -lt "$max_attempts" ]; do
        if ! check_process; then
            return 0
        fi
        sleep "$interval"
        attempts=$((attempts + 1))
    done
    return 1
}

kill_process() {
    local pids=($(pgrep -x "$serviceName"))
    if [ ${#pids[@]} -eq 0 ]; then
        echo -e "[${yellow}提示${plain}] 未检测到$serviceName进程"
        return 1
    fi
    for pid in "${pids[@]}"; do
        echo -e "[${yellow}停止${plain}] 终止进程PID:$pid"
        kill -TERM "$pid"
    done
    if wait_for_process_stopped 10; then
        echo -e "[${green}成功${plain}] 进程全部终止"
    else
        echo -e "[${red}错误${plain}] 进程停止超时，强制kill"
        for pid in "${pids[@]}"; do kill -9 $pid; done
    fi
}

# ===================== 运行目录初始化 =====================
ensure_runtime_files() {
    mkdir -p "$installPath"
    chmod 755 "$installPath"
    [ -f "$PATH_NOHUP" ] || touch "$PATH_NOHUP"
    [ -f "$PATH_ERR" ] || touch "$PATH_ERR"
    chmod 640 "$PATH_NOHUP" "$PATH_ERR"
}

# ===================== systemd服务创建 =====================
create_service() {
    ensure_runtime_files
    cat > /lib/systemd/system/${serviceName}.service << EOT
[Unit]
Description=${serviceName}
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=${installPath}
Environment=HOME=${installPath}
ExecStart=/bin/sh -c 'exec "${installPath}/${serviceName}" >> "${PATH_NOHUP}" 2>> "${PATH_ERR}"' sh
SyslogIdentifier=${serviceName}
StandardOutput=syslog
Restart=always
RestartSec=3
TimeoutSec=300
LimitCORE=infinity
LimitNOFILE=655360
LimitNPROC=655360
[Install]
WantedBy=multi-user.target
EOT
    touch /var/log/${serviceName}.log
    touch /var/log/hhminer.log
    cat > /etc/rsyslog.d/${serviceName}.conf << EOT
if \$programname == '${serviceName}' then /var/log/${serviceName}.log
& stop
EOT
    systemctl restart rsyslog > /dev/null 2>&1 &
    systemctl daemon-reload
    systemctl enable ${serviceName}
}

remove_service_file() {
    if is_systemd_available; then
        systemctl disable --now "${serviceName}.service" >/dev/null 2>&1
        rm -f -- "/lib/systemd/system/${serviceName}.service"
        rm -f -- "/usr/lib/systemd/system/${serviceName}.service"
        rm -f -- "/etc/rsyslog.d/${serviceName}.conf"
        systemctl restart rsyslog > /dev/null 2>&1 &
        systemctl daemon-reload
    fi
}

# ===================== 启停核心函数 =====================
start() {
    echo -e "[${yellow}操作${plain}] 启动$serviceName代理程序"
    check_process
    if [ $? -eq 0 ]; then
        echo -e "[${yellow}提示${plain}] 程序已在运行，无需重复启动"
        return
    fi
    ensure_runtime_files
    create_service
    systemctl start "${serviceName}.service"
    if wait_for_process_started 10; then
        clear
        ip=$(get_ip)
        echo ""
        echo -e "|----------------------------------------------------------------|"
        echo -e "           ${green}程序启动成功${plain}"
        echo -e ""
        echo -e "WEB（IP）   ：${green} https://${ip}:11113 ${plain}"
        echo -e "后端端口      ：${green} 11112 ${plain}"
        echo -e "用户名        ：${green} admin ${plain}"
        echo -e "密码          ：${green} 1122345 ${plain}"
        echo -e ""
        echo -e "[${yellow}安全提示${plain}] 服务器/服务商防火墙务必放行11113端口，登录后修改默认密码"
        echo "|----------------------------------------------------------------|"
    else
        echo -e "[${red}错误${plain}] 程序启动失败，请查看实时错误日志(菜单4)"
    fi
}

stop() {
    echo -e "[${yellow}操作${plain}] 停止$serviceName进程"
    if is_systemd_available && [ -f "/lib/systemd/system/${serviceName}.service" ]; then
        systemctl stop "${serviceName}.service"
    fi
    if check_process; then
        kill_process
    else
        echo -e "[${yellow}提示${plain}] 未检测到运行中的$serviceName进程"
    fi
}

restart() {
    stop
    sleep 1
    start
}

# ===================== TCP/文件句柄系统优化 =====================
cleanup_global_network_optimization() {
    local keys=(
        fs.file-max fs.inotify.max_user_instances
        net.ipv4.tcp_congestion_control net.core.default_qdisc
        net.ipv4.tcp_fin_timeout net.ipv4.tcp_fastopen net.ipv4.tcp_fastopen_blackhole_timeout_sec
        net.ipv4.tcp_max_orphans net.ipv4.tcp_tw_reuse net.ipv4.ip_local_port_range
        net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_no_metrics_save
        net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat
        net.ipv4.tcp_syn_retries net.ipv4.tcp_synack_retries
        net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
        net.core.somaxconn net.core.rmem_max net.core.wmem_max
        net.core.rmem_default net.core.wmem_default
        net.core.netdev_max_backlog net.core.netdev_budget
        net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_slow_start_after_idle
        vm.swappiness vm.dirty_ratio vm.dirty_background_ratio
    )
    local files=("/etc/sysctl.conf")
    local f
    local key
    sed -i '/ulimit -SHn/d' /etc/profile 2>/dev/null || true
    touch /etc/sysctl.conf
    if [ -d /etc/sysctl.d ]; then
        while IFS= read -r f; do
            [ -f "$f" ] && files+=("$f")
        done < <(find /etc/sysctl.d -maxdepth 1 -name "*.conf" 2>/dev/null)
    fi
    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        sed -i '/^# === ${SYSCTL_TAG} network optimization begin ===/,/^# === ${SYSCTL_TAG} network optimization end ===/d' "$f"
        for key in "${keys[@]}"; do
            sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "$f"
        done
    done
    rm -f "/etc/sysctl.d/99-${SYSCTL_TAG}-optimize.conf" /etc/sysctl.d/99-tcpmux-optimize.conf 2>/dev/null || true
}

sysctl_key_path() {
    local key="$1"
    echo "/proc/sys/${key//./\/}"
}

apply_sysctl_setting() {
    local key="$1"
    local value="$2"
    local output_file="$3"
    local available
    [ -e "$(sysctl_key_path "$key")" ] || return 1
    if [ "$key" = "net.ipv4.tcp_congestion_control" ]; then
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
        [[ "$available" == *"$value"* ]] || return 1
    fi
    if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
        echo "${key} = ${value}" >> "$output_file"
        return 0
    fi
    return 1
}

apply_global_network_optimization() {
    local sysctl_file="/etc/sysctl.conf"
    local applied_count=0
    if ! command -v sysctl >/dev/null 2>&1; then
        echo -e "[${red}错误${plain}] 未找到sysctl，无法优化网络参数"
        return 1
    fi
    cleanup_global_network_optimization
    {
        echo ""
        echo "# === ${SYSCTL_TAG} network optimization begin ==="
        echo "# Generated by hhminer.sh 连接数优化"
        echo "# 文件句柄与TCP队列优化"
    } >> "$sysctl_file"
    apply_sysctl_setting fs.file-max 1048576 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting fs.inotify.max_user_instances 8192 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.default_qdisc fq "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_congestion_control bbr "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_fastopen 3 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_fastopen_blackhole_timeout_sec 0 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_fin_timeout 15 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_max_orphans 262144 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_tw_reuse 1 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_max_tw_buckets 2000000 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_max_syn_backlog 65535 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_slow_start_after_idle 0 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_no_metrics_save 1 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_mtu_probing 1 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_notsent_lowat 16384 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_syn_retries 3 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_synack_retries 3 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_keepalive_time 600 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_keepalive_intvl 30 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_keepalive_probes 3 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.ip_local_port_range "10000 65535" "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_rmem "4096 87380 16777216" "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.ipv4.tcp_wmem "4096 65536 16777216" "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.somaxconn 65535 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.rmem_max 16777216 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.wmem_max 16777216 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.rmem_default 2097152 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.wmem_default 2097152 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.netdev_max_backlog 50000 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting net.core.netdev_budget 600 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting vm.swappiness 10 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting vm.dirty_ratio 10 "$sysctl_file" && applied_count=$((applied_count + 1))
    apply_sysctl_setting vm.dirty_background_ratio 5 "$sysctl_file" && applied_count=$((applied_count + 1))
    echo "# === ${SYSCTL_TAG} network optimization end ===" >> "$sysctl_file"
    mkdir -p /etc/security/limits.d
    cat > "/etc/security/limits.d/99-${SYSCTL_TAG}.conf" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    if is_systemd_available; then
        mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
        cat > "/etc/systemd/system.conf.d/99-${SYSCTL_TAG}-limits.conf" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
        cat > "/etc/systemd/user.conf.d/99-${SYSCTL_TAG}-limits.conf" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
        systemctl daemon-reload
    fi
    sysctl -p "$sysctl_file" >/dev/null 2>&1 || true
    echo -e "[${green}优化${plain}] 全局网络/文件句柄优化完成，修改项:${applied_count}，重启服务器生效"
}

# ===================== 日志查看函数 =====================
view_systemd_log() {
    if ! command -v journalctl >/dev/null 2>&1; then
        echo -e "[${red}错误${plain}] 当前系统不支持journalctl"
        return 1
    fi
    echo -e "[${yellow}提示${plain}] 查看systemd服务日志，Ctrl+C退出"
    journalctl -u "${serviceName}.service" -n 100 -f
}

view_error_log() {
    echo -e "[${yellow}提示${plain}] 实时错误日志，按Ctrl+C退出查看"
    tail -f "$PATH_ERR"
}

# ===================== 安装/卸载原版逻辑 =====================
install_hhminer() {
    check_os
    check_dependencies
    case $os in
        'ubuntu'|'debian')
            apt-get -y update >/dev/null 2>&1
            apt-get -y install wget git >/dev/null 2>&1
            ;;
        'centos')
            yum install -y wget git >/dev/null 2>&1
            ;;
    esac
    if check_process; then
        echo -e "[${yellow}提示${plain}] 检测到hhminer正在运行，必须停止才能重装"
        echo "1. 停止程序并继续安装"
        echo "2. 取消安装"
        read -p "请选择: " choose
        case $choose in
        1) stop ;;
        2) echo -e "[${yellow}提示${plain}] 安装取消"; return ;;
        *) echo -e "[${red}错误${plain}] 输入无效，取消安装"; return ;;
        esac
    fi
    if [ -x ${updatePath} ]; then
        rm -rf ${updatePath}
    fi
    mkdir -p ${updatePath}
    cd ${updatePath}
    wget --no-check-certificate https://raw.githubusercontent.com/735840086/hhminer/main/hhminer
    if [ $? -ne 0 ]; then
        echo -e "[${red}错误${plain}] 主程序下载失败"
        exit -1;
    fi
    chmod +x hhminer
    wget --no-check-certificate https://raw.githubusercontent.com/735840086/hhminer/main/version
    if [ $? -ne 0 ]; then
        echo -e "[${red}错误${plain}] version文件下载失败"
        exit -1;
    fi
    if [ -f "${installPath}/hhminer.bak" ]; then
        rm -rf "${installPath}/hhminer.bak"
        rm -rf "${installPath}/version.bak"
    fi
    if [ -f "${installPath}/hhminer" ]; then
        mv "${installPath}/hhminer" "${installPath}/hhminer.bak"
        mv "${installPath}/version" "${installPath}/version.bak"
    fi
    mv "${updatePath}/hhminer" "${installPath}/hhminer"
    mv "${updatePath}/version" "${installPath}/version"
    create_service
    start
}

uninstall_hhminer() {
    read -p "输入YES确认完全卸载hhminer（删除程序、服务、日志）: " confirm
    if [ "$confirm" != "YES" ]; then
        echo -e "[${yellow}提示${plain}] 卸载操作已取消"
        return
    fi
    stop
    remove_service_file
    rm -rf ${installPath}
    echo -e "[${green}成功${plain}] hhminer程序、服务、日志全部卸载完毕"
}

# ===================== 主菜单（仅保留8项指定功能） =====================
show_menu() {
    clear
    echo -e "${bold}${blue}+=============================================+${plain}"
    echo -e "${bold}        hhMiner 精简管理脚本 ${plain}"
    echo -e "${bold}${blue}+=============================================+${plain}"
    echo "  1. 安装/重装程序"
    echo "  2. 启动服务"
    echo "  3. 停止服务"
    echo "  4. 重启服务"
    echo "  5. 解除系统TCP/文件句柄连接限制"
    echo "  6. 查看systemd服务日志"
    echo "  7. 实时错误日志"
    echo "  8. 卸载hhminer完整程序"
    echo -e "${bold}${blue}+=============================================+${plain}"
    echo -e "${yellow}提示：连接限制修改后需重启服务器生效${plain}"
    echo -e "${bold}${blue}+=============================================+${plain}"
}

# ===================== 入口执行 =====================
if [ "$EUID" -ne 0 ]; then
    echo -e "[${red}错误${plain}] 请使用root权限执行本脚本"
    exit 1;
fi

while true; do
    show_menu
    read -p "请输入操作序号: " opt
    case ${opt} in
    1) install_hhminer ;;
    2) start ;;
    3) stop ;;
    4) restart ;;
    5) apply_global_network_optimization ;;
    6) view_systemd_log ;;
    7) view_error_log ;;
    8) uninstall_hhminer ;;
    *)
        echo -e "[${red}错误${plain}] 输入序号无效，回车返回菜单"
        read
        ;;
    esac
    echo -e "\n${yellow}操作执行完成，按回车返回主菜单${plain}"
    read
done
