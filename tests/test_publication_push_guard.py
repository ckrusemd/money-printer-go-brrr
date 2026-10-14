"""Offline push-guard fixtures; all commits/fetches use disposable local repos."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import publication_push_guard as guard


ROOT = Path(__file__).resolve().parents[1]


class PublicationPushGuardTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.repository = self.scratch / "repository"
        self.repository.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Offline fixture")
        self.git("config", "user.email", "fixture@example.test")
        self.git("config", "commit.gpgsign", "false")
        for path in sorted(guard.IMAGE_INPUTS | {"index.Rmd"}):
            self.write(path, "Original " + path + "\n")
        self.before = self.commit()

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.repository, stderr=subprocess.PIPE).decode().strip()

    def write(self, name, text):
        path = self.repository / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "Offline fixture commit")
        return self.git("rev-parse", "HEAD")

    def event(self, before=None, after=None):
        return {"ref": "refs/heads/main", "repository": {"default_branch": "main"},
                "before": before or self.before, "after": after or self.git("rev-parse", "HEAD")}

    def decide(self, event=None):
        return guard.decide_push_render("push", event or self.event(), self.repository)

    def cli(self, event_name, payload=None):
        event_path, output, summary = (self.scratch / name for name in ("event.json", "output", "summary"))
        if payload is not None:
            event_path.write_text(payload)
        result = subprocess.run([sys.executable, str(ROOT / "scripts/publication_push_guard.py")],
                                capture_output=True, text=True, cwd=self.repository,
                                env={**os.environ, "GITHUB_EVENT_NAME": event_name,
                                     "GITHUB_EVENT_PATH": str(event_path), "GITHUB_WORKSPACE": str(self.repository),
                                     "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)})
        return result, output.read_text(), summary.read_text()

    def test_all_image_inputs_exactly_match_container_workflow(self):
        workflow = (ROOT / ".github/workflows/build-container.yml").read_text()
        paths = workflow.split("    paths:\n", 1)[1].split("\n\n", 1)[0]
        declared = {line.strip()[2:].strip("\"'") for line in paths.splitlines() if line.strip().startswith("- ")}
        self.assertEqual(len(guard.IMAGE_INPUTS), 9)
        self.assertEqual(guard.IMAGE_INPUTS, declared)

    def test_every_image_input_defers(self):
        before = self.before
        for path in sorted(guard.IMAGE_INPUTS):
            with self.subTest(path=path):
                self.write(path, "Changed " + path + "\n")
                after = self.commit()
                decision = self.decide(self.event(before, after))
                self.assertFalse(decision.render_allowed)
                self.assertIn(path, decision.reason)
                before = after

    def test_content_only_push_and_empty_diff_allow_render(self):
        self.assertTrue(self.decide().render_allowed)
        self.write("index.Rmd", "Only chapter content changed\n")
        self.commit()
        self.assertTrue(self.decide().render_allowed)

    def test_mixed_multicommit_push_checks_complete_range_not_head_parent(self):
        self.write("Dockerfile", "Image change in first commit\n")
        self.commit()
        self.write("index.Rmd", "Content change in second commit\n")
        self.commit()
        self.assertNotIn("Dockerfile", self.git("diff", "--name-only", "HEAD^", "HEAD"))
        self.assertFalse(self.decide().render_allowed)

    def test_deleted_inputs_defer(self):
        before = self.before
        for path in sorted(guard.IMAGE_INPUTS):
            with self.subTest(path=path):
                (self.repository / path).unlink()
                after = self.commit()
                self.assertFalse(self.decide(self.event(before, after)).render_allowed)
                before = after

    def test_input_renamed_away_defers(self):
        (self.repository / "renv/settings.json").rename(self.repository / "former-settings.json")
        self.commit()
        self.assertFalse(self.decide().render_allowed)

    def test_file_renamed_into_input_defers(self):
        (self.repository / "Dockerfile").unlink()
        before = self.commit()
        (self.repository / "index.Rmd").rename(self.repository / "Dockerfile")
        after = self.commit()
        self.assertFalse(self.decide(self.event(before, after)).render_allowed)

    def test_nonpush_events_do_no_git_work_and_default_true(self):
        with patch.object(guard, "run_git", side_effect=AssertionError("Unexpected git work")):
            for event_name in ("workflow_run", "workflow_dispatch", "schedule", "pull_request"):
                self.assertTrue(guard.decide_push_render(event_name, {}, self.repository).render_allowed)

    def test_nondefault_branch_push_is_unchanged(self):
        event = self.event()
        event["ref"] = "refs/heads/feature"
        with patch.object(guard, "run_git", side_effect=AssertionError("Unexpected git work")):
            self.assertTrue(self.decide(event).render_allowed)

    def test_invalid_zero_or_missing_shas_defer_without_git(self):
        with patch.object(guard, "run_git", side_effect=AssertionError("Unexpected git work")):
            for field in ("before", "after"):
                for value in (None, "", "0" * 40, "HEAD^", "--help"):
                    with self.subTest(field=field, value=value):
                        event = self.event(after=self.before)
                        event[field] = value
                        decision = self.decide(event)
                        self.assertFalse(decision.render_allowed)
                        self.assertIn("push." + field, decision.reason)
            self.assertFalse(guard.decide_push_render("push", {}, self.repository).render_allowed)

    def test_checkout_must_match_push_after(self):
        self.write("index.Rmd", "New checkout\n")
        self.commit()
        decision = self.decide(self.event(after=self.before))
        self.assertFalse(decision.render_allowed)
        self.assertIn("Checkout differs", decision.reason)

    def test_unavailable_before_is_fetched_from_local_shallow_origin(self):
        self.write("Dockerfile", "New image\n")
        after = self.commit()
        shallow = self.scratch / "shallow"
        subprocess.run(["git", "clone", "--quiet", "--depth=1", self.repository.as_uri(), str(shallow)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with patch.object(guard, "run_git", wraps=guard.run_git) as runner:
            decision = guard.decide_push_render("push", self.event(after=after), shallow)
        self.assertFalse(decision.render_allowed)
        fetches = [call for call in runner.call_args_list if call.args[0][0] == "fetch"]
        self.assertEqual(len(fetches), 1)
        self.assertEqual(fetches[0].kwargs["timeout"], 35)
        self.assertEqual(fetches[0].args[0], ["fetch", "--no-tags", "--depth=1", "origin", self.before])

    def test_fetch_failure_or_timeout_defers_without_retry(self):
        real_git = guard.run_git
        for failure in (subprocess.CalledProcessError(1, "git fetch"),
                        subprocess.TimeoutExpired("git fetch", 35)):
            with self.subTest(failure=type(failure).__name__):
                def run(arguments, repository, timeout):
                    if arguments[0] == "fetch":
                        raise failure
                    return real_git(arguments, repository, timeout)
                with patch.object(guard, "run_git", side_effect=run) as runner:
                    decision = self.decide(self.event(before="f" * 40))
                self.assertFalse(decision.render_allowed)
                self.assertIn("fetch push.before", decision.reason)
                self.assertEqual(sum(call.args[0][0] == "fetch" for call in runner.call_args_list), 1)

    def test_diff_failure_defers_conservatively(self):
        real_git = guard.run_git
        def run(arguments, repository, timeout):
            if arguments[0] == "diff":
                raise subprocess.CalledProcessError(1, "git diff")
            return real_git(arguments, repository, timeout)
        with patch.object(guard, "run_git", side_effect=run):
            decision = self.decide()
        self.assertFalse(decision.render_allowed)
        self.assertIn("diff complete push range", decision.reason)

    def test_cli_deferral_is_successful_and_writes_output_and_diagnostic(self):
        self.write("Dockerfile", "Changed image\n")
        self.commit()
        result, output, summary = self.cli("push", json.dumps(self.event()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "render_allowed=false\n")
        self.assertIn("same-SHA container callback", summary)

    def test_cli_nonpush_defaults_true_without_event_file(self):
        result, output, _ = self.cli("workflow_run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "render_allowed=true\n")

    def test_cli_unusable_push_payload_defers_successfully(self):
        for payload in ("{", "[]", '{"repository":{"default_branch":1},"ref":"refs/heads/main"}'):
            with self.subTest(payload=payload):
                # Outputs append in Actions; each isolated invocation gets new files.
                for name in ("output", "summary"):
                    (self.scratch / name).unlink(missing_ok=True)
                result, output, summary = self.cli("push", payload)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "render_allowed=false\n")
                self.assertIn("Unusable push", summary)


if __name__ == "__main__":
    unittest.main()
