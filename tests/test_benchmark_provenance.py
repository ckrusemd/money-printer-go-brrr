"""No-secret fixtures for authenticated benchmark recovery (no render calls)."""

import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from scripts import benchmark_provenance as p


def run_record(run_id=p.LEGACY_RUN, sha=p.LEGACY_SOURCE, conclusion="cancelled"):
    return dict(id=int(run_id), head_sha=sha, status="completed", conclusion=conclusion,
                event="workflow_dispatch", path=p.WORKFLOW,
                repository=dict(full_name=p.REPOSITORY), head_repository=dict(full_name=p.REPOSITORY))


def zip_bytes(files):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as z:
        for name, value in files:
            z.writestr(name, value)
    return data.getvalue()


def legacy_logs():
    prefix = "2026-10-11T19:44:09.0000000Z "
    lines = [p.LEGACY_SOURCE, "  BASELINE_REF: " + p.LEGACY_BASELINE,
             "  SNAPSHOT_RUN_ID: " + p.LEGACY_SNAPSHOT_RUN,
             "  PUBLICATION_IMAGE: " + p.IMAGE_REPOSITORY + ":" + p.LEGACY_TAG,
             "Digest: " + p.LEGACY_IMAGE_DIGEST,
             "- book-provider-snapshots (ID: " + p.LEGACY_SNAPSHOT_ARTIFACT +
             ", Size: 16874346, Expected Digest: " + p.LEGACY_SNAPSHOT_DIGEST + ")",
             "SHA256 digest of downloaded artifact is " + p.LEGACY_SNAPSHOT_DIGEST[7:],
             "SHA256 digest of uploaded artifact zip is " + p.LEGACY_ARCHIVE_DIGEST[7:]]
    lines += [f"{version} run {run} : 60.25 seconds; 100 KB RSS; status 0 "
              for run in range(4) for version in ("baseline", "optimized")]
    return zip_bytes([("1_benchmark.txt", "\n".join(prefix + line for line in lines))])


