"""Export the latest run's source responses for success or failure diagnostics."""
import json
from pathlib import Path
import shutil

from scripts.notebooks.book import ROOT


def collect(root=ROOT):
    receipt_path = root / ".cache/notebook-last-run.json"
    if not receipt_path.is_file():
        return
    receipt = json.loads(receipt_path.read_text())
    run = Path(receipt["directory"]).resolve()
    if not run.is_relative_to((root / ".cache/notebook-runs").resolve()):
        raise ValueError("Notebook receipt points outside its run directory")
    source = run / "inputs"
    if not source.is_dir():
        return
    target = root / ".cache/book-inputs"
    target.mkdir(parents=True, exist_ok=True)
    for path in source.iterdir():
        if path.is_file():
            shutil.copy2(path, target / path.name)
    (target / "source-sha.txt").write_text(receipt["source_sha"] + "\n")


if __name__ == "__main__":
    collect()
