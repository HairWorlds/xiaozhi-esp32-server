#!/bin/bash
# 部署脚本
#
# 用法：
#   ./deploy.sh              拉取上游镜像，core/ 通过 volume 挂载（快速，适合首次部署）
#   ./deploy.sh --build      本地打包镜像，code 烧进镜像（代码改动后完整打包）
#   ./deploy.sh --restart    仅重启容器（scp 完代码后快速重载，秒级生效）
#
# 上传文件到服务器（在本机 Mac 执行）：
#   scp -r .\xiaozhi-server\* root@117.162.7.154:/opt/xiaozhi-esp32-server

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
LOCAL_IMAGE="xiaozhi-esp32-server:local"
UPSTREAM_IMAGE="ghcr.nju.edu.cn/xinnan-tech/xiaozhi-esp32-server:server_latest"

info()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; }
step()  { echo -e "\n${CYAN}▶ $1${NC}"; echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"; }

banner() {
  echo -e "${BLUE}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║    xiaozhi-esp32-server  部署脚本            ║"
  echo "  ║    服务器：${SERVER_IP}                   ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ── 参数解析 ──────────────────────────────────────────────────
MODE="pull"
for arg in "$@"; do
  case "$arg" in
    --build|-b)   MODE="build"   ;;
    --restart|-r) MODE="restart" ;;
    --pull|-p)    MODE="pull"    ;;
    --help|-h)
      echo "用法: $0 [选项]"
      echo ""
      echo "  (无参数)         拉取上游镜像，core/ 通过 volume 挂载（默认）"
      echo "  --build,  -b     本地打包 Docker 镜像，代码烧录进镜像"
      echo "  --restart,-r     仅重启容器（scp 后快速重载代码，无需重新打包）"
      echo "  --pull,   -p     显式指定拉取上游镜像模式"
      echo ""
      exit 0 ;;
    *)
      error "未知参数: $arg"; echo "使用 --help 查看帮助"; exit 1 ;;
  esac
done

banner

# ══════════════════════════════════════════════════════════════
# --restart 快速模式：仅重启容器
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "restart" ]; then
  step "快速重启  （scp 后重载代码）"

  if ! docker ps -a --format '{{.Names}}' | grep -q "^xiaozhi-esp32-server$"; then
    error "容器 xiaozhi-esp32-server 不存在，请先执行完整部署"
    exit 1
  fi

  docker restart xiaozhi-esp32-server
  info "容器已重启"

  sleep 3
  if docker ps --format '{{.Names}}' | grep -q "^xiaozhi-esp32-server$"; then
    info "容器运行中"
    docker ps --filter "name=xiaozhi-esp32-server" \
              --format "    名称: {{.Names}}\n    状态: {{.Status}}\n    端口: {{.Ports}}"
  else
    error "容器重启失败，查看日志："
    docker logs --tail=30 xiaozhi-esp32-server
    exit 1
  fi
  echo ""
  echo "  查看日志: docker logs -f xiaozhi-esp32-server"
  echo ""
  exit 0
fi

# ══════════════════════════════════════════════════════════════
# 步骤 1   检查运行环境
# ══════════════════════════════════════════════════════════════
step "1/5  检查运行环境"

if ! command -v docker &>/dev/null; then
  error "Docker 未安装"
  echo "    curl -fsSL https://get.docker.com | sh && systemctl enable --now docker"
  exit 1
fi
info "Docker 已安装：$(docker --version)"

if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  info "Docker Compose plugin：$(docker compose version)"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
  info "Docker Compose standalone：$(docker-compose --version)"
else
  error "Docker Compose 未安装"
  echo "    apt-get install -y docker-compose-plugin"
  exit 1
fi

if command -v python3 &>/dev/null; then
  info "Python3 已安装：$(python3 --version)"
else
  warn "Python3 未安装，若模型文件不存在将无法自动下载"
fi

# ══════════════════════════════════════════════════════════════
# 步骤 2   创建目录结构
# ══════════════════════════════════════════════════════════════
step "2/5  创建目录结构"

mkdir -p "${DEPLOY_DIR}/data"
mkdir -p "${DEPLOY_DIR}/models/SenseVoiceSmall"
mkdir -p "${DEPLOY_DIR}/tmp"
mkdir -p "${DEPLOY_DIR}/music"

info "目录结构已就绪"
echo "    ${DEPLOY_DIR}/"
echo "    ├── data/    ← 配置文件（挂载进容器）"
echo "    ├── models/  ← FunASR 模型文件（挂载进容器）"
echo "    ├── core/    ← Python 源码（--build 时烧录进镜像，默认时挂载）"
echo "    └── tmp/     ← 运行时临时文件"

# ══════════════════════════════════════════════════════════════
# 步骤 3   检查配置文件
# ══════════════════════════════════════════════════════════════
step "3/5  检查配置文件"

CONFIG_FILE="${DEPLOY_DIR}/data/.config.yaml"

if [ -f "${CONFIG_FILE}" ]; then
  info "data/.config.yaml 已存在，配置摘要："
  echo ""
  grep -E "^\s*(base_url|model_name|voice:|LLM:|TTS:|Memory:|Intent:|websocket)" \
       "${CONFIG_FILE}" 2>/dev/null | head -15 | sed 's/^/    /'
  echo ""
else
  warn "data/.config.yaml 不存在，将使用默认 config.yaml 运行"
fi

