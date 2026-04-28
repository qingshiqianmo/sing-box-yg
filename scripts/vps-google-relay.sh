#!/bin/bash
# ============================================================
# VPS Google 核心流量中继配置脚本
# 运行在 VPS 上，将核心 Google 流量通过 GCP 双跳转发
# 核心流量：Google Search / API / Gmail / Maps / Docs / Gemini
# 排除流量：YouTube / Google Video / YouTube CDN
#
# 使用方法（交互式）：bash vps-google-relay.sh
# 使用方法（参数式）：
#   bash vps-google-relay.sh \
#     --gcp-ip <GCP_IP> \
#     --gcp-port <PORT> \
#     --gcp-password <PASSWORD> \
#     --gcp-sni <SNI>
# ============================================================
export LANG=en_US.UTF-8

red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue()  { echo -e "\033[36m\033[01m$1\033[0m"; }
readp() { read -p "$(yellow "$1")" $2; }

[[ $EUID -ne 0 ]] && red "请以 root 模式运行脚本" && exit 1

# ── 常量定义 ──────────────────────────────────────────────
RELAY_TAG="gcp-google-relay"
BACKUP_DIR="/etc/s-box/backups"

# 核心 Google 域名后缀（不含 YouTube / Google Video）
GOOGLE_SUFFIXES='[
  "google.com",
  "googleapis.com",
  "gstatic.com",
  "googleusercontent.com",
  "googlesource.com",
  "appspot.com",
  "gmail.com",
  "googlemail.com",
  "deepmind.com",
  "gvt1.com",
  "gvt2.com",
  "recaptcha.net",
  "googletagmanager.com",
  "google-analytics.com",
  "googledns.com",
  "withgoogle.com"
]'

# ── 参数解析 ──────────────────────────────────────────────
GCP_IP=""
GCP_PORT=""
GCP_PASSWORD=""
GCP_SNI="www.bing.com"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gcp-ip)       GCP_IP="$2";       shift 2 ;;
        --gcp-port)     GCP_PORT="$2";     shift 2 ;;
        --gcp-password) GCP_PASSWORD="$2"; shift 2 ;;
        --gcp-sni)      GCP_SNI="$2";      shift 2 ;;
        *) shift ;;
    esac
done

