"""Regression tests for the version proposal, publishing and PR overview."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load_script(name):
    path = Path(__file__).resolve().parents[1] / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_script("propose-release")
notes = load_script("rolling-release-notes")
overview = load_script("repository-overview")


class AutomationTests(unittest.TestCase):
    def test_version_from_native_stack_and_no_release_loop(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                def git(*args):
                    return subprocess.check_output(["git", *args], text=True).strip()

                def commit(subject, filename):
                    path = Path(filename)
                    path.parent.mkdir(exist_ok=True)
                    path.write_text(subject)
                    git("add", filename)
                    git("commit", "-qm", subject)
                    return git("rev-parse", "HEAD")

                git("init", "-q")
                git("config", "user.email", "ci@example.invalid")
                git("config", "user.name", "Automation test")
                base = commit("Initial", "app")
                sources = dict.fromkeys(release.BRANCHES, base)
                for subject, expected in [("fix: update", "v2.1.1"), ("feat: new", "v2.2.0"), ("feat!: change", "v3.0.0")]:
                    head = commit(subject, "app")
                    heads = {**sources, "Go": head}
                    plan, body = release.propose("v2.1.0", sources, heads, "https://example.invalid")
                    self.assertEqual((plan["version"], plan["sources"]), (expected, heads))
                    self.assertIn(f"{base}...{head}", body)
                metadata = commit("chore(release): propose", ".github/release-plan.json")
                self.assertIsNone(release.propose("v3.0.0", heads, {**heads, "Go": metadata}, "https://example.invalid"))
            finally:
                os.chdir(previous)

    def test_dispatch_uses_reviewed_shas_and_rejects_stale_plan(self):
        sources = {stack: str(i) * 40 for i, stack in enumerate(release.BRANCHES, 1)}
        plan = {"previous": "v2.1.0", "version": "v2.2.0", "sources": sources}
        with patch.object(release.subprocess, "run") as dispatch:
            release.publish("owner/repo", "v2.1.0", plan)
            for stack, sha in sources.items():
                self.assertIn(f"{stack.lower()}_ref={sha}", dispatch.call_args.args[0])
            dispatch.reset_mock()
            release.publish("owner/repo", "v2.2.0", plan)
            with self.assertRaises(ValueError):
                release.publish("owner/repo", "v2.1.1", plan)
            dispatch.assert_not_called()

    def test_rolling_notes_preserve_other_platforms_and_manual_copy(self):
        url = "https://example.invalid"
        body = "## 下载\n\n校验文件后安装。\n"
        first = notes.update_notes(body, "go", "a" * 40, url)
        both = notes.update_notes(first, "rust", "b" * 40, url)
        self.assertEqual(both, notes.update_notes(both, "rust", "b" * 40, url))
        self.assertTrue(both.startswith(body))
        self.assertIn("a" * 40, both)

    def test_preview_failure_and_missing_native_checks_are_visible(self):
        checks = [{"name": name, "conclusion": "SUCCESS"} for name in ("contracts", "check")]
        rollup = {"state": "FAILURE", "contexts": {"nodes": checks + [{"context": "Vercel", "state": "FAILURE"}]}}
        pr = {"baseRefName": "Rust", "isDraft": True, "mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE",
              "reviewDecision": None, "commits": {"nodes": [{"commit": {"statusCheckRollup": rollup}}]}}
        self.assertIn("草稿", overview.pull_state(pr))
        self.assertIn("Vercel", overview.pull_state(pr))
        rollup.update(state="SUCCESS", contexts={"nodes": checks[:1]})
        self.assertIn("待核对原生 CI", overview.pull_state(pr))
        rollup["contexts"]["nodes"] = checks
        self.assertIn("检查通过", overview.pull_state(pr))


if __name__ == "__main__":
    unittest.main()
