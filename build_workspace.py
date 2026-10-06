#!/usr/bin/env python3
"""Turn app-chunker output (markdown) into a tasks/ workspace for run-agents.sh.

Usage:
    build_workspace.py chunker-output.md [--out tasks]
    cat chunker-output.md | build_workspace.py - --out tasks

Produces:
    <out>/ARCHITECTURE.md   everything before the first task spec
    <out>/NN-slug.md        one file per task spec
    <out>/manifest.tsv      id|slug|category|depends|file
"""
import argparse
import re
import sys
from pathlib import Path

TASK_RE = re.compile(r"^#{2,3}\s*Task\s+\[?(\d+)\]?\s*[:\-\u2013\u2014]\s*(.+?)\s*$", re.I)
# Lines that end the last task spec (summary table, parallelization plan, top-level headings)
STOP_RE = re.compile(r"^(\|\s*#\s*\||\**\s*Parallelization|#{1,2}\s+(?!Task\b))", re.I)


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:40].strip("-") or "task"


def parse(md: str):
    lines = md.splitlines()
    starts = [(i, TASK_RE.match(l)) for i, l in enumerate(lines)]
    starts = [(i, m) for i, m in starts if m]
    if not starts:
        sys.exit("error: no '### Task N: Title' headings found — is this app-chunker output?")

    preamble = "\n".join(lines[: starts[0][0]]).strip()
    tasks = []
    for n, (i, m) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        body = lines[i:end]
        for j, l in enumerate(body[1:], start=1):
            if STOP_RE.match(l.strip()):
                body = body[:j]
                break
        text = "\n".join(body).rstrip()
        text = re.sub(r"(\n\s*-{3,}\s*)+$", "", text).rstrip()  # drop trailing '---'
        cat = re.search(r"\*\*Category\*\*\s*:\s*`?([\w\-]+)`?", text)
        dep = re.search(r"\*\*Depends on\*\*\s*:\s*(.+)", text)
        deps = []
        if dep and not re.match(r"\s*none\b", dep.group(1), re.I):
            deps = [f"{int(d):02d}" for d in re.findall(r"\d+", dep.group(1))]
        tasks.append(
            dict(id=f"{int(m.group(1)):02d}", title=m.group(2), cat=cat.group(1) if cat else "task",
                 deps=deps, text=text)
        )
    return preamble, tasks


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="markdown file with the chunked tasks, or - for stdin")
    ap.add_argument("--out", default="tasks", help="output directory (default: tasks)")
    a = ap.parse_args()

    md = sys.stdin.read() if a.input == "-" else Path(a.input).read_text(encoding="utf-8")
    preamble, tasks = parse(md)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ids = {t["id"] for t in tasks}
    rows = []
    for t in tasks:
        unknown = [d for d in t["deps"] if d not in ids]
        if unknown:
            sys.exit(f"error: task {t['id']} depends on unknown task(s) {unknown}")
        slug = slugify(t["title"])
        fname = f"{t['id']}-{slug}.md"
        (out / fname).write_text(t["text"] + "\n", encoding="utf-8")
        rows.append(f"{t['id']}|{slug}|{t['cat']}|{','.join(t['deps']) or '-'}|{fname}")

    if preamble:
        (out / "ARCHITECTURE.md").write_text(preamble + "\n", encoding="utf-8")
    (out / "manifest.tsv").write_text(
        "# id|slug|category|depends|file\n" + "\n".join(rows) + "\n", encoding="utf-8"
    )
    print(f"wrote {len(tasks)} tasks to {out}/ (architecture: {'yes' if preamble else 'no'})")
    for r in rows:
        print("  " + r)


if __name__ == "__main__":
    main()
