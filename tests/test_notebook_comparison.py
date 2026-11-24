"""Replay comparisons work in runner-owned checkouts without global Git trust."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts.notebooks.compare import git


class ComparisonOwnershipTests(unittest.TestCase):
    def test_foreign_owned_source_can_be_archived_and_fetched_with_scoped_trust(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            baseline = Path(directory) / "baseline"
            source.mkdir()
            baseline.mkdir()
            git(["init", "--quiet"], source)
            subprocess.run(["git", "-c", "user.name=Fixture", "-c",
                            "user.email=fixture@example.invalid", "commit", "--quiet",
                            "--allow-empty", "-m", "Fixture"], cwd=source, check=True)
            sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
            with patch.dict(os.environ, {
                "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_COUNT": "0", "GIT_CONFIG_PARAMETERS": "",
            }):
                probe = subprocess.run(["git", "status", "--porcelain"], cwd=source, capture_output=True)
                self.assertNotEqual(probe.returncode, 0)
                self.assertIn(b"ownership", probe.stderr)
                archive = Path(directory) / "source.tar"
                git(["archive", sha, "-o", str(archive)], source)
                self.assertTrue(archive.is_file())
                git(["init", "--quiet"], baseline)
                git(["fetch", "--quiet", str(source), sha], baseline, trust=(source,))
                git(["reset", "--mixed", "--quiet", "FETCH_HEAD"], baseline)
                self.assertEqual(subprocess.check_output([
                    "git", "-c", "safe.directory=" + str(baseline), "rev-parse", "HEAD"
                ], cwd=baseline, text=True).strip(), sha)
                # Trust from one invocation must not escape into later Git commands.
                probe = subprocess.run(["git", "status", "--porcelain"], cwd=source, capture_output=True)
                self.assertNotEqual(probe.returncode, 0)
