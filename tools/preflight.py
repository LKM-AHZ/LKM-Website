#!/usr/bin/env python3
"""上线前体检 —— 把 DEPLOYMENT.md / OPS-CHEATSHEET.md 里靠人记的坑固化成可执行检查。

分两段：

* **静态检查**（不依赖容器在跑）：`.env` 存在与可解析、三主密钥强度与互异、必填密码、
  `LKM_ALLOWED_HOSTS` 是否含内网服务名+回环、`deploy/**` 是否被引入 CRLF、
  `docker compose config` 语法。
* **运行时检查**（容器在跑才做，否则 SKIP）：容器是否 restarting/unhealthy、
  `/api/v1/health`、MinIO 桶是否存在、两库 alembic 是否到 head、TLS 证书剩余天数。

只用标准库，任何装有 python3 的宿主机都能跑（无需 venv）。

用法：
    python3 tools/preflight.py                # 全量（静态 + 运行时）
    python3 tools/preflight.py --static-only  # 只做静态检查（CI / 未起栈时）
    python3 tools/preflight.py --json         # 机器可读输出

退出码：0 = 无 FAIL；1 = 有 FAIL。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

OK, WARN, FAIL, SKIP = "OK", "WARN", "FAIL", "SKIP"

# 三个主密钥（.env.example §三个必填密钥）：>64 位随机串且互不相同
MAIN_SECRETS = [
    "LKM_JWT_SECRET",
    "LKM_TOTP_ENCRYPTION_KEY",
    "LKM_VERIFICATION_CODE_PEPPER",
]
REQUIRED_PASSWORDS = ["POSTGRES_PASSWORD", "MINIO_ROOT_PASSWORD"]

# 弱值/占位值：出现即 FAIL
WEAK_VALUES = {"", "change-me", "changeme", "password", "secret", "test"}

# 容器 healthcheck 直连回环会被 TrustedHost 判 400，白名单必须含这些
HOST_WHITELIST_MUST = ["backend", "auth", "localhost", "127.0.0.1"]

HEALTH_URL = "http://127.0.0.1/api/v1/health"


class Report:
    """收集检查结论，最后统一渲染。"""

    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []

    def add(self, level: str, name: str, detail: str = "") -> None:
        self.rows.append((level, name, detail))

    @property
    def failed(self) -> bool:
        return any(level == FAIL for level, _, _ in self.rows)

    def render_text(self) -> str:
        lines: list[str] = []
        for level, name, detail in self.rows:
            mark = {"OK": "✓", "WARN": "!", "FAIL": "✗", "SKIP": "-"}[level]
            line = f"[{mark}] {name}"
            if detail:
                line += f" — {detail}"
            lines.append(line)
        fails = sum(1 for lv, _, _ in self.rows if lv == FAIL)
        warns = sum(1 for lv, _, _ in self.rows if lv == WARN)
        lines.append("")
        lines.append(f"结论：{fails} 项失败，{warns} 项警告（共 {len(self.rows)} 项）")
        return "\n".join(lines)

    def render_json(self) -> str:
        return json.dumps(
            {
                "ok": not self.failed,
                "checks": [
                    {"level": lv, "name": n, "detail": d} for lv, n, d in self.rows
                ],
            },
            ensure_ascii=False,
            indent=2,
        )


def parse_env(path: Path) -> dict[str, str]:
    """最小 .env 解析：KEY=VALUE，忽略注释/空行，去掉值两端引号。"""
    env: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip("'\"")
        env[key.strip()] = value
    return env


def compose(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=60,
    )


def running_services() -> set[str]:
    """当前处于 running 的服务名集合（compose 不可用时返回空集）。"""
    try:
        proc = compose("ps", "--status", "running", "--format", "{{.Service}}")
    except (OSError, subprocess.TimeoutExpired):
        return set()
    if proc.returncode != 0:
        return set()
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


# ── 静态检查 ────────────────────────────────────────────────────────────────


def check_env_file(rep: Report) -> dict[str, str] | None:
    """读取 .env：**读不到**返回 None，读到（哪怕解析出 0 条）返回 dict。

    区分这两种情况是必要的：下面所有依赖 .env 的检查都由「返回值是否非空」门控，
    若「存在但全被注释/全被引号破坏」也返回 {}，密钥强度、必填密码、ALLOWED_HOSTS
    这些检查会**整段消失**（报告里一条不出，极易被当成通过）。
    """
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        rep.add(FAIL, ".env 存在", "根目录无 .env，请 cp .env.example .env")
        return None
    rep.add(OK, ".env 存在", str(env_path))
    try:
        parsed = parse_env(env_path)
    except (OSError, UnicodeDecodeError) as exc:
        # parse_env 以 UTF-8 严格模式读取：GBK 中文注释等非 UTF-8 字节会抛 UnicodeDecodeError
        # （ValueError 子类），不接住的话整个体检脚本直接崩掉，而不是给出一条 FAIL
        rep.add(FAIL, ".env 可解析", str(exc))
        return None
    if not parsed:
        rep.add(WARN, ".env 可解析", "未解析出任何 KEY=VALUE 行（全被注释或格式损坏？）")
    return parsed


def check_secrets(rep: Report, env: dict[str, str]) -> None:
    seen: dict[str, str] = {}
    for key in MAIN_SECRETS:
        value = env.get(key, "")
        if value.lower() in WEAK_VALUES:
            rep.add(FAIL, f"密钥 {key}", "缺失或仍是占位值")
            continue
        if value in seen:
            rep.add(FAIL, f"密钥 {key}", f"与 {seen[value]} 相同（必须互异）")
            continue
        seen[value] = key
        if len(value) < 64:
            rep.add(WARN, f"密钥 {key}", f"长度 {len(value)} < 64，建议 openssl rand -hex 48")
        else:
            rep.add(OK, f"密钥 {key}", f"长度 {len(value)}")

    for key in REQUIRED_PASSWORDS:
        value = env.get(key, "")
        if value.lower() in WEAK_VALUES:
            rep.add(FAIL, f"密码 {key}", "缺失或仍是占位值")
        else:
            rep.add(OK, f"密码 {key}", "已设置")


def check_allowed_hosts(rep: Report, env: dict[str, str]) -> None:
    raw = env.get("LKM_ALLOWED_HOSTS", "")
    if not raw:
        # compose 有生产默认值兜底，未显式设置不算错
        rep.add(WARN, "LKM_ALLOWED_HOSTS", "未显式设置，将用 compose 默认值")
        return
    hosts = {h.strip() for h in raw.split(",") if h.strip()}
    missing = [h for h in HOST_WHITELIST_MUST if h not in hosts]
    if missing:
        rep.add(
            FAIL,
            "LKM_ALLOWED_HOSTS",
            f"缺少 {','.join(missing)}（容器 healthcheck 直连会被判 400）",
        )
    else:
        rep.add(OK, "LKM_ALLOWED_HOSTS", "含内网服务名 + 回环")


def check_restart_policy(rep: Report, env: dict[str, str]) -> None:
    policy = env.get("LKM_RESTART_POLICY", "no")
    if policy == "no":
        rep.add(WARN, "LKM_RESTART_POLICY", "=no（本地/测试策略）；服务器常驻应为 unless-stopped")
    else:
        rep.add(OK, "LKM_RESTART_POLICY", policy)


def check_crlf(rep: Report) -> None:
    """deploy/** 下 .sh 若被引入 CRLF，容器内会以 'bad interpreter' 反复重启。"""
    deploy = REPO_ROOT / "deploy"
    if not deploy.is_dir():
        rep.add(SKIP, "deploy/** CRLF", "无 deploy 目录")
        return
    bad: list[str] = []
    for path in deploy.rglob("*"):
        if path.is_file() and path.suffix in {".sh", ".yaml", ".yml", ".conf"}:
            try:
                if b"\r\n" in path.read_bytes():
                    bad.append(str(path.relative_to(REPO_ROOT)))
            except OSError:
                continue
    if bad:
        rep.add(FAIL, "deploy/** CRLF", f"{len(bad)} 个文件含 CRLF：{', '.join(bad[:3])}")
    else:
        rep.add(OK, "deploy/** CRLF", "关键脚本均为 LF")


def check_compose_config(rep: Report) -> None:
    try:
        proc = compose("config", "-q")
    except (OSError, subprocess.TimeoutExpired) as exc:
        rep.add(SKIP, "docker compose config", f"无法执行：{exc}")
        return
    if proc.returncode != 0:
        rep.add(FAIL, "docker compose config", (proc.stderr or "").strip()[-300:])
    else:
        rep.add(OK, "docker compose config", "语法通过")


# ── 运行时检查（容器在跑才做）───────────────────────────────────────────────


def check_health(rep: Report, running: set[str]) -> None:
    if not {"backend", "apisix"} <= running:
        rep.add(SKIP, "健康端点", "backend/apisix 未在跑")
        return
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=5) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        rep.add(FAIL, "健康端点", f"{HEALTH_URL} 请求失败：{exc}")
        return

    # 不能假定响应一定是「带 data 对象的 JSON 对象」：网关错误页/登录跳转可能回数组、字符串
    # 或 null，直接 .get() 会抛 AttributeError 让整个体检脚本崩掉，而不是走 FAIL 分支
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), dict):
        rep.add(FAIL, "健康端点", f"{HEALTH_URL} 返回体结构异常：{type(payload).__name__}")
        return
    data = payload["data"]
    unhealthy = [
        name
        for name in ("db", "redis")
        if isinstance(data.get(name), dict) and data[name].get("status") != "up"
    ]
    if payload.get("code") != 0 or data.get("status") != "ok" or unhealthy:
        rep.add(FAIL, "健康端点", f"status={data.get('status')} 依赖异常={unhealthy}")
    else:
        rep.add(OK, "健康端点", "db/redis 均 up")


def check_container_states(rep: Report) -> None:
    try:
        proc = compose("ps", "--format", "{{.Service}}\t{{.State}}\t{{.Status}}")
    except (OSError, subprocess.TimeoutExpired) as exc:
        rep.add(SKIP, "容器状态", f"无法执行：{exc}")
        return
    if proc.returncode != 0:
        rep.add(SKIP, "容器状态", "docker compose ps 失败")
        return

    bad: list[str] = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        service, state, status = parts[0], parts[1], parts[2]
        if state in {"restarting", "exited", "dead"} or "unhealthy" in status:
            bad.append(f"{service}({status})")
    if bad:
        rep.add(FAIL, "容器状态", f"异常：{', '.join(bad[:5])}")
    else:
        rep.add(OK, "容器状态", "无 restarting/exited/unhealthy")


def check_minio_bucket(rep: Report, env: dict[str, str], running: set[str]) -> None:
    if "minio" not in running:
        rep.add(SKIP, "MinIO 桶", "minio 未在跑")
        return
    bucket = env.get("LKM_S3_BUCKET", "lkm")
    # 不能写成 `A && B && C || echo MISSING`：`||` 绑定的是整条 && 链，mc alias 失败
    # （凭据未注入/mc 缺失）也会落到 MISSING，被误报成「桶不存在（S3 不自动建桶）」硬 FAIL。
    # 先把 alias 失败单独打哨兵 NOALIAS 标出，再由下面判成 SKIP。
    script = (
        'mc alias set m http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" '
        '>/dev/null 2>&1 || { echo NOALIAS; exit 0; }; '
        f'mc ls "m/{bucket}" >/dev/null 2>&1 && echo FOUND || echo MISSING'
    )
    try:
        proc = compose("exec", "-T", "minio", "sh", "-c", script)
    except (OSError, subprocess.TimeoutExpired) as exc:
        rep.add(SKIP, "MinIO 桶", f"无法执行：{exc}")
        return
    out = (proc.stdout or "").strip()
    if out.endswith("FOUND"):
        rep.add(OK, "MinIO 桶", f"{bucket} 存在")
    elif out.endswith("MISSING"):
        rep.add(FAIL, "MinIO 桶", f"{bucket} 不存在（S3 不自动建桶）")
    else:
        rep.add(SKIP, "MinIO 桶", "mc 不可用或凭据未注入")


def check_migrations(rep: Report, running: set[str]) -> None:
    if "backend" not in running:
        rep.add(SKIP, "alembic 到 head", "backend 未在跑")
        return
    chains = [("alembic.ini", "业务库"), ("alembic.auth.ini", "auth 库")]
    for ini, label in chains:
        try:
            heads = compose("exec", "-T", "backend", "python", "-m", "alembic", "-c", ini, "heads")
            current = compose(
                "exec", "-T", "backend", "python", "-m", "alembic", "-c", ini, "current"
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            rep.add(SKIP, f"alembic {label}", f"无法执行：{exc}")
            continue
        if heads.returncode != 0 or current.returncode != 0:
            rep.add(SKIP, f"alembic {label}", "命令失败（库未就绪？）")
            continue
        # 判注释用 strip 后的行：原来 `not ln.startswith("#")` 作用在未 strip 的行上，
        # 缩进的注释行不会被过滤，`#` 会被当成 revision 塞进集合
        head_revs = {
            ln.strip().split()[0]
            for ln in heads.stdout.splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        }
        cur_revs = {
            ln.strip().split()[0]
            for ln in current.stdout.splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        }
        if not head_revs:
            # 解析不到 head（输出格式变化/空输出，rc 仍为 0）时不能报「未到 head」——那是误报
            rep.add(SKIP, f"alembic {label}", "无法从 `alembic heads` 解析出 revision")
            continue
        if head_revs <= cur_revs:
            rep.add(OK, f"alembic {label}", "已到 head")
        else:
            rep.add(
                FAIL,
                f"alembic {label}",
                f"未到 head：current={sorted(cur_revs) or '空'} heads={sorted(head_revs)}",
            )


def check_certs(rep: Report, env: dict[str, str], running: set[str]) -> None:
    if "certbot" not in running:
        rep.add(SKIP, "TLS 证书", "certbot 未在跑（无域名时属正常）")
        return
    domains = [
        d.strip()
        for d in env.get("LKM_COMMUNITY_DOMAINS", "").split(",")
        if d.strip()
    ]
    if not domains:
        rep.add(SKIP, "TLS 证书", "未配置 LKM_COMMUNITY_DOMAINS")
        return
    for domain in domains:
        cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
        try:
            proc = compose("exec", "-T", "certbot", "openssl", "x509", "-in", cert, "-noout", "-enddate")
        except (OSError, subprocess.TimeoutExpired):
            rep.add(SKIP, f"TLS {domain}", "无法执行 openssl")
            continue
        if proc.returncode != 0:
            rep.add(WARN, f"TLS {domain}", "无证书（将回退自签，浏览器告警）")
            continue
        # openssl -enddate 输出 `notAfter=Sep 21 12:00:00 2026 GMT`
        raw = (proc.stdout or "").strip().split("=", 1)[-1].strip()
        try:
            expires = datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
        except ValueError:
            rep.add(WARN, f"TLS {domain}", f"无法解析到期时间：{raw!r}")
            continue
        days = (expires - datetime.now(timezone.utc)).days
        # docstring 承诺检查「剩余天数」，故必须有阈值：即将过期/已过期不能报 OK
        if days < 0:
            rep.add(FAIL, f"TLS {domain}", f"证书已过期（{expires.date()}）")
        elif days < 7:
            rep.add(FAIL, f"TLS {domain}", f"仅剩 {days} 天（{expires.date()}），续期大概率已失败")
        elif days < 30:
            rep.add(WARN, f"TLS {domain}", f"仅剩 {days} 天（{expires.date()}）")
        else:
            rep.add(OK, f"TLS {domain}", f"剩余 {days} 天（{expires.date()}）")


def main() -> int:
    parser = argparse.ArgumentParser(description="LKM 上线前体检")
    parser.add_argument("--static-only", action="store_true", help="跳过依赖容器的运行时检查")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    args = parser.parse_args()

    rep = Report()
    file_env = check_env_file(rep)
    # `is not None`：.env 存在但解析出 0 条时也要继续走检查（由 env.get(key, "") 报缺失），
    # 否则这三项检查会静默消失
    if file_env is not None:
        check_secrets(rep, file_env)
        check_allowed_hosts(rep, file_env)
        check_restart_policy(rep, file_env)
    # 运行时检查只用 env.get(...)，读不到 .env 时按空表继续（它们自身会打 SKIP/FAIL）
    env = file_env or {}
    check_crlf(rep)
    check_compose_config(rep)

    if not args.static_only:
        running = running_services()
        check_container_states(rep)
        check_health(rep, running)
        check_minio_bucket(rep, env, running)
        check_migrations(rep, running)
        check_certs(rep, env, running)

    print(rep.render_json() if args.json else rep.render_text())
    return 1 if rep.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
