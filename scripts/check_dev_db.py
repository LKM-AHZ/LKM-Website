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
    connection = await asyncpg.connect(
        host=settings.db_host,
        port=settings.db_port,
        database=settings.db_name,
        user=settings.db_user,
        password=reveal(settings.db_password),
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
        target = f"{settings.db_host}:{settings.db_port}/{settings.db_name}"
        print(f"[lkm:error] PostgreSQL 无法连接: {target} ({type(exc).__name__})", file=sys.stderr)
        print(
            "[lkm:error] 请启动 PostgreSQL，并核对 LKM-service/.env 中的 "
            "LKM_DB_HOST/PORT/NAME/USER/PASSWORD。Linux/macOS 可运行 "
            "./scripts/start_dev_db.sh，详见 DEVELOPMENT.md。",
            file=sys.stderr,
        )
        return 1
    print(f"[lkm] PostgreSQL 已就绪: {settings.db_host}:{settings.db_port}/{settings.db_name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
