#!/usr/bin/env bash
# ============================================================================
# BBR / TCP 一键优化脚本（通用，适用于绝大多数 Linux 服务器）
# 说明：
#   1. 自动识别系统 / 包管理器 / 内核版本
#   2. 按带宽档位选择缓冲区上限（并受内存上限保护，避免小内存 OOM）
#   3. 修改前自动备份 /etc/sysctl.conf，支持一键回滚
#   4. 对内核不支持的参数做容错（不报错即成功）
# ============================================================================

set -euo pipefail

# ---------- 全局变量 ----------
# 脚本版本号（在线升级时会读取远端脚本中的同名变量做比较）
SCRIPT_VERSION="1.0.9"
# 在线升级用的下载地址（/releases/latest/download/ 永远指向最新发布）
REMOTE_SCRIPT_URL="https://github.com/hankepeng/bbr-optimize/releases/latest/download/bbr-optimize.sh"
SYSCTL_CONF="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak-bbr"
# 内存保护上限：缓冲区再大也不超过这个值
RMEM_WMEM_MAX_64="67108864"   # 充裕内存
RMEM_WMEM_MAX_32="33554432"   # 内存偏小
# 区分"充裕内存"与"内存偏小"的阈值(MB)
#   2G 机型的 MemTotal 通常只显示约 1979MB（内核占用一部分），不能用 2048 直接比较
MEM_LARGE_MB="1800"

# 带宽档位：缓冲区上限按"带宽 × RTT"的 BDP 量级估算，留足余量
#   1 = ≤10Mbps     → 4M    （常见入门轻量套餐，BDP 仅百 KB 级）
#   2 = 10-100Mbps  → 16M   （主流轻量套餐）
#   3 = ≥100Mbps    → 64M   （大带宽 / 千兆，BDP 可达数十 MB）
TIER_FILE="/etc/bbr-optimize.tier"
TIER_1_MAX="4194304"
TIER_2_MAX="16777216"
TIER_3_MAX="67108864"
DEFAULT_TIER="2"
# 默认收发缓冲(保持小值：只放大上限，避免小内存机器连接数一多即 OOM)
RMEM_WMEM_DEFAULT="212992"
# tcp_rmem/tcp_wmem 的默认段(三段式中间值)：256K
#   该值决定连接初始窗口，是单流吞吐的起步门槛：
#   160ms RTT 下，208K 约对应 ~10Mbps 单流上限，256K 约对应 ~13Mbps；
#   内核会按实际链路自适应上探(不超过第三段上限)，低延迟场景也会自动收敛，不会吃亏
TCP_MEM_DEFAULT="262144"
# 本地源端口范围(放大以支撑高并发短连接；避开 1024~9999 里常见的系统服务端口)
IP_LOCAL_PORT_RANGE="10000 65535"
# 长连接保活：默认 7200s 太长，手机切网/掉线后要两小时才能发现死连接
TCP_KEEPALIVE_TIME="300"
TCP_KEEPALIVE_INTVL="30"
TCP_KEEPALIVE_PROBES="3"
# bo 快捷命令相关
BO_BIN="/usr/local/bin/bo"
BO_INSTALL_DIR="/opt/bbr-optimize"
BO_INSTALL_SCRIPT="$BO_INSTALL_DIR/bbr-optimize.sh"
BO_RAW_BASE="$REMOTE_SCRIPT_URL"

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

# ---------- 带宽档位 ----------
tier_name() {
    case "${1:-}" in
        1) echo "≤10Mbps（入门轻量）" ;;
        2) echo "10–100Mbps（主流轻量）" ;;
        3) echo "≥100Mbps（大带宽/千兆）" ;;
        *) echo "未设置" ;;
    esac
}

# 读取生效档位（未设置时回落到默认档）
current_tier() {
    local t=""
    [[ -r "$TIER_FILE" ]] && t="$(head -n1 "$TIER_FILE" 2>/dev/null | tr -d '[:space:]')"
    case "$t" in
        1|2|3) echo "$t" ;;
        *) echo "$DEFAULT_TIER" ;;
    esac
}

