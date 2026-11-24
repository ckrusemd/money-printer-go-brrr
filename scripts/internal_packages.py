"""Fingerprint/install/audit only the explicitly registered internal R package."""
import argparse
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "dstcollect"
SOURCE = "packages/dstcollect"


def sources(root=ROOT):
    return sorted(p.relative_to(root).as_posix() for p in (root / SOURCE).rglob("*")
                  if p.is_file() and not any(s in {".git", "__pycache__", ".Rcheck"} for s in p.parts))


def fingerprint(root=ROOT):
    digest = hashlib.sha256()
    for name in sources(root):
        content = (root / name).read_bytes()
        digest.update(name.encode() + b"\0" + str(len(content)).encode() + b"\0" + content)
    return digest.hexdigest()


def audit(root=ROOT):
    result = subprocess.check_output(["Rscript", "--vanilla", "-e",
        'cat(readLines(system.file("SOURCE_SHA256", package="dstcollect")))'], text=True).strip()
    if result != fingerprint(root):
        raise ValueError("Internal dstcollect source differs from the installed container package; rebuild/promote the image")


def install(root=ROOT):
    subprocess.run(["R", "CMD", "INSTALL", str(root / SOURCE)], check=True)
    location = subprocess.check_output(["Rscript", "--vanilla", "-e",
        'cat(system.file(package="dstcollect"))'], text=True).strip()
    (Path(location) / "SOURCE_SHA256").write_text(fingerprint(root) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "audit", "hash"])
    args = parser.parse_args()
    if args.command == "hash":
        print(fingerprint())
    else:
        {"install": install, "audit": audit}[args.command]()
