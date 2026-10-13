"""Regression checks for bounded, artifact-only Pages deployment recovery."""

from pathlib import Path
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/deploy_bookdown.yml"
ACTION = "actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346"


class PagesDeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.deploy = WORKFLOW.read_text().split("\n  deploy:\n", 1)[1]
        cls.first, cls.retry = cls.deploy.split(
            "      - name: Retry Pages deployment once after a failed attempt\n", 1
        )

    def test_retry_only_follows_failure_and_never_cancellation_or_success(self):
        self.assertIn("continue-on-error: true", self.first)
        self.assertIn("if: ${{ !cancelled() && steps.deployment.outcome == 'failure' }}", self.retry)
        for cancelled in (False, True):
            for outcome in ("success", "failure", "cancelled", "skipped"):
                should_retry = not cancelled and outcome == "failure"
                self.assertEqual(should_retry, (cancelled, outcome) == (False, "failure"))

    def test_retry_failure_is_not_silenced(self):
        self.assertNotIn("continue-on-error", self.retry)
        self.assertNotIn("always()", self.deploy)
        self.assertIn("needs: build", self.deploy)

    def test_two_bounded_attempts_use_the_same_uploaded_artifact(self):
        self.assertEqual(self.deploy.count(ACTION), 2)
        self.assertEqual(self.deploy.count("timeout: 240000"), 2)
        self.assertEqual(self.deploy.count("timeout-minutes: 5"), 2)
        self.assertIn("timeout-minutes: 10", self.deploy)
        for unwanted in ("sleep ", "while ", "render_book", "actions/checkout", "artifact_name:"):
            self.assertNotIn(unwanted, self.deploy)
        self.assertIn("pages: write", self.deploy)
        self.assertIn("id-token: write", self.deploy)
        self.assertIn("steps.deployment.outputs.page_url || steps.deployment_retry.outputs.page_url", self.deploy)


if __name__ == "__main__":
    unittest.main()
