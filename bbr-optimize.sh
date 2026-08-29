#!/usr/bin/env bash
# ============================================================================
# BBR / TCP 一键优化脚本（通用，适用于绝大多数 Linux 服务器）
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
# 默认收发缓冲(保持小值：只放大上限，避免小内存机器连接数一多即 OOM)
RMEM_WMEM_DEFAULT="212992"
# 本地源端口范围(放大以支撑高并发短连接)
IP_LOCAL_PORT_RANGE="1024 65535"
# TIME_WAIT 桶数量(扩容防连接洪峰被丢)
TW_BUCKETS="8192"
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
# 生成简体中文说明清单（参数|新值|原因），应用后展示给用户
CHANGES_FILE="/tmp/bbr-optimize.changes"

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

# 长肥管道缓冲区优化（只放大上限，默认值保持小值，防止小内存机器 OOM）
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${rmem_max}
net.core.rmem_default = ${RMEM_WMEM_DEFAULT}
net.core.wmem_default = ${RMEM_WMEM_DEFAULT}
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

# 高并发连接扩展优化
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}
net.ipv4.ip_local_port_range = ${IP_LOCAL_PORT_RANGE}
EOF

    # 生成参数与修改原因清单（应用后展示）
    cat > "$CHANGES_FILE" <<EOF
net.ipv4.tcp_congestion_control|bbr|启用 BBR 拥塞控制，降低长距离链路排队时延、提升吞吐
net.core.default_qdisc|fq|为 BBR 搭配 FQ 公平队列，削峰填谷、降低抖动
net.core.rmem_max / wmem_max|${rmem_max}|放大收发缓冲上限，适配"长肥管道"高带宽高延迟链路(按内存自动)
net.core.rmem_default / wmem_default|${RMEM_WMEM_DEFAULT}|保持默认缓冲为小值，避免小内存机器并发一多即 OOM
net.ipv4.tcp_rmem / tcp_wmem|4096...${rmem_max}|三段式缓冲(最小/默认/上限)，兼顾小包延迟与高吞吐
net.core.netdev_max_backlog|10000|加大网卡接收队列，扛瞬时流量突发
net.core.somaxconn|4096|加大 accept 队列，缓解连接洪峰排队
net.ipv4.tcp_max_syn_backlog|8192|加大半连接(SYN)队列，抗 SYN 突发与握手丢包
net.ipv4.tcp_fastopen|3|开启 TCP Fast Open(Client+Server)，减少建连往返时延
net.ipv4.tcp_early_retrans|3|提前重传，降低慢链路丢包造成的感知时延
net.ipv4.tcp_retries2|8|加快失败连接回收，减少无效重传与内存占用
net.ipv4.tcp_fin_timeout|15|缩短 FIN_WAIT 等待，加速连接释放
net.ipv4.tcp_mtu_probing|1|开启路径 MTU 探测，规避大包被分片或丢包的黑洞
net.ipv4.tcp_slow_start_after_idle|0|空闲重连不重置慢启动，利于低频长连接满速
net.ipv4.tcp_no_metrics_save|1|不缓存路由度量，避免旧快照干扰新路径
net.ipv4.tcp_tw_reuse|1|复用 TIME_WAIT 端口，降低高并发短连接端口不足
net.ipv4.ip_local_port_range|${IP_LOCAL_PORT_RANGE}|放大本地源端口范围(原默认 32768~60999 偏窄)，支撑更高并发
net.ipv4.tcp_max_tw_buckets|${TW_BUCKETS}|扩容 TIME_WAIT 桶(原 4096 偏小)，防连接洪峰被丢弃
net.ipv4.tcp_rfc1337|1|开启 RFC1337 防 TIME_WAIT 攻击
EOF

    echo "/tmp/bbr-optimize.conf"
}

