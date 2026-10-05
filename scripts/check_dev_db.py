"""Check the backend's configured PostgreSQL connection before local startup."""

import asyncio
import sys
from pathlib import Path

import asyncpg

BACKEND_DIR = Path(__file__).resolve().parents[1] / "LKM-service"
sys.path.insert(0, str(BACKEND_DIR))

from core.config import settings  # noqa: E402
from core.secrets import reveal  # noqa: E402


async def check_database() -> None:
    for host, port, database, user, password in (
        (
            settings.db_host,
            settings.db_port,
            settings.db_name,
            settings.db_user,
            settings.db_password,
        ),
        (
            settings.auth_db_host,
            settings.auth_db_port,
            settings.auth_db_name,
            settings.auth_db_user,
            settings.auth_db_password,
        ),
    ):
        connection = await asyncpg.connect(
            host=host,
            port=port,
            database=database,
            user=user,
            password=reveal(password),
            timeout=3,
        )
        try:
            await connection.execute("SELECT 1")
        finally:
            await connection.close()


def main() -> int:
    try:
        asyncio.run(check_database())
    except (OSError, asyncpg.PostgresError, TimeoutError) as exc:
        print(f"[lkm:error] PostgreSQL 业务库或认证库无法连接 ({type(exc).__name__})", file=sys.stderr)
        print(
            "[lkm:error] 请启动 PostgreSQL，并核对 LKM-service/.env 中的 "
            "LKM_DB_* 与 LKM_AUTH_DB_*。Linux/macOS 可运行 "
            "./scripts/start_dev_db.sh，详见 DEVELOPMENT.md。",
            file=sys.stderr,
        )
        return 1
    print("[lkm] PostgreSQL 业务库与认证库均可连接")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
