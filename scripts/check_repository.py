#!/usr/bin/env python3
"""Guard the public source tree against local data, credentials, and broken links."""

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PARTS = {".build", ".codex", "DerivedData", "outputs", "work"}
ALLOWED_IMAGES = {"docs/images/preview.png", "docs/images/cleanup-progress.png"}
SECRET_PATTERNS = [
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{32,}\b"),
]
LOCAL_PATH = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+/")
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")


def repository_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [ROOT / item.decode() for item in result.stdout.split(b"\0") if item]


def main() -> int:
    failures: list[str] = []
    files = repository_files()
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        parts = set(Path(relative).parts)
        if parts & FORBIDDEN_PARTS:
            failures.append(f"local output directory is included: {relative}")
        if path.suffix.lower() in {".sqlite", ".db", ".jsonl", ".zst"}:
            failures.append(f"local session/database data is included: {relative}")
        if path.suffix.lower() in {".png", ".jpg", ".jpeg"} and relative not in ALLOWED_IMAGES:
            failures.append(f"unreviewed image asset is included: {relative}")
        if not path.is_file() or path.suffix.lower() in {".png", ".jpg", ".jpeg"}:
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            failures.append(f"unexpected binary file is included: {relative}")
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(content):
                failures.append(f"credential-like string found in {relative}")
                break
        if LOCAL_PATH.search(content):
            failures.append(f"absolute home directory path found in {relative}")
        if path.suffix.lower() == ".md":
            for target in MARKDOWN_LINK.findall(content):
                target = target.split("#", 1)[0].strip().strip("<>")
                if not target or "://" in target or target.startswith(("mailto:", "/")):
                    continue
                if not (path.parent / target).resolve().is_file():
                    failures.append(f"broken relative Markdown link in {relative}: {target}")

    if failures:
        print("Repository hygiene checks failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"Repository hygiene checks passed for {len(files)} files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
