#!/usr/bin/env python3
"""Pulls every ```mermaid block out of a tree of notes and agent sessions.

    python3 tool/mermaid-bench/extract_corpus.py /tmp/mermaid_corpus ~/workspace ~/.claude/projects ~/.omp ~/.pi

Reads `*.md` files and `*.jsonl` / `*.json` session logs under each root,
finds the fenced blocks (inside JSON, in every string value), drops duplicates
by content, and writes `<out>/<hash>.mmd`. A corpus is somebody's own text:
keep it out of the repository.
"""
import hashlib
import json
import os
import re
import sys

FENCE = re.compile(r"```mermaid[^\n]*\n(.*?)\n[ \t]*```", re.S)
SKIP_DIRS = {"node_modules", ".git", "build", ".dart_tool"}


def strings(o):
    if isinstance(o, str):
        yield o
    elif isinstance(o, dict):
        for v in o.values():
            yield from strings(v)
    elif isinstance(o, list):
        for v in o:
            yield from strings(v)


def main():
    out, roots = sys.argv[1], [os.path.expanduser(r) for r in sys.argv[2:]]
    if not roots:
        sys.exit(__doc__)
    os.makedirs(out, exist_ok=True)
    seen = {}

    def add(text):
        for m in FENCE.finditer(text):
            block = m.group(1).strip("\n")
            if len(block) >= 8:
                seen.setdefault(hashlib.md5(block.encode()).hexdigest()[:10], block)

    for root in roots:
        for dirpath, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                path = os.path.join(dirpath, name)
                try:
                    if name.endswith(".md"):
                        add(open(path, errors="ignore").read())
                    elif name.endswith((".jsonl", ".json")):
                        for line in open(path, errors="ignore"):
                            if "mermaid" not in line:
                                continue
                            try:
                                obj = json.loads(line)
                            except ValueError:
                                continue
                            for s in strings(obj):
                                add(s)
                except OSError:
                    pass
    for h, block in seen.items():
        with open(os.path.join(out, h + ".mmd"), "w") as f:
            f.write(block + "\n")
    print(f"{len(seen)} diagrams in {out}")


if __name__ == "__main__":
    main()
