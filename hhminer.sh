yum install -y git

git --version 

#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

installPath=/opt/hhminer
updatePath=${installPath}/update
serviceName=hhminer

check_os() {
    if [[ -f /etc/redhat-release ]]; then
        os="centos"
    elif cat /etc/issue | grep -Eqi "debian"; then
        os="debian"
    elif cat /etc/issue | grep -Eqi "ubuntu"; then
        os="ubuntu"
    elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
        os="centos"
    elif cat /proc/version | grep -Eqi "debian"; then
        os="debian"
    elif cat /proc/version | grep -Eqi "ubuntu"; then
        os="ubuntu"
    elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
        os="centos"
    fi
}

get_ip(){
    local IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    [ ! -z ${IP} ] && echo ${IP} || echo
}

create_service() {
# Service
cat > /lib/systemd/system/${serviceName}.service << EOT
[Unit]
Description=${serviceName}
[Service]
Type=simple
WorkingDirectory=${installPath}
Environment=HOME=${installPath}
ExecStart=${installPath}/${serviceName}
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
systemctl restart  ${serviceName}

if systemctl is-active ${serviceName} &>/dev/null ;then
    echo -e "[${green}成功${plain}] 成功！"
    echo -e "   ：${green} https://$(get_ip):11113 ${plain}"
    echo -e "      ：${green} 0 ${plain}"
    echo -e "        ：${green} 0 ${plain}"
    echo -e "          ：${green} 0 ${plain}"
    echo -e "                    ：${yellow} 权限 ${plain}"
else
    echo -e "[${red}错误${plain}] ${SERVCIE_NAME} 启动失败"
fi
}

install_hhminer() {
    check_os
    case $os in
        'ubuntu'|'debian')
            apt-get -y update
            apt-get -y install wget
            ;;
        'centos')
            yum install -y wget
            ;;
    esac

    if [ -x ${updatePath} ]; then
        rm -rf ${updatePath}
    fi
    mkdir -p ${updatePath}

    cd ${updatePath}
    wget --no-check-certificate https://raw.githubusercontent.com/735840086/hhminer/main/hhminer
    if [ $? -ne 0 ]; then
        exit -1;
    fi
    chmod +x hhminer
    
    wget --no-check-certificate https://raw.githubusercontent.com/735840086/hhminer/main/version
        if [ $? -ne 0 ]; then
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
}

update_hhminer() {
    if [ -x ${updatePath} ]; then
        rm -rf ${updatePath}
    fi

    mkdir -p ${updatePath}

    cd ${updatePath}
       wget --no-check-certificate https://raw.githubusercontent.com/735840086/hhminer/main/version
    if [ $? -ne 0 ]; then
        exit -1;
    fi

    newVersion=$(cat ${updatePath}/version)
    oldVerion=$(cat ${installPath}/version)
    if [ "${newVersion}" == "${oldVerion}" ]; then
        echo -e "[${green}提示${plain}] 不需升级"
        exit 0
    fi

    install_hhminer
}

uninstall_hhminer() {
    systemctl stop ${serviceName}
    systemctl disable ${serviceName}
    rm -rf /lib/systemd/system/${serviceName}.service
    rm -rf /etc/rsyslog.d/${serviceName}.conf
    rm -rf /usr/lib/systemd/system/${serviceName}.service
    systemctl restart rsyslog > /dev/null 2>&1 &
    systemctl daemon-reload
    rm -rf ${installPath}
}


if [ "$EUID" -ne 0 ]; then
    echo -e "[${red}错误${plain}] root"
    exit 1;
fi


ops=( '安装或重新安装服务' '检测服务状态' '卸载服务' '退出' )
PS3="请输入操作的序号: "
select op in ${ops[@]}; do
    case ${op} in
    '安装或重新安装服务')
        install_allminer

        exit 0
    ;;
    '升级服务')
        update_allminer

        exit 0
    ;;
    '检测服务状态')
        systemctl status allminer
        if systemctl is-active ${serviceName} &>/dev/null ;then
            echo -e "[${green}提示${plain}] 服务运行中..."
        else
            echo -e "[${red}错误${plain}] 服务已停止"
        fi

        exit 0
    ;;
    '卸载服务')
        uninstall_allminer
        echo -e "[${green}提示${plain}] 服务已经卸载完毕"
        exit 0
    ;;
    '解除Linux系统连接数限制')
        modify_limit
        exit 0
    ;;
    '退出')
        exit 0
    ;;
    *)
        echo "请输入正确的序号"
   esac
done
