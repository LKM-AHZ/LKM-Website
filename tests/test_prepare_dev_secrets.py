"""Run with: python3 tests/test_prepare_dev_secrets.py"""

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "prepare_dev_secrets", ROOT / "scripts" / "prepare_dev_secrets.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fake_keypair(private_file, public_file):
    private_file.parent.mkdir(parents=True, exist_ok=True)
    private_file.write_text("private")
    public_file.write_text("public")


def main():
    original = module._generate_keypair
    module._generate_keypair = fake_keypair
    try:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            env_file = temp / ".env"
            key_dir = temp / "keys"

            # 全新环境：补齐密钥对与两个对称密钥
            values = module.collect(env_file=env_file, key_dir=key_dir, env={})
            assert values["LKM_JWT_PRIVATE_KEY_FILE"] == str(key_dir / "jwt-private.pem")
            assert values["LKM_JWT_PUBLIC_KEY_FILE"] == str(key_dir / "jwt-public.pem")
            assert (key_dir / "jwt-private.pem").read_text() == "private"
            for key in ("LKM_TOTP_ENCRYPTION_KEY", "LKM_VERIFICATION_CODE_PEPPER"):
                assert len(values[key]) == 64
                assert values[key].isalnum()
            assert (
                values["LKM_TOTP_ENCRYPTION_KEY"]
                != values["LKM_VERIFICATION_CODE_PEPPER"]
            )

            # 密钥对已在磁盘上：复用，不重复生成
            again = module.collect(env_file=env_file, key_dir=key_dir, env={})
            assert again["LKM_JWT_PRIVATE_KEY_FILE"] == values["LKM_JWT_PRIVATE_KEY_FILE"]

            # .env / 进程环境已有非空值：跳过；空值仍视为缺失
            env_file.write_text(
                "LKM_TOTP_ENCRYPTION_KEY=from-file\n"
                "LKM_VERIFICATION_CODE_PEPPER=\n"
            )
            provided = module.collect(
                env_file=env_file,
                key_dir=key_dir,
                env={"LKM_JWT_PRIVATE_KEY_FILE": "inline"},
            )
            assert set(provided) == {"LKM_VERIFICATION_CODE_PEPPER"}

            # 密钥对只存在一半：报错而不是静默轮换
            half = temp / "half"
            half.mkdir()
            (half / "jwt-private.pem").write_text("x")
            try:
                module.collect(env_file=env_file, key_dir=half, env={})
            except RuntimeError as exc:
                assert "只存在一半" in str(exc)
            else:
                raise AssertionError("只存在一半的密钥对应报错")
    finally:
        module._generate_keypair = original

    print("prepare_dev_secrets: ok")


if __name__ == "__main__":
    main()
