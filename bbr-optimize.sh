#!/usr/bin/env bash
# ============================================================================
# BBR / TCP 一键优化脚本（面向跨境代理节点）
# 适用：香港 / 新加坡 / 日本 / 美国 轻量服务器
#       AWS Lightsail · 腾讯云轻量 · 阿里云轻量
# 说明：
#   1. 自动识别系统 / 包管理器 / 内核版本
#   2. 按内存大小自动选择缓冲区配置（1G 用 32M，2G+ 用 64M）
#   3. 修改前自动备份 /etc/sysctl.conf，支持一键回滚
#   4. 对内核不支持的参数做容错（不报错即成功）
# ============================================================================

set -euo pipefail

# ---------- 全局变量 ----------
SYSCTL_CONF="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak-bbr"
# 大内存(>=2048MB)缓冲区上限
RMEM_WMEM_MAX_64="67108864"
# 小内存(<2048MB)缓冲区上限
RMEM_WMEM_MAX_32="33554432"
# bo 快捷命令相关
BO_BIN="/usr/local/bin/bo"
BO_INSTALL_DIR="/opt/bbr-optimize"
BO_INSTALL_SCRIPT="$BO_INSTALL_DIR/bbr-optimize.sh"
BO_RAW_BASE="https://raw.githubusercontent.com/hankepeng/bbr-optimize/main/bbr-optimize.sh"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[信息]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*"; }
ok()    { echo -e "${GREEN}[成功]${NC} $*"; }

# ---------- 通用函数 ----------
need_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 身份运行本脚本（sudo bash bbr-optimize.sh）"
        exit 1
    fi
}

detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/debian_version ]]; then
        OS_NAME="Debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_NAME="CentOS/RedHat"
    else
        OS_NAME="Unknown"
    fi

    # 包管理器
    if   command -v apt-get >/dev/null 2>&1; then PKG="apt"
    elif command -v yum     >/dev/null 2>&1; then PKG="yum"
    elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
    else PKG="none"; fi

    KERNEL_REL="$(uname -r)"
    # 内存大小(MB)
    if [[ -r /proc/meminfo ]]; then
        MEM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
    else
        MEM_MB=2048
    fi
}

# 探测本机 IP（内网/公网，IPv4/IPv6，带超时；只在启动时调用一次缓存）
detect_ip() {
    LOCAL_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}')"
    LOCAL_IP="${LOCAL_IP%%/*}"   # 去掉 /24 形式的子网前缀
    LOCAL_IP="${LOCAL_IP:-未知}"

    LOCAL_IP6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2; exit}')"
    LOCAL_IP6="${LOCAL_IP6%%/*}"  # 去掉 /64 形式的前缀
    LOCAL_IP6="${LOCAL_IP6:-无}"

    PUBLIC_IP="获取失败"; PUB_CITY=""; PUB_CC=""
    PUBLIC_IP6=""
    if command -v curl >/dev/null 2>&1; then
        local j
        j="$(curl -4 -fsS --max-time 5 https://ipinfo.io/json 2>/dev/null)"
        if [[ -n "$j" ]]; then
            # ipinfo.io 返回的是带空格的缩进 JSON，正则需允许冒号后有任意空格
            PUBLIC_IP="$(printf '%s' "$j" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')"
            PUB_CITY="$(printf '%s' "$j" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p')"
            PUB_CC="$(printf '%s' "$j" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')"
        fi
        # 回退：ipinfo 不可达或解析为空时，依次尝试其他公网 IP 服务
        if [[ -z "$PUBLIC_IP" ]]; then
            PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
        fi
        if [[ -z "$PUBLIC_IP" ]]; then
            PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null)"
        fi
        # 公网 IPv6：仅当本机存在全局 IPv6 时才尝试（避免多一次超时等待）
        if [[ "$LOCAL_IP6" != "无" ]]; then
            PUBLIC_IP6="$(curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null)"
        fi
    fi
    PUBLIC_IP="${PUBLIC_IP:-获取失败}"
    PUBLIC_IP6="${PUBLIC_IP6:-无}"
}

# 判断内核是否支持 BBR（4.9+ 自带）
kernel_supports_bbr() {
    local major minor
    major=$(echo "$KERNEL_REL" | awk -F'.' '{print $1}')
    minor=$(echo "$KERNEL_REL" | awk -F'.' '{print $2}')
    if [[ "$major" -gt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -ge 9 ]]; }; then
        return 0
    fi
    return 1
}

load_bbr_module() {
    if ! kernel_supports_bbr; then
        warn "当前内核 ${KERNEL_REL} < 4.9，原生不支持 BBR。"
        return 1
    fi
    # 尝试加载 BBR 模块（部分发行版默认未启用）
    if ! grep -qw "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null && info "已加载 tcp_bbr 内核模块" || warn "无法加载 tcp_bbr 模块（可能已内建，忽略）"
    fi
}