tier_configured() {
    local t=""
    [[ -r "$TIER_FILE" ]] && t="$(head -n1 "$TIER_FILE" 2>/dev/null | tr -d '[:space:]')"
    case "$t" in 1|2|3) return 0 ;; *) return 1 ;; esac
}

# 环境中显示的档位文案（未设置时标注"默认"）
tier_label() {
    if tier_configured; then
        tier_name "$(current_tier)"
    else
        echo "$(tier_name "$(current_tier)")（默认）"
    fi
}

# 交互设置带宽档位
set_tier() {
    echo ""
    echo -e "${CYAN}========== 设置带宽档位 ==========${NC}"
    echo "  缓冲区上限按带宽档位选择（≈ 带宽 × RTT 的 BDP 量级）："
    echo "    1) ≤10Mbps       → 上限 4M"
    echo "    2) 10–100Mbps    → 上限 16M"
    echo "    3) ≥100Mbps      → 上限 64M"
    echo ""
    echo "  当前档位: $(tier_label)"
    echo "  提示: 填错了也不影响正确性，只是缓冲区偏大或偏小；可用测速确认套餐带宽。"
    local c
    read -rp "请选择档位 [1/2/3，直接回车保持当前]: " c
    [[ -z "$c" ]] && c="$(current_tier)"
    case "$c" in
        1|2|3)
            printf '%s\n' "$c" > "$TIER_FILE"
            ok "已设置带宽档位: $(tier_name "$c")"
            info "该档位将在下次『应用配置』时生效。"
            ;;
        *) error "无效输入，档位未修改。" ;;
    esac
}

# TIME_WAIT 桶上限：应不小于源端口范围宽度，否则短连接洪峰时桶先溢出，内核会强杀 TIME_WAIT
tw_buckets() {
    if [[ "${MEM_MB:-0}" -ge "$MEM_LARGE_MB" ]]; then echo 65536
    elif [[ "${MEM_MB:-0}" -ge 1024 ]]; then echo 32768
    else echo 16384
    fi
}

# 孤儿套接字上限（进程已关闭 fd、但仍在内核里占用内存的 socket）
tcp_orphans() {
    if [[ "${MEM_MB:-0}" -ge "$MEM_LARGE_MB" ]]; then echo 32768
    elif [[ "${MEM_MB:-0}" -ge 1024 ]]; then echo 16384
    else echo 8192
    fi
}

# TCP 全局内存三段水位（单位：页，1 页 = 4KB）
#   按物理内存比例取 6.25% / 12.5% / 25%，与内核开机自算的比例同量级；
#   显式写入可避免开机时可用内存偏低导致水位被压得过低（进而限制窗口上探）
tcp_mem_triplet() {
    local pages p0 p1 p2
    pages=$(( ${MEM_MB:-2048} * 256 ))
    p0=$(( pages / 16 )); p1=$(( pages / 8 )); p2=$(( pages / 4 ))
    [[ $p0 -lt 4096  ]] && p0=4096
    [[ $p1 -lt 8192  ]] && p1=8192
    [[ $p2 -lt 16384 ]] && p2=16384
    echo "$p0 $p1 $p2"
}

# 档位对应的名义缓冲区上限（未做内存收敛）
tier_raw_max() {
    case "$(current_tier)" in
        1) echo "$TIER_1_MAX" ;;
        2) echo "$TIER_2_MAX" ;;
        3) echo "$TIER_3_MAX" ;;
    esac
}

# 内存可承受的缓冲区上限
mem_buffer_cap() {
    if [[ "${MEM_MB:-0}" -lt "$MEM_LARGE_MB" ]]; then echo "$RMEM_WMEM_MAX_32"; else echo "$RMEM_WMEM_MAX_64"; fi
}

