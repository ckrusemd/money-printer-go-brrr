"""Authenticate fixed-repository benchmark evidence; never render or deploy.

Legacy provenance comes from the original runner logs AND immutable archive
digest, not from invented metadata or a relaxed numerical-coverage gate.
"""

import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

REPOSITORY = "ckrusemd/money-printer-go-brrr"
IMAGE_REPOSITORY = "ghcr.io/ckrusemd/money-printer-go-brrr-r"
WORKFLOW = ".github/workflows/deploy_bookdown.yml"
LEGACY_RUN = "38169256067"
LEGACY_SOURCE = "0e4d1110188a68f203a3fa17efdfd0010b1a96a4"
LEGACY_BASELINE = "b7e08934877da8a88b4b2393a3745b994f8bff48"
LEGACY_TAG = "candidate-minimal-982a97b9a5415969738bb8ea6f314eead0ab150c"
LEGACY_IMAGE_DIGEST = "sha256:89a9b02fd62a3cbca56bb06519dabfc321117ac69fd2432dc7c8b3cbaf17a5db"
LEGACY_ARCHIVE_DIGEST = "sha256:cfc889b82604bc9a58a54e02311ad9c074f56c8ced670add17da43fd33f2ad41"
LEGACY_SNAPSHOT_RUN = "38166191755"
LEGACY_SNAPSHOT_ARTIFACT = "11712094467"
LEGACY_SNAPSHOT_DIGEST = "sha256:1109864ee6b096cc5e6fd6662790d39d8e3263f7a5122542917f5ff5600df668"
FIELDS = ("schema", "repository", "source_sha", "baseline_sha", "image",
          "snapshot_run_id", "benchmark_run_id", "mode", "snapshot_artifact_id",
          "snapshot_artifact_digest")


def api(path, binary=False):
    # gh handles authenticated API redirects without forwarding credentials to
    # artifact storage. Fixed host/repository, no shell or caller-supplied URLs.
    result = subprocess.run(["gh", "api", "--hostname", "github.com",
                             f"repos/{REPOSITORY}/{path}"], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=120 if binary else 35)
    return result.stdout if binary else json.loads(result.stdout)


def validate_run(run, run_id, successful=False):
    if (str(run.get("id")) != str(run_id) or run.get("status") != "completed"
            or run.get("event") not in (("workflow_dispatch", "push", "schedule", "workflow_run") if successful else ("workflow_dispatch",))
            or run.get("path") != WORKFLOW
            or run.get("repository", {}).get("full_name") != REPOSITORY
            or run.get("head_repository", {}).get("full_name") != REPOSITORY
            or not re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", ""))
            or run.get("conclusion") not in (("success",) if successful else ("success", "cancelled", "failure", "timed_out"))):
        raise ValueError("Untrusted/incomplete benchmark or snapshot run")


