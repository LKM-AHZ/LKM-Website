#!/usr/bin/env python3
"""备份 / 恢复一条龙 —— 把 OPS-CHEATSHEET.md 里三条手敲命令合成一条，并加产物校验。

覆盖三处持久化状态：

* **PostgreSQL**：`pg_dump` 逻辑备份（业务库 + auth 库同实例，一次导出）。
* **MinIO 对象**：`mc mirror --preserve m/<bucket>`（文件库 + 成员头像），
  先镜像到 minio 容器内 `/tmp` 再 `docker cp` 出来（exec 无法新增挂载，这是可靠路径）。
* **backend 命名卷**：`tar czf`（含 blog_repos 等）。

之所以强调「一条龙」：cheatsheet 的三条命令最容易漏掉 MinIO——而文件全部在对象存储里，
只备份数据库等于丢文件。

用法：
    python3 tools/backup.py backup                  # 产出到 ./backups/<日期>/
    python3 tools/backup.py backup --out /mnt/bak    # 指定输出根目录
    python3 tools/backup.py list                     # 列出已有备份
    python3 tools/backup.py restore --from backups/2026-09-19 --only db --yes
"""

from __future__ import annotations

import argparse
import datetime
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "backups"


def compose(*args: str, timeout: int = 900) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def project_name() -> str:
    """compose 项目名，用于拼命名卷 `${project}_backend_data`。

    取不到时回退目录名（大写/带点的目录、或 .env 里设了 COMPOSE_PROJECT_NAME 都会不一致），
    所以回退必须留痕：否则备份/恢复会对着一个不存在的卷干活，恢复还会「成功」地写进空卷。
    """
    try:
        proc = compose("config", "--format", "json", timeout=60)
        data = json.loads(proc.stdout)
        if data.get("name"):
            return str(data["name"])
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        print(f"警告：无法解析 compose 项目名（{exc}），回退为目录名", file=sys.stderr)
        return REPO_ROOT.name.lower().replace(".", "")
    print("警告：compose config 未返回 name，回退为目录名", file=sys.stderr)
    return REPO_ROOT.name.lower().replace(".", "")


def env_value(key: str, default: str) -> str:
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        return default
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        # 兼容 `export KEY=value`（常见 .env 写法）
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        # 原先还带了 `not line.startswith("#")`：一旦以 `KEY=` 开头就不可能以 `#` 开头，是死条件
        if line.startswith(f"{key}="):
            return line.partition("=")[2].strip().strip("'\"") or default
    return default