# 按档位取缓冲区上限，再受内存上限保护
# 注意：该函数会被 $() 调用（子shell），因此不做告警，收敛说明统一由 health_check 输出
tier_buffer_max() {
    local rmem_max mem_cap
    rmem_max="$(tier_raw_max)"
    mem_cap="$(mem_buffer_cap)"
    if [[ "$rmem_max" -gt "$mem_cap" ]]; then rmem_max="$mem_cap"; fi
    echo "$rmem_max"
}

build_config() {
    local rmem_max twb orphans tcp_mem_tri
    # 按带宽档位选择缓冲区上限（并受内存上限保护）
    rmem_max="$(tier_buffer_max)"
    twb="$(tw_buckets)"
    orphans="$(tcp_orphans)"
    tcp_mem_tri="$(tcp_mem_triplet)"
    info "带宽档位：$(tier_name "$(current_tier)") → 缓冲区上限 ${rmem_max}" >&2

    cat > /tmp/bbr-optimize.conf <<EOF
# ================= BBR/TCP 优化配置 (由 bbr-optimize.sh 写入) =================
# 带宽档位: $(current_tier) （$(tier_name "$(current_tier)")）
# 核心拥塞控制与队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 长肥管道缓冲区优化（core 默认值保持小值防 OOM；tcp 默认段 256K 抬高单流起步吞吐）
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${rmem_max}
net.core.rmem_default = ${RMEM_WMEM_DEFAULT}
net.core.wmem_default = ${RMEM_WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${TCP_MEM_DEFAULT} ${rmem_max}
net.ipv4.tcp_wmem = 4096 ${TCP_MEM_DEFAULT} ${rmem_max}

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
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1

# 高并发连接扩展优化
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_max_tw_buckets = ${twb}
net.ipv4.tcp_max_orphans = ${orphans}
net.ipv4.ip_local_port_range = ${IP_LOCAL_PORT_RANGE}

# TCP 全局内存水位(页)：低/压力/硬上限
net.ipv4.tcp_mem = ${tcp_mem_tri}

# 长连接保活：更快发现手机切网/掉线后的失效连接
net.ipv4.tcp_keepalive_time = ${TCP_KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl = ${TCP_KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${TCP_KEEPALIVE_PROBES}
EOF

    # 生成参数与修改原因清单（应用后展示）
    cat > "$CHANGES_FILE" <<EOF
net.ipv4.tcp_congestion_control|bbr|启用 BBR 拥塞控制，降低长距离链路排队时延、提升吞吐
net.core.default_qdisc|fq|为 BBR 搭配 FQ 公平队列，削峰填谷、降低抖动
net.core.rmem_max / wmem_max|${rmem_max}|按带宽档位选择上限(≈带宽×RTT 的 BDP)，并受内存上限保护
net.core.rmem_default / wmem_default|${RMEM_WMEM_DEFAULT}|保持默认缓冲为小值，避免小内存机器并发一多即 OOM
net.ipv4.tcp_rmem / tcp_wmem|4096 ${TCP_MEM_DEFAULT} ${rmem_max}|三段式缓冲(最小/默认/上限)，默认段提到 256K 抬高单流吞吐起步门槛，内核按链路自适应
net.core.netdev_max_backlog|10000|加大网卡接收队列，扛瞬时流量突发
net.core.somaxconn|4096|加大 accept 队列，缓解连接洪峰排队
net.ipv4.tcp_max_syn_backlog|8192|加大半连接(SYN)队列，抗 SYN 突发与握手丢包
net.ipv4.tcp_fastopen|3|开启 TCP Fast Open(Client+Server)，减少建连往返时延
net.ipv4.tcp_early_retrans|3|提前重传，降低慢链路丢包造成的感知时延
net.ipv4.tcp_retries2|8|加快失败连接回收，减少无效重传与内存占用
net.ipv4.tcp_fin_timeout|15|缩短 FIN_WAIT 等待，加速连接释放
net.ipv4.tcp_mtu_probing|1|开启路径 MTU 探测，规避大包被分片或丢包的黑洞
net.ipv4.tcp_slow_start_after_idle|0|空闲重连不重置慢启动，利于低频长连接满速
net.ipv4.tcp_no_metrics_save|0|保留最近一次连接的拥塞窗口，重复连接无需重新慢启动
net.ipv4.tcp_tw_reuse|1|复用 TIME_WAIT 端口，降低高并发短连接端口不足
net.ipv4.ip_local_port_range|${IP_LOCAL_PORT_RANGE}|放大本地源端口范围(原默认 32768~60999 偏窄)，且避开低位系统服务端口
net.ipv4.tcp_max_tw_buckets|${twb}|扩容 TIME_WAIT 桶到与端口范围宽度匹配，避免短连接洪峰时桶先溢出
net.ipv4.tcp_max_orphans|${orphans}|提高孤儿 socket 上限，避免连接回收阶段被限流丢包
net.ipv4.tcp_mem|${tcp_mem_tri}|按内存比例设置 TCP 全局内存水位(低/压力/硬上限)，避免开机低水位限制窗口上探
net.ipv4.tcp_keepalive_time|${TCP_KEEPALIVE_TIME}|空闲连接 5 分钟即开始探测(原 7200s 太长)，手机切网/掉线能快速发现
net.ipv4.tcp_keepalive_intvl|${TCP_KEEPALIVE_INTVL}|探测间隔 30s，配合 3 次探测约 90s 判定死连接
net.ipv4.tcp_keepalive_probes|${TCP_KEEPALIVE_PROBES}|探测 3 次仍无响应即断开并释放资源
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
    echo -e "□ 源端口范围 / TIME_WAIT 桶：\n   $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr -s '[:space:]' ' ' || echo 未知) / $(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo 未知)"
    echo -e "□ 长连接保活(时间/间隔/次数)：\n   $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo 未知) / $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo 未知) / $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo 未知)"
    echo -e "□ 内核 BBR 可用性：$(grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && echo 可用 || echo 不可用)"
}

# ---------- 环境健康检查（应用时给出分析与建议） ----------
health_check() {
    echo ""
    echo -e "${CYAN}========== 健康检查与建议 ==========${NC}"

    # 1. 内存与默认缓冲风险
    if [[ "${MEM_MB:-0}" -lt 1024 ]]; then
        warn "内存偏小(${MEM_MB}MB)：默认收发缓冲已设为小值(${RMEM_WMEM_DEFAULT})，仅放大上限，避免并发时 OOM。"
    elif [[ "${MEM_MB:-0}" -lt "$MEM_LARGE_MB" ]]; then
        info "内存 ${MEM_MB}MB（不足 2G）：缓冲区上限按内存收敛为 $(mem_buffer_cap)，属于保护策略。"
    fi

    # 2. 是否无 swap（无 swap 时 swappiness 意义不大）
    if [[ -r /proc/meminfo ]]; then
        local swaptotal swappiness
        swaptotal=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
        if [[ "${swaptotal:-0}" -eq 0 ]]; then
            info "本机无 Swap：swappiness(${swappiness}) 在无 swap 环境下基本无影响，可忽略。"
        fi
    fi

    # 3. 源端口范围
    # 注意：sysctl 输出的两个数字之间是 TAB，按空白统一切分，避免直接做数值比较时报语法错误
    local port_range pstart pend
    port_range="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    [[ -z "$port_range" ]] && port_range="32768 60999"
    pstart="$(printf '%s' "$port_range" | awk '{print $1}')"
    pend="$(printf '%s' "$port_range" | awk '{print $2}')"
    if [[ "$port_range" == "$IP_LOCAL_PORT_RANGE" ]]; then
        info "本地源端口范围 ${port_range}：符合推荐配置。"
    else
        warn "本地源端口范围(${port_range})与推荐值(${IP_LOCAL_PORT_RANGE})不一致：范围偏窄时高并发短连接可能端口耗尽。"
    fi

    # 4. TIME_WAIT 桶
    local twb twb_expect
    twb="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo -)"
    twb_expect="$(tw_buckets)"
    if [[ "$twb" != "-" && "$twb" -lt "$twb_expect" ]]; then
        warn "TIME_WAIT 桶(${twb})小于源端口范围宽度：洪峰时桶先溢出，内核会强杀 TIME_WAIT（日志报 overflow），建议 ≥${twb_expect}。"
    fi

    # 5. 监听端口是否落在临时端口范围内（重载时可能被出站连接抢占而绑定失败）
    if command -v ss >/dev/null 2>&1 && [[ "$pstart" =~ ^[0-9]+$ && "$pend" =~ ^[0-9]+$ ]]; then
        local port conflict=""
        while read -r port; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            if [[ "$port" -ge "$pstart" && "$port" -le "$pend" ]]; then
                conflict="${conflict} ${port}"
            fi
        done < <(ss -lntH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u)
        if [[ -n "$conflict" ]]; then
            warn "监听端口${conflict} 落在临时端口范围(${port_range})内：出站连接可能占用同一端口，导致服务重载时绑定失败。"
            info "  建议把这类端口排除出临时端口：sysctl -w net.ipv4.ip_local_reserved_ports=端口1,端口2（替换为实际端口）"
        fi
    fi

    # 6. 是否存在脚本段落之外的同名参数（手动添加的旧配置，会与脚本段互相覆盖）
    local elsewhere
    elsewhere="$(awk '
        /^# ================= BBR\/TCP 优化配置 \(end\)/ { inblk=0; next }
        /^# ================= BBR\/TCP 优化配置/       { inblk=1; next }
        !inblk && /^net\.(ipv4\.tcp_(congestion_control|rmem|wmem)|core\.(rmem|wmem)_max)/ { n++ }
        END { print n+0 }
    ' "$SYSCTL_CONF" 2>/dev/null)"
    if [[ "${elsewhere:-0}" -gt 0 ]]; then
        warn "检测到脚本段落之外还有 ${elsewhere} 条同名的 TCP 参数（可能手动添加）：后写的会覆盖先写的，建议清理旧的自定义项。"
    fi

    # 7. 带宽档位提示
    local want got
    want="$(tier_raw_max)"; got="$(tier_buffer_max)"
    info "当前带宽档位: $(tier_label)，缓冲区上限 ${got}；若与套餐实际带宽不符，用菜单 7 调整后重新应用。"
    if [[ "$got" -lt "$want" ]]; then
        warn "该档位建议上限 ${want} 已按内存(${MEM_MB}MB)收敛为 ${got}：属正常保护，想要更大上限需增加内存。"
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
    echo "  带宽档位   : $(tier_label)"
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

# ---------- 在线升级 ----------
# $1 是否高于 $2（版本号按点分段比较）
ver_gt() {
    [[ "$1" != "$2" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# 从脚本文件中解析版本号
parse_version() {
    grep -m1 '^SCRIPT_VERSION=' "$1" 2>/dev/null \
        | sed 's/^SCRIPT_VERSION=//; s/["'"'"']//g' | tr -d '[:space:]'
}

upgrade_script() {
    local tmp remote_ver ans self updated
    tmp="$(mktemp /tmp/bbr-optimize.upgrade.XXXXXX)" || { error "无法创建临时文件。"; return 1; }

    info "正在获取最新版本（网络不佳时可能需要几秒）..."
    if ! curl -fsSL --max-time 20 "$REMOTE_SCRIPT_URL" -o "$tmp"; then
        error "下载最新脚本失败，请检查网络或稍后重试。"
        rm -f "$tmp"
        return 1
    fi

    # 下载内容先做语法校验，避免把损坏文件覆盖到本地
    if ! bash -n "$tmp" 2>/dev/null; then
        error "下载的脚本语法校验未通过，已放弃升级（本地文件未改动）。"
        rm -f "$tmp"
        return 1
    fi

    remote_ver="$(parse_version "$tmp")"
    echo "  当前版本 : v${SCRIPT_VERSION}"
    echo "  最新版本 : ${remote_ver:+v${remote_ver}}${remote_ver:-未知}"

    if [[ -z "$remote_ver" ]]; then
        warn "无法解析远端版本号，为避免误覆盖，已跳过自动升级。"
        rm -f "$tmp"
        return 1
    fi
    if [[ "$remote_ver" == "$SCRIPT_VERSION" ]] || ! ver_gt "$remote_ver" "$SCRIPT_VERSION"; then
        ok "已是最新版本（v${SCRIPT_VERSION}），无需升级。"
        rm -f "$tmp"
        return 0
    fi

    read -rp "确认升级到 v${remote_ver}？[y/N]: " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        info "已取消升级。"
        rm -f "$tmp"
        return 0
    fi

    updated=""
    # 1. 脚本本身是实体文件时原地替换
    self="${BASH_SOURCE[0]:-}"
    if [[ -n "$self" && -f "$self" && "$self" != /dev/fd/* && "$self" != /dev/stdin ]]; then
        if cp -f "$tmp" "$self" && chmod +x "$self"; then
            ok "已升级当前脚本：${self}"
            updated="$self"
        else
            error "写入 ${self} 失败，请检查权限。"
        fi
    fi

    # 2. 已安装 bo 快捷命令时同步更新
    if [[ -f "$BO_INSTALL_SCRIPT" ]]; then
        if cp -f "$tmp" "$BO_INSTALL_SCRIPT" && chmod +x "$BO_INSTALL_SCRIPT"; then
            ok "已同步更新 bo 快捷命令：${BO_INSTALL_SCRIPT}"
            [[ -z "$updated" ]] && updated="$BO_INSTALL_SCRIPT"
        else
            warn "更新 ${BO_INSTALL_SCRIPT} 失败。"
        fi
    fi

    # 3. 通过管道/进程替换运行（无实体文件）时，安装到固定目录
    if [[ -z "$updated" ]]; then
        mkdir -p "$BO_INSTALL_DIR" 2>/dev/null
        if cp -f "$tmp" "$BO_INSTALL_SCRIPT" && chmod +x "$BO_INSTALL_SCRIPT"; then
            ok "已保存新版本到：${BO_INSTALL_SCRIPT}"
            updated="$BO_INSTALL_SCRIPT"
        fi
    fi

    rm -f "$tmp"

    if [[ -z "$updated" ]]; then
        error "升级未能写入任何文件。"
        return 1
    fi

    info "3 秒后自动重启脚本以加载新版本（Ctrl+C 可取消）..."
    sleep 3
    exec bash "$updated"
}

# ---------- 主菜单 ----------
menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${CYAN}      BBR / TCP 一键优化脚本   v${SCRIPT_VERSION}${NC}"
        echo -e "${CYAN}====================================================${NC}"
        show_env
        echo -e " ${GREEN}1)${NC} 一键应用推荐优化配置（按带宽档位选参）"
        echo -e " ${GREEN}2)${NC} 仅预览将写入的配置（不修改系统）"
        echo -e " ${GREEN}3)${NC} 验证当前 BBR 是否生效"
        echo -e " ${GREEN}4)${NC} 回滚到修改前的原配置"
        echo -e " ${GREEN}5)${NC} 卸载本脚本的配置（恢复 cubic 默认）"
        echo -e " ${GREEN}6)${NC} 启用/停用 bo 快捷命令（当前: $(bo_state && echo 已启用 || echo 已停用)）"
        echo -e " ${GREEN}7)${NC} 设置带宽档位（当前: $(tier_label)）"
        echo -e " ${GREEN}8)${NC} 在线升级脚本（当前版本: v${SCRIPT_VERSION}）"
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
            7) set_tier ;;
            8) upgrade_script ;;
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