def select_artifact(payload, name):
    records = [a for a in payload.get("artifacts", []) if a.get("name") == name]
    if len(records) != 1:
        raise ValueError("Expected exactly one immutable named artifact")
    artifact = records[0]
    if (artifact.get("expired") or not re.fullmatch(r"[1-9][0-9]*", str(artifact.get("id")))
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", ""))):
        raise ValueError("Expired artifact or missing immutable digest")
    return artifact


def read_receipt(text):
    receipt = {}
    for line in text.splitlines():
        if ": " not in line:
            raise ValueError("Invalid provenance receipt line")
        key, value = line.split(": ", 1)
        if key in receipt:
            raise ValueError("Duplicate provenance field")
        receipt[key] = value
    validate_receipt(receipt)
    return receipt


def validate_receipt(receipt):
    if (not all(k in receipt for k in FIELDS) or receipt["schema"] != "1"
            or receipt["repository"] != REPOSITORY or receipt["mode"] not in ("fresh", "legacy")
            or not re.fullmatch(r"[0-9a-f]{40}", receipt["source_sha"])
            or not re.fullmatch(r"[0-9a-f]{40}", receipt["baseline_sha"])
            or not re.fullmatch(re.escape(IMAGE_REPOSITORY) + r"@sha256:[0-9a-f]{64}", receipt["image"])
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", receipt["snapshot_artifact_digest"])
            or any(not re.fullmatch(r"[1-9][0-9]*", receipt[k])
                   for k in ("snapshot_run_id", "benchmark_run_id", "snapshot_artifact_id"))):
        raise ValueError("Invalid source/image provenance")


def legacy_receipt(run, artifact, logs):
    if (str(run["id"]) != LEGACY_RUN or run["head_sha"] != LEGACY_SOURCE
            or str(artifact["id"]) != "11722321180" or artifact["digest"] != LEGACY_ARCHIVE_DIGEST):
        raise ValueError("Unknown legacy source/archive provenance")
    with zipfile.ZipFile(io.BytesIO(logs)) as archive:
        text = archive.read("1_benchmark.txt").decode("utf-8")
    checks = (
        r"^\S+ " + LEGACY_SOURCE + r"$",
        r"^\S+\s+BASELINE_REF: " + LEGACY_BASELINE + r"$",
        r"^\S+\s+SNAPSHOT_RUN_ID: " + LEGACY_SNAPSHOT_RUN + r"$",
        r"^\S+\s+PUBLICATION_IMAGE: " + re.escape(IMAGE_REPOSITORY + ":" + LEGACY_TAG) + r"$",
        r"^\S+ Digest: " + re.escape(LEGACY_IMAGE_DIGEST) + r"$",
        r"book-provider-snapshots \(ID: " + LEGACY_SNAPSHOT_ARTIFACT +
        r", Size: [0-9]+, Expected Digest: " + re.escape(LEGACY_SNAPSHOT_DIGEST) + r"\)",
        r"^\S+ SHA256 digest of downloaded artifact is " + LEGACY_SNAPSHOT_DIGEST.removeprefix("sha256:") + r"$",
        r"^\S+ SHA256 digest of uploaded artifact zip is " + LEGACY_ARCHIVE_DIGEST.removeprefix("sha256:") + r"$",
    )
    if not all(re.search(pattern, text, re.MULTILINE) for pattern in checks):
        raise ValueError("Original runner logs do not bind source/image/snapshot receipts")
    runs = re.findall(r"^\S+ (baseline|optimized) run ([0-3]) : ([0-9.]+) seconds; ([0-9]+) KB RSS; status ([0-9]+)\s*$", text, re.MULTILINE)
    if (len(runs) != 8 or len({(v, n) for v, n, *_ in runs}) != 8
            or any(status != "0" or not math.isfinite(float(seconds)) or float(seconds) <= 0 or int(rss) <= 0
                   for _, _, seconds, rss, status in runs)):
        raise ValueError("Original runner logs lack eight unique successful measured runs")
    return dict(schema="1", repository=REPOSITORY, source_sha=LEGACY_SOURCE,
                baseline_sha=LEGACY_BASELINE, image=IMAGE_REPOSITORY + "@" + LEGACY_IMAGE_DIGEST,
                snapshot_run_id=LEGACY_SNAPSHOT_RUN, benchmark_run_id=LEGACY_RUN,
                mode="legacy", snapshot_artifact_id=LEGACY_SNAPSHOT_ARTIFACT,
                snapshot_artifact_digest=LEGACY_SNAPSHOT_DIGEST,
                archive_digest=artifact["digest"], logs_digest="sha256:" + hashlib.sha256(logs).hexdigest())


def verify_archive(data, artifact):
    if "sha256:" + hashlib.sha256(data).hexdigest() != artifact["digest"]:
        raise ValueError("Immutable artifact archive digest mismatch")
    archive = zipfile.ZipFile(io.BytesIO(data))
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise ValueError("Duplicate archive paths")
    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        if (not path.parts or path.is_absolute() or ".." in path.parts or "\\" in info.filename
                or info.filename.rstrip("/") != path.as_posix()
                or (info.external_attr >> 16) & 0o170000 == 0o120000):
            raise ValueError("Unsafe artifact archive path")
    return archive


def write_receipt(receipt, output):
    validate_receipt(receipt)
    if any("\n" in str(v) or "\r" in str(v) for v in receipt.values()):
        raise ValueError("Multiline provenance field")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(f"{k}: {v}\n" for k, v in receipt.items()), encoding="utf-8")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            for key in ("image", "snapshot_run_id", "source_sha"):
                stream.write(f"{key}={receipt[key]}\n")