def container_id(service: str) -> str | None:
    try:
        proc = compose("ps", "-q", service, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    cid = (proc.stdout or "").strip().splitlines()
    return cid[0] if cid else None


# ── 备份 ────────────────────────────────────────────────────────────────────


def backup_db(target: Path, pg_user: str, pg_db: str) -> bool:
    print(f"  → pg_dump {pg_user}@{pg_db}")
    # 先写 .part、校验通过后再改名：直接写 target 时一次中断/失败就会留下空的 db.sql，
    # cmd_list 照旧报「文件存在」，restore 也会拿它去恢复
    part = target.with_name(target.name + ".part")
    with open(part, "w", encoding="utf-8") as fh:
        try:
            proc = subprocess.run(
                ["docker", "compose", "exec", "-T", "postgres", "pg_dump", "-U", pg_user, pg_db],
                cwd=REPO_ROOT,
                stdout=fh,
                stderr=subprocess.PIPE,
                text=True,
                timeout=900,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"    ✗ 失败：{exc}")
            part.unlink(missing_ok=True)
            return False
    if proc.returncode != 0:
        print(f"    ✗ pg_dump 退出码 {proc.returncode}：{(proc.stderr or '').strip()[-200:]}")
        part.unlink(missing_ok=True)
        return False
    text = part.read_text(encoding="utf-8", errors="ignore")
    if "PostgreSQL database dump" not in text:
        print("    ✗ 产物不含 dump 头，疑似失败/空库")
        part.unlink(missing_ok=True)
        return False
    part.replace(target)
    print(f"    ✓ {target.name}（{target.stat().st_size // 1024} KB）")
    return True


def backup_minio(target: Path, bucket: str) -> bool:
    print(f"  → mc mirror {bucket}")
    cid = container_id("minio")
    if not cid:
        print("    ✗ minio 容器未运行")
        return False
    script = (
        'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1'
        f" && rm -rf /tmp/lkm_backup && mc mirror --preserve m/{bucket} /tmp/lkm_backup"
    )
    try:
        proc = compose("exec", "-T", "minio", "sh", "-c", script)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"    ✗ 失败：{exc}")
        return False
    if proc.returncode != 0:
        print(f"    ✗ mc mirror 退出码 {proc.returncode}：{(proc.stderr or '').strip()[-200:]}")
        return False
    if target.exists():
        shutil.rmtree(target)
    try:
        cp = subprocess.run(
            ["docker", "cp", f"{cid}:/tmp/lkm_backup", str(target)],
            capture_output=True,
            text=True,
            timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        # 与其它 subprocess 调用保持一致：不把异常抛到 cmd_backup 之外（那会带崩后续步骤）
        print(f"    ✗ docker cp 失败：{exc}")
        return False
    if cp.returncode != 0:
        print(f"    ✗ docker cp 失败：{(cp.stderr or '').strip()[-200:]}")
        # 拷贝失败时**不删**容器里的镜像产物：那是唯一一份，重 mirror 很贵，留着还能人工重试
        return False
    compose("exec", "-T", "minio", "rm", "-rf", "/tmp/lkm_backup", timeout=120)
    count = sum(1 for _ in target.rglob("*") if _.is_file()) if target.exists() else 0
    print(f"    ✓ {target.name}（{count} 个对象）")
    return True


def backup_volume(target: Path, volume: str) -> bool:
    print(f"  → tar 卷 {volume}")
    # 同 backup_db：tar 半途失败会留下损坏的 tar.gz，而 list/restore 只看文件名
    part_name = f"{target.name}.part"
    part = target.with_name(part_name)
    try:
        proc = subprocess.run(
            [
                "docker", "run", "--rm",
                "-v", f"{volume}:/data:ro",
                "-v", f"{target.parent}:/backup",
                "alpine",
                "tar", "czf", f"/backup/{part_name}", "-C", "/data", ".",
            ],
            capture_output=True,
            text=True,
            timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"    ✗ 失败：{exc}")
        part.unlink(missing_ok=True)
        return False
    if proc.returncode != 0 or not part.exists():
        print(f"    ✗ tar 失败：{(proc.stderr or '').strip()[-200:]}")
        part.unlink(missing_ok=True)
        return False
    part.replace(target)
    print(f"    ✓ {target.name}（{target.stat().st_size // 1024} KB）")
    return True


def cmd_backup(args: argparse.Namespace) -> int:
    stamp = datetime.date.today().isoformat()
    dest = Path(args.out) / stamp
    dest.mkdir(parents=True, exist_ok=True)
    print(f"备份目录：{dest}")

    ok = True
    if not args.skip_db:
        ok &= backup_db(dest / "db.sql", env_value("POSTGRES_USER", "lkm"), env_value("POSTGRES_DB", "lkm"))
    if not args.skip_minio:
        ok &= backup_minio(dest / "minio", env_value("LKM_S3_BUCKET", "lkm"))
    if not args.skip_volume:
        ok &= backup_volume(dest / "backend_files.tar.gz", f"{project_name()}_backend_data")

    print("\n完成。" if ok else "\n存在失败项，请检查上面 ✗。")
    return 0 if ok else 1


# ── 恢复 ────────────────────────────────────────────────────────────────────


def restore_db(src: Path, pg_user: str, pg_db: str) -> bool:
    print(f"  → psql 恢复 {pg_db}")
    if not src.exists():
        print(f"    ✗ 找不到 {src}")
        return False
    with open(src, encoding="utf-8") as fh:
        try:
            # ON_ERROR_STOP=1：不加时 psql 逐条继续执行、语句失败也不改退出码，
            # 恢复打在重复键/缺角色上照样退出 0 → 这里会误报「✓ 已恢复」，
            # 而库里其实只恢复了一半
            proc = subprocess.run(
                [
                    "docker", "compose", "exec", "-T", "postgres", "psql",
                    "-v", "ON_ERROR_STOP=1", "-U", pg_user, "-d", pg_db,
                ],
                cwd=REPO_ROOT,
                stdin=fh,
                capture_output=True,
                text=True,
                timeout=900,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"    ✗ 失败：{exc}")
            return False
    if proc.returncode != 0:
        print(f"    ✗ psql 退出码 {proc.returncode}：{(proc.stderr or '').strip()[-200:]}")
        return False
    print("    ✓ 已恢复")
    return True


def restore_minio(src: Path, bucket: str) -> bool:
    print(f"  → mc mirror 回 {bucket}")
    if not src.exists():
        print(f"    ✗ 找不到 {src}")
        return False
    cid = container_id("minio")
    if not cid:
        print("    ✗ minio 容器未运行")
        return False
    # docker cp 到已存在的目录会把源目录嵌进去（/tmp/lkm_restore/<dirname>/…），
    # 之后 mc mirror 会给每个对象多套一层错误前缀 —— 先清掉容器内的目标路径
    compose("exec", "-T", "minio", "rm", "-rf", "/tmp/lkm_restore", timeout=120)
    cp = subprocess.run(
        ["docker", "cp", str(src), f"{cid}:/tmp/lkm_restore"],
        capture_output=True, text=True, timeout=900,
    )
    if cp.returncode != 0:
        print(f"    ✗ docker cp 失败：{(cp.stderr or '').strip()[-200:]}")
        return False
    script = (
        'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1'
        f" && mc mirror --preserve /tmp/lkm_restore m/{bucket}"
    )
    try:
        proc = compose("exec", "-T", "minio", "sh", "-c", script)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"    ✗ 失败：{exc}")
        return False
    finally:
        # 成败都清掉容器内中转目录：留着会让容器磁盘慢慢长起来
        compose("exec", "-T", "minio", "rm", "-rf", "/tmp/lkm_restore", timeout=120)
    if proc.returncode != 0:
        print(f"    ✗ mc mirror 退出码 {proc.returncode}：{(proc.stderr or '').strip()[-200:]}")
        return False
    print("    ✓ 已恢复")
    return True


