#!/usr/bin/env bash
#
# LKM 统一开发服务器启动脚本
#
# 用法：
#   ./dev.sh            # 启动 AUTH(:8001)、业务后端(:8000) 与桌面端(flutter run)
#   ./dev.sh all        # 同上
#   ./dev.sh back       # 只启动 AUTH 与业务后端
#   ./dev.sh desktop    # 只启动桌面端（桌面/桌面端）
#   ./dev.sh --no-run   # 只安装依赖，不启动服务
#   ./dev.sh back --no-run  # 只安装后端依赖
#   ./dev.sh desktop --no-run  # 只安装桌面端依赖
#
set -euo pipefail

# 脚本所在目录（根目录）与各子项目路径
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT_DIR/LKM-service"
DESKTOP_DIR="$ROOT_DIR/LKM-desktop"

# 默认端口（都可覆盖：与既有服务撞端口时按需换）
BACKEND_PORT="${BACKEND_PORT:-8000}"

# 双形态退役后认证只由独立 AUTH 进程提供：本地开发同时起 auth（固定 8001，见 auth/main.py）
# 并通过内部缝地址/令牌把 backend 指过去。
export LKM_AUTH_HTTP_URL="${LKM_AUTH_HTTP_URL:-http://127.0.0.1:8001}"
export LKM_AUTH_HTTP_TOKEN="${LKM_AUTH_HTTP_TOKEN:-dev-internal-auth-token-change-me-32chars}"

log() {
  echo -e "\033[1;36m[lkm]\033[0m $*"
}

error() {
  echo -e "\033[1;31m[lkm:error]\033[0m $*" >&2
}

# 检查命令是否存在
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "未找到命令 '$cmd'，请先安装。"
    exit 1
  fi
}

validate_port() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]{1,5}$ ]] || (( 10#$value < 1 || 10#$value > 65535 )); then
    error "$name 必须是 1–65535 之间的端口号（当前: $value）。"
    exit 2
  fi
}

install_deps() {
  if [ ! -f "$BACKEND_DIR/pyproject.toml" ]; then
    error "未找到 $BACKEND_DIR/pyproject.toml（子模块未初始化？）。"
    return 1
  fi
  log "安装后端依赖 (uv sync)..."
  (cd "$BACKEND_DIR" && uv sync)
}

run_backend() {
  if [ ! -d "$BACKEND_DIR" ]; then
    error "目录不存在: $BACKEND_DIR（子模块未初始化？）"
    return 1
  fi
  log "启动后端: uvicorn main:app --reload --port $BACKEND_PORT"
  (cd "$BACKEND_DIR" && uv run uvicorn main:app --reload --port "$BACKEND_PORT")
}

run_auth() {
  log "启动 AUTH 进程: python -m auth.main (8001)"
  (cd "$BACKEND_DIR" && uv run python -m auth.main)
}

# 桌面端设备：按当前平台选，可用 DESKTOP_DEVICE 覆盖。
desktop_device() {
  if [ -n "${DESKTOP_DEVICE:-}" ]; then
    echo "$DESKTOP_DEVICE"
    return
  fi
  case "$(uname -s)" in
    Darwin*) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo linux ;;
  esac
}

install_desktop_deps() {
  if [ ! -f "$DESKTOP_DIR/pubspec.yaml" ]; then
    error "未找到 $DESKTOP_DIR/pubspec.yaml（子模块未初始化？）。"
    return 1
  fi
  log "安装桌面端依赖 (flutter pub get)..."
  (cd "$DESKTOP_DIR" && flutter pub get)
  log "安装 webf 依赖 (pnpm install)..."
  (cd "$DESKTOP_DIR" && pnpm --dir webf install --frozen-lockfile --ignore-scripts)
}

# assets/webf/ 是生成物、不进 git，启动前必须重建，否则客户端缺少小程序资源。
build_webf() {
  log "构建 webf 资源 (pnpm --dir webf build)..."
  (cd "$DESKTOP_DIR" && pnpm --dir webf build)
}

