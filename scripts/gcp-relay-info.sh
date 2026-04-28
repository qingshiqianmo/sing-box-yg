#!/bin/bash
# ============================================================
# GCP 中继节点信息获取 + 防火墙自动配置脚本
# 运行在 GCP 上：
#   1. 自动读取 Hysteria2 配置
#   2. 自动开放防火墙（OS层 + GCP VPC层）
#   3. 输出 VPS 端一键安装命令
# 使用方法：bash gcp-relay-info.sh
# ============================================================
export LANG=en_US.UTF-8

red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue()  { echo -e "\033[36m\033[01m$1\033[0m"; }

[[ $EUID -ne 0 ]] && red "请以 root 模式运行脚本" && exit 1

# ── 查找有效的 sing-box 配置文件 ──────────────────────────
find_config() {
    for f in /etc/s-box/sb.json /etc/s-box/sb10.json /etc/s-box/sb11.json; do
        if [[ -f "$f" ]] && jq -e '.inbounds' "$f" >/dev/null 2>&1; then
            if jq -e '.inbounds[] | select(.type=="hysteria2")' "$f" >/dev/null 2>&1; then
                echo "$f"
                return 0
            fi
        fi
    done
    return 1
}

# ── OS 层防火墙放行（iptables / ufw）────────────────────
open_os_firewall() {
    local port="$1"
    blue "  [防火墙] 配置 OS 层防火墙..."

    # ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/udp" >/dev/null 2>&1
        green "  ✓ ufw 已放行 UDP ${port}"
    fi

    # iptables（确保规则不重复）
    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p udp --dport "${port}" -j ACCEPT
            green "  ✓ iptables 已放行 UDP ${port}"
        else
            green "  ✓ iptables 规则已存在 UDP ${port}"
        fi
        # 持久化（若有）
        command -v netfilter-persistent &>/dev/null && netfilter-persistent save >/dev/null 2>&1
        command -v iptables-save &>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# ── GCP VPC 层防火墙放行（gcloud CLI）───────────────────
open_gcp_firewall() {
    local port="$1"
    local vps_ip="$2"

    blue "  [防火墙] 尝试配置 GCP VPC 防火墙规则..."

    if ! command -v gcloud &>/dev/null; then
        yellow "  ⚠ 未找到 gcloud CLI，跳过 VPC 防火墙自动配置。"
        yellow "    请手动在 GCP 控制台添加防火墙规则："
        yellow "    → 入站规则 | UDP | 端口 ${port} | 来源 ${vps_ip}/32"
        return
    fi

    local rule_name="allow-hy2-relay-udp${port}"

    # 检查规则是否已存在
    if gcloud compute firewall-rules describe "${rule_name}" --quiet >/dev/null 2>&1; then
        green "  ✓ GCP VPC 防火墙规则已存在：${rule_name}"
        return
    fi

    # 获取当前实例的网络
    local network
    network=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/network" \
        -H "Metadata-Flavor: Google" 2>/dev/null | awk -F'/' '{print $NF}')
    [[ -z "$network" ]] && network="default"

    # 创建防火墙规则（仅允许来自 VPS IP）
    local source_ranges="0.0.0.0/0"
    if [[ -n "$vps_ip" && "$vps_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        source_ranges="${vps_ip}/32"
    fi

    if gcloud compute firewall-rules create "${rule_name}" \
        --direction=INGRESS \
        --priority=1000 \
        --network="${network}" \
        --action=ALLOW \
        --rules="udp:${port}" \
        --source-ranges="${source_ranges}" \
        --description="Hysteria2 relay for VPS Google routing" \
        --quiet 2>/dev/null; then
        green "  ✓ GCP VPC 防火墙规则已创建：${rule_name}"
        green "    允许来源 ${source_ranges} → UDP ${port}"
    else
        yellow "  ⚠ gcloud 创建防火墙规则失败（可能权限不足）"
        yellow "    请手动在 GCP 控制台添加防火墙规则："
        yellow "    → VPC网络 > 防火墙 > 创建规则"
        yellow "    → 入站 | UDP | 端口 ${port} | 来源 ${source_ranges}"
    fi
}

# ══════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════
echo
blue "============================================================"
blue "      GCP 中继节点配置脚本（含防火墙自动配置）"
blue "============================================================"
echo

# 检查 jq
if ! command -v jq &>/dev/null; then
    yellow "正在安装 jq..."
    apt-get install -y jq 2>/dev/null || yum install -y jq 2>/dev/null
fi

# 检查 sing-box 服务
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

# 提取 Hysteria2 参数
HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$CONFIG_FILE" | head -1)
HY2_PASSWORD=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "$CONFIG_FILE" | head -1)

if [[ -z "$HY2_PORT" || -z "$HY2_PASSWORD" ]]; then
    red "错误：无法从配置文件中提取 Hysteria2 端口或密码！"
    exit 1
fi

# 获取 GCP 公网 IP
GCP_IP=$(curl -sf4m5 "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
    -H "Metadata-Flavor: Google" 2>/dev/null)
[[ -z "$GCP_IP" ]] && GCP_IP=$(curl -s4m5 ifconfig.me 2>/dev/null || curl -s4m5 icanhazip.com 2>/dev/null)
if [[ -z "$GCP_IP" ]]; then
    yellow "警告：自动获取公网 IP 失败"
    read -p "请手动输入 GCP 公网 IP：" GCP_IP
fi

# SNI：优先使用已申请的域名证书，否则用 bing 自签
SNI="www.bing.com"
if [[ -f /root/ygkkkca/ca.log ]]; then
    REAL_SNI=$(cat /root/ygkkkca/ca.log 2>/dev/null)
    [[ -n "$REAL_SNI" ]] && SNI="$REAL_SNI"
fi

# VPS IP 仅在设置了 VPS_IP 环境变量时才用于限定防火墙来源
# 默认允许所有来源（0.0.0.0/0），如需限制请：export VPS_IP=38.97.250.99
VPS_IP="${VPS_IP:-}"

# 显示提取到的配置
echo
blue "============================================================"
green "✓ 成功提取 GCP Hysteria2 配置信息："
blue "  GCP IP      : $GCP_IP"
blue "  HY2 端口    : $HY2_PORT"
blue "  HY2 密码    : $HY2_PASSWORD"
blue "  TLS SNI     : $SNI"
blue "============================================================"
echo

# ── 自动配置防火墙 ────────────────────────────────────────
blue "------------------------------------------------------------"
blue "正在自动配置防火墙..."
blue "------------------------------------------------------------"
open_os_firewall "$HY2_PORT"
open_gcp_firewall "$HY2_PORT" "$VPS_IP"
echo

# ── 输出 VPS 安装命令 ──────────────────────────────────────
green "============================================================"
green "✓ 防火墙配置完成！请将以下命令复制到 VPS 上执行："
green "============================================================"
echo
echo "bash <(curl -Ls https://raw.githubusercontent.com/qingshiqianmo/sing-box-yg/main/scripts/vps-google-relay.sh) \\"
echo "  --gcp-ip \"$GCP_IP\" \\"
echo "  --gcp-port \"$HY2_PORT\" \\"
echo "  --gcp-password \"$HY2_PASSWORD\" \\"
echo "  --gcp-sni \"$SNI\""
echo
yellow "⚠ 注意：请在【VPS】上执行上述命令，不要在 GCP 上执行！"
echo
