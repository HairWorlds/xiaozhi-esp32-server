#!/bin/bash

set -e

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="digital-human"
INSTALL_DIR="/opt/digital-human"
VENV_DIR="${INSTALL_DIR}/.venv"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PORT=8006

# ── 与 xiaozhi-server 的连接配置 ──────────────────────────────
# OTA 地址由 index.html 发起，经 Nginx 反向代理：
#   浏览器 POST https://tea.iskaola.com/xiaozhi/ota/
#       → Nginx → http://117.162.7.154:8003/xiaozhi/ota/
# WebSocket 同理：
#   浏览器 wss://tea.iskaola.com/xiaozhi/v1/
#       → Nginx → ws://117.162.7.154:8000/xiaozhi/v1/
# 安全组仍需放行 8003 / 8000（Nginx 到 xiaozhi 的内网/公网连接）
XIAOZHI_OTA_URL="https://tea.iskaola.com/xiaozhi/ota/"

info()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; }
step()  { echo -e "\n${CYAN}▶ 步骤 $1${NC}"; echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"; }

echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║    digital-human  systemd 部署脚本           ║"
echo "  ║    服务端口：${PORT}  健康检查：/health       ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ══════════════════════════════════════════════════════════════
# 步骤 1 / 5   检查运行环境
# ══════════════════════════════════════════════════════════════
step "1/5  检查运行环境"

# 必须 root 或 sudo 可用（写 /etc/systemd）
SUDO=""
if [ "$(id -u)" != "0" ]; then
  if command -v sudo &>/dev/null; then
    SUDO="sudo"
    warn "非 root 用户，将使用 sudo 执行特权操作"
  else
    error "需要 root 权限或 sudo，请以 root 运行或安装 sudo"
    exit 1
  fi
fi

# systemd
if ! command -v systemctl &>/dev/null; then
  error "未检测到 systemd，本脚本仅支持 systemd 系统（Ubuntu 16.04+ / Debian 8+）"
  exit 1
fi
info "systemd 可用：$(systemctl --version | head -1)"

# python3
if ! command -v python3 &>/dev/null; then
  error "python3 未安装"
  echo "    sudo apt-get install -y python3"
  exit 1
fi
info "Python3：$(python3 --version)"

# ── 检测并安装 python3-venv（含 ensurepip） ───────────────────
if ! python3 -c "import venv, ensurepip" &>/dev/null 2>&1; then
  warn "python3-venv 未安装，自动安装..."
  PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  $SUDO apt-get update -q
  $SUDO apt-get install -y "python${PYVER}-venv" -q 2>/dev/null \
    || $SUDO apt-get install -y python3-venv -q
  if ! python3 -c "import venv, ensurepip" &>/dev/null 2>&1; then
    error "python3-venv 安装失败，请手动执行："
    echo "    sudo apt-get install -y python${PYVER}-venv"
    exit 1
  fi
fi
info "python3-venv 已就绪"

# ══════════════════════════════════════════════════════════════
# 步骤 2 / 5   复制项目文件
# ══════════════════════════════════════════════════════════════
step "2/5  复制项目文件到 ${INSTALL_DIR}"

$SUDO mkdir -p "${INSTALL_DIR}"
# rsync 保留符号链接、权限；--delete 删除目标中已移除的文件
if command -v rsync &>/dev/null; then
  $SUDO rsync -a --delete \
    --exclude='.venv' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='wakeword_runtime/logs' \
    "${DEPLOY_DIR}/" "${INSTALL_DIR}/"
else
  warn "rsync 未安装，使用 cp 复制（不会删除旧文件）"
  $SUDO cp -r "${DEPLOY_DIR}/." "${INSTALL_DIR}/"
fi

# 确保 logs 目录存在
$SUDO mkdir -p "${INSTALL_DIR}/wakeword_runtime/logs"

# 确保当前用户可写（或指定 owner）
OWNER="$(id -un)"
$SUDO chown -R "${OWNER}:${OWNER}" "${INSTALL_DIR}" 2>/dev/null || true

info "文件已同步到 ${INSTALL_DIR}"

# ── 注入 OTA URL，替换 index.html 中的本机开发地址 ───────────
INDEX_HTML="${INSTALL_DIR}/index.html"
if [ -f "${INDEX_HTML}" ]; then
  # 将 value="http://127.0.0.1:8002/xiaozhi/ota/" 替换为实际地址
  sed -i "s|value=\"http://127\.0\.0\.1:[0-9]*/xiaozhi/ota/\"|value=\"${XIAOZHI_OTA_URL}\"|g" \
      "${INDEX_HTML}"
  info "index.html OTA 地址已更新 → ${XIAOZHI_OTA_URL}"
else
  warn "未找到 index.html，跳过 OTA 地址注入"
fi

# ══════════════════════════════════════════════════════════════
# 步骤 3 / 5   创建虚拟环境 & 安装依赖
# ══════════════════════════════════════════════════════════════
step "3/5  创建虚拟环境 & 安装依赖"

# 旧 venv 缺少 pip 时（曾在 ensurepip 安装前创建）删除重建
if [ -d "${VENV_DIR}" ] && ! "${VENV_DIR}/bin/python3" -m pip --version &>/dev/null 2>&1; then
  warn "已有虚拟环境缺少 pip，删除重建..."
  rm -rf "${VENV_DIR}"
fi

if [ ! -d "${VENV_DIR}" ]; then
  info "创建虚拟环境 ${VENV_DIR}..."
  python3 -m venv "${VENV_DIR}"
fi

VENV_PY="${VENV_DIR}/bin/python3"
VENV_PIP="${VENV_DIR}/bin/pip"

# 升级 pip 到最新（静默）
"${VENV_PIP}" install --upgrade pip -q

# numpy 被 detector.py 直接引用，但 sherpa-onnx 的包元数据未声明该依赖，需显式安装
"${VENV_PIP}" install numpy -q

# 安装 requirements（sherpa-onnx / sounddevice / pypinyin）
REQUIREMENTS="${INSTALL_DIR}/wakeword_runtime/requirements.txt"
if [ -f "${REQUIREMENTS}" ]; then
  info "安装依赖（${REQUIREMENTS}）..."
  "${VENV_PIP}" install -r "${REQUIREMENTS}" -q
  info "依赖安装完成"
else
  warn "未找到 requirements.txt，跳过依赖安装"
fi

# ── 检测是否有音频设备，无则自动禁用唤醒词 ───────────────────
CONFIG_JSON="${INSTALL_DIR}/wakeword_runtime/config.json"
HAS_AUDIO=false
if "${VENV_PY}" -c "import sounddevice; sounddevice.query_devices()" &>/dev/null 2>&1; then
  HAS_AUDIO=true
fi

if [ "${HAS_AUDIO}" = "false" ]; then
  warn "未检测到音频设备，自动将 config.json 中 wakeword.enabled 设为 false"
  if command -v python3 &>/dev/null && [ -f "${CONFIG_JSON}" ]; then
    python3 - "${CONFIG_JSON}" <<'PYEOF'
import json, sys
path = sys.argv[1]
cfg = json.loads(open(path).read())
cfg.setdefault("wakeword", {})["enabled"] = False
open(path, "w").write(json.dumps(cfg, indent=2, ensure_ascii=False))
print(f"  已写入: {path}")
PYEOF
  fi
fi

# ══════════════════════════════════════════════════════════════
# 步骤 4 / 5   写入 systemd service 文件
# ══════════════════════════════════════════════════════════════
step "4/5  写入 systemd service 文件（${SERVICE_FILE}）"

$SUDO tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Digital Human Web Server (Live2D + Wakeword Bridge)
Documentation=https://github.com/xinnan-tech/xiaozhi-esp32-server
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_PY} ${INSTALL_DIR}/start.py
Restart=always
RestartSec=5
# 崩溃超过 5 次/10 分钟时暂停重启，防止雪崩
StartLimitIntervalSec=600
StartLimitBurst=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
# 使 print() 实时写入 journal，不缓冲
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

