"""Check branch names and pull request titles."""

import os
import re
import sys


TYPES = "feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert"
BRANCH = rf"(?:{TYPES})/[a-z0-9]+(?:-[a-z0-9]+)*"
TITLE = rf"(?:{TYPES})(?:\([^()\r\n]+\))?!?: \S[^\r\n]*"

checks = [
    (
        BRANCH,
        os.environ.get("PR_BRANCH", ""),
        "Use a branch name such as fix/scan-removal-flows.",
    ),
    (
        TITLE,
        os.environ.get("PR_TITLE", ""),
        "Use a Conventional Commit title, such as fix: clear outdated scan results.",
    ),
]

errors = [message for pattern, value, message in checks if not re.fullmatch(pattern, value)]
for message in errors:
    print(f"::error::{message}")
sys.exit(bool(errors))
