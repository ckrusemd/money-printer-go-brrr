"""Compare a full candidate book with a baseline using the same recorded inputs.

Used only by explicit validation dispatches; production publication never replays.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

from scripts.notebooks.book import ROOT
from scripts.publication_image_key import image_key


def snapshots(directory):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.iterdir() if p.is_file()}


def compare(reference, root=ROOT):
    if not re.fullmatch(r"[0-9a-f]{40}", reference):
        raise ValueError("Baseline must be a full immutable commit SHA")
    receipt = json.loads((root / ".cache/notebook-last-run.json").read_text())
    run = Path(receipt["directory"]).resolve()
    if not run.is_relative_to((root / ".cache/notebook-runs").resolve()) or not receipt["complete"]:
        raise ValueError("Expected a completed candidate notebook run")
    inputs = run / "inputs"
    before = snapshots(inputs)
    evidence = root / ".cache/notebook-comparison"
    evidence.mkdir(exist_ok=True)
    subprocess.run(["git", "fetch", "--no-tags", "origin", reference], cwd=root, check=True)
    with tempfile.TemporaryDirectory(prefix="money-book-baseline-") as tmp:
        baseline = Path(tmp)
        archive = baseline / "source.tar"
        subprocess.run(["git", "archive", reference, "-o", str(archive)], cwd=root, check=True)
        with tarfile.open(archive) as tar:
            tar.extractall(baseline, filter="data")
        archive.unlink()
        if image_key(baseline) != image_key(root):
            raise ValueError("Baseline must use the same locked publication environment")
        # Preserve the source receipt without modifying the user's working tree.
        subprocess.run(["git", "init", "--quiet"], cwd=baseline, check=True)
        subprocess.run(["git", "fetch", "--quiet", str(root), reference], cwd=baseline, check=True)
        subprocess.run(["git", "reset", "--mixed", "--quiet", "FETCH_HEAD"], cwd=baseline, check=True)
        review = root / ".cache/research-models/review.rds"
        if review.is_file():
            target = baseline / ".cache/research-models/review.rds"
            target.parent.mkdir(parents=True)
            shutil.copy2(review, target)
        env = {k: v for k, v in os.environ.items() if k != "FRED_API"}
        env["BOOK_AS_OF"] = receipt["as_of"]
        subprocess.run(["python3", "-m", "scripts.notebooks.book", "build", "--replay", str(inputs)],
                       cwd=baseline, env=env, check=True)
        baseline_receipt = json.loads((baseline / ".cache/notebook-last-run.json").read_text())
        results = Path(baseline_receipt["directory"]) / "results"
        shutil.copytree(results, evidence / "baseline-results", dirs_exist_ok=True)
        command = '''source("scripts/benchmark_book.R")
args <- commandArgs(TRUE)
files <- lapply(args, function(path) sort(list.files(path, "\\\\.rds$", recursive=TRUE)))
stopifnot(length(files[[1]]) > 0L, identical(files[[1]], files[[2]]))
for (name in files[[1]]) {
  if (!book_numeric_equal(readRDS(file.path(args[1], name)), readRDS(file.path(args[2], name)), 1e-8))
    stop("Numerical comparison failed: ", name)
}
cat("Compared", length(files[[1]]), "complete numerical captures at absolute tolerance 1e-8\\n")
'''
        subprocess.run(["Rscript", "--vanilla", "-e", command,
                        str(results), str(run / "results")], cwd=root, check=True)
        if snapshots(inputs) != before:
            raise ValueError("Replay modified recorded provider inputs")
        (evidence / "summary.json").write_text(json.dumps({
            "baseline_sha": reference, "candidate_sha": receipt["source_sha"],
            "as_of": receipt["as_of"], "absolute_tolerance": 1e-8,
            "provider_inputs_unchanged": True, "passed": True,
        }, indent=2) + "\n")
    print("Baseline replay and complete numerical comparison passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    compare(parser.parse_args().reference)
