"""Exercise CI image selection without a registry or Docker daemon."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
DIGEST = "ghcr.io/ckrusemd/money-printer-go-brrr-r@sha256:" + "a" * 64
CONTEXT = "b" * 64


class NotebookCIImageTests(unittest.TestCase):
    def select(self, *, pin=DIGEST, pin_context=CONTEXT, cached=True,
               selected_context=CONTEXT):
        workflow = yaml.safe_load((ROOT / ".github/workflows/book-ci.yml").read_text())
        script = next(step["run"] for step in workflow["jobs"]["offline-book"]["steps"]
                      if step["name"] == "Select or build an image matching the candidate lock")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            driver = '''import json, os, sys
from pathlib import Path
args = sys.argv[2:]
if sys.argv[1] == "python3":
    if args == ["scripts/publication_image_key.py"]:
        print(os.environ["FIXTURE_CONTEXT"])
    elif os.environ["FIXTURE_PIN"]:
        print(os.environ["FIXTURE_PIN"])
    else:
        sys.exit(1)
else:
    with open(os.environ["FIXTURE_LOG"], "a") as stream:
        stream.write(json.dumps(args) + "\\n")
    if args[0] == "pull":
        sys.exit(0 if args[1] == os.environ["FIXTURE_PIN"] or os.environ["FIXTURE_CACHED"] == "yes" else 1)
    if args[0] == "inspect":
        print(os.environ["FIXTURE_PIN_CONTEXT"] if args[-1] == os.environ["FIXTURE_PIN"]
              else os.environ["FIXTURE_SELECTED_CONTEXT"])
'''
            command = root / "driver.py"
            command.write_text(driver)
            # Functions also work with a noexec /tmp in read-only containers.
            functions = '''docker() { "$FIXTURE_PYTHON" "$FIXTURE_DRIVER" docker "$@"; }
python3() { "$FIXTURE_PYTHON" "$FIXTURE_DRIVER" python3 "$@"; }
'''
            log = root / "calls.jsonl"
            result = subprocess.run(["bash", "-c", functions + script], capture_output=True, text=True,
                env={**os.environ, "FIXTURE_PYTHON": sys.executable, "FIXTURE_DRIVER": str(command),
                     "GITHUB_WORKSPACE": str(ROOT), "BOOK_CI_IMAGE": "ci-fixture", "FIXTURE_PIN": pin,
                     "FIXTURE_CONTEXT": CONTEXT, "FIXTURE_PIN_CONTEXT": pin_context,
                     "FIXTURE_SELECTED_CONTEXT": selected_context,
                     "FIXTURE_CACHED": "yes" if cached else "no", "FIXTURE_LOG": str(log)})
            self.assertTrue(log.exists(), result.stderr)
            return result, [json.loads(line) for line in log.read_text().splitlines()]

    def test_notebook_edit_uses_the_exact_promoted_digest(self):
        result, calls = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call for call in calls if call[0] == "pull"], [["pull", DIGEST]])
        self.assertIn(["tag", DIGEST, "ci-fixture"], calls)

    def test_dependency_change_uses_matching_candidate_instead_of_stale_pin(self):
        result, calls = self.select(pin_context="old-context")
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = next(call[1] for call in calls if call[0] == "tag")
        self.assertTrue(selected.endswith(":context-" + CONTEXT))

    def test_missing_candidate_builds_the_requested_context(self):
        result, calls = self.select(pin="", cached=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[0] == "build" and "PUBLICATION_CONTEXT=" + CONTEXT in call
                            for call in calls))

    def test_wrong_candidate_label_stops_before_any_container_runs(self):
        result, calls = self.select(pin="", selected_context="wrong-context")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "run" for call in calls))


if __name__ == "__main__":
    unittest.main()