# ---------- 配置生成 ----------
build_config() {
    local rmem_max
    # 按内存选择缓冲区上限
    if [[ "$MEM_MB" -ge 2048 ]]; then
        rmem_max="$RMEM_WMEM_MAX_64"
        info "检测到内存 ≥ 2G (${MEM_MB}MB)，使用 64M 缓冲区上限" >&2
    else
        rmem_max="$RMEM_WMEM_MAX_32"
        info "检测到内存 < 2G (${MEM_MB}MB)，使用 32M 缓冲区上限" >&2
    fi

    cat > /tmp/bbr-optimize.conf <<EOF
# ================= BBR/TCP 优化配置 (由 bbr-optimize.sh 写入) =================
# 核心拥塞控制与队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 长肥管道缓冲区优化
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${rmem_max}
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${rmem_max}

# 队列与并发优化
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192

# 握手与重传优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 15

# 跨境链路专属优化
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
EOF
    echo "/tmp/bbr-optimize.conf"
}

# ---------- 备份 ----------
backup_config() {
    if [[ -f "$BACKUP_FILE" ]]; then
        warn "检测到已有备份 ${BACKUP_FILE}，本次修改前不重复备份。"
    else
        cp "$SYSCTL_CONF" "$BACKUP_FILE"
        ok "已备份原配置 → ${BACKUP_FILE}"
    fi
}

# ---------- 应用配置（容错处理不支持的参数） ----------
apply_config() {
    local conf_file conf_dir
    conf_file="$(build_config)"
    conf_dir="$(dirname "$SYSCTL_CONF")"

    backup_config
    load_bbr_module || true

    # 写入/更新 /etc/sysctl.conf 中的 BBR 段落
    # 先删除历史 BBR 段（避免重复堆积）
    if grep -q "# ================= BBR/TCP 优化配置" "$SYSCTL_CONF"; then
        sed -i "/# ================= BBR\/TCP 优化配置/,/# ================= BBR\/TCP 优化配置 (end)/d" "$SYSCTL_CONF"
    fi
    printf '\n' >> "$SYSCTL_CONF"
    cat "$conf_file" >> "$SYSCTL_CONF"
    echo "# ================= BBR/TCP 优化配置 (end) =================" >> "$SYSCTL_CONF"

    # 校验配置段确实写入，避免 cat 失败却误报成功
    if grep -q "# ================= BBR/TCP 优化配置" "$SYSCTL_CONF"; then
        ok "打包写入 /etc/sysctl.conf 完成。"
    else
        error "配置写入失败，请检查文件权限或磁盘空间。"
        return 1
    fi

    info "应用配置并执行 sysctl -p ..."
    if sysctl -p "$SYSCTL_CONF" >/tmp/sysctl-p.log 2>&1; then
        ok "sysctl 全部生效，无报错。"
    else
        # 部分内核对个别参数不识别，做容错
        warn "sysctl -p 部分参数报错（通常为内核过新/过旧不支持），尝试逐条放宽处理..."
        # 说明：以下仅作为提示，不阻塞
        grep -i "unknown\|No such file" /tmp/sysctl-p.log | head -n 20 || true
    fi
}

# ---------- 验证 ----------
verify_config() {
    echo ""
    echo -e "${CYAN}========== BBR 运行验证 ==========${NC}"
    echo -e "□ 拥塞控制算法：\n   当前 $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
    echo -e "□ 队列算法：\n   当前 $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)"
    echo -e "□ 缓冲区上限(rmem_max)：\n   $(sysctl -n net.core.rmem_max 2>/dev/null || echo 未知)"
    echo -e "□ 内核 BBR 可用性：$(grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && echo 可用 || echo 不可用)"
}

# 判断 BBR 是否真正生效
bbr_active() {
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]
}

# 是否已全面优化（bbr 拥塞控制 + fq 队列）
optimized() {
    bbr_active \
        && [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]]
}

# bo 快捷命令当前是否可用（阶段判断：存在且可执行）
bo_state() {
    [[ -x "$BO_BIN" ]]
}

