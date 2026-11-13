#!/usr/bin/env bash
#
# LKM 统一开发服务器启动脚本
#
# 用法：
#   ./dev.sh          # 启动后端(LKM-service)
#   ./dev.sh back      # 仅启动后端
#   ./dev.sh --no-run  # 仅安装后端依赖，不启动服务
#   ./dev.sh back --no-run  # 仅安装后端依赖
#
set -euo pipefail

# 脚本所在目录（根目录）与各子项目路径
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT_DIR/LKM-service"

# 默认端口（都可覆盖：与既有服务撞端口时按需换）
BACKEND_PORT="${BACKEND_PORT:-8000}"

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

# 只装所选模式需要的依赖；未知参数不能悄悄启动全部服务。
MODE=back
MODE_SEEN=false
NO_RUN=false
for arg in "$@"; do
  case "$arg" in
    all|back|后端)
      if [ "$MODE_SEEN" = true ]; then
        error "只能指定一个启动模式。"
        exit 2
      fi
      MODE_SEEN=true
      case "$arg" in
        后端) MODE=back ;;
        *) MODE="$arg" ;;
      esac
      ;;
    --no-run) NO_RUN=true ;;
    *) error "未知参数: $arg（用法: ./dev.sh [all|back] [--no-run]）"; exit 2 ;;
  esac
done

require_cmd uv
if [ "$NO_RUN" = false ]; then
  validate_port BACKEND_PORT "$BACKEND_PORT"
fi

install_deps
if [ "$NO_RUN" = true ]; then
  log "依赖安装完成。"
  exit 0
fi

(cd "$BACKEND_DIR" && uv run python "$ROOT_DIR/scripts/check_dev_db.py")
log "准备业务库与认证库 schema..."
(cd "$BACKEND_DIR" && uv run python "$ROOT_DIR/scripts/prepare_dev_db.py")

# 每个服务独占进程组，退出时连 uv/python 等孙进程一起停止。
# 单服务模式也走同一套收尾逻辑，避免 Ctrl+C 后留下监听端口的子进程。
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

run_backend & pids+=("$!")

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
