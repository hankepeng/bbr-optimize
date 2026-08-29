# BBR / TCP 一键优化脚本（跨境代理节点版）

面向 **香港 / 新加坡 / 日本 / 美国** 等跨境轻量服务器的 BBR 拥塞控制与 TCP 参数一键优化脚本，自带交互式菜单，支持自动识别环境、按内存选参、备份与回滚。

适用于：AWS Lightsail · 腾讯云轻量 · 阿里云轻量 等常见云厂商轻量主机。

---

## 功能特性

- **一键优化**：脚本自动完成 BBR 拥塞控制 + fq 队列 + 长肥管道缓冲区等核心 TCP 参数配置
- **按内存自动选参**：≥2G 内存自动使用 64M 缓冲区上限，<2G 自动使用 32M（无需手动改）
- **自动识别环境**：检测系统发行版、内核版本、内存大小，判断 BBR 是否可用
- **环境速览**：菜单实时显示系统/内核/内存、内网与公网 IP（含城市/国家）、BBR 与优化状态
- **内核模块兼容**：自动 `modprobe tcp_bbr` 加载模块；对内核不支持的参数宽容处理（`sysctl -p` 不报错才算成功）
- **修改前自动备份**：`/etc/sysctl.conf` 自动备份，支持一键回滚
- **幂等写入**：以标记段落形式写入，重复运行不堆积重复项
- **写后校验**：校验配置段确实写入后才执行 `sysctl -p`，避免误报成功
- **完整维护闭环**：菜单集成「应用 / 预览 / 验证 / 回滚 / 卸载 / bo 切换 / 退出」
- **静默部署**：支持 `--apply` 无交互批量应用
- **bo 快捷命令**：可自定义启停，终端输入 `bo` 即可一键进入菜单

---

## 适用环境

- Linux 内核 ≥ 4.9（原生支持 BBR）
- 常见发行版：Debian / Ubuntu / CentOS / RedHat / Rocky / AlmaLinux 等
- 内存 1G 及以上
- 需要 root 权限执行

---

## 快速开始

### 一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/hankepeng/bbr-optimize/main/bbr-optimize.sh -o bbr-optimize.sh \
  && bash bbr-optimize.sh
```

执行后进入交互菜单，选择 `1` 即可一键应用优化配置。

> 推荐「先下载后执行」而非 `bash <(curl ...)`：GitHub 的 `raw.githubusercontent.com` 在部分地区（特别是海外服务器）存在 **CDN 缓存滞后**，更新脚本后分支 URL 可能被边缘节点缓存旧版。先下载到本地文件再执行更稳定可靠。

### 若不巧拉到旧版

- 用**按提交 SHA 寻址**的 raw URL 强制取最新（绕开分支缓存）。示例：
  ```bash
  curl -fsSL https://raw.githubusercontent.com/hankepeng/bbr-optimize/42ce1cc0b96ab4e6eddf41ae3263bb343f66e1d4/bbr-optimize.sh -o bbr-optimize.sh
  ```
- 亦可直接查看仓库最新提交号替换上段链接中的 `42ce1c...`。

### 手动安装

```bash
# 下载
curl -fsSL https://raw.githubusercontent.com/hankepeng/bbr-optimize/main/bbr-optimize.sh -o bbr-optimize.sh

# 赋予执行权限并运行
chmod +x bbr-optimize.sh
bash bbr-optimize.sh
```

> 脚本通过 `/tmp` 临时文件生成配置，不额外依赖第三方软件包，绝大多数主机可直接执行。

### 静默一键应用（无交互，适合批量部署）

```bash
curl -fsSL https://raw.githubusercontent.com/hankepeng/bbr-optimize/main/bbr-optimize.sh -o bbr-optimize.sh \
  && bash bbr-optimize.sh --apply
```

> 提示：`--apply` 会直接应用配置并打印验证结果后退出，不进入菜单，适合在无终端（无 TTY）环境下批量跑或集成到自动化工具。

### 快捷命令 `bo`（可选）

进入菜单后选择 `6` 可**启用 / 停用** `bo` 快捷命令。

- **启用后**：脚本会安装到 `/opt/bbr-optimize/` 并生成软链 `/usr/local/bin/bo`，之后在终端直接输入 `bo` 即可打开菜单，无需反复输入长命令。
- **停用时**：删除 `/usr/local/bin/bo`，不影响已生效的优化配置。
- 提示：`bo` 是否启用、BBR 是否已优化，均会在菜单「当前环境」栏直接显示。

---

## 交互菜单说明

进入脚本后会先展示「当前环境」速览，再列出操作项：

```text
========== 当前环境 ==========
  系统       : Debian GNU/Linux 12 (bookworm)
  内核       : 6.1.0-50-cloud-amd64
  内存       : 973 MB
  包管理器   : apt
  内网 IP     : 10.0.0.5
  公网 IP     : 12.34.56.78（Singapore, SG）
  BBR 支持   : 是
  优化状态   : 已开启（bbr + fq）
  bo 快捷命令: 未启用（可用选项 6 开启）
```

| 序号 | 功能 | 说明 |
|------|------|------|
| `1` | 一键应用推荐配置 | 自动按内存选择缓冲区大小，应用并执行 `sysctl -p` |
| `2` | 仅预览配置 | 只打印将写入的内容，不修改系统 |
| `3` | 验证 BBR 是否生效 | 显示拥塞算法、队列算法、缓冲区上限 |
| `4` | 回滚原配置 | 恢复脚本修改前的 `/etc/sysctl.conf` |
| `5` | 卸载 | 移除脚本写入内容，拥塞控制回退为 cubic |
| `6` | 启用/停用 `bo` 快捷命令 | 可一键进入菜单的终端快捷命令 |
| `0` | 退出 | 退出脚本 |

---

## 配置内容

### 核心拥塞控制与队列
```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

### 长肥管道缓冲区优化
```
# 2G+ 内存为 64M，1G 内存自动为 32M（脚本自动选择）
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
```

### 队列与并发优化
```
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
```

### 握手与重传优化
```
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 15
```

### 跨境链路专属优化
```
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
```

---

## 验证 BBR 是否生效

```bash
# 确认拥塞控制算法为 bbr
sysctl net.ipv4.tcp_congestion_control

# 确认队列算法
sysctl net.core.default_qdisc

# 确认缓冲区上限
sysctl net.core.rmem_max

# 确认内核可用的拥塞控制中包含 bbr
cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

预期输出：

```text
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.rmem_max = 67108864
```

也可以直接在脚本菜单中选择 `3` 自动验证。

---

## 备份与回滚

- 备份文件：`/etc/sysctl.conf.bak-bbr`
- 修改前脚本自动创建备份（若已存在则不重复覆盖）
- 菜单 `4` 可一键回滚；菜单 `5` 可卸载脚本配置并恢复为系统默认拥塞控制 `cubic`

---

## 安全与注意事项

1. **务必以 root 运行**，否则脚本会拒绝执行。
2. 不同内核版本对个别参数的支持不同（如 `tcp_early_retrans` 在新版本被移除，`tcp_tw_reuse` 在新内核语义变化），脚本已做容错，不影响整体生效。
3. 建议在应用前先通过菜单 `2` 预览配置。
4. 修改 `sysctl` 属于系统级优化，生产环境建议先在小流量节点灰度验证。
5. 本脚本面向跨境代理节点等长肥管道高带宽场景；不同业务形态可能需要个性化调整。

---

## License

MIT License