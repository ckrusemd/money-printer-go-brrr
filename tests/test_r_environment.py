"""Keep R, CRAN snapshot, bootstrap and publication image pins consistent."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class REnvironmentTests(unittest.TestCase):
    def test_r_version_and_image_digest_match_lock_and_smoke_test(self):
        root = json.loads((ROOT / "renv.lock").read_text())
        publication = json.loads((ROOT / "renv/publication.lock").read_text())
        self.assertEqual(root["R"], publication["R"])
        version = root["R"]["Version"]
        docker = (ROOT / "Dockerfile").read_text()
        self.assertRegex(docker, r"^FROM rocker/r-ver:" + re.escape(version) + r"@sha256:[a-f0-9]{64}\n")
        smoke = (ROOT / ".github/workflows/build-container.yml").read_text()
        self.assertIn('getRversion()) == "' + version + '"', smoke)

    def test_dated_snapshot_and_renv_bootstrap_are_consistent(self):
        lock = json.loads((ROOT / "renv/publication.lock").read_text())
        repository = lock["R"]["Repositories"][0]["URL"]
        self.assertRegex(repository, r"^https://packagemanager\.posit\.co/cran/\d{4}-\d{2}-\d{2}$")
        docker = (ROOT / "Dockerfile").read_text()
        self.assertIn("RENV_CONFIG_REPOS_OVERRIDE=" + repository, docker)
        version = lock["Packages"]["renv"]["Version"]
        self.assertIn('version <- "' + version + '"', (ROOT / "renv/activate.R").read_text())
        self.assertIn('packageVersion("renv") == "' + version + '"', docker)
        # Restore only explicit pinned remotes, not dkstat's optional geodata.
        self.assertIn('RENV_CONFIG_INSTALL_REMOTES = "FALSE"', docker)

    def test_ci_checks_the_candidate_lock_before_offline_fixtures(self):
        workflow = (ROOT / ".github/workflows/book-ci.yml").read_text()
        selection = workflow.split("      - name: Select or build an image matching the candidate lock\n")[1].split("\n      - name:")[0]
        self.assertIn('as.character(getRversion()) == lock$R$Version', selection)
        self.assertIn('utils::packageVersion(p) == package_version(lock$Packages[[p]]$Version)', selection)
        self.assertIn('docker build --tag "$BOOK_CI_IMAGE" .', selection)
        self.assertNotIn("sleep", selection)


if __name__ == "__main__":
    unittest.main()