run_desktop() {
  if [ ! -d "$DESKTOP_DIR" ]; then
    error "目录不存在: $DESKTOP_DIR（子模块未初始化？）"
    return 1
  fi
  local device
  device="$(desktop_device)"
  log "启动桌面端: flutter run -d $device"
  # stdin 接 /dev/null：后台进程组读终端会被 SIGTTIN 挂起且无法交互；
  # 需要热重载等交互键时请单独在 LKM-desktop 下运行 flutter run。
  (cd "$DESKTOP_DIR" && flutter run -d "$device" </dev/null)
}

# 缺失的开发密钥自动补齐；已有环境变量/.env 配置时不改动。
prepare_dev_secrets() {
  local output
  log "准备开发密钥（缺失时自动生成）..."
  if ! output="$(cd "$BACKEND_DIR" && uv run python "$ROOT_DIR/scripts/prepare_dev_secrets.py" --shell)"; then
    error "生成开发密钥失败。"
    exit 1
  fi
  [ -z "$output" ] || eval "$output"
}

# 未知参数不能悄悄启动服务。双形态退役后 auth 是后端的硬依赖；
# 无参默认 all = 后端（AUTH + backend）+ 桌面端。
MODE="all"
MODE_SEEN=false
NO_RUN=false
for arg in "$@"; do
  case "$arg" in
    all|back|desktop|后端|桌面|桌面端)
      if [ "$MODE_SEEN" = true ]; then
        error "只能指定一个启动模式。"
        exit 2
      fi
      MODE_SEEN=true
      case "$arg" in
        back|后端) MODE="back" ;;
        desktop|桌面|桌面端) MODE="desktop" ;;
        *) MODE="all" ;;
      esac
      ;;
    --no-run) NO_RUN=true ;;
    *) error "未知参数: $arg（用法: ./dev.sh [all|back|desktop] [--no-run]）"; exit 2 ;;
  esac
done

if [ "$MODE" != "desktop" ]; then
  require_cmd uv
  if [ "$NO_RUN" = false ]; then
    validate_port BACKEND_PORT "$BACKEND_PORT"
  fi
fi
if [ "$MODE" != "back" ]; then
  require_cmd flutter
  require_cmd node
  require_cmd pnpm
fi

if [ "$MODE" != "desktop" ]; then install_deps; fi
if [ "$MODE" != "back" ]; then install_desktop_deps; fi
if [ "$NO_RUN" = true ]; then
  log "依赖安装完成。"
  exit 0
fi

if [ "$MODE" != "desktop" ]; then
  (cd "$BACKEND_DIR" && uv run python "$ROOT_DIR/scripts/check_dev_db.py")
  log "准备业务库与认证库 schema..."
  (cd "$BACKEND_DIR" && uv run python "$ROOT_DIR/scripts/prepare_dev_db.py")
  prepare_dev_secrets
fi

# 每个服务独占进程组，退出时连 uv/python 等孙进程一起停止，
# 避免 Ctrl+C 后留下监听端口的子进程。
set -m
pids=()
cleanup() {
  trap - HUP INT TERM EXIT
  if (( ${#pids[@]} == 0 )); then return; fi
  log "收到退出信号，正在停止..."
  for p in "${pids[@]}"; do
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
  done
  for p in "${pids[@]}"; do
    wait "$p" 2>/dev/null || true
  done
  # uv 可能先退出，实际监听端口的孙进程仍在收尾；等进程组清空再退出。
  for _ in {1..50}; do
    local active=false
    for p in "${pids[@]}"; do
      if kill -0 -- "-$p" 2>/dev/null; then active=true; fi
    done
    if [ "$active" = false ]; then return; fi
    sleep 0.1
  done
  for p in "${pids[@]}"; do
    kill -KILL -- "-$p" 2>/dev/null || true
  done
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap cleanup EXIT

if [ "$MODE" != "desktop" ]; then
  run_auth & pids+=("$!")
  run_backend & pids+=("$!")
fi
if [ "$MODE" != "back" ]; then
  build_webf
  run_desktop & pids+=("$!")
fi

# 无参 wait 永远返回 0；轮询首个退出者并保留其退出码。
# macOS 自带 Bash 3.2 不支持 wait -n。
status=0
while :; do
  for p in "${pids[@]}"; do
    if ! kill -0 "$p" 2>/dev/null; then
      wait "$p" || status=$?
      break 2
    fi
  done
  sleep 1
done
exit "$status"
