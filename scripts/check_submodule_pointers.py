"""校验根仓库提交的子模块指针：commit 确实存在于远端，且它在子仓库里的 CI 是绿的。

要解决的问题
    `LKM-Website` 只做编排，四个应用仓库是独立 Git 仓库。根仓库提交里存的是子模块指针
    （gitlink SHA），指针本身不携带任何验证信息：
      1. 子仓库改完忘了 push，根仓库却更新了指针 → 根 CI 检出子模块时才会炸
         （contracts 工作流里那段重复的错误提示就是在补这个洞）；
      2. 子仓库 push 了但 CI 是红的，根仓库 PR 依然能合 —— 跨仓检查在 GitHub 上没法
         互相作为必需检查，不主动查就等于没有。

检查方式
    - **可达性**：GET /repos/{owner}/{repo}/commits/{sha} 是否 200；
    - **CI 结论**：GET /repos/{owner}/{repo}/commits/{sha}/check-runs，任一已完成的
      check run 结论属于失败类即判红。

判定粒度（刻意的）
    - 已完成且失败 → **退出码 1**（真失败，不能合）；
    - 只有排队/进行中的 run → 只告警：子仓 CI 常要跑几分钟，刚 push 完就要求「全绿」
      会把根仓库的检查变成时间竞赛；
    - 完全没有 check run → 只告警（例如 `LKM-on-VSCode` 目前没有 CI）；
    - API 不可用（网络/限流）→ 告警并跳过，不因基础设施问题拦住 PR。

用法
    python3 scripts/check_submodule_pointers.py
    GITHUB_TOKEN=... python3 scripts/check_submodule_pointers.py   # 提高 API 限额

退出码：0 通过（允许告警）；1 指针不可达或子仓 CI 有失败。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
_API = "https://api.github.com"
_FAILED_CONCLUSIONS = {
    "failure",
    "timed_out",
    "cancelled",
    "action_required",
    "startup_failure",
    "stale",
}


@dataclass
class Pointer:
    path: str
    sha: str
    url: str


@dataclass
class Result:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.errors


def _slug(url: str) -> str:
    """`https://github.com/o/r.git` → `o/r`。"""
    cleaned = url.removesuffix(".git").rstrip("/")
    match = re.search(r"github\.com[/:]([^/]+)/([^/]+)$", cleaned)
    if not match:
        raise ValueError(f"无法从子模块 URL 解析 owner/repo: {url}")
    return f"{match.group(1)}/{match.group(2)}"


def _git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=REPO_ROOT, check=True, capture_output=True
    ).stdout.decode()


def _pointers() -> list[Pointer]:
    """从 .gitmodules 取 path/url，从索引取 gitlink SHA（不要求子模块已检出）。"""
    raw = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    ).stdout.decode()
    pointers: list[Pointer] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        key, path = line.split(None, 1)
        name = key.removesuffix(".path")
        url = _git("config", "-f", ".gitmodules", "--get", f"{name}.url").strip()
        sha = _git("rev-parse", f"HEAD:{path.strip()}").strip()
        pointers.append(Pointer(path=path.strip(), sha=sha, url=url))
    return sorted(pointers, key=lambda p: p.path)


def _request(path: str, token: str | None) -> tuple[int, dict[str, object] | None]:
    request = urllib.request.Request(f"{_API}{path}")
    request.add_header("Accept", "application/vnd.github+json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except (urllib.error.URLError, TimeoutError):
        # 网络/限流：交给上层告警，不当作「子模块有问题」
        return 0, None


def _api_get(path: str) -> tuple[int, dict[str, object] | None]:
    """带认证请求；若 token 无权跨仓读（401/403），退回匿名再试一次。

    根仓库的 GITHUB_TOKEN 属于本仓库的安装，能否读别的公开仓库取决于安装配置。
    与其「有 token 就假定能读」，不如在 401/403 时退回匿名——公开仓库的数据匿名可读，
    这样既不会因为 token 权限不够而让整个校验静默失效，也不会误报。
    """
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    status, payload = _request(path, token)
    if token and status in (401, 403):
        status, payload = _request(path, None)
    return status, payload


def _check(pointer: Pointer) -> Result:
    result = Result()
    slug = _slug(pointer.url)
    short = pointer.sha[:12]
    label = f"{slug}@{short}"

    status, _payload = _api_get(f"/repos/{slug}/commits/{pointer.sha}")
    if status == 200:
        pass
    elif status in (404, 422):
        result.errors.append(f"{label} 在远端不存在（子仓库改完没 push？）")
        return result
    else:
        result.warnings.append(f"{label} 可达性未校验（HTTP {status}）")

    status, payload = _api_get(
        f"/repos/{slug}/commits/{pointer.sha}/check-runs?per_page=100"
    )
    if status != 200 or payload is None:
        result.warnings.append(f"{label} 的 check-runs 未校验（HTTP {status}）")
        return result

    runs = payload.get("check_runs") or []
    if not runs:
        result.warnings.append(f"{label} 没有 check run（该子仓库可能未配 CI）")
        return result

    failed = [
        str(run.get("name"))
        for run in runs
        if run.get("status") == "completed"
        and str(run.get("conclusion")) in _FAILED_CONCLUSIONS
    ]
    pending = sum(1 for run in runs if run.get("status") != "completed")
    if failed:
        result.errors.append(f"{label} 的 CI 失败: {', '.join(failed)}")
    if pending:
        result.warnings.append(f"{label} 有 {pending} 个 check run 尚未完成")
    return result


def main() -> int:
    pointers = _pointers()
    if not pointers:
        print("[lkm] 未发现子模块指针")
        return 0

    ok = True
    for pointer in pointers:
        result = _check(pointer)
        print(f"[{'OK' if result.passed else 'FAIL'}] {pointer.path:<22} {pointer.sha[:12]}")
        for note in result.errors:
            print(f"       error: {note}")
        for note in result.warnings:
            print(f"       warn : {note}")
        ok = ok and result.passed

    if not ok:
        print(
            "[lkm:error] 子模块指针校验失败：先让对应子仓库的 CI 变绿并 push，再更新根仓库指针。",
            file=sys.stderr,
        )
        return 1
    print("[lkm] 子模块指针校验通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
