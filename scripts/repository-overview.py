"""Render the live GitHub branch, PR, CI and release overview."""

import argparse
import html
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote, urlencode


STACKS = {"master": "nuxt", "codex/go": "go", "Rust": "rust", "Flutter": "flutter"}
MARKER = "<!-- nekotribe-repository-overview -->"
PR_QUERY = """
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $endCursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title isDraft headRefName baseRefName headRepository { nameWithOwner }
        mergeable mergeStateStatus reviewDecision
        commits(last: 1) { nodes { commit { statusCheckRollup {
          state contexts(first: 100) { nodes {
            ... on CheckRun { name status conclusion }
            ... on StatusContext { context state }
          } }
        } } } }
      }
    }
  }
}
"""


def api(*args, data=None):
    return json.loads(subprocess.check_output(
        ["gh", "api", *args], input=json.dumps(data).encode() if data is not None else None
    ))


def plain(value):
    text = html.escape(" ".join(value.split()), quote=False).replace("@", "@\u200b")
    return re.sub(r"([\\`*_\[\]()|~])", r"\\\1", text)


def pull_state(pr):
    nodes = pr["commits"]["nodes"]
    rollup = nodes[0]["commit"]["statusCheckRollup"] if nodes else None
    flags = []
    if pr["isDraft"]:
        flags.append("草稿")
    if pr["mergeable"] == "CONFLICTING":
        flags.append("有合并冲突")
    if pr["reviewDecision"] == "CHANGES_REQUESTED":
        flags.append("评审要求修改")
    checks = rollup["contexts"]["nodes"] if rollup else []
    failures = []
    passed = set()
    for item in checks:
        name = item.get("name") or item.get("context", "")
        state = item.get("conclusion") or item.get("state") or item.get("status")
        if state in {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"}:
            failures.append(plain(name))
        elif state == "SUCCESS":
            passed.add(name)
    if failures:
        flags.append("失败或中止 · " + "、".join(dict.fromkeys(failures)))
    elif not rollup or rollup["state"] in {"PENDING", "EXPECTED"}:
        flags.append("等待检查")
    elif rollup["state"] != "SUCCESS":
        flags.append("检查异常")
    elif pr["baseRefName"] in STACKS and not {"contracts", "check"} <= passed:
        flags.append("待核对原生 CI")
    else:
        flags.append("检查通过")
    if pr["mergeStateStatus"] == "BEHIND":
        flags.append("基线已更新")
    return "；".join(flags)


def run_link(run, url):
    if run is None:
        return "尚无运行记录"
    state = run["conclusion"] or run["status"]
    return f"[{plain(state)}]({url}/actions/runs/{int(run['id'])})"


def latest_run(base, workflow, **filters):
    query = urlencode({"per_page": 1, **filters})
    runs = api(f"{base}/actions/workflows/{workflow}.yml/runs?{query}")["workflow_runs"]
    return runs[0] if runs else None


def render(repo):
    owner, name = repo.split("/")
    url = f"https://github.com/{repo}"
    base = f"repos/{repo}"
    pages = api("graphql", "--paginate", "--slurp", "-f", f"query={PR_QUERY}",
                "-f", f"owner={owner}", "-f", f"name={name}")
    prs = [pr for page in pages for pr in page["data"]["repository"]["pullRequests"]["nodes"]]
    branches = {b["name"]: b["commit"]["sha"] for page in
                api(f"{base}/branches?per_page=100", "--paginate", "--slurp") for b in page}
    stable = api(f"{base}/releases/latest")["tag_name"]
    lines = [MARKER, f"**{len(branches)} 条远端分支 · {len(prs)} 个开放 PR**", "",
             f"[最新正式版 {plain(stable)}]({url}/releases/latest) · [滚动版]({url}/releases/tag/rolling-latest) · "
             f"[历史版本]({url}/releases) · [所有构建]({url}/actions)", "",
             "## 主分支构建", "", "| 分支 | 当前提交 | 最近一次推送构建 |", "| --- | --- | --- |"]
    for branch, stack in STACKS.items():
        sha = branches[branch]
        run = latest_run(base, f"ci-{stack}", branch=branch, event="push")
        state = run_link(run, url)
        if run and run["head_sha"] != sha:
            state = f"等待当前提交 · 上次 {state}"
        lines.append(f"| {plain(branch)} | [{sha[:8]}]({url}/commit/{sha}) | {state} |")
    lines.extend(["", "## 发版与审计", ""])
    for title, workflow in (("正式版打包", "release"), ("版本提议", "release-pr"), ("依赖审计", "dependency-audit")):
        lines.append(f"- [{title}]({url}/actions/workflows/{workflow}.yml) · {run_link(latest_run(base, workflow), url)}")
    lines.extend(["", "## 开放 PR", ""])
    if prs:
        lines.extend(["| PR | 源分支 → 目标分支 | 检查与评审 |", "| --- | --- | --- |"])
    else:
        lines.append("当前没有开放 PR。")
    covered = set(STACKS)
    for pr in prs:
        source = pr["headRefName"]
        head_repo = (pr["headRepository"] or {}).get("nameWithOwner")
        if head_repo == repo:
            covered.add(source)
        elif head_repo:
            source = f"{head_repo}:{source}"
        n = pr["number"]
        lines.append(f"| [#{n}]({url}/pull/{n}) {plain(pr['title'])} | {plain(source)} → "
                     f"{plain(pr['baseRefName'])} | {pull_state(pr)} · [详情]({url}/pull/{n}/checks) |")
    remaining = sorted(set(branches) - covered)
    lines.extend(["", "## 没有开放 PR 的其他远端分支", ""])
    for branch in remaining:
        lines.append(f"- [{plain(branch)}]({url}/tree/{quote(branch, safe='')}) · {branches[branch][:8]}")
    if not remaining:
        lines.append("当前非主分支均有关联的开放 PR。")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), required=not os.getenv("GITHUB_REPOSITORY"))
    parser.add_argument("--issue", type=int)
    args = parser.parse_args()
    report = render(args.repo)
    if not args.issue:
        print(report, end="")
    else:
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
            summary.write(report)
        if len(report.encode()) > 60000:
            link = f"https://github.com/{args.repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
            report = report.encode()[:58000].decode(errors="ignore").rsplit("\n", 1)[0] + f"\n\n[查看完整总览]({link})\n"
        endpoint = f"repos/{args.repo}/issues/{args.issue}"
        issue = api(endpoint)
        if "pull_request" in issue or not (issue["body"] or "").startswith(MARKER):
            raise ValueError("The configured issue does not contain the repository overview marker")
        if issue["body"].replace("\r\n", "\n") != report:
            api(endpoint, "--method", "PATCH", "--input", "-", data={"body": report})