info "service 文件已写入"

# ══════════════════════════════════════════════════════════════
# 步骤 5 / 5   启动服务
# ══════════════════════════════════════════════════════════════
step "5/5  启动 ${SERVICE_NAME} 服务"

$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"
$SUDO systemctl restart "${SERVICE_NAME}"

# 等待启动（最多 15 秒）
echo -n "    等待服务启动"
for i in $(seq 1 15); do
  sleep 1
  printf "."
  if curl -sf --max-time 2 "http://localhost:${PORT}/health" &>/dev/null; then
    echo ""
    break
  fi
done
echo ""

# ── 验证 ──────────────────────────────────────────────────────
if $SUDO systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "服务运行中"
  echo ""
  $SUDO systemctl status "${SERVICE_NAME}" --no-pager -l | head -20 | sed 's/^/    /'
else
  error "服务启动失败，最近日志："
  echo ""
  journalctl -u "${SERVICE_NAME}" --no-pager -n 30 | sed 's/^/    /'
  exit 1
fi

if curl -sf --max-time 3 "http://localhost:${PORT}/health" &>/dev/null; then
  info "健康检查通过（端口 ${PORT}）"
else
  warn "健康检查未响应（端口 ${PORT}），服务可能仍在初始化，稍后可再试"
fi

# ══════════════════════════════════════════════════════════════
# 完成
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           digital-human 部署完成 ✔           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  服务端口：${PORT}"
echo ""
echo "  常用运维命令："
echo "    查看日志:    journalctl -u ${SERVICE_NAME} -f"
echo "    重启服务:    systemctl restart ${SERVICE_NAME}"
echo "    停止服务:    systemctl stop ${SERVICE_NAME}"
echo "    禁用自启:    systemctl disable ${SERVICE_NAME}"
echo ""
