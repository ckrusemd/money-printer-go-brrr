"""Defer main-push rendering when the same push requires a new container image.

No remote writes, retries, sleeps, or polling. Fetch only an unavailable before
commit, with a 35-second bound; any unusable comparison defers conservatively.
"""

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess


# Keep exactly synchronized with build-container.yml's push.paths (fixture tested).
IMAGE_INPUTS = frozenset({
    "Dockerfile", ".dockerignore", "renv.lock", "renv/publication.lock",
    "renv/settings.json", "renv/activate.R", ".Rprofile",
    ".github/workflows/build-container.yml",
})
FETCH_TIMEOUT_SECONDS = 35


@dataclass(frozen=True)
class PushDecision:
    render_allowed: bool
    reason: str


def run_git(arguments, repository, timeout):
    return subprocess.run(
        ["git", *arguments], cwd=repository, check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
    )


def decide_push_render(event_name, event, repository):
    if event_name != "push":
        return PushDecision(True, "Non-push event: image-input deferral does not apply.")
    metadata = event.get("repository") if isinstance(event, dict) else None
    branch = metadata.get("default_branch") if isinstance(metadata, dict) else None
    ref = event.get("ref") if isinstance(event, dict) else None
    if not isinstance(branch, str) or not branch or not isinstance(ref, str) or not ref:
        return PushDecision(False, "Unusable push branch metadata; defer rendering to the container workflow.")
    if ref != "refs/heads/" + branch:
        return PushDecision(True, "Non-default-branch push: image-input deferral does not apply.")
    before, after = event.get("before"), event.get("after")
    for name, sha in (("before", before), ("after", after)):
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha) or sha == "0" * 40:
            return PushDecision(False, "Unusable push." + name + "; defer rendering to the container workflow.")
    phase = "inspect checked-out commit"
    try:
        head = run_git(["rev-parse", "HEAD"], repository, timeout=5).stdout.decode().strip()
        if head.lower() != after.lower():
            return PushDecision(False, "Checkout differs from push.after; defer rendering to the container workflow.")
        phase = "inspect push.before"
        try:
            run_git(["cat-file", "-e", before + "^{commit}"], repository, timeout=5)
        except subprocess.CalledProcessError:
            phase = "fetch push.before (35-second limit)"
            run_git(["fetch", "--no-tags", "--depth=1", "origin", before], repository,
                    timeout=FETCH_TIMEOUT_SECONDS)
        phase = "diff complete push range"
        # No rename collapsing: report both deletion and addition, including a
        # container input renamed away. NUL separation handles arbitrary names.
        diff = run_git(["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z",
                        before, after, "--"], repository, timeout=10)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        return PushDecision(False, "Cannot " + phase + " (" + type(error).__name__ +
                            "); defer rendering to the container workflow.")
    paths = {os.fsdecode(path) for path in diff.stdout.split(b"\0") if path}
    changed = sorted(paths & IMAGE_INPUTS)
    if changed:
        return PushDecision(False, "Container image inputs changed: " + ", ".join(changed) +
                            "; defer rendering to the successful same-SHA container callback.")
    return PushDecision(True, "Complete push range has no container image input changes.")


def main():
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()) if event_name == "push" else {}
    except (KeyError, OSError, json.JSONDecodeError, UnicodeError):
        decision = PushDecision(False, "Unusable push event payload; defer rendering to the container workflow.")
    else:
        decision = decide_push_render(event_name, event, os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
    allowed = "true" if decision.render_allowed else "false"
    print("render_allowed=" + allowed + ": " + decision.reason)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("render_allowed=" + allowed + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write("Publication push preflight: " + decision.reason + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
