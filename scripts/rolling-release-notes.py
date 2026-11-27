"""Update one platform's build provenance in the rolling release description."""

import argparse
import re
import sys


STACKS = {
    "nuxt": ("Nuxt", "master"),
    "go": ("Go", "codex/go"),
    "rust": ("Rust", "Rust"),
    "flutter": ("Flutter", "Flutter"),
}
HEADING = "## 当前构建源码提交"


def update_notes(body, stack, sha, repository_url):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Expected the full commit SHA of the uploaded build")
    name, branch = STACKS[stack]
    prefix = f"- {name} (`{branch}`) — "
    row = f"{prefix}[{sha}]({repository_url}/commit/{sha})"
    lines = body.splitlines(keepends=True)
    headings = [
        i for i, line in enumerate(lines)
        if re.fullmatch(HEADING + r"(?:（\d{4}-\d{2}-\d{2}）)?", line.rstrip("\r\n"))
    ]
    if not headings:
        return body.rstrip("\r\n") + ("\n\n" if body.strip() else "") + f"{HEADING}\n\n{row}\n"
    if len(headings) != 1:
        raise ValueError("Multiple build provenance sections in rolling release notes")
    start = headings[0]
    lines[start] = HEADING + "\n"
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^#{1,2}\s", lines[i])), len(lines))
    matches = [i for i in range(start + 1, end) if lines[i].startswith(prefix)]
    if len(matches) > 1:
        raise ValueError(f"Multiple build provenance rows for {name}")
    if matches:
        lines[matches[0]] = row + "\n"
    else:
        lines.insert(start + 1, "\n" + row + "\n")
    return "".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stack", choices=STACKS)
    parser.add_argument("sha")
    parser.add_argument("repository_url")
    args = parser.parse_args()
    sys.stdout.write(update_notes(sys.stdin.read(), args.stack, args.sha, args.repository_url))
