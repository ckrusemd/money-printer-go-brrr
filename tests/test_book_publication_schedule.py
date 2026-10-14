import base64
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import unittest

from scripts import book_publication_schedule as schedule

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hosted_scheduler", ROOT / "scripts/configure-hosted-scheduler.py")
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)


def state(day="2026-10-14"):
    return {"schema": 1, "last_publication_date": day, "source_sha": "a" * 40}


class FakeGitHub:
    repository = "ckrusemd/money-printer-go-brrr"

    def __init__(self, stored=None, branch_exists=False):
        self.stored = stored
        self.branch_exists = branch_exists
        self.calls = []

    def request(self, method, path, payload=None, missing=False):
        self.calls.append((method, path, payload))
        if method == "GET":
            if path == "":
                return {"full_name": self.repository}
            if path.startswith("/git/ref/"):
                return {} if self.branch_exists else None
            if self.stored is None:
                raise RuntimeError("Fixture missing state on existing branch")
            return {"encoding": "base64", "sha": "b" * 40,
                    "content": base64.b64encode(json.dumps(self.stored).encode()).decode()}
        return {"sha": "c" * 40}


class PublicationScheduleTests(unittest.TestCase):
    def test_both_dst_boundaries_preserve_0500_local(self):
        for before, due in (
            ("2026-03-28T03:59:59+00:00", "2026-03-28T04:00:00+00:00"),
            ("2026-03-29T02:59:59+00:00", "2026-03-29T03:00:00+00:00"),
            ("2026-10-24T02:59:59+00:00", "2026-10-24T03:00:00+00:00"),
            ("2026-10-25T03:59:59+00:00", "2026-10-25T04:00:00+00:00"),
        ):
            with self.subTest(due=due):
                self.assertFalse(schedule.decide(datetime.fromisoformat(before), None)[0])
                self.assertTrue(schedule.decide(datetime.fromisoformat(due), None)[0])

    def test_success_duplicate_skips_and_delayed_or_failed_publication_recovers(self):
        now = datetime.fromisoformat("2026-10-14T19:00:00+00:00")
        self.assertFalse(schedule.decide(now, state())[0])
        self.assertTrue(schedule.decide(now, state("2026-10-13"))[0])
        self.assertTrue(schedule.decide(now, None)[0])

    def test_future_invalid_or_malformed_state_fails_closed(self):
        now = datetime.fromisoformat("2026-10-14T03:00:00+00:00")
        for stored in (state("2026-10-15"), {}, state("2026-02-30"),
                       {**state(), "schema": True}, {**state(), "source_sha": "bad"}):
            with self.subTest(stored=stored), self.assertRaises(ValueError):
                schedule.decide(now, stored)

    def test_ordinary_manual_push_and_callback_are_unchanged(self):
        for event_name in ("push", "workflow_run", "workflow_dispatch"):
            self.assertFalse(schedule.scheduled_event(event_name, {}))
        self.assertTrue(schedule.scheduled_event("schedule", {}))
        event = {"ref": "refs/heads/main", "inputs": {
            "scheduled_delivery": "true", "publish": "true", "benchmark": "false"}}
        self.assertTrue(schedule.scheduled_event("workflow_dispatch", event))
        for inputs in ({"publish": "false"}, {"benchmark": "true"}, {"scheduled_delivery": "invalid"}):
            bad = {**event, "inputs": {**event["inputs"], **inputs}}
            with self.assertRaises(ValueError):
                schedule.scheduled_event("workflow_dispatch", bad)
        with self.assertRaises(ValueError):
            schedule.scheduled_event("workflow_dispatch", {**event, "ref": "refs/heads/feature"})

    def test_initial_state_requires_confirmed_repo_and_absent_branch(self):
        api = FakeGitHub()
        self.assertEqual(schedule.read_state(api), (None, None))
        self.assertEqual(api.calls[0][1], "")
        with self.assertRaises(RuntimeError):
            schedule.read_state(FakeGitHub(branch_exists=True))
        with self.assertRaises(RuntimeError):
            schedule.read_state(FakeGitHub(stored={}, branch_exists=True))

    def test_writes_orphan_initial_state_or_compare_and_swap_existing(self):
        api = FakeGitHub()
        schedule.write_state(api, "2026-10-14", "a" * 40)
        writes = [call for call in api.calls if call[0] != "GET"]
        self.assertEqual([call[1] for call in writes], ["/git/trees", "/git/commits", "/git/refs"])
        self.assertEqual(writes[1][2]["parents"], [])
        api = FakeGitHub(state("2026-10-13"), True)
        schedule.write_state(api, "2026-10-14", "a" * 40)
        self.assertEqual(api.calls[-1][0], "PUT")
        self.assertEqual(api.calls[-1][2]["sha"], "b" * 40)
        with self.assertRaises(RuntimeError):
            schedule.write_state(FakeGitHub(state("2026-10-15"), True), "2026-10-14", "a" * 40)

    def test_gate_precedes_container_and_state_follows_success_only(self):
        workflow = (ROOT / ".github/workflows/deploy_bookdown.yml").read_text()
        build = workflow.split("\n  build:\n")[1].split("\n  benchmark:\n")[0]
        self.assertIn("needs.publication-image.outputs.schedule_allowed == 'true'", build)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn('cron: "17 * * * *"', workflow)
        journal = workflow.split("\n  publication-state:\n")[1]
        self.assertIn("needs: [build, deploy]", journal)
        self.assertNotIn("always()", journal)
        self.assertIn("contents: write", journal)
        self.assertIn("needs.build.outputs.as_of", journal)


class HostedProviderTests(unittest.TestCase):
    def test_secret_free_plan_matches_workflow_and_copenhagen_slots(self):
        job = provider.job_spec()
        self.assertFalse(job["enabled"])
        self.assertNotIn("Authorization", job["extendedData"]["headers"])
        self.assertEqual(job["schedule"]["timezone"], "Europe/Copenhagen")
        self.assertEqual(job["schedule"]["hours"], [5])
        self.assertEqual(job["schedule"]["minutes"], [0, 10, 30])
        body = json.loads(job["extendedData"]["body"])
        self.assertEqual(body["ref"], "main")
        self.assertTrue(body["inputs"]["scheduled_delivery"])
        self.assertFalse(body["inputs"]["benchmark"])

    def test_identity_and_incomplete_list_fail_before_writes(self):
        class FakeProvider:
            def __init__(self, result):
                self.result = result
            def request(self, method, path, payload=None):
                if method != "GET":
                    raise AssertionError("Unexpected write")
                return self.result
        job = {**provider.job_spec(), "jobId": 1}
        for result in ({"someFailed": True, "jobs": []}, {"jobs": [job, job]},
                       {"jobs": [{**job, "url": "https://example.invalid"}]}):
            with self.assertRaises(RuntimeError):
                provider.managed_job(FakeProvider(result))
        with self.assertRaises(RuntimeError):
            provider.configure(FakeProvider({"jobs": [job]}), prepare=True)


if __name__ == "__main__":
    unittest.main()
