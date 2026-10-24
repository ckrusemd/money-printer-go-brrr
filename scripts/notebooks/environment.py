"""Audit the container identity and the pinned notebook execution tools."""
from importlib.metadata import version
import os
import re
import subprocess

from scripts.notebooks.book import ROOT
from scripts.publication_image_key import image_key


def audit(root=ROOT):
    expected = image_key(root)
    actual = os.environ.get("NOTEBOOK_IMAGE_CONTEXT")
    bootstrap = actual == "development" and os.environ.get("NOTEBOOK_REQUIRE_PIN") != "true"
    if actual != expected and not bootstrap:
        raise ValueError("Container does not match the dependency context. Reopen the devcontainer or rebuild and promote its image.")
    for line in (root / "scripts/notebooks/requirements.lock").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            package, locked = line.split("==", 1)
            if version(package) != locked:
                raise ValueError("Locked Python package mismatch: " + package)
    quarto = re.search(r"^ARG QUARTO_VERSION=(\S+)$", (root / "Dockerfile").read_text(), re.M)[1]
    installed = subprocess.check_output(["quarto", "--version"], text=True).strip()
    if installed != quarto:
        raise ValueError("Locked Quarto version mismatch")
    from jupyter_client.kernelspec import KernelSpecManager
    kernel = KernelSpecManager().get_kernel_spec("money-r")
    if "--vanilla" not in kernel.argv:
        raise ValueError("The project R kernel must start with --vanilla")


if __name__ == "__main__":
    audit()
    subprocess.run(["Rscript", "--vanilla", "scripts/notebooks/environment.R"], cwd=ROOT, check=True)
    print("Notebook container, Python, Quarto and R environment verified")