# 展示"本次修改的参数清单 + 原因"
show_changes() {
    if [[ ! -f "$CHANGES_FILE" ]]; then
        return 0
    fi
    echo ""
    echo -e "${CYAN}========== 本次修改的参数与原因 ==========${NC}"
    printf "%-38s %-22s %s\n" "参数" "新值" "原因"
    echo "----------------------------------------------------------------------------------------"
    local param newv reason
    while IFS='|' read -r param newv reason; do
        printf "%-38s %-22s %s\n" "$param" "$newv" "$reason"
    done < "$CHANGES_FILE"
    echo "----------------------------------------------------------------------------------------"
    echo "注：实际是否生效以『验证』(菜单 3) 为准。"
    echo ""
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
        # 部分内核对个别参数不识别（过新/过旧），做容错：列出失败项但不中断
        local not_applied=0
        while IFS= read -r line; do
            if [[ "$line" =~ unknown\ key|No\ such\ file|unable ]]; then
                warn "  未生效: $line"
                not_applied=1
            fi
        done < /tmp/sysctl-p.log
        [[ "$not_applied" -eq 1 ]] && warn "个别参数当前内核不支持，已跳过（不影响 BBR 主功能）。"
    fi

    # 应用后展示本次改动的参数与原因
    show_changes
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

# ---------- 环境健康检查（应用时给出分析与建议） ----------
health_check() {
    echo ""
    echo -e "${CYAN}========== 健康检查与建议 ==========${NC}"

    # 1. 内存 / 默认缓冲风险
    if [[ "${MEM_MB:-0}" -lt 2048 ]]; then
        warn "小内存机器(${MEM_MB}MB)：默认收发缓冲已设为小值(${RMEM_WMEM_DEFAULT})，仅放大上限，降低并发 OOM 风险。"
    fi

    # 2. 是否无 swap（无 swap 时 swappiness 意义不大）
    if [[ -r /proc/meminfo ]]; then
        local swaptotal swappiness
        swaptotal=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
        if [[ "${swaptotal:-0}" -eq 0 ]]; then
            info "本机无 Swap：swappiness(${swappiness}) 实际影响有限；如需缓存更激进可将系统内存调大。"
        fi
    fi

    # 3. 源端口范围
    local port_range pstart
    port_range="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '32768 60999')"
    read -r pstart _ < <(printf '%s' "$port_range")
    if [[ -n "$pstart" && "$pstart" -gt 1024 ]]; then
        warn "本地源端口范围(${port_range})偏窄：高并发短连接下可能端口不足，建议扩至 ${IP_LOCAL_PORT_RANGE}。"
    else
        info "本地源端口范围 ${port_range}：已覆盖高并发场景。"
    fi

    # 4. TIME_WAIT 桶
    local twb
    twb="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo -)"
    if [[ "$twb" != "-" && "$twb" -lt 8192 ]]; then
        warn "TIME_WAIT 桶(${twb})偏小：高并发可能丢连接，建议 ≥8192。"
    fi

    # 5. 是否存在旧的自定义优化段落（用户在脚本之外手动加的，可能与脚本段冲突）
    if grep -q "^net\.ipv4\.tcp_congestion_control\|^net\.ipv4\.tcp_rmem\|^net\.core\.rmem_max" "$SYSCTL_CONF"; then
        local elsewhere
        elsewhere=$(grep -n "^net\.ipv4\.tcp_congestion_control\|^net\.core\.rmem_max\|^net\.ipv4\.tcp_rmem" "$SYSCTL_CONF" \
            | grep -v "^[0-9]*:.*# ================= BBR/TCP 优化配置" | wc -l)
        if [[ "$elsewhere" -gt 0 ]]; then
            warn "检测到脚本段落之外还有同名的 TCP 参数（可能手动添加）：重复定义可能导致值被覆盖，建议删除旧的自定义项。"
        fi
    fi

    echo ""
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
            1) apply_config && { info "配置已应用，请查看上方结果。"; health_check; } ;;
            2) echo "---- 即将写入的配置预览 ----"; build_config >/dev/null; cat /tmp/bbr-optimize.conf; show_changes ;;  # 预览但不写库
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
    health_check
    exit 0
fi

# 进入交互菜单前探测一次 IP（缓存，避免菜单刷新时重复请求）
detect_ip

menu