# ══════════════════════════════════════════════════════════════
# 步骤 4   准备 FunASR 模型
# ══════════════════════════════════════════════════════════════
step "4/5  准备 FunASR 语音识别模型（SenseVoiceSmall，约 600MB）"

MODEL_FILE="${DEPLOY_DIR}/models/SenseVoiceSmall/model.pt"

if [ -f "${MODEL_FILE}" ]; then
  info "模型文件已存在，跳过下载"
  echo "    路径：${MODEL_FILE}  大小：$(du -sh "${MODEL_FILE}" | cut -f1)"
else
  warn "模型文件不存在，开始自动下载..."

  if ! command -v python3 &>/dev/null; then
    error "python3 未安装，无法自动下载模型"
    echo "    pip3 install modelscope"
    echo "    python3 -c \"from modelscope import snapshot_download; snapshot_download('iic/SenseVoiceSmall', local_dir='${DEPLOY_DIR}/models/SenseVoiceSmall')\""
    exit 1
  fi

  SUDO=""
  [ "$(id -u)" != "0" ] && SUDO="sudo"

  if ! python3 -c "import venv, ensurepip" &>/dev/null 2>&1; then
    info "安装 python3-venv..."
    PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    $SUDO apt-get update -q \
      && { $SUDO apt-get install -y "python${PYVER}-venv" -q 2>/dev/null \
           || $SUDO apt-get install -y python3-venv -q; }
    if ! python3 -c "import venv, ensurepip" &>/dev/null 2>&1; then
      error "python3-venv 安装失败"
      exit 1
    fi
  fi

  VENV_DIR="${DEPLOY_DIR}/.venv-modelscope"
  VENV_PY="${VENV_DIR}/bin/python3"
  if [ -d "${VENV_DIR}" ] && ! "${VENV_PY}" -m pip --version &>/dev/null 2>&1; then
    rm -rf "${VENV_DIR}"
  fi
  [ ! -d "${VENV_DIR}" ] && python3 -m venv "${VENV_DIR}"
  "${VENV_PY}" -c "import modelscope" &>/dev/null 2>&1 \
    || "${VENV_PY}" -m pip install modelscope -q

  info "开始下载模型..."
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

  [ -f "${MODEL_FILE}" ] && info "模型下载成功" || { error "模型文件不存在，请检查网络"; exit 1; }
fi

# ══════════════════════════════════════════════════════════════
# 步骤 5   启动容器
# ══════════════════════════════════════════════════════════════
step "5/5  启动 xiaozhi-esp32-server 容器  [模式: ${MODE}]"

cd "${DEPLOY_DIR}"

# 停止旧容器
if docker ps -a --format '{{.Names}}' | grep -q "^xiaozhi-esp32-server$"; then
  warn "检测到已有容器，先停止..."
  $COMPOSE_CMD down 2>/dev/null || docker rm -f xiaozhi-esp32-server 2>/dev/null || true
fi

# ── build 模式：本地打包 ───────────────────────────────────────
if [ "$MODE" = "build" ]; then

  if [ ! -f "${DEPLOY_DIR}/Dockerfile" ]; then
    error "找不到 Dockerfile（${DEPLOY_DIR}/Dockerfile）"
    exit 1
  fi

  info "拉取上游基础镜像（确保 base 层最新）..."
  docker pull "${UPSTREAM_IMAGE}"

  info "本地打包镜像 ${LOCAL_IMAGE} ..."
  docker build \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    -t "${LOCAL_IMAGE}" \
    "${DEPLOY_DIR}"

  info "打包完成：$(docker images "${LOCAL_IMAGE}" --format '{{.Repository}}:{{.Tag}}  {{.Size}}  {{.CreatedSince}}')"

  COMPOSE_FILE="docker-compose.local.yml"
  if [ ! -f "${DEPLOY_DIR}/${COMPOSE_FILE}" ]; then
    error "找不到 ${COMPOSE_FILE}"
    exit 1
  fi

  info "启动容器（使用本地镜像）..."
  $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d

# ── pull 模式：上游镜像 + volume 挂载 ──────────────────────────
else

  info "拉取最新镜像（${UPSTREAM_IMAGE}）..."
  $COMPOSE_CMD pull

  info "启动容器（core/ 通过 volume 挂载）..."
  $COMPOSE_CMD up -d

fi

# ── 等待初始化 ─────────────────────────────────────────────────
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
  $COMPOSE_CMD logs --tail=40
  exit 1
fi

# ── 验证端口 ───────────────────────────────────────────────────
echo ""
info "验证端口..."
check_port() {
  local port=$1 name=$2
  if curl -sf --max-time 5 "http://localhost:${port}" &>/dev/null \
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
echo -e "${GREEN}║               部署完成 ✔  [${MODE}]$(printf '%-14s' '')║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  ESP32 设备填写以下地址："
echo -e "    WebSocket:  ${CYAN}ws://${SERVER_IP}:8000/xiaozhi/v1/${NC}"
echo -e "    OTA:        ${CYAN}http://${SERVER_IP}:8003${NC}"
echo ""
echo "  常用运维命令："
echo "    查看日志:    docker logs -f xiaozhi-esp32-server"
echo "    快速重载:    bash ${DEPLOY_DIR}/deploy.sh --restart"
echo "    重新打包:    bash ${DEPLOY_DIR}/deploy.sh --build"
echo "    停止服务:    cd ${DEPLOY_DIR} && ${COMPOSE_CMD} down"
echo ""
