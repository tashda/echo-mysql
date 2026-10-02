#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
from collections import OrderedDict
from dataclasses import dataclass


@dataclass(frozen=True)
class Category:
    name: str
    patterns: tuple[str, ...]


REPO_CATEGORIES: dict[str, list[Category]] = {
    "echo-mysql": [
        Category("Wire Protocol", ("Sources/MySQLWire/", "Tests/MySQLWireTests/")),
        Category("Client APIs", ("Sources/MySQLKit/",)),
        Category("Testing & Fixtures", ("Sources/MySQLKitTesting/", "Tests/MySQLKitTests/")),
        Category("CI & Release", (".github/", "Package.swift", "scripts/")),
        Category("Documentation", ("README", "CHANGELOG", "docs/")),
    ],
}


def git(*args: str) -> str:
    result = subprocess.run(["git", *args], check=True, capture_output=True, text=True)
    return result.stdout.strip()


def git_lines(*args: str) -> list[str]:
    output = git(*args)
    return [line for line in output.splitlines() if line.strip()]


def path_matches(path: str, pattern: str) -> bool:
    if pattern.startswith("*."):
        return path.endswith(pattern[1:])
    return path.startswith(pattern) or path == pattern


def categorize(files: list[str], repo_key: str) -> str:
    categories = REPO_CATEGORIES.get(repo_key, [])
    best_name = "Other Changes"
    best_score = -1
    for category in categories:
        score = sum(1 for path in files for pattern in category.patterns if path_matches(path, pattern))
        if score > best_score:
            best_name = category.name
            best_score = score
    return best_name


def short_paths(files: list[str], limit: int = 4) -> str:
    if not files:
        return ""
    preview = files[:limit]
    rendered = ", ".join(f"`{path}`" for path in preview)
    remainder = len(files) - len(preview)
    if remainder > 0:
        rendered += f", and {remainder} more"
    return rendered


def commit_range(previous_tag: str | None) -> str | None:
    if previous_tag:
        verified = subprocess.run(["git", "rev-parse", "--verify", "--quiet", previous_tag], capture_output=True, text=True)
        if verified.returncode == 0:
            return f"{previous_tag}..HEAD"
    return None


def load_commits(range_spec: str | None, repo_key: str) -> OrderedDict[str, list[tuple[str, list[str]]]]:
    if range_spec:
        hashes = git_lines("rev-list", "--reverse", "--no-merges", range_spec)
    else:
        hashes = git_lines("rev-list", "--reverse", "--max-count=30", "--no-merges", "HEAD")

    grouped: OrderedDict[str, list[tuple[str, list[str]]]] = OrderedDict()
    for commit_hash in hashes:
        subject = git("show", "-s", "--format=%s", commit_hash)
        files = git_lines("show", "--format=", "--name-only", "--diff-filter=ACDMRTUXB", commit_hash)
        category = categorize(files, repo_key)
        grouped.setdefault(category, []).append((subject, files))
    return grouped


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-key", required=True, choices=sorted(REPO_CATEGORIES.keys()))
    parser.add_argument("--repo-name", required=True)
    parser.add_argument("--new-tag", required=True)
    parser.add_argument("--previous-tag", default="")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    previous_tag = args.previous_tag.strip() or None
    range_spec = commit_range(previous_tag)
    if range_spec is None:
        previous_tag = None
    grouped = load_commits(range_spec, args.repo_key)
    commit_count = sum(len(entries) for entries in grouped.values())
    repository = os.environ.get("GITHUB_REPOSITORY", "")

    lines: list[str] = [
        f"# {args.repo_name} {args.new_tag}",
        "",
        "## Summary",
        "",
    ]

    if previous_tag:
        lines.append(f"- Release range: `{previous_tag}` -> `{args.new_tag}`")
    else:
        lines.append(f"- Release range: initial curated release snapshot for `{args.new_tag}`")
    lines.append(f"- Commits included: {commit_count}")
    if repository and previous_tag:
        lines.append(f"- Compare: https://github.com/{repository}/compare/{previous_tag}...{args.new_tag}")
    lines.extend(["", "## Detailed Changes", ""])

    if not grouped:
        lines.extend(["- No application changes were detected in the selected range.", ""])
    else:
        for category, entries in grouped.items():
            if not entries:
                continue
            lines.extend([f"### {category}", ""])
            for subject, files in entries:
                lines.append(f"- {subject}")
                touched = short_paths(files)
                if touched:
                    lines.append(f"  - Touched: {touched}")
            lines.append("")

    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines).rstrip() + "\n")


if __name__ == "__main__":
    main()
