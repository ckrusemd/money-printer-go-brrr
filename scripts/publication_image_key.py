"""Fingerprint exactly the publication Docker context, never research data."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INPUTS = (".dockerignore", "Dockerfile", "renv/activate.R",
          "renv.lock", "renv/settings.json", "scripts/notebooks/requirements.lock")


def image_key(root=ROOT):
    digest = hashlib.sha256()
    for name in INPUTS:
        contents = (root / name).read_bytes()
        digest.update(name.encode() + b"\0")
        digest.update(str(len(contents)).encode() + b"\0" + contents)
    return digest.hexdigest()


if __name__ == "__main__":
    print(image_key())
