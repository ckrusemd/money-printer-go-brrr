"""Fingerprint exactly the publication Docker context, never research data."""
import hashlib
from pathlib import Path
try:
    from scripts.internal_packages import sources
except ModuleNotFoundError:  # Also support python scripts/publication_image_key.py.
    from internal_packages import sources

ROOT = Path(__file__).resolve().parents[1]
INPUTS = (".dockerignore", "Dockerfile", "renv/activate.R",
          "renv.lock", "renv/settings.json", "scripts/notebooks/requirements.lock",
          "scripts/internal_packages.py")


def input_paths(root=ROOT):
    return (*INPUTS, *sources(root))


def image_key(root=ROOT):
    digest = hashlib.sha256()
    for name in input_paths(root):
        contents = (root / name).read_bytes()
        digest.update(name.encode() + b"\0")
        digest.update(str(len(contents)).encode() + b"\0" + contents)
    return digest.hexdigest()


if __name__ == "__main__":
    print(image_key())
