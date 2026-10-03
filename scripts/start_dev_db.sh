#!/usr/bin/env bash
# Create/start an isolated local PostgreSQL instance for Linux/macOS development.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/.dev"
DATA_DIR="$LOCAL_DIR/postgres"
PASSWORD_FILE="$LOCAL_DIR/postgres.password"
ENV_FILE="$ROOT_DIR/LKM-service/.env"
PORT=15432

fail() {
  printf '[lkm:error] %s\n' "$*" >&2
  exit 1
}

command -v pg_config >/dev/null 2>&1 || fail '未找到 PostgreSQL 开发工具 pg_config。'
command -v openssl >/dev/null 2>&1 || fail '未找到 openssl。'
PG_BIN="$(pg_config --bindir)"
for tool in initdb pg_ctl psql createdb; do
  [ -x "$PG_BIN/$tool" ] || fail "未找到 $PG_BIN/$tool。"
done

umask 077
mkdir -p "$LOCAL_DIR"
if [ -f "$ENV_FILE" ]; then
  PYTHON="$ROOT_DIR/LKM-service/.venv/bin/python"
  [ -x "$PYTHON" ] || fail '未找到后端 Python 环境；请先运行 ./dev.sh back --no-run。'
  PORT="$(cd "$ROOT_DIR/LKM-service" && "$PYTHON" - "$PASSWORD_FILE" <<'PY'
import sys
from pathlib import Path

from core.config import settings
from core.secrets import reveal

if (
    settings.db_host not in {"localhost", "127.0.0.1"}
    or settings.auth_db_host not in {"localhost", "127.0.0.1"}
    or settings.db_port != settings.auth_db_port
    or settings.db_user != "postgres"
    or settings.auth_db_user != "postgres"
    or settings.db_name != "lkm"
    or settings.auth_db_name != "lkm_auth"
    or not reveal(settings.db_password)
    or reveal(settings.db_password) != reveal(settings.auth_db_password)
):
    sys.exit("[lkm:error] 已有 .env 的数据库配置不适合本地实例；请自行启动对应数据库。")

password_file = Path(sys.argv[1])
password = reveal(settings.db_password)
if password_file.exists():
    if password_file.read_text().strip() != password:
        sys.exit("[lkm:error] .env 的数据库密码与现有本地实例不一致。")
else:
    password_file.write_text(password + "\n")
    password_file.chmod(0o600)
print(settings.db_port)
PY
)" || exit 1
else
  if [ ! -e "$PASSWORD_FILE" ]; then
    openssl rand -hex 24 > "$PASSWORD_FILE"
  fi
fi

if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
  [ ! -e "$DATA_DIR" ] || fail "检测到不完整的数据目录: $DATA_DIR。请先检查。"
  "$PG_BIN/initdb" -D "$DATA_DIR" -U postgres --pwfile="$PASSWORD_FILE" \
    --auth-host=scram-sha-256 --auth-local=scram-sha-256 --no-instructions
fi

[ -f "$PASSWORD_FILE" ] || fail "找不到数据库密码文件: $PASSWORD_FILE。"
if ! "$PG_BIN/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1; then
  "$PG_BIN/pg_ctl" -D "$DATA_DIR" -l "$LOCAL_DIR/postgres.log" \
    -o "-h 127.0.0.1 -p $PORT -k $LOCAL_DIR" -w start
fi

export PGPASSWORD
PGPASSWORD="$(cat "$PASSWORD_FILE")"
for database in lkm lkm_auth; do
  if ! "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d "$database" \
    -Atqc 'SELECT 1' >/dev/null 2>&1; then
    "$PG_BIN/createdb" -h 127.0.0.1 -p "$PORT" -U postgres "$database"
  fi
done

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
# Managed by scripts/start_dev_db.sh
LKM_DB_HOST=127.0.0.1
LKM_DB_PORT=$PORT
LKM_DB_NAME=lkm
LKM_DB_USER=postgres
LKM_DB_PASSWORD=$PGPASSWORD
LKM_AUTH_DB_HOST=127.0.0.1
LKM_AUTH_DB_PORT=$PORT
LKM_AUTH_DB_NAME=lkm_auth
LKM_AUTH_DB_USER=postgres
LKM_AUTH_DB_PASSWORD=$PGPASSWORD
EOF
fi
printf '[lkm] 本地 PostgreSQL 已就绪: 127.0.0.1:%s (lkm, lkm_auth)\n' "$PORT"
