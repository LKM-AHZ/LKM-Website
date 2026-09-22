#!/usr/bin/env bash
#
# LKM 统一开发服务器启动脚本
#
# 用法：
#   ./dev.sh          # 同时启动 SSR 前端(LKM-official-website)+静态官网(LKM-official-static)+后端(LKM-service)
#   ./dev.sh front     # 仅启动 SSR 前端
#   ./dev.sh site      # 仅启动静态官网(LKM-official-static)
#   ./dev.sh back      # 仅启动后端
#   ./dev.sh --no-run  # 仅安装依赖，不启动服务
#
# 环境变量：
#   LKM_API_KEY 前端里通过 API_URL 指向后端，默认关闭后端请求。
#   如需让前端连上本脚本启动的后端，可在运行前设置：export API_URL=http://localhost:8000
#   SITE_PORT 静态官网端口(默认 4322)，避免与 SSR 前端 4321 冲突
#
set -euo pipefail

# 脚本所在目录（根目录）与各子项目路径
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$ROOT_DIR/LKM-official-website"
BACKEND_DIR="$ROOT_DIR/LKM-service"
SITE_DIR="$ROOT_DIR/LKM-official-static"

# 默认端口（都可覆盖：两站同时起、或与既有服务撞端口时按需换）
BACKEND_PORT="${BACKEND_PORT:-8000}"
SITE_PORT="${SITE_PORT:-4322}"
FRONT_PORT="${FRONT_PORT:-4321}"

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

install_deps() {
  # $1: all | front | site | back —— 只装所选 MODE 需要的依赖
  local targets="$1"

  # 前端依赖（pnpm）
  case "$targets" in
    all|front)
      if [ -f "$FRONTEND_DIR/package.json" ]; then
        log "安装前端依赖 (pnpm install)..."
        (cd "$FRONTEND_DIR" && pnpm install)
      else
        error "未找到 $FRONTEND_DIR/package.json（子模块未初始化？），无法安装依赖。"
        return 1
      fi
      ;;
  esac

  # 后端依赖（uv）
  case "$targets" in
    all|back)
      if [ -f "$BACKEND_DIR/pyproject.toml" ]; then
        log "安装后端依赖 (uv sync)..."
        (cd "$BACKEND_DIR" && uv sync)
      else
        error "未找到 $BACKEND_DIR/pyproject.toml（子模块未初始化？），无法安装依赖。"
        return 1
      fi
      ;;
  esac

  # 静态官网依赖（pnpm）
  case "$targets" in
    all|site)
      if [ -f "$SITE_DIR/package.json" ]; then
        log "安装静态官网依赖 (pnpm install)..."
        (cd "$SITE_DIR" && pnpm install)
      else
        error "未找到 $SITE_DIR/package.json（子模块未初始化？），无法安装依赖。"
        return 1
      fi
      ;;
  esac
}

run_frontend() {
  # 先查目录：子模块没初始化时 `cd` 的报错发生在子 shell 里，位置靠后且信息少
  if [ ! -d "$FRONTEND_DIR" ]; then
    error "目录不存在: $FRONTEND_DIR（子模块未初始化？）"
    return 1
  fi
  log "启动 SSR 前端: pnpm run dev --port $FRONT_PORT"
  (cd "$FRONTEND_DIR" && pnpm run dev --port "$FRONT_PORT")
}

run_static_site() {
  if [ ! -d "$SITE_DIR" ]; then
    error "目录不存在: $SITE_DIR（子模块未初始化？）"
    return 1
  fi
  log "启动静态官网: pnpm run dev --port $SITE_PORT"
  (cd "$SITE_DIR" && pnpm run dev --port "$SITE_PORT")
}

run_backend() {
  if [ ! -d "$BACKEND_DIR" ]; then
    error "目录不存在: $BACKEND_DIR（子模块未初始化？）"
    return 1
  fi
  log "启动后端: uvicorn main:app --reload --port $BACKEND_PORT"
  (cd "$BACKEND_DIR" && uv run uvicorn main:app --reload --port "$BACKEND_PORT")
}

# 仅安装依赖时
case "${1:-}" in
  --no-run)
    require_cmd pnpm
    require_cmd uv
    install_deps all
    log "依赖安装完成。"
    exit 0
    ;;
esac

# 只装所选 MODE 需要的依赖（`./dev.sh front` 不该顺带跑 uv sync 与静态官网的 pnpm install）。
# uv sync / pnpm install 自身是增量的，已同步时几乎不耗时。
MODE="${1:-all}"
case "$MODE" in
  front|前端)           INSTALL_TARGETS=front ;;
  site|static|静态官网) INSTALL_TARGETS=site ;;
  back|后端)            INSTALL_TARGETS=back ;;
  *)                    INSTALL_TARGETS=all ;;
esac

require_cmd pnpm
# uv 只在真要跑后端时才要求：front/site 模式不启后端，不该因本机没装 Python 工具链而中止
case "$INSTALL_TARGETS" in
  all|back) require_cmd uv ;;
esac

install_deps "$INSTALL_TARGETS"

case "$MODE" in
  front|前端)
    log "SSR 前端（仅）"
    run_frontend
    ;;
  site|static|静态官网)
    log "静态官网（仅）"
    run_static_site
    ;;
  back|后端)
    log "后端（仅）"
    run_backend
    ;;
  all|*)
    log "同时启动 SSR 前端、静态官网与后端（Ctrl+C 可同时停止）"
    # 开作业控制：每个后台服务独占一个进程组，收尾时按进程组 kill 才能连 pnpm/node、
    # uv/python 这些孙进程一起带走。不用 `kill 0`——它连本脚本（乃至未开作业控制时的
    # 父 shell）一起杀，且绑在 EXIT trap 上会在正常结束时自我触发、递归。
    set -m
    pids=""
    cleanup() {
      trap - INT TERM EXIT
      echo
      log "收到退出信号，正在停止..."
      for p in $pids; do
        kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
      done
    }
    trap cleanup INT TERM EXIT
    run_frontend &
    pids="$pids $!"
    run_static_site &
    pids="$pids $!"
    run_backend &
    pids="$pids $!"
    # 无参 wait 永远返回 0：任一服务启动失败都会被当成功吞掉。改成轮询等待首个退出者，
    # 取它的退出码（不用 `wait -n`——bash 4.3+ 才有，macOS 自带 3.2 会报错）。
    status=0
    while :; do
      for p in $pids; do
        if ! kill -0 "$p" 2>/dev/null; then
          wait "$p" || status=$?
          break 2
        fi
      done
      sleep 1
    done
    cleanup
    exit "$status"
    ;;
esac
