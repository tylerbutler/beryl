"""Preserve release mode across pushes without repeating unchanged candidates."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tomllib


def stdout(*args):
    return subprocess.run(
        args, check=True, stdout=subprocess.PIPE, text=True,
    ).stdout.strip()


def release_mode(version):
    base, _, pre = version.split("+", 1)[0].partition("-")
    return base, pre.rsplit(".", 1)[0]


def shared_mode(versions):
    modes = {release_mode(version)[1] for version in versions}
    modes.discard("")
    if len(modes) > 1:
        raise ValueError(f"Conflicting prerelease modes: {', '.join(sorted(modes))}")
    return next(iter(modes), "")


def parse_targets(value, packages):
    targets = {}
    for spec in value.split(",") if value.strip() else []:
        name, separator, version = spec.strip().partition("=")
        if not separator or name not in packages or not version.strip():
            raise ValueError(f"Expected a releasable package=version target: {spec}")
        if name in targets:
            raise ValueError(f"Duplicate version target: {name}")
        targets[name] = version.strip()
    return targets


def new_candidate_changes(packages):
    candidate_paths = [
        f"{package['path']}/gleam.toml"
        for package in packages.values()
        if release_mode(package["version"])[1]
    ]
    baseline = stdout(
        "git", "log", "-1", "--format=%H", "-G", "^version[[:space:]]*=",
        "--", *candidate_paths,
    )
    if not baseline:
        raise RuntimeError("Cannot find the current candidate's version commit.")
    changed = stdout(
        "git", "diff", "--name-only", baseline, "HEAD", "--",
        ":(glob).changes/unreleased/*.toml",
    ).splitlines()
    config = tomllib.loads(Path("gleam.toml").read_text())["tools"]["trellis"]
    owners = set(packages)
    for owner, bundled in config.get("publish", {}).get("bundle", {}).items():
        if owner in owners:
            owners.update(bundled)
    for path in changed:
        for ref in ("HEAD", baseline):
            if not stdout("git", "ls-tree", "--name-only", ref, "--", path):
                # A fragment may have been added or deleted in this diff.
                continue
            fragment = tomllib.loads(stdout("git", "show", f"{ref}:{path}"))
            if fragment.get("package") in owners:
                return True
    return False


def pending_targets(packages, current_pre):
    pending = json.loads(stdout(
        "gh", "pr", "list", "--head", "release/pending", "--base", "main",
        "--state", "open", "--json", "headRefOid,isCrossRepository",
    ))
    pending = [pr for pr in pending if not pr["isCrossRepository"]]
    if not pending:
        return None
    sha = pending[0]["headRefOid"]
    subprocess.run(["git", "fetch", "--quiet", "origin", sha], check=True)
    changed = {}
    for name, package in packages.items():
        target = tomllib.loads(stdout(
            "git", "show", f"{sha}:{package['path']}/gleam.toml",
        ))["version"]
        if target != package["version"]:
            changed[name] = target
    if not changed:
        return None
    target_pre = shared_mode(changed.values())
    pre = target_pre or ("none" if current_pre else "")
    targets = {
        name: release_mode(version)[0]
        for name, version in changed.items()
        if pre != "none" or not release_mode(packages[name]["version"])[1]
    }
    return pre, targets


def prepare(event, pre="", versions=""):
    if event not in ("push", "workflow_dispatch"):
        raise ValueError(f"Unsupported release preparation event: {event}")
    packages = {
        package["name"]: package
        for package in json.loads(stdout(
            "trellis", "list", "--releasable", "--json",
        ))["packages"]
    }
    if any(package["lifecycle"] != "git_only" for package in packages.values()):
        raise RuntimeError("All releasable packages must use git_only; Hex is disabled.")
    pre = pre.strip()
    targets = parse_targets(versions, packages)
    if event != "workflow_dispatch":
        current_pre = shared_mode(package["version"] for package in packages.values())
        pending = pending_targets(packages, current_pre)
        if pending is not None:
            pre, targets = pending
        elif current_pre:
            if not new_candidate_changes(packages):
                print("No new fragments since the current candidate; nothing to prepare.")
                return False
            pre = current_pre

    args = ["--pre", pre] if pre else []
    for name, version in targets.items():
        args.extend(["--set", f"{name}={version}"])
    # Validate all overrides and suppress empty release PRs before any mutation.
    plan = json.loads(stdout("trellis", "version", "plan", "--json", *args))
    if not plan["bumped"]:
        print("No unreleased changes; nothing to prepare.")
        return False
    subprocess.run([
        "trellis", "release", "pr", "--base", "main", "--branch", "release/pending",
        *args,
    ], check=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pre", default=os.environ.get("INPUT_PRE", ""))
    parser.add_argument("--versions", default=os.environ.get("INPUT_VERSIONS", ""))
    options = parser.parse_args()
    if stdout("git", "branch", "--show-current") != "main":
        raise SystemExit("Run release preparation on main.")
    prepared = prepare(
        os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch"),
        options.pre, options.versions,
    )
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as handle:
            handle.write(f"prepared={str(prepared).lower()}\n")


if __name__ == "__main__":
    main()
