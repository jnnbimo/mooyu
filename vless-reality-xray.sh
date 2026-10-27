#!/usr/bin/env bash
set -o pipefail

# Xray VLESS Reality 安装脚本。
sleep 1

cat <<'EOF'
                     _ ___                   
 ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ 
|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |
|___|___|  _  |___|___|_|_|___|  _  |___|___|
        |_____|               |_____|        
EOF

red=$'\e[91m'
green=$'\e[92m'
yellow=$'\e[93m'
magenta=$'\e[95m'
cyan=$'\e[96m'
none=$'\e[0m'

xray_install_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
xray_config="/usr/local/etc/xray/config.json"

error() {
    echo -e "\n$red 输入错误! $none\n"
}

warn() {
    echo -e "\n$yellow $1 $none\n"
}

# 端口校验：输入端口字符串，输出校验状态，不修改外部状态。
validate_port() {
    local input_port=$1
    [[ $input_port =~ ^[0-9]+$ ]] && [[ $input_port -ge 1 ]] && [[ $input_port -le 65535 ]]
}

# UUID 校验：输入 UUID 字符串，输出校验状态，不修改外部状态。
validate_uuid() {
    local input_uuid=$1
    [[ $input_uuid =~ ^[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}$ ]]
}

# ShortID 校验：输入 ShortID 字符串，输出校验状态，不修改外部状态。
validate_shortid() {
    local input_shortid=$1
    [[ ${#input_shortid} -le 16 ]] && [[ $(( ${#input_shortid} % 2 )) -eq 0 ]] && [[ $input_shortid =~ ^[0-9a-fA-F]*$ ]]
}

# Reality 密钥生成：依赖 xray 命令，可选输入已有私钥，输出 private_key 和 public_key 全局变量。
# 兼容 xray x25519 的历史输出格式：
#   旧版: "Private key: ..." / "Public key: ..."
#   新版: "PrivateKey: ..." / "Password: ..." 或 "Password (PublicKey): ..."
generate_reality_keypair() {
    local key_output
    if [[ -n "$1" ]]; then
        key_output=$(xray x25519 -i "$1")
    else
        key_output=$(xray x25519)
    fi
    private_key=$(echo "${key_output}" | awk -F': *' '/^Private ?[Kk]ey/ {print $NF}')
    public_key=$(echo "${key_output}" | awk -F': *' '/^(Public ?[Kk]ey|Password)/ {print $NF}')

    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
        echo -e "${red}Xray Reality 密钥生成失败，xray x25519 输出:${none}"
        echo "${key_output}"
        return 1
    fi
}

# 准备基础命令：安装 curl 和 wget，供后续下载安装脚本使用。
apt-get -y install curl wget -qq

InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))

for i in "${InFaces[@]}"; do
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    if [[ -n "$Public_IPv4" ]]; then
        IPv4="$Public_IPv4"
        break
    fi
done

default_uuid=$(cat /proc/sys/kernel/random/uuid)

if [ $# -ge 1 ] && [[ "${1}" != "uninstall" ]]; then
    port=${1}
    if [[ -z $port ]]; then
        port=443
    fi
    if ! validate_port "${port}"; then
        error
        exit 1
    fi

    domain=${2}
    if [[ -z $domain ]]; then
        domain="tesla.com"
    fi

    uuid=${3}
    if [[ -z $uuid ]]; then
        uuid=${default_uuid}
    fi
    if ! validate_uuid "${uuid}"; then
        error
        exit 1
    fi

    ip=${IPv4}
    echo -e "$yellow 本机IP = ${cyan}${ip}${none}"
    echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
    echo -e "$yellow 用户ID (UUID) = $cyan${uuid}${none}"
    echo -e "$yellow SNI = ${cyan}$domain${none}"
    echo "----------------------------------------------------------------"
fi

# 安装 Xray 并生成 VLESS Reality 配置。
install_xray() {
    if [[ -z $port ]]; then
        read -p "按回车键开始安装 Xray..."
    fi

    echo
    echo -e "$yellow准备工作$none"
    echo "----------------------------------------------------------------"
    apt update
    apt install -y curl wget sudo net-tools lsof

    echo
    echo -e "${yellow}Xray 官方脚本安装最新稳定版本${none}"
    echo "----------------------------------------------------------------"

    if ! bash -c "$(curl -fsSL ${xray_install_url})" @ install; then
        echo -e "${red}Xray 安装脚本执行失败${none}"
        return 1
    fi

    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${red}Xray 安装失败，未找到 xray 命令${none}"
        return 1
    fi

    mkdir -p "$(dirname "${xray_config}")"

    if [[ -n $uuid ]]; then
        generate_reality_keypair || return 1
        shortid=$(echo -n ${uuid} | sha1sum | head -c 16)

        echo
        echo "私钥公钥要在安装 Xray 之后才可以生成"
        echo -e "$yellow 私钥 (PrivateKey) = ${cyan}${private_key}${none}"
        echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}${none}"
        echo -e "$yellow ShortId = ${cyan}${shortid}${none}"
        echo "----------------------------------------------------------------"
    fi

    echo
    echo -e "$yellow打开BBR$none"
    echo "----------------------------------------------------------------"
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    echo
    echo -e "$yellow配置 Xray VLESS Reality$none"
    echo "----------------------------------------------------------------"

    ip=${IPv4}

    if [[ -z $port ]]; then
        default_port=443
        while :; do
            read -p "请输入端口 [${magenta}1-65535${none}] Input port (默认Default ${cyan}${default_port}${none}): " port
            [ -z "$port" ] && port=$default_port
            if validate_port "${port}"; then
                echo
                echo
                echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
                echo "----------------------------------------------------------------"
                echo
                break
            fi
            error
        done
    fi

    if [[ -z $uuid ]]; then
        while :; do
            echo -e "请输入 ${yellow}UUID${none}"
            read -p "默认ID: ${cyan}${default_uuid}${none}: " uuid
            [ -z "$uuid" ] && uuid=$default_uuid
            if validate_uuid "${uuid}"; then
                echo
                echo
                echo -e "$yellow UUID = $cyan$uuid$none"
                echo "----------------------------------------------------------------"
                echo
                break
            fi
            error
        done
    fi

    if [[ -z $private_key ]]; then
        generate_reality_keypair || return 1
        default_private_key=${private_key}

        while :; do
            echo -e "请输入 ${yellow}x25519 Private Key${none} x25519私钥 :"
            read -p "默认私钥 Private Key: ${cyan}${default_private_key}${none}: " input_private_key
            [ -z "$input_private_key" ] && input_private_key=$default_private_key
            # Xray 可从私钥反算公钥，手动输入私钥时同时完成格式校验。
            if generate_reality_keypair "${input_private_key}"; then
                break
            fi
            error
        done

        echo
        echo
        echo -e "$yellow 私钥 (PrivateKey) = ${cyan}${private_key}$none"
        echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}$none"
        echo "----------------------------------------------------------------"
        echo
    fi

    if [[ -z $shortid ]]; then
        default_shortid=$(echo -n ${uuid} | sha1sum | head -c 16)
        while :; do
            echo -e "请输入 ${yellow}ShortID${none} :"
            read -p "默认ShortID: ${cyan}${default_shortid}${none}: " shortid
            [ -z "$shortid" ] && shortid=$default_shortid
            if validate_shortid "${shortid}"; then
                echo
                echo
                echo -e "$yellow ShortID = ${cyan}${shortid}$none"
                echo "----------------------------------------------------------------"
                echo
                break
            fi
            error
        done
    fi

    if [[ -z $domain ]]; then
        echo -e "请输入一个 ${magenta}伪装域名${none}"
        read -p "默认: www.msn.cn: " domain
        [ -z "$domain" ] && domain="www.msn.cn"

        echo
        echo
        echo -e "$yellow SNI = ${cyan}$domain$none"
        echo "----------------------------------------------------------------"
        echo
    fi

    echo
    echo -e "$yellow 配置 ${xray_config} $none"
    echo "----------------------------------------------------------------"

    cat > "${xray_config}" <<-EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "${domain}:443",
          "serverNames": [
            "${domain}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${shortid}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

    echo
    echo -e "$yellow校验 Xray 配置$none"
    echo "----------------------------------------------------------------"
    if xray run -test -config "${xray_config}"; then
        echo -e "$green✓ Xray 配置校验通过$none"
    else
        echo -e "${red}Xray 配置校验失败，已停止启动${none}"
        return 1
    fi

    echo
    echo -e "$yellow重启 Xray$none"
    echo "----------------------------------------------------------------"

    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        echo -e "$green✓ Xray 已成功启动$none"
    else
        echo -e "${red}Xray 启动失败${none}"
        echo -e "${yellow}Xray 服务状态:${none}"
        systemctl status xray --no-pager -l
        echo -e "${yellow}Xray 最近日志:${none}"
        journalctl -u xray --no-pager -n 80
        return 1
    fi

    fingerprint="random"
    spiderx=""

    echo
    echo "---------- Xray 配置信息 -------------"
    echo -e "$green ---VLESS Reality 服务器配置--- $none"
    echo -e "$yellow 地址 (Address) = $cyan${ip}$none"
    echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
    echo -e "$yellow 用户ID (UUID) = $cyan${uuid}$none"
    echo -e "$yellow 流控 (Flow) = ${cyan}xtls-rprx-vision${none}"
    echo -e "$yellow 传输协议 (Network) = ${cyan}tcp/raw$none"
    echo -e "$yellow 底层传输安全 (TLS) = ${cyan}reality${none}"
    echo -e "$yellow SNI = ${cyan}${domain}$none"
    echo -e "$yellow 指纹 (Fingerprint) = ${cyan}${fingerprint}$none"
    echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}${none}"
    echo -e "$yellow ShortId = ${cyan}${shortid}${none}"
    echo -e "$yellow Xray 版本 (Version) = ${cyan}$(xray version | head -n 1)${none}"

    echo
    echo "---------- VLESS Reality URL ----------"
    vless_reality_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&spx=${spiderx}"
    echo -e "${cyan}${vless_reality_url}${none}"
    echo
    echo "---------- END -------------"

    echo
    echo "安装完成！"
    read -p "按回车键返回主菜单..."
}

