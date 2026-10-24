"""Run, retain and authenticate the weekly research comparison; never trade."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from zoneinfo import ZoneInfo

try:
    from scripts.book_publication_schedule import GitHub, NoRedirects
except ModuleNotFoundError:
    from book_publication_schedule import GitHub, NoRedirects

REPOSITORY = "ckrusemd/money-printer-go-brrr"
WORKFLOW = ".github/workflows/research-review.yml"
ARTIFACT = "research-model-review"
ZONE = ZoneInfo("Europe/Copenhagen")
FILES = {"review.rds", "summary.json", "scores.csv", "provenance.json"}


def week_start(now):
    local = now.astimezone(ZONE)
    sunday = local.date() - timedelta(days=(local.weekday() + 1) % 7)
    boundary = datetime.combine(sunday, datetime.min.time(), ZONE).replace(hour=2)
    if local < boundary:
        boundary -= timedelta(days=7)
    return boundary


def trusted_run(run):
    return (run.get("conclusion") == "success" and run.get("status") == "completed"
            and run.get("path") == WORKFLOW and run.get("head_branch") == "main"
            and run.get("event") in {"schedule", "workflow_dispatch"}
            and run.get("repository", {}).get("full_name") == REPOSITORY
            and run.get("head_repository", {}).get("full_name") == REPOSITORY
            and re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")) is not None)


def successful_runs(api):
    payload = api.request("GET", "/actions/workflows/research-review.yml/runs?branch=main&status=success&per_page=20", missing=True)
    return [r for r in (payload or {}).get("workflow_runs", []) if trusted_run(r)]


def due(now, runs):
    local = now.astimezone(ZONE)
    if local.weekday() != 6 or local.hour < 2:
        return False
    return not any(datetime.fromisoformat(r["created_at"].replace("Z", "+00:00")) >= week_start(now) for r in runs)


def gate():
    scheduled = os.environ.get("GITHUB_EVENT_NAME") == "schedule"
    allowed = not scheduled or due(datetime.now(timezone.utc), successful_runs(GitHub()))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write("due=" + str(allowed).lower() + "\n")
    print("Weekly comparison due" if allowed else "Outside Sunday 02:00 Copenhagen window, or already completed this week")


def record(directory):
    from scripts.notebooks.book import source_commit
    summary = json.loads((directory / "summary.json").read_text())
    sha = source_commit()
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or summary.get("schema") != 1:
        raise ValueError("Invalid review source or summary")
    receipt = {"schema": 1, "repository": REPOSITORY, "workflow": WORKFLOW,
               "source_sha": sha, "run_id": os.environ.get("GITHUB_RUN_ID"),
               "review_date": summary["review_date"], "signature": summary["signature"],
               "sha256": {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
                          for name in FILES - {"provenance.json"}}}
    (directory / "provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")


def archive_bytes(artifact_id):
    # Authenticate only to GitHub. Do not forward its token to redirected storage.
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip",
        headers={"Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
                 "Accept": "application/vnd.github+json"})
    try:
        response = urllib.request.build_opener(NoRedirects()).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise RuntimeError(f"Review artifact HTTP {error.code}") from None
        location = error.headers["Location"]
        if urllib.parse.urlsplit(location).scheme != "https":
            raise ValueError("Insecure artifact location")
        response = urllib.request.urlopen(location, timeout=60)
    with response:
        data = response.read(20_000_001)
    if len(data) > 20_000_000:
        raise ValueError("Oversized review artifact")
    return data


def validate_archive(data, artifact, run):
    digest = "sha256:" + hashlib.sha256(data).hexdigest()
    if artifact.get("digest") != digest:
        raise ValueError("Review archive digest mismatch")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if set(archive.namelist()) != FILES or len(archive.namelist()) != len(FILES):
            raise ValueError("Unexpected review archive members")
        if sum(i.file_size for i in archive.infolist()) > 50_000_000:
            raise ValueError("Oversized unpacked review")
        values = {name: archive.read(name) for name in FILES}
    receipt = json.loads(values["provenance.json"])
    summary = json.loads(values["summary.json"])
    if (not trusted_run(run) or receipt.get("schema") != 1
            or receipt.get("repository") != REPOSITORY or receipt.get("workflow") != WORKFLOW
            or receipt.get("source_sha") != run["head_sha"]
            or str(receipt.get("run_id")) != str(run["id"])
            or receipt.get("signature") != summary.get("signature")
            or receipt.get("review_date") != summary.get("review_date")):
        raise ValueError("Untrusted review provenance")
    for name in FILES - {"provenance.json"}:
        if receipt.get("sha256", {}).get(name) != hashlib.sha256(values[name]).hexdigest():
            raise ValueError("Review member digest mismatch")
    return values


def restore(directory):
    api = GitHub()
    for run in successful_runs(api):
        payload = api.request("GET", f"/actions/runs/{run['id']}/artifacts?per_page=100")
        artifacts = [a for a in payload.get("artifacts", [])
                     if a.get("name") == ARTIFACT and not a.get("expired")]
        if len(artifacts) != 1:
            continue
        artifact = artifacts[0]
        if not re.fullmatch(r"[1-9][0-9]*", str(artifact.get("id"))):
            raise ValueError("Invalid review artifact ID")
        values = validate_archive(archive_bytes(artifact["id"]), artifact, run)
        directory.mkdir(parents=True, exist_ok=True)
        for name, value in values.items():
            temporary = directory / (name + ".tmp")
            temporary.write_bytes(value)
            temporary.replace(directory / name)
        print(f"Authenticated weekly review from main run {run['id']}; R checks signature and age before use")
        return True
    print("No successful main review artifact; daily forecasts retain their benchmark")
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["gate", "run", "restore"])
    parser.add_argument("--directory", type=Path, default=Path(".cache/research-models"))
    args = parser.parse_args()
    if args.command == "gate":
        gate()
    elif args.command == "restore":
        try:
            restore(args.directory)
        except (RuntimeError, ValueError, OSError, KeyError, zipfile.BadZipFile):
            # Daily publication can proceed honestly without validated alternatives.
            print("Weekly review unavailable or failed authentication; benchmark fallback remains active")
    else:
        from scripts.notebooks.environment import audit
        audit()
        subprocess.run(["Rscript", "--vanilla", "scripts/research_review.R", str(args.directory)], check=True)
        record(args.directory)


if __name__ == "__main__":
    main()
