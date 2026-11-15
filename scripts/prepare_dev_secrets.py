"""补齐本地开发所需的密钥；已有配置一律不改动。

用法（在 LKM-service 下经 uv 运行，cryptography 由后端依赖提供）：

    uv run python scripts/prepare_dev_secrets.py --shell   # 输出 export 行供 eval
    uv run python scripts/prepare_dev_secrets.py --json    # 输出 JSON 供 dev.ps1 解析

来源优先级与原 dev.ps1 一致：进程环境变量或 ``LKM-service/.env`` 里的非空值即视为
已配置，本脚本只为缺失项生成值。JWT 密钥对写到 ``deploy/jwt/keys/``（绝对路径）。
stdout 只留机器可读输出，日志一律走 stderr。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shlex
import string
import sys
from pathlib import Path
from typing import Mapping

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / "LKM-service" / ".env"
KEY_DIR = ROOT / "deploy" / "jwt" / "keys"
PRIVATE_KEY_FILE = KEY_DIR / "jwt-private.pem"
PUBLIC_KEY_FILE = KEY_DIR / "jwt-public.pem"

# 任一 JWT 配置已存在就认为签发/验签密钥已由用户安排，不再生成文件。
JWT_KEYS = (
    "LKM_JWT_PRIVATE_KEY_FILE",
    "LKM_JWT_PUBLIC_KEY_FILE",
    "LKM_JWT_PRIVATE_KEY",
    "LKM_JWT_PUBLIC_KEY",
)
SECRET_KEYS = ("LKM_TOTP_ENCRYPTION_KEY", "LKM_VERIFICATION_CODE_PEPPER")
ALPHABET = string.ascii_letters + string.digits


def log(message: str) -> None:
    print(f"[lkm] {message}", file=sys.stderr)


def _env_file_has_key(env_file: Path, key: str) -> bool:
    """``.env`` 里存在未被注释的 ``KEY=非空值`` 行。"""
    if not env_file.exists():
        return False
    pattern = re.compile(
        rf"^\s*(?:export\s+)?{re.escape(key)}\s*=\s*\S", re.MULTILINE
    )
    text = env_file.read_text(encoding="utf-8", errors="ignore")
    return bool(pattern.search(text))


def _provided(key: str, env_file: Path, env: Mapping[str, str]) -> bool:
    return bool(env.get(key, "").strip()) or _env_file_has_key(env_file, key)


def _random_secret(length: int = 64) -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(length))


def _generate_keypair(private_file: Path, public_file: Path) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    public_pem = key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    private_file.parent.mkdir(parents=True, exist_ok=True)
    try:
        private_file.write_bytes(private_pem)
        private_file.chmod(0o600)
        public_file.write_bytes(public_pem)
    except OSError:
        private_file.unlink(missing_ok=True)
        public_file.unlink(missing_ok=True)
        raise


def collect(
    *,
    env_file: Path = ENV_FILE,
    key_dir: Path = KEY_DIR,
    env: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """返回需要注入的 ``KEY=value``；已有配置时不返回对应项。"""
    env = os.environ if env is None else env
    values: dict[str, str] = {}

    if not any(_provided(key, env_file, env) for key in JWT_KEYS):
        private_file = key_dir / PRIVATE_KEY_FILE.name
        public_file = key_dir / PUBLIC_KEY_FILE.name
        has_private = private_file.exists()
        has_public = public_file.exists()
        if has_private != has_public:
            raise RuntimeError(
                f"开发密钥对只存在一半: {key_dir}。请检查后再重新生成，避免误轮换。"
            )
        if not has_private:
            log("已为开发环境生成 RS256 密钥对 (deploy/jwt/keys)。")
            _generate_keypair(private_file, public_file)
        values["LKM_JWT_PRIVATE_KEY_FILE"] = str(private_file)
        values["LKM_JWT_PUBLIC_KEY_FILE"] = str(public_file)

    for key in SECRET_KEYS:
        if not _provided(key, env_file, env):
            values[key] = _random_secret()
            log(f"已为开发环境生成 {key}。")

    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--shell", action="store_true", help="输出 export 行")
    group.add_argument("--json", action="store_true", help="输出 JSON 对象")
    args = parser.parse_args()

    try:
        values = collect()
    except RuntimeError as exc:
        print(f"[lkm:error] {exc}", file=sys.stderr)
        return 1

    if args.json:
        json.dump(values, sys.stdout, ensure_ascii=False)
    else:
        for key, value in values.items():
            print(f"export {key}={shlex.quote(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