# 卸载 Xray：使用官方脚本移除程序、服务、配置与日志。
uninstall() {
    echo
    echo -e "$red========== 卸载 Xray ==========$none"
    echo
    read -p "确认卸载吗？这将删除 Xray 相关文件 [y/${cyan}N${none}]: " confirm

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "$yellow已取消卸载$none"
        return
    fi

    echo
    echo -e "$yellow正在卸载...$none"
    echo "----------------------------------------------------------------"

    if bash -c "$(curl -fsSL ${xray_install_url})" @ remove --purge; then
        echo
        echo -e "$green========== 卸载完成 ==========$none"
        echo -e "$yellow所有 Xray 相关文件已删除$none"
    else
        echo -e "${red}Xray 官方卸载脚本执行失败，请检查上方输出${none}"
    fi
    echo
    read -p "按回车键返回主菜单..."
}

show_menu() {
    clear
    echo -e "                     _ ___                   "
    echo -e " ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ "
    echo -e "|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |"
    echo -e "|___|___|  _  |___|___|_|_|___|  _  |___|___|"
    echo -e "        |_____|               |_____|        "
    echo
    echo -e "$cyan========== Xray VLESS Reality 安装脚本 ==========$none"
    echo
    echo -e "$green 1.$none 安装 Xray Reality"
    echo -e "$green 2.$none 卸载 Xray Reality"
    echo -e "$green 0.$none 退出"
    echo
    echo "================================================"
    echo
}

main() {
    if [[ "${1}" == "uninstall" ]]; then
        uninstall
        exit 0
    elif [[ $# -ge 1 ]]; then
        install_xray
        exit $?
    fi

    while true; do
        show_menu
        read -p "请选择 [${cyan}0-2${none}]: " choice

        case $choice in
            1)
                install_xray
                ;;
            2)
                uninstall
                ;;
            0)
                echo -e "$yellow再见！$none"
                exit 0
                ;;
            *)
                echo -e "$red无效选项！$none"
                sleep 2
                ;;
        esac
    done
}

main "$@"
