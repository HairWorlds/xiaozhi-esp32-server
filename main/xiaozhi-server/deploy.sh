#!/bin/bash

set -e

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_IP="117.162.7.154"

info()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; }
step()  { echo -e "\n${CYAN}▶ 步骤 $1${NC}"; echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"; }
banner(){
  echo -e "${BLUE}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║    xiaozhi-esp32-server  部署脚本            ║"
  echo "  ║    服务器：${SERVER_IP}                   ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

banner

# ══════════════════════════════════════════════════════════════
# 步骤 1 / 5   检查运行环境
# ══════════════════════════════════════════════════════════════
step "1/5  检查运行环境"

# Docker
if ! command -v docker &>/dev/null; then
  error "Docker 未安装"
  echo "  请先安装 Docker："
  echo "    curl -fsSL https://get.docker.com | sh"
  echo "    systemctl enable --now docker"
  exit 1
fi
info "Docker 已安装：$(docker --version)"

# Docker Compose（优先使用 plugin，兼容旧版 standalone）
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  info "Docker Compose plugin：$(docker compose version)"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
  info "Docker Compose standalone：$(docker-compose --version)"
else
  error "Docker Compose 未安装"
  echo "  安装命令："
  echo "    apt-get install -y docker-compose-plugin   # Ubuntu/Debian"
  echo "    yum install -y docker-compose-plugin       # CentOS/RHEL"
  exit 1
fi

# Python3（用于下载模型）
if command -v python3 &>/dev/null; then
  info "Python3 已安装：$(python3 --version)"
else
  warn "Python3 未安装，若模型文件不存在将无法自动下载"
fi

# ══════════════════════════════════════════════════════════════
# 步骤 2 / 5   创建目录结构
# ══════════════════════════════════════════════════════════════
step "2/5  创建目录结构"

mkdir -p "${DEPLOY_DIR}/data"
mkdir -p "${DEPLOY_DIR}/models/SenseVoiceSmall"
mkdir -p "${DEPLOY_DIR}/tmp"
mkdir -p "${DEPLOY_DIR}/music"

info "目录结构已就绪"
echo "    ${DEPLOY_DIR}/"
echo "    ├── data/          ← 配置文件（挂载进容器）"
echo "    ├── models/        ← FunASR 模型文件（挂载进容器）"
echo "    ├── tmp/           ← 运行时临时文件"
echo "    └── music/         ← 本地音乐文件（可选）"

# ══════════════════════════════════════════════════════════════
# 步骤 3 / 5   检查配置文件
# ══════════════════════════════════════════════════════════════
step "3/5  检查配置文件"

CONFIG_FILE="${DEPLOY_DIR}/data/.config.yaml"

if [ -f "${CONFIG_FILE}" ]; then
  info "data/.config.yaml 已存在，配置摘要："
  echo ""
  # 打印几个关键字段
  grep -E "^\s*(base_url|model_name|voice:|LLM:|TTS:|Memory:|Intent:|websocket)" \
       "${CONFIG_FILE}" 2>/dev/null | head -15 | sed 's/^/    /'
  echo ""
else
  warn "data/.config.yaml 不存在，将使用默认 config.yaml 运行"
  warn "建议将本机的 data/.config.yaml 上传到 ${DEPLOY_DIR}/data/ 后重新执行"
fi

# ══════════════════════════════════════════════════════════════
# 步骤 4 / 5   准备 FunASR 模型（SenseVoiceSmall）
# ══════════════════════════════════════════════════════════════
step "4/5  准备 FunASR 语音识别模型（SenseVoiceSmall，约 600MB）"

MODEL_FILE="${DEPLOY_DIR}/models/SenseVoiceSmall/model.pt"

if [ -f "${MODEL_FILE}" ]; then
  info "模型文件已存在，跳过下载"
  echo "    路径：${MODEL_FILE}"
  echo "    大小：$(du -sh "${MODEL_FILE}" | cut -f1)"
else
  warn "模型文件不存在，开始自动下载..."

  if ! command -v python3 &>/dev/null; then
    error "python3 未安装，无法自动下载模型"
    echo ""
    echo "  手动下载步骤："
    echo "    pip3 install modelscope"
    echo "    python3 -c \\"
    echo "      \"from modelscope import snapshot_download; \\"
    echo "       snapshot_download('iic/SenseVoiceSmall', local_dir='${DEPLOY_DIR}/models/SenseVoiceSmall')\""
    echo ""
    echo "  或从以下地址手动下载 model.pt 放到："
    echo "    ${MODEL_FILE}"
    exit 1
  fi

  # 使用独立虚拟环境安装 modelscope，绕过所有 pip/PEP668 兼容性问题
  # Ubuntu 需要单独安装 python3-venv（含 ensurepip）；兼容 root 和普通用户
  SUDO=""
  [ "$(id -u)" != "0" ] && SUDO="sudo"

  # 检测 ensurepip（不是检测 venv 模块，import venv 在无 ensurepip 时也能通过）
  if ! python3 -c "import venv, ensurepip" &>/dev/null 2>&1; then
    info "安装 python3-venv（含 ensurepip）..."
    PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    $SUDO apt-get update -q \
      && { $SUDO apt-get install -y "python${PYVER}-venv" -q 2>/dev/null \
           || $SUDO apt-get install -y python3-venv -q; }
    # 安装后再验证一次
    if ! python3 -c "import venv, ensurepip" &>/dev/null 2>&1; then
      error "python3-venv 安装失败，请手动执行："
      echo "    sudo apt-get install -y python$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")-venv"
      exit 1
    fi
  fi

  VENV_DIR="${DEPLOY_DIR}/.venv-modelscope"
  VENV_PY="${VENV_DIR}/bin/python3"
  # 若旧 venv 缺少 pip（在 ensurepip 安装前创建的残留），直接删除重建
  if [ -d "${VENV_DIR}" ] && ! "${VENV_PY}" -m pip --version &>/dev/null 2>&1; then
    warn "已有虚拟环境缺少 pip，删除重建..."
    rm -rf "${VENV_DIR}"
  fi
  if [ ! -d "${VENV_DIR}" ]; then
    info "创建虚拟环境 ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}"
  fi

  if ! "${VENV_PY}" -c "import modelscope" &>/dev/null 2>&1; then
    info "安装 modelscope 到虚拟环境..."
    "${VENV_PY}" -m pip install modelscope -q
  fi

  info "开始下载模型（国内使用 modelscope，速度较快）..."
  "${VENV_PY}" - <<PYEOF
import os, sys
os.environ.setdefault('MODELSCOPE_CACHE', '${DEPLOY_DIR}/models')
try:
    from modelscope import snapshot_download
    snapshot_download('iic/SenseVoiceSmall', local_dir='${DEPLOY_DIR}/models/SenseVoiceSmall')
    print("  模型下载完成")
except Exception as e:
    print(f"  下载失败: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

  if [ -f "${MODEL_FILE}" ]; then
    info "模型下载成功：${MODEL_FILE}"
  else
    error "模型文件不存在，下载可能失败，请检查网络或手动下载"
    exit 1
  fi
fi

# ══════════════════════════════════════════════════════════════
# 步骤 5 / 5   启动容器
# ══════════════════════════════════════════════════════════════
step "5/5  启动 xiaozhi-esp32-server 容器"

cd "${DEPLOY_DIR}"

# 如果已有旧容器先停止（不删数据卷）
if docker ps -a --format '{{.Names}}' | grep -q "^xiaozhi-esp32-server$"; then
  warn "检测到已有容器，先停止旧容器..."
  $COMPOSE_CMD down
fi

# 拉取最新镜像
info "拉取最新镜像（ghcr.nju.edu.cn/xinnan-tech/xiaozhi-esp32-server:server_latest）..."
$COMPOSE_CMD pull
# 启动
info "启动容器..."
$COMPOSE_CMD up -d

# 等待服务初始化（首次加载 FunASR 模型需要约 30s）
echo ""
warn "等待服务初始化（首次加载 FunASR 模型约需 30 秒）..."
for i in $(seq 1 6); do
  sleep 5
  printf "    已等待 %ds...\r" $((i * 5))
done
echo ""

# ── 验证容器状态 ───────────────────────────────────────────────
if docker ps --format '{{.Names}}' | grep -q "^xiaozhi-esp32-server$"; then
  info "容器运行中"
  echo ""
  docker ps --filter "name=xiaozhi-esp32-server" \
            --format "    名称: {{.Names}}\n    状态: {{.Status}}\n    端口: {{.Ports}}"
else
  error "容器启动失败，最近日志："
  echo ""
  $COMPOSE_CMD logs --tail=40
  exit 1
fi

# ── 验证端口 ───────────────────────────────────────────────────
echo ""
info "验证端口..."

check_port() {
  local port=$1 name=$2
  if curl -sf --max-time 5 "http://localhost:${port}" &>/dev/null \
  || curl -sf --max-time 5 "http://localhost:${port}/xiaozhi/v1/ota/check" &>/dev/null \
  || nc -z localhost "${port}" 2>/dev/null; then
    info "${name} 端口 ${port} 正常"
  else
    warn "${name} 端口 ${port} 暂未响应（可能仍在加载，稍后可用 docker logs 查看）"
  fi
}

check_port 8000 "WebSocket"
check_port 8003 "HTTP/OTA"

# ══════════════════════════════════════════════════════════════
# 完成
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║               部署完成 ✔                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  ESP32 设备填写以下地址："
echo -e "    WebSocket:  ${CYAN}ws://${SERVER_IP}:8000/xiaozhi/v1/${NC}"
echo -e "    OTA:        ${CYAN}http://${SERVER_IP}:8003${NC}"
echo ""
echo "  CloudV3 后端地址（已在 .config.yaml 中配置）："
echo -e "    LLM 接口:   ${CYAN}http://${SERVER_IP}:8088/chat-api/v1/chat/completions${NC}"
echo ""
echo "  常用运维命令："
echo "    查看日志:    docker logs -f xiaozhi-esp32-server"
echo "    重启服务:    cd ${DEPLOY_DIR} && ${COMPOSE_CMD} restart"
echo "    停止服务:    cd ${DEPLOY_DIR} && ${COMPOSE_CMD} down"
echo "    升级镜像:    cd ${DEPLOY_DIR} && ${COMPOSE_CMD} pull && ${COMPOSE_CMD} up -d"
echo ""
echo "  验证 CloudV3 链路（可直接粘贴到终端执行）："
echo "    curl -N -X POST http://${SERVER_IP}:8088/chat-api/v1/chat/completions \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"model\":\"cloud-medical\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"user\":\"test-001\"}'"
echo ""
