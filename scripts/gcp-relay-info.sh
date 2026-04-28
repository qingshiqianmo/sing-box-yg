#!/bin/bash
# ============================================================
# GCP 中继节点信息获取脚本
# 运行在 GCP 上，自动读取 Hysteria2 配置并输出 VPS 端安装命令
# 使用方法：bash gcp-relay-info.sh
# ============================================================
export LANG=en_US.UTF-8

red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue()  { echo -e "\033[36m\033[01m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请以 root 模式运行脚本" && exit 1

# 查找有效的 sing-box 配置文件
find_config() {
    for f in /etc/s-box/sb.json /etc/s-box/sb10.json /etc/s-box/sb11.json; do
        if [[ -f "$f" ]] && jq -e '.inbounds' "$f" >/dev/null 2>&1; then
            # 确认里面有 hysteria2 inbound
            if jq -e '.inbounds[] | select(.type=="hysteria2")' "$f" >/dev/null 2>&1; then
                echo "$f"
                return 0
            fi
        fi
    done
    return 1
}

echo
blue "============================================================"
blue "          GCP 中继节点信息获取脚本"
blue "============================================================"
echo

# 检查 jq 是否安装
if ! command -v jq &>/dev/null; then
    yellow "正在安装 jq..."
    apt-get install -y jq 2>/dev/null || yum install -y jq 2>/dev/null
fi

# 检查 sing-box 服务状态
if ! systemctl is-active --quiet sing-box; then
    red "错误：sing-box 服务未运行！"
    yellow "请先运行 sb.sh 完成 GCP 上的 sing-box 安装。"
    exit 1
fi
green "✓ sing-box 服务运行正常"

# 查找配置文件
CONFIG_FILE=$(find_config)
if [[ -z "$CONFIG_FILE" ]]; then
    red "错误：未找到包含 Hysteria2 配置的 sing-box 配置文件！"
    yellow "请确认 sing-box 已通过 sb.sh 正确安装并配置了 Hysteria2 协议。"
    exit 1
fi
green "✓ 找到配置文件：$CONFIG_FILE"

# 提取 Hysteria2 配置参数
HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$CONFIG_FILE" | head -1)
HY2_PASSWORD=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "$CONFIG_FILE" | head -1)

if [[ -z "$HY2_PORT" || -z "$HY2_PASSWORD" ]]; then
    red "错误：无法从配置文件中提取 Hysteria2 端口或密码！"
    exit 1
fi

# 获取 GCP 公网 IP
GCP_IP=$(curl -s4m5 ifconfig.me 2>/dev/null || curl -s4m5 icanhazip.com 2>/dev/null)
if [[ -z "$GCP_IP" ]]; then
    yellow "警告：自动获取公网 IP 失败，请手动填写 GCP IP 地址。"
    read -p "请输入 GCP 公网 IP：" GCP_IP
fi

# SNI 默认为 bing 自签证书
SNI="www.bing.com"
# 如果使用了域名证书，尝试读取
if [[ -f /root/ygkkkca/ca.log ]]; then
    REAL_SNI=$(cat /root/ygkkkca/ca.log 2>/dev/null)
    [[ -n "$REAL_SNI" ]] && SNI="$REAL_SNI"
fi

echo
blue "============================================================"
green "✓ 成功提取 GCP Hysteria2 配置信息："
blue "  GCP IP      : $GCP_IP"
blue "  HY2 端口    : $HY2_PORT"
blue "  HY2 密码    : $HY2_PASSWORD"
blue "  TLS SNI     : $SNI"
blue "============================================================"
echo
yellow "⚠ 请确保 GCP 防火墙/安全组已放行以下规则："
yellow "  - UDP 入站端口：$HY2_PORT"
yellow "  - 来源：VPS IP (38.97.250.99)"
echo
green "============================================================"
green "请将以下命令完整复制，在【VPS (38.97.250.99)】上执行："
green "============================================================"
echo
echo "bash <(curl -Ls https://raw.githubusercontent.com/qingshiqianmo/sing-box-yg/main/scripts/vps-google-relay.sh) \\"
echo "  --gcp-ip \"$GCP_IP\" \\"
echo "  --gcp-port \"$HY2_PORT\" \\"
echo "  --gcp-password \"$HY2_PASSWORD\" \\"
echo "  --gcp-sni \"$SNI\""
echo
yellow "或者，如果脚本尚未推送到 GitHub，请手动传输后在 VPS 上执行："
echo "bash vps-google-relay.sh --gcp-ip \"$GCP_IP\" --gcp-port \"$HY2_PORT\" --gcp-password \"$HY2_PASSWORD\" --gcp-sni \"$SNI\""
echo
