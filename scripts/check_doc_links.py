"""检查根仓库 Markdown 的相对链接是否都指向真实存在的文件。

为什么需要它
    根仓库的文档散落在 README / AGENTS / docs/ / deploy/ 里，互相引用很多。文档搬家
    （例如把 DEPLOYMENT.md 移进 docs/）时，链接不会跟着改，而 Markdown 渲染器不会报错，
    只有点开的人才发现 404。这类问题此前靠人工全量扫描才发现，且已经发生过一次
    （docs/ 迁移后有 24 条断链，其中还有一处漏在子模块文档里）。

检查范围
    只查**相对路径**链接。`http(s)://`、`mailto:`、纯锚点 `#foo`、绝对路径 `/foo`
    不属于「仓库内文件」，跳过（外链是否可用需要联网，不放进 CI）。
    `#fragment` 会被剥掉：本脚本不做标题锚点校验。

用法
    python3 scripts/check_doc_links.py            # 仓库根目录执行
    python3 scripts/check_doc_links.py --verbose  # 打印每条被检查的链接

退出码：0 全部有效；1 存在断链。
"""

from __future__ import annotations

import re
import subprocess
import sys
import urllib.parse
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# [文本](目标 "可选标题")；目标里允许 &、#、%。捕获组 1 是目标。
_LINK_RE = re.compile(r"\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")

# 不是「仓库内相对文件」的链接
_SKIP_PREFIXES = ("http://", "https://", "mailto:", "tel:", "#", "/", "//")


def _tracked_markdown() -> list[Path]:
    """用 git 索引取 Markdown：自动排除 .gitignore 的内容与子模块目录。"""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "*.md"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        # 没有 git（例如导出的 tarball）时退化为全盘扫描，跳过已知非文档目录
        return sorted(
            p
            for p in REPO_ROOT.rglob("*.md")
            if not any(
                part in {".git", "node_modules", ".venv", "dist"}
                for part in p.relative_to(REPO_ROOT).parts
            )
        )
    return [REPO_ROOT / p for p in out.decode().split("\0") if p]


def _target_path(source: Path, raw_target: str) -> Path | None:
    """把链接目标解析成仓库内路径；不是相对文件链接时返回 None。"""
    target = raw_target.strip()
    if not target or target.startswith(_SKIP_PREFIXES):
        return None
    # 去掉 #fragment 与 ?query（Markdown 链接里不会出现查询串，但防御一下）
    target = target.split("#", 1)[0].split("?", 1)[0]
    if not target:
        return None
    # 链接里可能有 %E4%B8%AD 这样的转义
    target = urllib.parse.unquote(target)
    resolved = (source.parent / target).resolve()
    # 指向仓库外的相对链接（../ 出根）也应报错，这里统一交给存在性判断
    return resolved


def main(argv: list[str]) -> int:
    verbose = "--verbose" in argv
    checked = 0
    broken: list[tuple[Path, str]] = []

    for source in _tracked_markdown():
        try:
            text = source.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            print(f"[warn] 跳过非 UTF-8 文件: {source.relative_to(REPO_ROOT)}")
            continue
        for match in _LINK_RE.finditer(text):
            raw = match.group(1)
            resolved = _target_path(source, raw)
            if resolved is None:
                continue
            checked += 1
            if verbose:
                print(f"  {source.relative_to(REPO_ROOT)} -> {raw}")
            if not resolved.exists():
                broken.append((source, raw))

    print(f"[lkm] 检查 {checked} 条相对链接，涉及 {len(_tracked_markdown())} 个 Markdown 文件")
    if not broken:
        print("[lkm] 文档链接全部有效")
        return 0

    print(f"[lkm:error] 发现 {len(broken)} 条断链:", file=sys.stderr)
    for source, raw in broken:
        print(f"  {source.relative_to(REPO_ROOT)} -> {raw}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
