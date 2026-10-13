"""Offline fixtures for the exact publication-lock validator embedded in CI."""

import ast
import copy
import json
from pathlib import Path
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
APPROVED = {"IRdisplay", "IRkernel", "pacman", "pbdZMQ", "repr", "uuid"}


class PublicationLockSubsetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (REPOSITORY / ".github/workflows/book-ci.yml").read_text(encoding="utf-8")
        step = cls.workflow.split(
            "      - name: Check publication lock is an approved identical-record subset\n", 1
        )[1].split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0])
        # Execute the production function, not a second implementation of policy.
        definitions = [node for node in ast.parse(script).body if isinstance(node, ast.FunctionDef)]
        if len(definitions) != 1 or definitions[0].name != "validate_publication_lock":
            raise AssertionError("Expected the actual CI subset validator")
        namespace = {}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), "book-ci-lock-validator", "exec"), namespace)
        cls.validate = staticmethod(namespace["validate_publication_lock"])
        cls.root = json.loads((REPOSITORY / "renv.lock").read_text(encoding="utf-8"))
        cls.publication = json.loads((REPOSITORY / "renv/publication.lock").read_text(encoding="utf-8"))

    def test_real_lock_omits_exactly_six_and_preserves_all_212_records_and_r_metadata(self):
        self.assertEqual(self.validate(self.root, self.publication), APPROVED)
        self.assertEqual(len(self.root["Packages"]), 218)
        self.assertEqual(len(self.publication["Packages"]), 212)
        self.assertEqual(self.publication["R"], self.root["R"])
        for name, record in self.publication["Packages"].items():
            with self.subTest(package=name):
                self.assertEqual(record, self.root["Packages"][name])

    def test_full_lock_and_each_approved_omission_are_allowed(self):
        self.assertEqual(self.validate(self.root, self.root), set())
        for name in APPROVED:
            with self.subTest(package=name):
                publication = copy.deepcopy(self.root)
                del publication["Packages"][name]
                self.assertEqual(self.validate(self.root, publication), {name})

    def test_every_unapproved_omission_is_rejected(self):
        for name in self.publication["Packages"]:
            with self.subTest(package=name):
                publication = copy.deepcopy(self.publication)
                del publication["Packages"][name]
                with self.assertRaisesRegex(ValueError, "Unapproved publication omissions"):
                    self.validate(self.root, publication)

    def test_extra_record_is_rejected(self):
        publication = copy.deepcopy(self.publication)
        publication["Packages"]["unknown-fixture"] = {"Package": "unknown-fixture", "Version": "1.0"}
        with self.assertRaisesRegex(ValueError, "Extra publication records"):
            self.validate(self.root, publication)

    def test_version_and_record_metadata_drift_are_rejected(self):
        for field, value in (
            ("Version", "999.0"), ("Source", "changed"), ("Repository", "other"),
            ("Imports", ["changed"]), ("Suggests", ["changed"]),
            ("Title", "changed"), ("UnknownField", "new metadata"),
        ):
            with self.subTest(field=field):
                publication = copy.deepcopy(self.publication)
                publication["Packages"]["bookdown"][field] = value
                with self.assertRaisesRegex(ValueError, "Changed publication records"):
                    self.validate(self.root, publication)
        publication = copy.deepcopy(self.publication)
        del publication["Packages"]["bookdown"]["Version"]
        with self.assertRaisesRegex(ValueError, "Changed publication records"):
            self.validate(self.root, publication)

    def test_r_version_repository_and_metadata_drift_are_rejected(self):
        for field, value in (
            ("Version", "4.4.0"),
            ("Repositories", [{"Name": "CRAN", "URL": "https://example.invalid"}]),
            ("UnknownField", "changed"),
        ):
            with self.subTest(field=field):
                publication = copy.deepcopy(self.publication)
                publication["R"][field] = value
                with self.assertRaisesRegex(ValueError, "Publication R metadata differs"):
                    self.validate(self.root, publication)

    def test_dependency_and_closure_audits_are_adjacent_inside_offline_container(self):
        step = self.workflow.split(
            "      - name: Parse sources and discover every R fixture without network\n", 1
        )[1].split("\n      - name:", 1)[0]
        self.assertIn("docker run --rm --network none --read-only", step)
        self.assertIn(
            "Rscript --vanilla scripts/check_publication_dependencies.R\n"
            "              Rscript --vanilla scripts/check_publication_closure.R", step
        )


if __name__ == "__main__":
    unittest.main()
