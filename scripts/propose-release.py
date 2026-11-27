"""Prepare one version PR from the four source branches since the latest stable release."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


BRANCHES = {"Nuxt": "master", "Go": "codex/go", "Rust": "Rust", "Flutter": "Flutter"}
PLAN = Path(".github/release-plan.json")
SHA = r"[0-9a-f]{40}"


def git(*args):
    return subprocess.check_output(["git", *args], encoding="utf-8").strip()


def version_parts(tag):
    if not re.fullmatch(r"v(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){2}", tag):
        raise ValueError(f"Expected a stable release tag, got {tag}")
    return tuple(map(int, tag[1:].split(".")))


def published_sources(notes):
    sources = {}
    for stack in BRANCHES:
        matches = re.findall(rf"^- {stack} — \[({SHA})\]\(", notes, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"Expected one published source commit for {stack}")
        sources[stack] = matches[0]
    return sources


def propose(latest, sources, heads, repo_url):
    major, minor, patch = version_parts(latest)
    breaking = feature = False
    rows = []
    for stack, base in sources.items():
        head = heads[stack]
        subprocess.run(["git", "merge-base", "--is-ancestor", base, head], check=True)
        # Exclude the proposal file so merging a release PR cannot start a release cycle.
        messages = git("log", "--first-parent", "--format=%B%x00", f"{base}..{head}",
                       "--", ".", ":(exclude).github/release-plan.json")
        if not messages:
            continue
        breaking |= bool(re.search(r"^(?:[\w-]+(?:\([^\n)]*\))?!:|BREAKING[ -]CHANGE:)", messages, re.M))
        feature |= bool(re.search(r"^feat(?:\([^\n)]*\))?:", messages, re.M))
        link = f"{repo_url}/compare/{base}...{head}"
        rows.append(f"- {stack} · [查看 {messages.count(chr(0))} 个提交]({link})")
    if not rows:
        return None
    if breaking:
        version = f"v{major + 1}.0.0"
    elif feature:
        version = f"v{major}.{minor + 1}.0"
    else:
        version = f"v{major}.{minor}.{patch + 1}"
    plan = {"version": version, "previous": latest, "sources": heads}
    body = (f"合并此 PR 将使用下列四栈源码快照构建 **{version}**，并在资产校验通过后发布独立的 GitHub Release。\n\n"
            f"自 [{latest}]({repo_url}/releases/tag/{latest}) 以来的变更\n\n" + "\n".join(rows) + "\n")
    return plan, body


def publish(repo, latest_tag, plan):
    version = plan["version"]
    if version_parts(version) <= version_parts(plan["previous"]):
        raise ValueError("A release must advance the stable version")
    if version == latest_tag:
        print(f"{version} is already published.")
        return
    if plan["previous"] != latest_tag:
        raise ValueError("The proposal was based on a different stable version")
    args = ["gh", "workflow", "run", "release.yml", "--repo", repo, "--ref", "master",
            "-f", f"version={version}", "-f", "prerelease=false"]
    for stack in BRANCHES:
        sha = plan["sources"][stack]
        if not re.fullmatch(SHA, sha):
            raise ValueError(f"Invalid {stack} source commit")
        args.extend(["-f", f"{stack.lower()}_ref={sha}"])
    subprocess.run(args, check=True)


def prepare(repo, latest):
    tag = latest["tag_name"]
    last_plan = json.loads(PLAN.read_text(encoding="utf-8")) if PLAN.exists() else None
    if last_plan and version_parts(last_plan["version"]) > version_parts(tag):
        print(f"Waiting for the merged release {last_plan['version']} to finish.")
    else:
        sources = published_sources(latest["body"])
        heads = {stack: git("rev-parse", f"origin/{branch}") for stack, branch in BRANCHES.items()}
        proposal = propose(tag, sources, heads, f"{os.environ['GITHUB_SERVER_URL']}/{repo}")
        if proposal:
            plan, body = proposal
            PLAN.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
            Path(os.environ["RUNNER_TEMP"], "release-pr.md").write_text(body, encoding="utf-8")
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as outputs:
                print(f"version={plan['version']}", file=outputs)
        else:
            print(f"No unreleased changes after {tag}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    latest = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/releases/latest"]))
    if args.publish:
        publish(repo, latest["tag_name"], json.loads(PLAN.read_text(encoding="utf-8")))
    else:
        prepare(repo, latest)