def prepare_recovery(run_id, evidence, output):
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("Invalid completed benchmark run ID")
    archive_path = output.with_suffix(".archive.zip")
    logs_path = output.with_suffix(".logs.zip")
    if any(path.exists() for path in (evidence, output, archive_path, logs_path)):
        raise ValueError("Recovery destination already exists")
    run = api(f"actions/runs/{run_id}")
    validate_run(run, run_id)
    artifact = select_artifact(api(f"actions/runs/{run_id}/artifacts?per_page=100"), "book-benchmark-evidence")
    data = api(f"actions/artifacts/{artifact['id']}/zip", binary=True)
    logs = None
    with verify_archive(data, artifact) as archive:
        if "provenance.dcf" in archive.namelist():
            receipt = read_receipt(archive.read("provenance.dcf").decode("utf-8"))
            if receipt["mode"] != "fresh" or receipt["source_sha"] != run["head_sha"] or receipt["benchmark_run_id"] != run_id:
                raise ValueError("Source/run provenance mismatch")
        else:
            logs = api(f"actions/runs/{run_id}/logs", binary=True)
            receipt = legacy_receipt(run, artifact, logs)
        snapshot_run = api(f"actions/runs/{receipt['snapshot_run_id']}")
        validate_run(snapshot_run, receipt["snapshot_run_id"], successful=True)
        snapshot = select_artifact(api(f"actions/runs/{receipt['snapshot_run_id']}/artifacts?per_page=100"), "book-provider-snapshots")
        if str(snapshot["id"]) != receipt["snapshot_artifact_id"] or snapshot["digest"] != receipt["snapshot_artifact_digest"]:
            raise ValueError("Snapshot artifact provenance mismatch")
        archive.extractall(evidence)
    output.parent.mkdir(parents=True, exist_ok=True)
    archive_path.write_bytes(data)
    if logs is not None:
        logs_path.write_bytes(logs)
    # Keep the receipt and archive relocatable together across the separate
    # verifier, namespace audit and aggregation jobs (and local test mounts).
    receipt.update(archive_digest=artifact["digest"], archive_path=archive_path.name,
                   artifact_id=str(artifact["id"]))
    write_receipt(receipt, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("fresh", "recover"))
    parser.add_argument("--output", type=Path, default=Path(".cache/benchmark-provenance.dcf"))
    parser.add_argument("--run-id")
    parser.add_argument("--evidence", type=Path, default=Path(".cache/book-benchmark"))
    parser.add_argument("--image")
    parser.add_argument("--baseline-sha")
    parser.add_argument("--snapshot-run-id")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.mode == "recover":
        prepare_recovery(args.run_id or "", args.evidence, args.output)
    else:
        run_id = args.snapshot_run_id or ""
        if not re.fullmatch(r"[1-9][0-9]*", run_id):
            raise ValueError("Invalid successful snapshot run ID")
        run = api(f"actions/runs/{run_id}")
        validate_run(run, run_id, successful=True)
        artifact = select_artifact(api(f"actions/runs/{run_id}/artifacts?per_page=100"), "book-provider-snapshots")
        write_receipt(dict(schema="1", repository=os.environ["GITHUB_REPOSITORY"],
            source_sha=os.environ["GITHUB_SHA"], baseline_sha=args.baseline_sha,
            image=args.image, snapshot_run_id=run_id, benchmark_run_id=os.environ["GITHUB_RUN_ID"],
            mode="fresh", snapshot_artifact_id=str(artifact["id"]), snapshot_artifact_digest=artifact["digest"]), args.output)


if __name__ == "__main__":
    main()