# ── 工具函数 ──────────────────────────────────────────────
find_config() {
    for f in /etc/s-box/sb.json /etc/s-box/sb10.json /etc/s-box/sb11.json; do
        if [[ -f "$f" ]] && jq -e '.outbounds' "$f" >/dev/null 2>&1; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

check_deps() {
    if ! command -v jq &>/dev/null; then
        yellow "正在安装 jq..."
        apt-get install -y jq 2>/dev/null || yum install -y jq 2>/dev/null
    fi
    if ! command -v jq &>/dev/null; then
        red "错误：jq 安装失败，请手动安装后重试。"
        exit 1
    fi
}

cleanup_old_relay() {
    local cfg="$1"
    blue "  清理旧的 GCP 中继配置（含旧版 Shadowsocks 方案）..."
    # 清理新标签 gcp-google-relay 和旧版标签 google-relay-out
    local tmp
    tmp=$(jq --arg tag "$RELAY_TAG" '
        .outbounds = [.outbounds[] | select(.tag != $tag and .tag != "google-relay-out")] |
        .route.rules = [.route.rules[] | select(.outbound != $tag and .outbound != "google-relay-out")]
    ' "$cfg")
    echo "$tmp" > "$cfg"

    # 清理旧版 GCP 独立 Shadowsocks 服务（如存在）
    if systemctl list-unit-files 2>/dev/null | grep -q 'sing-box-google-relay.service'; then
        blue "  检测到旧版 GCP 中继服务，正在停止并清理..."
        systemctl stop sing-box-google-relay 2>/dev/null || true
        systemctl disable sing-box-google-relay 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box-google-relay.service
        systemctl daemon-reload
        rm -rf /etc/sing-box-google-relay
        green "  ✓ 旧版 Shadowsocks 中继服务已清理"
    fi
}

inject_relay() {
    local cfg="$1"
    blue "  注入 GCP Hysteria2 出口配置..."

    # 同时完成：添加 outbound + 将路由规则插到最顶端
    local tmp
    tmp=$(jq \
        --arg     ip       "$GCP_IP" \
        --argjson port     "$GCP_PORT" \
        --arg     pwd      "$GCP_PASSWORD" \
        --arg     sni      "$GCP_SNI" \
        --arg     tag      "$RELAY_TAG" \
        --argjson suffixes "$GOOGLE_SUFFIXES" '
        # 1. 添加 GCP Hysteria2 outbound
        .outbounds += [{
            "type": "hysteria2",
            "tag": $tag,
            "server": $ip,
            "server_port": $port,
            "password": $pwd,
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "insecure": true,
                "alpn": ["h3"]
            }
        }] |
        # 2. 将 Google 分流规则插入路由表最顶端（优先级最高）
        .route.rules = [
            {
                "domain_suffix": $suffixes,
                "outbound": $tag
            }
        ] + [.route.rules[] | select(.outbound != $tag)]
    ' "$cfg")
    echo "$tmp" > "$cfg"
}

verify_config() {
    local cfg="$1"
    if ! /etc/s-box/sing-box check -c "$cfg" >/dev/null 2>&1; then
        red "错误：配置文件验证失败！"
        red "正在从备份恢复..."
        local latest_bak
        latest_bak=$(ls -t "${BACKUP_DIR}"/sb.json.bak_* 2>/dev/null | head -1)
        if [[ -n "$latest_bak" ]]; then
            cp "$latest_bak" "$cfg"
            red "已恢复备份：$latest_bak"
        fi
        return 1
    fi
    return 0
}

# ── 主流程 ────────────────────────────────────────────────
echo
blue "============================================================"
blue "       VPS Google 核心流量双跳中继配置脚本"
blue "============================================================"
echo

# 1. 检查依赖
check_deps

# 2. 检查 sing-box 服务
if ! systemctl is-active --quiet sing-box; then
    red "错误：sing-box 服务未运行！"
    yellow "请先通过 sb.sh 完成 VPS 上的 sing-box 安装。"
    exit 1
fi
green "✓ sing-box 服务运行正常"

# 3. 查找配置文件
CONFIG_FILE=$(find_config)
if [[ -z "$CONFIG_FILE" ]]; then
    red "错误：未找到有效的 sing-box 配置文件！"
    exit 1
fi
green "✓ 配置文件：$CONFIG_FILE"

# 4. 交互式获取参数（若未通过命令行提供）
echo
if [[ -z "$GCP_IP" ]]; then
    readp "请输入 GCP 的公网 IP 地址：" GCP_IP
fi
if [[ -z "$GCP_PORT" ]]; then
    readp "请输入 GCP 的 Hysteria2 端口：" GCP_PORT
fi
if [[ -z "$GCP_PASSWORD" ]]; then
    readp "请输入 GCP 的 Hysteria2 密码（UUID）：" GCP_PASSWORD
fi
readp "请输入 TLS SNI 域名（回车默认 www.bing.com）：" input_sni
[[ -n "$input_sni" ]] && GCP_SNI="$input_sni"

# 5. 参数验证
if [[ -z "$GCP_IP" || -z "$GCP_PORT" || -z "$GCP_PASSWORD" ]]; then
    red "错误：GCP IP、端口、密码均为必填项！"
    exit 1
fi
if ! [[ "$GCP_PORT" =~ ^[0-9]+$ ]] || [[ "$GCP_PORT" -lt 1 || "$GCP_PORT" -gt 65535 ]]; then
    red "错误：端口号无效：$GCP_PORT"
    exit 1
fi

echo
blue "------------------------------------------------------------"
blue "确认配置参数："
blue "  GCP IP      : $GCP_IP"
blue "  HY2 端口    : $GCP_PORT"
blue "  HY2 密码    : $GCP_PASSWORD"
blue "  TLS SNI     : $GCP_SNI"
blue "  中继标签    : $RELAY_TAG"
blue "------------------------------------------------------------"
readp "确认以上配置并继续？[Y/n]：" confirm
[[ "${confirm,,}" == "n" ]] && yellow "已取消操作。" && exit 0

# 6. 备份配置
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/sb.json.bak_$(date +%s)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
green "✓ 配置已备份至：$BACKUP_FILE"

# 7. 停止服务
blue "  停止 sing-box 服务..."
systemctl stop sing-box

# 8. 清理旧配置
cleanup_old_relay "$CONFIG_FILE"
green "✓ 旧的中继配置已清理"

# 9. 注入新配置
inject_relay "$CONFIG_FILE"
green "✓ 新的 GCP 中继配置已注入"

# 10. 验证配置
blue "  验证配置文件格式..."
if ! verify_config "$CONFIG_FILE"; then
    red "配置验证失败，已回滚！请检查参数是否正确。"
    systemctl start sing-box
    exit 1
fi
green "✓ 配置文件验证通过"

# 11. 重启服务
blue "  重启 sing-box 服务..."
systemctl restart sing-box
sleep 2

# 12. 显示结果
echo
blue "============================================================"
if systemctl is-active --quiet sing-box; then
    green "✓ sing-box 服务启动成功！"
else
    red "✗ sing-box 服务启动失败！"
    yellow "查看日志：journalctl -u sing-box -n 30 --no-pager"
    exit 1
fi
systemctl status sing-box --no-pager | grep "Active:"

echo
green "============================================================"
green "配置完成！以下 Google 核心域名流量将通过 GCP 双跳："
yellow "  ✓ google.com / Gmail / Google API"
yellow "  ✓ Gemini AI (googleapis.com)"
yellow "  ✓ Google Docs / Drive / Maps"
yellow "  ✓ Google 静态资源 (gstatic.com)"
yellow "  ✗ YouTube（不包含，直连或走 VPS）"
yellow "  ✗ Google Video CDN（不包含）"
green "============================================================"
echo
blue "验证方法："
blue "1. 保持客户端连接 VPS（不改客户端配置）"
blue "2. 访问 https://www.google.com → 查看是否可访问"
blue "3. 访问 https://ipinfo.io → 确认全局出口仍为 VPS IP"
blue "4. 访问 https://www.google.com/search?q=what+is+my+ip → 确认结果为 GCP IP"
echo
yellow "如需撤销此配置，只需重新运行本脚本并跳过（或传入错误参数触发回滚）"
yellow "或手动恢复备份：cp $BACKUP_FILE $CONFIG_FILE && systemctl restart sing-box"
echo
