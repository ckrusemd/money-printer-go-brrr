"""Offline tests of the actual candidate-image resolver embedded in CI."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/deploy_bookdown.yml"
REPOSITORY = "ghcr.io/ckrusemd/money-printer-go-brrr-r:"


class PublicationImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        resolver = cls.workflow.split("  publication-image:\n", 1)[1].split("\n  build:\n", 1)[0]
        cls.resolver = textwrap.dedent(resolver.split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0])

    def resolve(self, tag="latest", allow=True, default="latest"):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            result = subprocess.run(
                [sys.executable, "-c", self.resolver], capture_output=True, text=True,
                env={**os.environ, "PUBLICATION_TAG": tag,
                     "ALLOW_PUBLICATION_TAG": "true" if allow else "false",
                     "DEFAULT_PUBLICATION_TAG": default, "GITHUB_OUTPUT": str(output)},
            )
            return result, output.read_text() if output.exists() else ""

    def test_default_and_valid_candidate_tags_stay_in_fixed_repository(self):
        for tag in ("latest", "candidate-" + "a" * 40, "v1.2_3", "a" * 128):
            with self.subTest(tag=tag):
                result, output = self.resolve(tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "image=" + REPOSITORY + tag + "\n")

    def test_invalid_tags_cannot_change_repository_or_inject_outputs(self):
        for tag in ("", "a" * 129, ".hidden", "-tag", "other/image:tag",
                    REPOSITORY + "latest", "tag@sha256:abc", "tag:other",
                    "tag\nimage=evil", "tag with spaces", "$(echo evil)", "täg"):
            with self.subTest(tag=tag):
                result, output = self.resolve(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")

    def test_publish_requires_promoted_digest_and_ignores_candidate(self):
        # Bootstrap configurations cannot accidentally deploy an unvalidated image.
        from scripts.notebooks.image import pinned
        try:
            expected = pinned()
        except ValueError:
            expected = None
        result, output = self.resolve("candidate-fixture", allow=False)
        if expected is None:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Publication is not promoted", result.stderr)
            self.assertEqual(output, "")
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output, "image=" + expected + "\n")

    def test_workflow_limits_override_and_wires_both_consumers(self):
        self.assertIn("ALLOW_PUBLICATION_TAG: ${{ github.event_name == 'workflow_dispatch' && (inputs.benchmark || !inputs.publish) }}", self.workflow)
        self.assertIn("DEFAULT_PUBLICATION_TAG: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || 'latest' }}", self.workflow)
        build = self.workflow.split("\n  build:\n", 1)[1].split("\n  benchmark:\n", 1)[0]
        benchmark = self.workflow.split("\n  benchmark:\n", 1)[1].split("\n  deploy:\n", 1)[0]
        self.assertIn("needs: publication-image", build)
        self.assertIn("image: ${{ needs.publication-image.outputs.image }}", build)
        self.assertIn("needs: publication-image", benchmark)
        self.assertIn("PUBLICATION_IMAGE: ${{ needs.publication-image.outputs.image }}", benchmark)
        self.assertIn('docker pull "$PUBLICATION_IMAGE"', benchmark)
        self.assertIn('"$PUBLICATION_IMAGE" --vanilla', benchmark)
        self.assertIn("--network none", benchmark)
        self.assertIn("completed_benchmark_run_id:", self.workflow)
        render = benchmark.split("      - name: Render eight fixed-input books only without network\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: inputs.completed_benchmark_run_id == ''", render)
        self.assertIn("scripts/benchmark_book.R render-only", render)
        recovery = benchmark.split("      - name: Authenticate completed benchmark archive without rendering\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: inputs.completed_benchmark_run_id != ''", recovery)
        self.assertIn("benchmark_provenance.py recover", recovery)
        self.assertNotIn("render-only", recovery)
        self.assertIn("namespace: [indicators-correlations, etf-correlations]", benchmark)
        self.assertIn("fail-fast: false", benchmark)
        self.assertIn("needs: [benchmark, benchmark-audit]", benchmark)
        self.assertIn("scripts/benchmark_book.R aggregate", benchmark)
        self.assertIn("scripts/benchmark_book.R verify", benchmark)
        self.assertIn("Rscript --vanilla scripts/check_publication_closure.R", build)
        self.assertIn("github.event.workflow_run.head_sha == github.sha", build)
        self.assertIn("github.event.workflow_run.head_repository.full_name == github.repository", build)
        self.assertIn("github.event.workflow_run.repository.full_name == github.repository", build)
        self.assertIn("github.event.workflow_run.head_branch == github.event.repository.default_branch", build)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", build)
        self.assertIn("github.event.workflow_run.event != 'pull_request'", build)

    def test_push_preflight_gates_before_container_start_and_leaves_other_events_alone(self):
        preflight = self.workflow.split("  publication-image:\n", 1)[1].split("\n  build:\n", 1)[0]
        build = self.workflow.split("\n  build:\n", 1)[1].split("\n  benchmark:\n", 1)[0]
        self.assertIn("timeout-minutes: 2", preflight)
        self.assertIn("render_allowed: ${{ github.event_name != 'push' && 'true' || steps.push_guard.outputs.render_allowed || 'false' }}", preflight)
        self.assertEqual(preflight.count("if: github.event_name == 'push'"), 2)
        self.assertEqual(preflight.count("timeout-minutes: 1"), 3)
        self.assertIn("ref: ${{ github.sha }}", preflight)
        self.assertIn("fetch-depth: 1", preflight)
        self.assertIn("run: python3 scripts/publication_push_guard.py", preflight)
        self.assertIn("needs.publication-image.outputs.render_allowed == 'true' &&", build)
        self.assertLess(build.index("outputs.render_allowed"), build.index("    container:"))

    def test_namespace_audits_and_aggregate_are_separate_jobs_with_complete_proofs(self):
        benchmark = self.workflow.split("\n  benchmark:\n", 1)[1].split("\n  benchmark-audit:\n", 1)[0]
        audit = self.workflow.split("\n  benchmark-audit:\n", 1)[1].split("\n  benchmark-aggregate:\n", 1)[0]
        aggregate = self.workflow.split("\n  benchmark-aggregate:\n", 1)[1].split("\n  deploy:\n", 1)[0]
        self.assertIn("scripts/benchmark_book.R verify", benchmark)
        self.assertNotIn("scripts/benchmark_book.R audit", benchmark)
        self.assertIn("needs: benchmark", audit)
        self.assertIn("namespace: [indicators-correlations, etf-correlations]", audit)
        self.assertIn("fail-fast: false", audit)
        self.assertIn("scripts/benchmark_book.R audit", audit)
        self.assertIn('"$NAMESPACE"', audit)
        self.assertIn("name: book-benchmark-audit-${{ matrix.namespace }}", audit)
        self.assertIn("needs: [benchmark, benchmark-audit]", aggregate)
        self.assertIn("scripts/benchmark_book.R aggregate", aggregate)
        self.assertIn("name: book-benchmark-parity", aggregate)
        self.assertIn("pattern: book-benchmark-audit-*", aggregate)
        self.assertIn("merge-multiple: true", aggregate)
        for job in (audit, aggregate):
            self.assertIn("--network none", job)
            self.assertIn("name: book-benchmark-receipts", job)
            self.assertIn("name: book-provider-snapshots", job)
            self.assertNotIn("render-only", job)

    def test_failed_snapshots_are_diagnostic_only(self):
        def step(name):
            return self.workflow.split("      - name: " + name + "\n", 1)[1].split("\n      - name:", 1)[0]

        successful = step("Retain successful provider snapshots")
        # No status override: GitHub's default success() skips this on failure.
        self.assertNotIn("\n        if:", successful)
        self.assertIn("name: book-provider-snapshots\n", successful)
        self.assertIn("if-no-files-found: error", successful)
        self.assertIn("retention-days: 14", successful)

        diagnostic = step("Retain diagnostic provider snapshots on failure")
        self.assertIn("if: failure()\n", diagnostic)
        self.assertIn("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02", diagnostic)
        self.assertIn("name: book-provider-snapshots-debug\n", diagnostic)
        self.assertIn("path: .cache/book-inputs\n", diagnostic)
        self.assertIn("include-hidden-files: true", diagnostic)
        self.assertIn("if-no-files-found: warn", diagnostic)
        self.assertIn("retention-days: 3", diagnostic)
        # The debug name appears only at upload, never as a replay input.
        self.assertEqual(self.workflow.count("book-provider-snapshots-debug"), 1)
        download = step("Download recorded provider snapshots")
        self.assertIn("name: book-provider-snapshots\n", download)
        self.assertNotIn("book-provider-snapshots-debug", download)
        deploy = self.workflow.split("\n  deploy:\n", 1)[1]
        self.assertIn("needs: build", deploy)
        self.assertNotIn("always()", deploy)
        self.assertNotIn("failure()", deploy)


if __name__ == "__main__":
    unittest.main()
