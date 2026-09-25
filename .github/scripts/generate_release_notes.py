#!/usr/bin/env python3
"""Build test-release notes from commits since the preceding reachable tag."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import defaultdict

TAG_PATTERN = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
REPO_PATTERN = re.compile(r"^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$")
CONVENTIONAL = re.compile(r"^(feat|fix|perf|refactor|docs|test|build|ci|chore)(?:\(([^)]+)\))?!?:\s*(.+)$", re.I)
CATEGORIES = (
    ("feat", "Features"),
    ("fix", "Fixes"),
    ("perf", "Performance"),
    ("refactor", "Internal changes"),
    ("docs", "Documentation"),
    ("test", "Tests"),
    ("build", "Maintenance"),
    ("ci", "Maintenance"),
    ("chore", "Maintenance"),
    ("other", "Other changes"),
)


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], text=True, encoding="utf-8"
    ).strip()


def escape_markdown(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("[", "\\[")
        .replace("]", "\\]")
        .replace("`", "\\`")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("@", "&#64;")
    )


def previous_tag(tag: str) -> str | None:
    candidates = [
        name
        for name in git("tag", "--merged", tag, "--sort=-version:refname").splitlines()
        if TAG_PATTERN.fullmatch(name)
    ]
    try:
        index = candidates.index(tag)
    except ValueError as error:
        raise ValueError(f"Tag {tag} is missing from reachable tag history") from error
    return candidates[index + 1] if index + 1 < len(candidates) else None


def release_notes(tag: str, repository: str) -> str:
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError(f"Invalid release tag: {tag}")
    if not REPO_PATTERN.fullmatch(repository):
        raise ValueError(f"Invalid repository name: {repository}")
    git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    prior = previous_tag(tag)
    revision_range = f"{prior}..{tag}" if prior else tag
    commits = git(
        "log", "--no-merges", "--format=%H%x09%s", revision_range
    ).splitlines()
    groups: dict[str, list[str]] = defaultdict(list)
    for item in commits:
        sha, subject = item.split("\t", 1)
        match = CONVENTIONAL.fullmatch(subject)
        kind = match.group(1).lower() if match else "other"
        if match:
            scope = match.group(2)
            title = match.group(3)
            if scope:
                scope = {"macos": "macOS", "windows": "Windows", "ui": "UI"}.get(
                    scope.lower(), scope
                )
                title = f"{scope}: {title}"
        else:
            title = subject
        commit_url = f"https://github.com/{repository}/commit/{sha}"
        groups[kind].append(f"- {escape_markdown(title)} ([{sha[:7]}]({commit_url}))")

    heading = f"## Changes since {prior}" if prior else "## Changes in this release"
    lines = [f"NetPilot {tag} test build.", "", heading, ""]
    emitted = set()
    for kind, label in CATEGORIES:
        if kind in ("build", "ci", "chore"):
            if "Maintenance" in emitted:
                continue
            entries = groups["build"] + groups["ci"] + groups["chore"]
        else:
            entries = groups[kind]
        if not entries:
            continue
        lines.extend((f"### {label}", "", *entries, ""))
        emitted.add(label)
    if not commits:
        lines.extend(("No source changes since the preceding tag.", ""))
    if prior:
        lines.extend(
            (
                f"[Compare {prior}...{tag}](https://github.com/{repository}/compare/{prior}...{tag})",
                "",
            )
        )
    lines.extend(
        (
            "## Test package notes",
            "",
            "- **macOS:** This DMG includes Rules, dependency discovery, Sub-rules, and Networks. App Routing is unavailable. It is Apple Development signed, not Developer ID notarized; installation and helper approval may require Privacy & Security.",
            "- **Windows:** The WFP driver uses the test certificate included in this release. Install on a test machine in Test Mode after trusting that certificate. Live routing and installer acceptance remain pending.",
            "- Verify downloads against `SHA256SUMS.txt`.",
            "",
        )
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    try:
        sys.stdout.write(release_notes(args.tag, args.repository))
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Could not generate release notes: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
