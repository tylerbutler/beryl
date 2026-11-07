"""Offline tests: only fixture version application may mutate release state."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest.mock import patch

import release_pr


ROOT = Path(__file__).resolve().parents[1]


def package(name, version):
    return {
        "name": name, "version": version,
        "path": f"packages/{name}", "lifecycle": "git_only",
    }


@contextmanager
def directory(path):
    previous = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.packages = {
            "beryl": package("beryl", "0.5.0"),
            "beryl_mist": package("beryl_mist", "0.4.0"),
        }
        self.pending = []
        self.manifests = {}

    def stdout(self, *args):
        if args[:2] == ("trellis", "list"):
            return json.dumps({"packages": list(self.packages.values())})
        if args[:3] == ("trellis", "version", "plan"):
            return json.dumps({"bumped": [{"name": "beryl"}]})
        if args[:3] == ("gh", "pr", "list"):
            return json.dumps(self.pending)
        if args[:2] == ("git", "show"):
            return f'version = "{self.manifests[args[2]]}"'
        raise AssertionError(f"Unexpected command: {args}")

    def prepare(self, event="workflow_dispatch", pre="", versions=""):
        with patch.object(release_pr, "stdout", side_effect=self.stdout), \
             patch.object(release_pr.subprocess, "run") as run:
            prepared = release_pr.prepare(event, pre, versions)
            commands = [call.args[0] for call in run.call_args_list]
        releases = [command for command in commands if command[:3] == ["trellis", "release", "pr"]]
        return prepared, releases

    def test_first_rc_with_separate_targets(self):
        prepared, commands = self.prepare(pre="rc", versions="beryl=1.0.0,beryl_mist=0.5.0")
        self.assertTrue(prepared)
        self.assertEqual(commands[0][-6:], [
            "--pre", "rc", "--set", "beryl=1.0.0", "--set", "beryl_mist=0.5.0",
        ])

    def test_invalid_inputs_never_prepare(self):
        for pre, versions in [
            ("", "unknown=1.0.0"),
            ("", "beryl=1.0.0,beryl=2.0.0"), ("", "beryl="),
        ]:
            with self.subTest(pre=pre, versions=versions), self.assertRaises(ValueError):
                self.prepare(pre=pre, versions=versions)

    def test_hex_lifecycle_is_rejected(self):
        self.packages["beryl"]["lifecycle"] = "hex"
        with self.assertRaisesRegex(RuntimeError, "Hex is disabled"):
            self.prepare()

    def test_non_release_event_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            self.prepare(event="pull_request")

    def test_main_refuses_feature_branch_before_preparation(self):
        with patch.object(release_pr, "stdout", return_value="feature"), \
             patch.object(release_pr, "prepare") as prepare, \
             patch("sys.argv", ["release_pr.py"]):
            with self.assertRaisesRegex(SystemExit, "on main"):
                release_pr.main()
            prepare.assert_not_called()

    def test_workflow_output_reports_skipped_preparation(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            with patch.object(release_pr, "stdout", return_value="main"), \
                 patch.object(release_pr, "prepare", return_value=False), \
                 patch("sys.argv", ["release_pr.py"]), \
                 patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
                release_pr.main()
            self.assertEqual(output.read_text(), "prepared=false\n")

    def test_pending_rc_preserves_targets(self):
        self.pending = [{"headRefOid": "abc", "isCrossRepository": False}]
        self.manifests = {
            "abc:packages/beryl/gleam.toml": "1.0.0-rc.1",
            "abc:packages/beryl_mist/gleam.toml": "0.5.0-rc.1",
        }
        _, commands = self.prepare(event="push")
        self.assertEqual(commands[0][-6:], [
            "--pre", "rc", "--set", "beryl=1.0.0", "--set", "beryl_mist=0.5.0",
        ])

    def test_pending_promotion_preserves_late_package_target(self):
        self.packages["beryl"]["version"] = "1.0.0-rc.2"
        self.pending = [{"headRefOid": "abc", "isCrossRepository": False}]
        self.manifests = {
            "abc:packages/beryl/gleam.toml": "1.0.0",
            "abc:packages/beryl_mist/gleam.toml": "0.5.0",
        }
        _, commands = self.prepare(event="push")
        self.assertEqual(commands[0][-4:], ["--pre", "none", "--set", "beryl_mist=0.5.0"])

    def test_pending_stable_preserves_explicit_target(self):
        self.pending = [{"headRefOid": "abc", "isCrossRepository": False}]
        self.manifests = {
            "abc:packages/beryl/gleam.toml": "1.0.0",
            "abc:packages/beryl_mist/gleam.toml": "0.4.0",
        }
        _, commands = self.prepare(event="push")
        self.assertEqual(commands[0][-2:], ["--set", "beryl=1.0.0"])

    def test_stale_pending_candidate_does_not_promote(self):
        self.packages["beryl"]["version"] = "1.0.0-rc.1"
        self.pending = [{"headRefOid": "abc", "isCrossRepository": False}]
        self.manifests = {
            "abc:packages/beryl/gleam.toml": "1.0.0-rc.1",
            "abc:packages/beryl_mist/gleam.toml": "0.4.0",
        }
        with patch.object(release_pr, "new_candidate_changes", return_value=False):
            self.assertEqual(self.prepare(event="push"), (False, []))

    def test_unchanged_candidate_does_not_prepare(self):
        self.packages["beryl"]["version"] = "1.0.0-rc.1"
        with patch.object(release_pr, "new_candidate_changes", return_value=False):
            self.assertEqual(self.prepare(event="push"), (False, []))

    def test_new_candidate_continues_without_pinning(self):
        self.packages["beryl"]["version"] = "1.0.0-rc.1"
        with patch.object(release_pr, "new_candidate_changes", return_value=True):
            _, commands = self.prepare(event="push")
        self.assertEqual(commands[0][-2:], ["--pre", "rc"])
        self.assertNotIn("--set", commands[0])

    def test_cross_repository_pending_is_ignored(self):
        self.pending = [{"headRefOid": "abc", "isCrossRepository": True}]
        _, commands = self.prepare(event="push")
        self.assertNotIn("--pre", commands[0])

    def test_conflicting_package_modes_fail(self):
        self.packages["beryl"]["version"] = "1.0.0-rc.1"
        self.packages["beryl_mist"]["version"] = "0.5.0-beta.1"
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            self.prepare(event="push")

    def test_empty_plan_does_not_prepare(self):
        with patch.object(release_pr, "stdout", side_effect=[
            json.dumps({"packages": list(self.packages.values())}),
            json.dumps({"bumped": []}),
        ]), patch.object(release_pr.subprocess, "run") as run:
            self.assertFalse(release_pr.prepare("workflow_dispatch"))
            run.assert_not_called()

    def test_invalid_semver_fails_before_mutation(self):
        with patch.object(release_pr, "stdout", side_effect=[
            json.dumps({"packages": list(self.packages.values())}),
            subprocess.CalledProcessError(1, ["trellis", "version", "plan"]),
        ]), patch.object(release_pr.subprocess, "run") as run:
            with self.assertRaises(subprocess.CalledProcessError):
                release_pr.prepare("workflow_dispatch", versions="beryl=not-semver")
            run.assert_not_called()

    def test_native_prerelease_labels_are_preserved(self):
        _, commands = self.prepare(pre="beta")
        self.assertEqual(commands[0][-2:], ["--pre", "beta"])

    def test_invalid_label_fails_before_mutation(self):
        with patch.object(release_pr, "stdout", side_effect=[
            json.dumps({"packages": list(self.packages.values())}),
            subprocess.CalledProcessError(1, ["trellis", "version", "plan"]),
        ]), patch.object(release_pr.subprocess, "run") as run:
            with self.assertRaises(subprocess.CalledProcessError):
                release_pr.prepare("workflow_dispatch", pre="rc; echo bad")
            run.assert_not_called()


class CandidateFragmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cwd = directory(self.temp.name)
        self.cwd.__enter__()
        self.addCleanup(self.cwd.__exit__, None, None, None)
        self.git("init", "-q", "-b", "main")
        Path("packages/beryl").mkdir(parents=True)
        Path(".changes/unreleased").mkdir(parents=True)
        Path("gleam.toml").write_text(
            '[tools.trellis.publish.bundle]\nberyl = ["beryl_protocol"]\n',
        )
        Path("packages/beryl/gleam.toml").write_text('version = "1.0.0-rc.1"\n')
        self.fragment("initial", "beryl")
        self.commit()
        self.packages = {"beryl": package("beryl", "1.0.0-rc.1")}

    def git(self, *args):
        return release_pr.stdout(
            "git", "-c", "user.name=Release test", "-c", "user.email=test@example.invalid",
            *args,
        )

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-q", "-m", "fixture")

    def fragment(self, name, owner):
        Path(f".changes/unreleased/{name}.toml").write_text(
            f'package = "{owner}"\nkind = "Fixed"\nbody = "fixture"\n',
        )

    def test_retained_fragments_and_unrelated_commits_do_not_repeat_rc(self):
        Path("README.md").write_text("Docs only\n")
        self.commit()
        self.assertFalse(release_pr.new_candidate_changes(self.packages))

    def test_new_owned_fragment_continues_rc(self):
        self.fragment("new", "beryl")
        self.commit()
        self.assertTrue(release_pr.new_candidate_changes(self.packages))

    def test_bundle_fragment_continues_rc(self):
        self.fragment("protocol", "beryl_protocol")
        self.commit()
        self.assertTrue(release_pr.new_candidate_changes(self.packages))

    def test_excluded_fragment_does_not_continue_rc(self):
        self.fragment("example", "chatroom")
        self.commit()
        self.assertFalse(release_pr.new_candidate_changes(self.packages))

    def test_deleted_owned_fragment_is_a_change(self):
        Path(".changes/unreleased/initial.toml").unlink()
        self.commit()
        self.assertTrue(release_pr.new_candidate_changes(self.packages))

    def test_new_stable_package_fragment_joins_cycle(self):
        self.packages["beryl_mist"] = package("beryl_mist", "0.4.0")
        self.fragment("mist", "beryl_mist")
        self.commit()
        self.assertTrue(release_pr.new_candidate_changes(self.packages))


class TrellisCycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cwd = directory(self.temp.name)
        self.cwd.__enter__()
        self.addCleanup(self.cwd.__exit__, None, None, None)
        subprocess.run(["git", "init", "-q", "-b", "main"], check=True)
        Path("gleam.toml").write_text(
            '[tools.trellis]\nmembers = ["packages/*"]\n'
            '[tools.trellis.publish]\npackage_tags = ["exact"]\n'
            'repository_tag_package = "beryl"\n'
            'repository_tag_format = "v{series}"\nrepository_tags = ["minor"]\n'
            '[tools.trellis.publish.lifecycle]\ndefault = "git_only"\n'
            '[tools.trellis.changelog]\nstrictness = "warn"\n',
        )
        for name, version in (("beryl", "0.5.0"), ("beryl_mist", "0.4.0")):
            path = Path("packages") / name
            path.mkdir(parents=True)
            dependencies = '[dependencies]\nberyl = { path = "../beryl" }\n' if name == "beryl_mist" else ""
            (path / "gleam.toml").write_text(
                f'name = "{name}"\nversion = "{version}"\n{dependencies}',
            )
        Path(".changes/unreleased").mkdir(parents=True)
        Path(".changes/unreleased/core.toml").write_text(
            'package = "beryl"\nkind = "Added"\nbody = "fixture"\n',
        )
        self.commit()

    def commit(self):
        subprocess.run(["git", "add", "."], check=True)
        subprocess.run([
            "git", "-c", "user.name=Release test", "-c", "user.email=test@example.invalid",
            "commit", "-q", "-m", "fixture",
        ], check=True)

    def trellis(self, *args):
        return release_pr.stdout("trellis", *args)

    def assert_not_published(self, *args):
        result = subprocess.run(
            ["trellis", "publish", *args, "--dry-run"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("so it is never published", result.stderr)

    def test_rc_continuation_promotion_and_tag_plans(self):
        targets = ["--set", "beryl=1.0.0", "--set", "beryl_mist=0.5.0"]
        plan = json.loads(self.trellis("version", "plan", "--json", "--pre", "rc", *targets))
        self.assertEqual(
            {entry["name"]: entry["next"] for entry in plan["bumped"]},
            {"beryl": "1.0.0-rc.0", "beryl_mist": "0.5.0-rc.0"},
        )
        beta = json.loads(self.trellis("version", "plan", "--json", "--pre", "beta", *targets))
        self.assertTrue(all(entry["next"].endswith("-beta.0") for entry in beta["bumped"]))
        self.trellis("version", "apply", "--pre", "rc", *targets)
        self.commit()
        self.assertTrue(Path(".changes/unreleased/core.toml").exists())
        tags = self.trellis("tag", "plan", "--json")
        self.assertIn("beryl-v1.0.0-rc.0", tags)
        self.assertNotIn('"v1.0"', tags)
        self.assertEqual(self.trellis("publish", "--all-untagged", "--dry-run"), "")
        for name, version in (("beryl", "1.0.0"), ("beryl_mist", "0.5.0")):
            self.assert_not_published(name)
            self.assert_not_published("--tag", f"{name}-v{version}-rc.0")
        continued = json.loads(self.trellis("version", "plan", "--json", "--pre", "rc"))
        self.assertTrue(all(entry["next"].endswith("-rc.1") for entry in continued["bumped"]))
        check = json.loads(self.trellis(
            "changelog", "check", "--base", "HEAD~1", "--head", "HEAD", "--format", "json",
        ))
        self.assertTrue(check["ok"])
        self.trellis("version", "apply", "--pre", "none")
        self.commit()
        self.assertFalse(Path(".changes/unreleased/core.toml").exists())
        tags = self.trellis("tag", "plan", "--json")
        self.assertIn('"v1.0"', tags)
        self.assertIn("beryl-v1.0.0", tags)
        self.assertEqual(self.trellis("publish", "--all-untagged", "--dry-run"), "")
        for name, version in (("beryl", "1.0.0"), ("beryl_mist", "0.5.0")):
            self.assert_not_published(name)
            self.assert_not_published("--tag", f"{name}-v{version}")
        check = json.loads(self.trellis(
            "changelog", "check", "--base", "HEAD~1", "--head", "HEAD", "--format", "json",
        ))
        self.assertTrue(check["ok"])
        self.assertEqual(release_pr.stdout("git", "tag", "--list"), "")


class BundledCycleTests(TrellisCycleTests):
    def setUp(self):
        super().setUp()
        with open("gleam.toml", "a") as config:
            config.write(
                '[tools.trellis.publish.bundle]\nberyl = ["beryl_protocol"]\n'
                '[tools.trellis.publish.lifecycle.packages]\n'
                '"packages/beryl_protocol" = "workspace"\n',
            )
        Path("packages/beryl_protocol/src").mkdir(parents=True)
        Path("packages/beryl_protocol/gleam.toml").write_text(
            'name = "beryl_protocol"\nversion = "0.1.0"\n',
        )
        Path("packages/beryl_protocol/src/beryl_protocol.gleam").write_text(
            "pub fn identity(value: a) -> a { value }\n",
        )
        with open("packages/beryl/gleam.toml", "a") as manifest:
            manifest.write('[dependencies]\nberyl_protocol = { path = "../beryl_protocol" }\n')
        self.commit()

    def test_protocol_is_not_independently_released(self):
        packages = json.loads(self.trellis("list", "--releasable", "--json"))["packages"]
        self.assertEqual({package["name"] for package in packages}, {"beryl", "beryl_mist"})
        self.trellis("doctor")
        self.assertNotIn("beryl_protocol-v", self.trellis("tag", "plan", "--json"))


class WorkflowPolicyTests(unittest.TestCase):
    def test_repository_disables_hex_and_preserves_protocol_bundle(self):
        config = tomllib.loads((ROOT / "gleam.toml").read_text())["tools"]["trellis"]
        lifecycle = config["publish"]["lifecycle"]
        self.assertEqual(lifecycle["default"], "git_only")
        self.assertEqual(lifecycle["packages"], {"packages/beryl_protocol": "workspace"})
        self.assertEqual(config["publish"]["bundle"], {"beryl": ["beryl_protocol"]})
        self.assertIn("examples/**", config["exclude"]["@release"])
        self.assertIn("benchmarks/**", config["exclude"]["@release"])

    def test_workflows_do_not_publish_to_hex(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            content = path.read_text()
            self.assertNotRegex(content, r"\b(?:trellis|gleam)\s+publish\b")
        publish = (ROOT / ".github/workflows/publish.yml").read_text()
        self.assertIn("github.event.pull_request.merge_commit_sha", publish)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", publish)
        self.assertIn("trellis tag create --push --github-release", publish)


if __name__ == "__main__":
    unittest.main()