# 启用 bo 快捷命令：将脚本安装到固定目录并建立软链
enable_bo_shortcut() {
    mkdir -p "$BO_INSTALL_DIR"
    local src="${BASH_SOURCE[0]:-}"
    if [[ -f "$src" && "$src" != /dev/fd/* ]]; then
        cp -f "$src" "$BO_INSTALL_SCRIPT"
    else
        curl -fsSL "$BO_RAW_BASE" -o "$BO_INSTALL_SCRIPT" \
            || { error "无法下载脚本，bo 快捷命令安装失败。"; return 1; }
    fi
    chmod +x "$BO_INSTALL_SCRIPT"
    ln -sf "$BO_INSTALL_SCRIPT" "$BO_BIN"
    ok "已启用 bo 快捷命令：之后在终端输入 bo 即可打开菜单。"
}

# 停用 bo 快捷命令
disable_bo_shortcut() {
    rm -f "$BO_BIN"
    ok "已停用 bo 快捷命令。"
}

# 切换 bo 快捷命令的启用/停用
toggle_bo_shortcut() {
    if bo_state; then
        disable_bo_shortcut
    else
        enable_bo_shortcut
    fi
}

# ---------- 回滚 ----------
rollback_config() {
    if [[ ! -f "$BACKUP_FILE" ]]; then
        error "没有找到备份文件 ${BACKUP_FILE}，无法回滚。"
        return 1
    fi
    cp "$BACKUP_FILE" "$SYSCTL_CONF"
    info "正在重新加载回滚后的配置..."
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    ok "已回滚到原配置。"
}

# ---------- 卸载（清除本脚本写入内容并回滚内核参数） ----------
uninstall_config() {
    if grep -q "# ================= BBR/TCP 优化配置" "$SYSCTL_CONF"; then
        sed -i "/# ================= BBR\/TCP 优化配置/,/# ================= BBR\/TCP 优化配置 (end)/d" "$SYSCTL_CONF"
    fi
    # 恢复为系统默认值
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
    ok "已移除本脚本写入的 BBR/TCP 配置，并回退拥塞控制为 cubic。"
    info "如需要完全恢复最初状态，可执行回滚（菜单 4）。"
}

# ---------- 环境信息预览 ----------
show_env() {
    echo ""
    echo -e "${CYAN}========== 当前环境 ==========${NC}"
    echo "  系统       : ${OS_NAME:-未知} ${OS_VERSION:-}"
    echo "  内核       : ${KERNEL_REL:-未知}"
    echo "  内存       : ${MEM_MB:-未知} MB"
    if [[ -n "${PUB_CITY:-}" ]]; then
        echo "  公网 IP    : ${PUBLIC_IP:-获取失败}（${PUB_CITY}${PUB_CC:+, ${PUB_CC}}）"
    else
        echo "  公网 IP    : ${PUBLIC_IP:-获取失败}"
    fi
    echo "  公网 IPv6  : ${PUBLIC_IP6:-无}"
    echo "  BBR 支持   : $(kernel_supports_bbr && echo 是 || echo 否)"
    if optimized; then
        echo -e "  优化状态   : ${GREEN}已开启（bbr + fq）${NC}"
    elif bbr_active; then
        echo -e "  优化状态   : ${YELLOW}部分开启（拥塞算法为 bbr，但默认队列非 fq）${NC}"
    else
        echo -e "  优化状态   : ${RED}未开启 BBR（可用选项 1 一键优化）${NC}"
    fi
    echo ""
}

# ---------- 主菜单 ----------
menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${CYAN}         BBR / TCP 一键优化脚本 (跨境节点版)${NC}"
        echo -e "${CYAN}====================================================${NC}"
        show_env
        echo -e " ${GREEN}1)${NC} 一键应用推荐优化配置（自动按内存选择）"
        echo -e " ${GREEN}2)${NC} 仅预览将写入的配置（不修改系统）"
        echo -e " ${GREEN}3)${NC} 验证当前 BBR 是否生效"
        echo -e " ${GREEN}4)${NC} 回滚到修改前的原配置"
        echo -e " ${GREEN}5)${NC} 卸载本脚本的配置（恢复 cubic 默认）"
        echo -e " ${GREEN}6)${NC} 启用/停用 bo 快捷命令（当前: $(bo_state && echo 已启用 || echo 已停用)）"
        echo ""
        echo -e " ${GREEN}0)${NC} 退出"
        echo ""
        read -rp "请输入序号并回车: " choice
        echo ""
        case "$choice" in
            1) apply_config && info "配置已应用，请查看上方结果。" ;;
            2) echo "---- 即将写入的配置预览 ----"; cat "$(build_config)" ;;  # 预览但不写库
            3) verify_config ;;
            4) rollback_config ;;
            5) uninstall_config ;;
            6) toggle_bo_shortcut ;;
            0) echo "再见。"; exit 0 ;;
            *) error "无效输入，请重新选择。" ;;
        esac
        echo ""
        read -rsp "按回车返回菜单..."
    done
}

# ============================================================================
# 主入口
# ============================================================================
need_root
detect_system

# 避免 set -e 在菜单的 while 中误退出
set +e

# 非交互模式：--apply 直接应用并验证后退出（适合批量化/无 TTY 场景）
if [[ "${1:-}" == "--apply" ]]; then
    info "非交互模式：直接应用 BBR/TCP 优化配置。"
    apply_config
    echo ""
    verify_config
    exit 0
fi

# 进入交互菜单前探测一次 IP（缓存，避免菜单刷新时重复请求）
detect_ip

menu