"""Prepare both local database schemas before starting development servers."""

import asyncio
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1] / "LKM-service"
sys.path.insert(0, str(BACKEND_DIR))

from auth.db.init import init_auth_db  # noqa: E402
from auth.db.session import dispose_auth_engine  # noqa: E402
from boot.assemble import assemble  # noqa: E402
from core.config import settings  # noqa: E402
from core.db.init_db import init_db  # noqa: E402
from core.db.session import dispose_engine  # noqa: E402


async def prepare() -> None:
    if settings.env not in {"dev", "local", "test"}:
        raise RuntimeError("仅允许为本地开发环境准备数据库 schema")

    assemble()
    try:
        await init_db()
        await init_auth_db()
    finally:
        await dispose_engine()
        await dispose_auth_engine()


if __name__ == "__main__":
    asyncio.run(prepare())
    print("[lkm] 业务库与认证库 schema 已就绪")