class BenchmarkProvenanceTests(unittest.TestCase):
    def test_only_completed_fixed_repository_own_workflow_runs_accepted(self):
        p.validate_run(run_record(), p.LEGACY_RUN)
        for field, value in (("status", "in_progress"), ("event", "pull_request"),
                             ("path", ".github/workflows/other.yml"), ("head_sha", "a"),
                             ("conclusion", "skipped"), ("id", 123)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                record = run_record()
                record[field] = value
                p.validate_run(record, p.LEGACY_RUN)
        for field in ("repository", "head_repository"):
            record = run_record()
            record[field] = dict(full_name="other/repo")
            with self.assertRaises(ValueError):
                p.validate_run(record, p.LEGACY_RUN)
        with self.assertRaises(ValueError):
            p.validate_run(run_record(), p.LEGACY_RUN, successful=True)

    def test_snapshot_source_requires_success_but_supports_normal_triggers(self):
        for event in ("workflow_dispatch", "push", "schedule", "workflow_run"):
            record = run_record(conclusion="success")
            record["event"] = event
            p.validate_run(record, p.LEGACY_RUN, successful=True)

    def test_unique_named_unexpired_digest_artifact(self):
        artifact = dict(id=123, name="book-benchmark-evidence", expired=False,
                        digest="sha256:" + "a" * 64)
        p.select_artifact(dict(artifacts=[artifact]), artifact["name"])
        for records in ([], [artifact, artifact], [{**artifact, "expired": True}],
                        [{**artifact, "digest": None}], [{**artifact, "id": "1/path"}]):
            with self.assertRaises((ValueError, TypeError)):
                p.select_artifact(dict(artifacts=records), artifact["name"])

    def test_legacy_binds_actual_logs_source_pull_and_input_and_output_digests(self):
        artifact = dict(id=11722321180, digest=p.LEGACY_ARCHIVE_DIGEST)
        receipt = p.legacy_receipt(run_record(), artifact, legacy_logs())
        self.assertEqual(receipt["image"], p.IMAGE_REPOSITORY + "@" + p.LEGACY_IMAGE_DIGEST)
        self.assertEqual(receipt["source_sha"], p.LEGACY_SOURCE)
        self.assertEqual(receipt["snapshot_run_id"], p.LEGACY_SNAPSHOT_RUN)
        for field in (p.LEGACY_SOURCE, p.LEGACY_BASELINE, p.LEGACY_SNAPSHOT_RUN,
                      p.LEGACY_TAG, p.LEGACY_IMAGE_DIGEST, p.LEGACY_SNAPSHOT_ARTIFACT,
                      p.LEGACY_SNAPSHOT_DIGEST, "SHA256 digest of uploaded artifact zip is",
                      "optimized run 3"):
            with zipfile.ZipFile(io.BytesIO(legacy_logs())) as z:
                text = z.read("1_benchmark.txt").decode().replace(field, "wrong")
            with self.subTest(field=field), self.assertRaises(ValueError):
                p.legacy_receipt(run_record(), artifact, zip_bytes([("1_benchmark.txt", text)]))
        for bad in (dict(id=1, digest=p.LEGACY_ARCHIVE_DIGEST),
                    dict(id=11722321180, digest="sha256:" + "b" * 64)):
            with self.assertRaises(ValueError):
                p.legacy_receipt(run_record(), bad, legacy_logs())

    def test_archive_digest_and_paths_are_checked_before_extraction(self):
        for name in ("../escape", "/absolute", "dir\\escape", "dir//file", "dir/./file", "./ok", ".", "ok"):
            data = zip_bytes([(name, "data")])
            artifact = dict(digest="sha256:" + hashlib.sha256(data).hexdigest())
            if name == "ok":
                p.verify_archive(data, artifact).close()
            else:
                with self.assertRaises(ValueError):
                    p.verify_archive(data, artifact)
        with self.assertRaises(ValueError):
            p.verify_archive(data, dict(digest="sha256:" + "0" * 64))
        duplicate = zip_bytes([("same", "1"), ("same", "2")])
        with self.assertRaises(ValueError):
            p.verify_archive(duplicate, dict(digest="sha256:" + hashlib.sha256(duplicate).hexdigest()))
        symlink = io.BytesIO()
        with zipfile.ZipFile(symlink, "w") as z:
            info = zipfile.ZipInfo("link")
            info.external_attr = 0o120777 << 16
            z.writestr(info, "../../escape")
        data = symlink.getvalue()
        with self.assertRaises(ValueError):
            p.verify_archive(data, dict(digest="sha256:" + hashlib.sha256(data).hexdigest()))

    def test_future_recovery_uses_authenticated_receipt_and_never_renders(self):
        receipt = dict(schema="1", repository=p.REPOSITORY, source_sha="a" * 40,
                       baseline_sha="b" * 40, image=p.IMAGE_REPOSITORY + "@sha256:" + "c" * 64,
                       snapshot_run_id="12", benchmark_run_id="34", mode="fresh",
                       snapshot_artifact_id="56", snapshot_artifact_digest="sha256:" + "d" * 64)
        text = "".join(f"{k}: {v}\n" for k, v in receipt.items())
        data = zip_bytes([("provenance.dcf", text), ("runs.csv", "fixture")])
        artifact = dict(id=78, name="book-benchmark-evidence", expired=False,
                        digest="sha256:" + hashlib.sha256(data).hexdigest())
        responses = {
            "actions/runs/34": run_record("34", "a" * 40, "success"),
            "actions/runs/34/artifacts?per_page=100": dict(artifacts=[artifact]),
            "actions/artifacts/78/zip": data,
            "actions/runs/12": run_record("12", "e" * 40, "success"),
            "actions/runs/12/artifacts?per_page=100": dict(artifacts=[dict(id=56,
                name="book-provider-snapshots", expired=False, digest="sha256:" + "d" * 64)]),
        }
        with tempfile.TemporaryDirectory() as directory, patch.object(p, "api", side_effect=lambda path, **kw: responses[path]) as api:
            output = Path(directory) / "receipt.dcf"
            evidence = Path(directory) / "evidence"
            p.prepare_recovery("34", evidence, output)
            self.assertEqual((evidence / "runs.csv").read_text(), "fixture")
            self.assertEqual(p.read_receipt(output.read_text())["source_sha"], "a" * 40)
            self.assertEqual(p.read_receipt(output.read_text())["archive_path"], "receipt.archive.zip")
            self.assertTrue(output.with_suffix(".archive.zip").exists())
            self.assertEqual(api.call_count, 5)
            # Existing evidence is never overwritten.
            with self.assertRaises(ValueError):
                p.prepare_recovery("34", evidence, output)
        responses["actions/runs/34"]["head_sha"] = "f" * 40
        with tempfile.TemporaryDirectory() as directory, patch.object(p, "api", side_effect=lambda path, **kw: responses[path]):
            with self.assertRaises(ValueError):
                p.prepare_recovery("34", Path(directory) / "evidence", Path(directory) / "receipt.dcf")
            self.assertFalse((Path(directory) / "evidence").exists())

    def test_existing_recovery_receipts_and_archives_are_never_overwritten(self):
        for suffix in (".dcf", ".archive.zip", ".logs.zip"):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "receipt.dcf"
                existing = output.with_suffix(suffix)
                existing.write_bytes(b"preserved")
                with patch.object(p, "api") as api, self.assertRaises(ValueError):
                    p.prepare_recovery("34", Path(directory) / "evidence", output)
                api.assert_not_called()
                self.assertEqual(existing.read_bytes(), b"preserved")

    def test_legacy_recovery_writes_only_after_snapshot_authentication(self):
        data = zip_bytes([("runs.csv", "fixture")])
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        with patch.object(p, "LEGACY_ARCHIVE_DIGEST", digest):
            responses = {
                f"actions/runs/{p.LEGACY_RUN}": run_record(),
                f"actions/runs/{p.LEGACY_RUN}/artifacts?per_page=100": dict(artifacts=[dict(
                    id=11722321180, name="book-benchmark-evidence", expired=False, digest=digest)]),
                "actions/artifacts/11722321180/zip": data,
                f"actions/runs/{p.LEGACY_RUN}/logs": legacy_logs(),
                f"actions/runs/{p.LEGACY_SNAPSHOT_RUN}": run_record(p.LEGACY_SNAPSHOT_RUN, conclusion="success"),
                f"actions/runs/{p.LEGACY_SNAPSHOT_RUN}/artifacts?per_page=100": dict(artifacts=[dict(
                    id=int(p.LEGACY_SNAPSHOT_ARTIFACT), name="book-provider-snapshots", expired=False,
                    digest=p.LEGACY_SNAPSHOT_DIGEST)]),
            }
            with tempfile.TemporaryDirectory() as directory, patch.object(p, "api", side_effect=lambda path, **kw: responses[path]):
                output = Path(directory) / "nested" / "receipt.dcf"
                p.prepare_recovery(p.LEGACY_RUN, Path(directory) / "evidence", output)
                self.assertEqual(p.read_receipt(output.read_text())["mode"], "legacy")
                self.assertEqual(output.with_suffix(".logs.zip").read_bytes(), legacy_logs())
            responses[f"actions/runs/{p.LEGACY_SNAPSHOT_RUN}"]["conclusion"] = "failure"
            with tempfile.TemporaryDirectory() as directory, patch.object(p, "api", side_effect=lambda path, **kw: responses[path]):
                with self.assertRaises(ValueError):
                    p.prepare_recovery(p.LEGACY_RUN, Path(directory) / "evidence", Path(directory) / "receipt.dcf")
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_invalid_receipts_cannot_change_repository_image_or_inject_outputs(self):
        receipt = p.legacy_receipt(run_record(), dict(id=11722321180, digest=p.LEGACY_ARCHIVE_DIGEST), legacy_logs())
        for field, value in (("schema", "2"), ("repository", "other/repo"),
                             ("image", "other/image@sha256:" + "a" * 64),
                             ("image", p.IMAGE_REPOSITORY + ":latest"),
                             ("source_sha", "wrong"), ("snapshot_run_id", "12\nimage=evil")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                p.validate_receipt({**receipt, field: value})


if __name__ == "__main__":
    unittest.main()
