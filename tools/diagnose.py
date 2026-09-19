#!/usr/bin/env python3
"""Pulsar / worker 故障一键诊断。

针对本项目复发性故障：Pulsar 不健康时，依赖它的 backend / worker-* 会卡在
`Created` 状态（compose 的 depends_on: service_healthy 不满足），表现为「worker 起不来」
而日志空白——真正的根因在 broker 侧。

本脚本一次给齐：容器状态、broker 就绪、各订阅 backlog、ledger 数据占用、
Pulsar 近期错误摘要，并按发现给出处置建议。

只用标准库。Pulsar 的 `pulsar-admin` 是 JVM 客户端，单次调用约 10s+，故全量运行
可能需要 1~2 分钟；用 `--quick` 可跳过 backlog 查询。

用法：
    python3 tools/diagnose.py            # 全量
    python3 tools/diagnose.py --quick    # 跳过 backlog（只查状态/健康/ledger）
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PULSAR_ADMIN_URL = "http://127.0.0.1:8080"

# 内置兜底（容器未跑时用）；容器在跑则从后端 messaging.SUBSCRIPTIONS 动态读，避免漂移。
DEFAULT_SUBSCRIPTIONS: list[tuple[str, str]] = [
    ("send", "persistent://lkm/auth/email"),
    ("notify", "persistent://lkm/biz/notify.upload"),
    ("points-reward", "persistent://lkm/biz/points.apply"),
    ("points-stats", "persistent://lkm/biz/points.apply"),
    ("points-tasks", "persistent://lkm/biz/points.apply"),
    ("notification", "persistent://lkm/biz/points.apply"),
    ("user-invalidate", "persistent://lkm/auth/user.events"),
    ("jobs", "persistent://lkm/system/cron"),
    ("dlq-persist", "persistent://lkm/system/dlq"),
]

WORKER_PREFIX = "worker"


def compose(*args: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", "compose", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def service_rows() -> list[tuple[str, str, str]]:
    """[(service, state, status)]；compose 不可用返回空。"""
    try:
        proc = compose("ps", "-a", "--format", "{{.Service}}\t{{.State}}\t{{.Status}}")
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    rows: list[tuple[str, str, str]] = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            rows.append((parts[0], parts[1], parts[2]))
    return rows


def is_abnormal(state: str, status: str) -> bool:
    return state in {"created", "restarting", "exited", "dead"} or "unhealthy" in status


def extract_json(text: str) -> dict | None:
    """从可能混有日志行的输出里取第一段合法 JSON 对象。"""
    start = text.find("{")
    if start < 0:
        return None
    try:
        return json.loads(text[start:])
    except ValueError:
        # 尾部有日志时，逐个右括号回退
        for end in range(len(text), start, -1):
            if text[end - 1] == "}":
                try:
                    return json.loads(text[start:end])
                except ValueError:
                    continue
    return None


def pulsar_ready() -> tuple[bool, str]:
    """同 compose healthcheck：namespace lkm/biz 存在即就绪。"""
    try:
        proc = compose(
            "exec",
            "-T",
            "pulsar",
            "bin/pulsar-admin",
            "--admin-url",
            PULSAR_ADMIN_URL,
            "namespaces",
            "list",
            "lkm",
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"无法执行 pulsar-admin：{exc}"
    if proc.returncode != 0:
        lines = (proc.stderr or proc.stdout or "").strip().splitlines()
        return False, (lines[-1] if lines else "pulsar-admin 失败")
    namespaces = {ln.strip() for ln in proc.stdout.splitlines() if ln.strip()}
    if "lkm/biz" in namespaces:
        return True, "namespace lkm/biz 存在"
    return False, f"namespace 未就绪：{sorted(namespaces) or '空'}"


def load_subscriptions(rows: list[tuple[str, str, str]]) -> list[tuple[str, str]]:
    running = {s for s, state, _ in rows if state == "running"}
    if "backend" not in running:
        return DEFAULT_SUBSCRIPTIONS
    code = (
        "from app.core import messaging as m;"
        "print('\\n'.join(f'{s.name}\\t{s.topic}' for s in m.SUBSCRIPTIONS.values()))"
    )
    try:
        proc = compose("exec", "-T", "backend", "python", "-c", code)
    except (OSError, subprocess.TimeoutExpired):
        return DEFAULT_SUBSCRIPTIONS
    if proc.returncode != 0:
        return DEFAULT_SUBSCRIPTIONS
    subs: list[tuple[str, str]] = []
    for line in proc.stdout.splitlines():
        if "\t" in line:
            name, _, topic = line.partition("\t")
            subs.append((name.strip(), topic.strip()))
    return subs or DEFAULT_SUBSCRIPTIONS


def topic_backlogs(subs: list[tuple[str, str]]) -> list[tuple[str, str, int | None]]:
    """按 topic 去重查询后，展开成 [(topic, sub, msgBacklog)]。"""
    by_topic: dict[str, list[str]] = {}
    for name, topic in subs:
        by_topic.setdefault(topic, []).append(name)

    out: list[tuple[str, str, int | None]] = []
    for topic, names in by_topic.items():
        try:
            proc = compose(
                "exec",
                "-T",
                "pulsar",
                "bin/pulsar-admin",
                "--admin-url",
                PULSAR_ADMIN_URL,
                "topics",
                "stats",
                topic,
            )
        except (OSError, subprocess.TimeoutExpired):
            out.extend((topic, n, None) for n in names)
            continue
        stats = extract_json(proc.stdout) if proc.returncode == 0 else None
        sub_stats = (stats or {}).get("subscriptions", {})
        for name in names:
            backlog = sub_stats.get(name, {}).get("msgBacklog")
            out.append((topic, name, backlog))
    return out


def ledger_usage() -> str:
    try:
        proc = compose("exec", "-T", "pulsar", "du", "-sh", "/pulsar/data")
    except (OSError, subprocess.TimeoutExpired):
        return "无法获取"
    if proc.returncode != 0:
        return "无法获取"
    return (proc.stdout or "").strip().split("\t")[0] or "无法获取"


def recent_pulsar_errors() -> list[str]:
    try:
        proc = compose("logs", "--tail", "300", "pulsar")
    except (OSError, subprocess.TimeoutExpired):
        return []
    pattern = re.compile(
        r"error|exception|noledger|ledger|bookie|corrupt|fenced", re.IGNORECASE
    )
    hits = [ln for ln in (proc.stdout + proc.stderr).splitlines() if pattern.search(ln)]
    return hits[-10:]


def advice(
    rows: list[tuple[str, str, str]], ready: bool, backlogs: list[tuple[str, str, int | None]]
) -> list[str]:
    tips: list[str] = []
    blocked = [
        s for s, state, _ in rows if s.startswith(WORKER_PREFIX) and state == "created"
    ]
    if blocked and not ready:
        tips.append(
            f"worker 卡 Created 且 broker 未就绪 → 根因在 Pulsar，非 worker 本身："
            f"先 `docker compose logs --tail 200 pulsar` 看 ledger/bookie，再 `docker compose up -d pulsar`"
            f"（卡住的服务：{', '.join(blocked)}）"
        )
    unhealthy = [f"{s}({st})" for s, state, st in rows if is_abnormal(state, st)]
    if unhealthy:
        tips.append(f"异常容器：{', '.join(unhealthy)}；逐一看 `docker compose logs --tail 120 <服务>`")

    lagging = [(t, n, b) for t, n, b in backlogs if b]
    if lagging:
        worst = sorted(lagging, key=lambda x: x[2] or 0, reverse=True)[:3]
        tips.append(
            "订阅积压（消费者落后）："
            + "; ".join(f"{t.split('/')[-1]}/{n}={b}" for t, n, b in worst)
            + " → 检查对应 worker-* 是否在跑/反复重启"
        )
    dlq = [b for t, n, b in backlogs if t.endswith("/dlq") and b]
    if dlq:
        tips.append("DLQ topic 有积压 → dlq-persist 消费者未跟上，死信没落库，后台「死信队列」会看不到")
    if not tips:
        tips.append("未发现明显异常。若业务仍异常，请看 `docker compose logs -f worker` 定位具体任务。")
    return tips


def main() -> int:
    parser = argparse.ArgumentParser(description="Pulsar/worker 诊断")
    parser.add_argument("--quick", action="store_true", help="跳过 backlog 查询（省 ~1 分钟）")
    args = parser.parse_args()

    rows = service_rows()
    if not rows:
        print("无法获取容器状态（docker compose 不可用，或栈未启动）。")
        return 1

    print("=== 容器状态 ===")
    for service, state, status in rows:
        mark = "!" if is_abnormal(state, status) else " "
        print(f" [{mark}] {service:<24} {state:<10} {status}")

    print("\n=== Pulsar broker 就绪 ===")
    ready, detail = pulsar_ready()
    print(f" [{'✓' if ready else '✗'}] {detail}")

    backlogs: list[tuple[str, str, int | None]] = []
    if not args.quick:
        subs = load_subscriptions(rows)
        print(f"\n=== 订阅 backlog（{len(subs)} 个订阅，需 ~1 分钟）===")
        backlogs = topic_backlogs(subs)
        for topic, name, backlog in backlogs:
            value = "?" if backlog is None else str(backlog)
            flag = "!" if backlog else " "
            print(f" [{flag}] {topic:<38} {name:<16} backlog={value}")

    print("\n=== ledger 数据占用 ===")
    print(f" /pulsar/data: {ledger_usage()}")

    print("\n=== Pulsar 近期错误（最后 300 行内匹配）===")
    errors = recent_pulsar_errors()
    if errors:
        for line in errors:
            print(f"   {line}")
    else:
        print("   无匹配（或日志不可读）")

    print("\n=== 处置建议 ===")
    for tip in advice(rows, ready, backlogs):
        print(f" - {tip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