def restore_volume(src: Path, volume: str) -> bool:
    print(f"  → 解包到卷 {volume}")
    if not src.exists():
        print(f"    ✗ 找不到 {src}")
        return False
    try:
        proc = subprocess.run(
            [
                "docker", "run", "--rm",
                "-v", f"{volume}:/data",
                "-v", f"{src.parent}:/backup:ro",
                "alpine",
                "tar", "xzf", f"/backup/{src.name}", "-C", "/data",
            ],
            capture_output=True, text=True, timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"    ✗ 失败：{exc}")
        return False
    if proc.returncode != 0:
        print(f"    ✗ tar 失败：{(proc.stderr or '').strip()[-200:]}")
        return False
    print("    ✓ 已恢复")
    return True


def cmd_restore(args: argparse.Namespace) -> int:
    src = Path(args.from_dir)
    if not src.is_dir():
        print(f"备份目录不存在：{src}", file=sys.stderr)
        return 1
    only = args.only
    if not args.yes:
        targets = only or "db,minio,volume"
        print(
            f"⚠ 即将用 {src} 覆盖当前 [{targets}]。这是破坏性操作。\n"
            "确认请加 --yes 重跑（恢复前建议先做一次 backup 兜底）。",
            file=sys.stderr,
        )
        return 1

    ok = True
    if only in (None, "db"):
        ok &= restore_db(src / "db.sql", env_value("POSTGRES_USER", "lkm"), env_value("POSTGRES_DB", "lkm"))
    if only in (None, "minio"):
        ok &= restore_minio(src / "minio", env_value("LKM_S3_BUCKET", "lkm"))
    if only in (None, "volume"):
        ok &= restore_volume(src / "backend_files.tar.gz", f"{project_name()}_backend_data")
    print("\n完成。" if ok else "\n存在失败项。")
    return 0 if ok else 1


# ── 列表 ────────────────────────────────────────────────────────────────────


def cmd_list(args: argparse.Namespace) -> int:
    root = Path(args.out)
    if not root.is_dir():
        print(f"无备份目录：{root}")
        return 0
    for entry in sorted(root.iterdir(), reverse=True):
        if not entry.is_dir():
            continue
        parts: list[str] = []
        for name in ("db.sql", "backend_files.tar.gz"):
            path = entry / name
            parts.append(f"{name}={path.stat().st_size // 1024}KB" if path.exists() else f"{name}=缺失")
        minio_dir = entry / "minio"
        count = sum(1 for p in minio_dir.rglob("*") if p.is_file()) if minio_dir.is_dir() else 0
        parts.append(f"minio={count}对象")
        print(f"{entry.name}  " + "  ".join(parts))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="LKM 备份/恢复")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_backup = sub.add_parser("backup", help="执行一次完整备份")
    p_backup.add_argument("--out", default=str(DEFAULT_OUT), help="输出根目录")
    p_backup.add_argument("--skip-db", action="store_true")
    p_backup.add_argument("--skip-minio", action="store_true")
    p_backup.add_argument("--skip-volume", action="store_true")
    p_backup.set_defaults(func=cmd_backup)

    p_restore = sub.add_parser("restore", help="从备份目录恢复（破坏性）")
    p_restore.add_argument("--from", dest="from_dir", required=True, help="备份目录（含 db.sql/minio/...）")
    p_restore.add_argument("--only", choices=["db", "minio", "volume"], help="只恢复其一")
    p_restore.add_argument("--yes", action="store_true", help="确认破坏性操作")
    p_restore.set_defaults(func=cmd_restore)

    p_list = sub.add_parser("list", help="列出已有备份")
    p_list.add_argument("--out", default=str(DEFAULT_OUT))
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
