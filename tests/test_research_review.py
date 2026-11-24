from datetime import datetime, timezone
import hashlib
import io
import json
import unittest
import zipfile

from scripts.research_review import due, trusted_run, validate_archive, week_start
from scripts.research_statbank import Forms


class ResearchReviewTests(unittest.TestCase):
    def run_record(self):
        return dict(id=123, conclusion="success", status="completed", head_branch="main",
                    path=".github/workflows/research-review.yml", event="workflow_dispatch",
                    head_sha="a" * 40, repository={"full_name": "ckrusemd/money-printer-go-brrr"},
                    head_repository={"full_name": "ckrusemd/money-printer-go-brrr"},
                    created_at="2026-10-25T02:00:00Z")

    def test_copenhagen_sunday_dst_transition_and_completed_review(self):
        # 25 October is the autumn clock change: both local 02:00 hours are due.
        first = datetime(2026, 10, 25, 0, 5, tzinfo=timezone.utc)
        second = datetime(2026, 10, 25, 1, 5, tzinfo=timezone.utc)
        self.assertTrue(due(first, []))
        self.assertTrue(due(second, []))
        self.assertFalse(due(datetime(2026, 10, 24, 23, 5, tzinfo=timezone.utc), []))
        self.assertFalse(due(second, [self.run_record()]))
        self.assertEqual(week_start(first).date(), week_start(second).date())
        self.assertFalse(due(datetime(2026, 10, 26, 8, tzinfo=timezone.utc), []))

    def test_only_successful_same_repository_main_runs_are_trusted(self):
        run = self.run_record()
        self.assertTrue(trusted_run(run))
        for key, value in {"head_branch": "feature", "event": "pull_request",
                           "path": ".github/workflows/book-ci.yml", "conclusion": "failure",
                           "head_repository": {"full_name": "attacker/fork"}}.items():
            with self.subTest(key=key):
                self.assertFalse(trusted_run({**run, key: value}))

    def bundle(self, extra=None):
        run = self.run_record()
        summary = {"signature": "fixture", "review_date": "2026-10-25"}
        values = {"review.rds": b"fixture-rds", "scores.csv": b"fixture-csv",
                  "summary.json": json.dumps(summary).encode()}
        receipt = dict(schema=1, repository="ckrusemd/money-printer-go-brrr",
                       workflow=run["path"], source_sha=run["head_sha"], run_id="123",
                       **summary, sha256={k: hashlib.sha256(v).hexdigest() for k, v in values.items()})
        values["provenance.json"] = json.dumps(receipt).encode()
        if extra:
            values.update(extra)
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            for name, value in values.items():
                archive.writestr(name, value)
        data = stream.getvalue()
        return data, {"digest": "sha256:" + hashlib.sha256(data).hexdigest()}, run

    def test_archive_and_member_hashes_bind_review_to_successful_run(self):
        data, artifact, run = self.bundle()
        self.assertEqual(validate_archive(data, artifact, run)["review.rds"], b"fixture-rds")
        with self.assertRaises(ValueError):
            validate_archive(data, {"digest": "sha256:" + "0" * 64}, run)
        with self.assertRaises(ValueError):
            validate_archive(data, artifact, {**run, "head_sha": "b" * 40})
        with self.assertRaises(ValueError):
            validate_archive(*self.bundle({"../escape": b"bad"}))
        with self.assertRaises(ValueError):
            validate_archive(*self.bundle({"review.rds": b"modified"}))

    def test_public_statbank_form_keeps_hidden_fields_and_category_codes(self):
        form = Forms()
        form.feed('<form name="main" action="save.asp"><input type="hidden" name="TS" value="x">'
                  '<select name="var1"><option value="00">All<option value="01">Other</select></form>')
        self.assertEqual(form.forms["main"]["fields"], [("TS", "x")])
        self.assertEqual(form.forms["main"]["options"], {"var1": ["00", "01"]})


if __name__ == "__main__":
    unittest.main()
