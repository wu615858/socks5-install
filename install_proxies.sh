#!/usr/bin/env bash
# Debian/Ubuntu 一键安装：Dante(SOCKS5) + TinyProxy(HTTP)
# 默认：SOCKS5 5555 / HTTP 4444 / 账号 123456 / 密码 654321
set -euo pipefail

# ---- 可调参数（命令行也可覆盖） ----
SOCKS_PORT="${SOCKS_PORT:-5555}"
HTTP_PORT="${HTTP_PORT:-4444}"
AUTH_USER="${AUTH_USER:-123456}"   # 纯数字 OK（Debian/Ubuntu）
AUTH_PASS="${AUTH_PASS:-654321}"

# 解析命令行，比如: --user 123 --pass 456 --socks 5555 --http 4444
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) AUTH_USER="$2"; shift 2 ;;
    --pass) AUTH_PASS="$2"; shift 2 ;;
    --socks) SOCKS_PORT="$2"; shift 2 ;;
    --http) HTTP_PORT="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

# ---- 前置检查 ----
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi
if ! command -v apt >/dev/null 2>&1; then
  echo "仅支持 Debian/Ubuntu（检测不到 apt）。"
  exit 1
fi

echo "[*] 更新软件源并安装组件..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y dante-server tinyproxy curl

# 获取出网接口IP用于 external
EXT_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
EXT_IP="${EXT_IP:-0.0.0.0}"

# ---- 配置 Dante（/etc/danted.conf）----
echo "[*] 写入 /etc/danted.conf"
cat >/etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${EXT_IP}
user.privileged: root
user.notprivileged: nobody
socksmethod: username
clientmethod: none
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass  { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF

# ---- 创建认证用户（纯数字 OK）----
if id -u "${AUTH_USER}" >/dev/null 2>&1; then
  echo "[*] 用户 ${AUTH_USER} 已存在，更新密码"
else
  echo "[*] 创建用户 ${AUTH_USER}"
  useradd -M --badname "${AUTH_USER}" || true
fi
echo "${AUTH_USER}:${AUTH_PASS}" | chpasswd

# ---- 启动 Dante ----
systemctl enable --now danted

# ---- 配置 TinyProxy（/etc/tinyproxy/tinyproxy.conf）----
echo "[*] 写入 /etc/tinyproxy/tinyproxy.conf"
install -d -o tinyproxy -g tinyproxy /var/log/tinyproxy
cat >/etc/tinyproxy/tinyproxy.conf <<EOF
User tinyproxy
Group tinyproxy
Port ${HTTP_PORT}
Listen 0.0.0.0
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogFile "/var/log/tinyproxy/tinyproxy.log"
PidFile "/run/tinyproxy/tinyproxy.pid"
BasicAuth ${AUTH_USER} ${AUTH_PASS}
Allow 0.0.0.0/0
MaxClients 100
StartServers 5
ViaProxyName "tinyproxy"
DisableViaHeader Yes
ConnectPort 443
ConnectPort 563
EOF

# ---- 启动 TinyProxy ----
systemctl enable --now tinyproxy

# ---- 可选：开放 UFW 端口（如未安装则忽略）----
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${SOCKS_PORT}"/tcp || true
  ufw allow "${HTTP_PORT}"/tcp || true
fi

# ---- 输出结果 ----
PUB_IP="$(curl -s --max-time 3 https://ifconfig.me || echo "${EXT_IP}")"
echo
echo "✅ 已完成"
echo "SOCKS5: socks5://${AUTH_USER}:${AUTH_PASS}@${PUB_IP}:${SOCKS_PORT}"
echo "HTTP  : http://${AUTH_USER}:${AUTH_PASS}@${PUB_IP}:${HTTP_PORT}"
echo
systemctl --no-pager -l status danted | sed -n '1,10p' || true
systemctl --no-pager -l status tinyproxy | sed -n '1,10p' || true
echo
echo "提示：记得在云厂商安全组放行 ${SOCKS_PORT}/TCP 和 ${HTTP_PORT}/TCP。"
