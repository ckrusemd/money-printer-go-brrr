"""Pin a validated image digest for VS Code and resolve that same image in CI."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from scripts.publication_image_key import image_key

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "ghcr.io/ckrusemd/money-printer-go-brrr-r"


def pinned(root=ROOT):
    config = json.loads((root / ".devcontainer/devcontainer.json").read_text())
    image = config.get("image", "")
    if not re.fullmatch(re.escape(REPOSITORY) + r"@sha256:[a-f0-9]{64}", image):
        raise ValueError("Publication is not promoted: build/validate the image, then run python -m scripts.notebooks.image pin IMAGE@sha256:DIGEST")
    return image


def verify(image, root=ROOT):
    if not re.fullmatch(re.escape(REPOSITORY) + r"@sha256:[a-f0-9]{64}", image):
        raise ValueError("Expected a digest in the fixed publication repository")
    subprocess.run(["docker", "pull", image], check=True)
    actual = subprocess.check_output(["docker", "inspect", "--format",
        '{{index .Config.Labels "org.money-printer.context"}}', image], text=True).strip()
    if actual != image_key(root):
        raise ValueError("Image dependency fingerprint does not match this checkout")
    subprocess.run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "Rscript",
        "-v", f"{root}:/project:ro", "-w", "/project", image,
        "--vanilla", "scripts/notebooks/environment.R"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["resolve", "pin", "verify"])
    parser.add_argument("image", nargs="?")
    args = parser.parse_args()
    if args.command == "resolve":
        image = pinned()
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a") as stream:
                stream.write("image=" + image + "\n")
        print(image)
    elif args.command == "verify":
        verify(args.image or pinned())
    else:
        if not args.image:
            parser.error("pin requires a digest reference")
        verify(args.image)
        # A promotion also proves the notebook execution and HTML/widget path.
        subprocess.run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python3",
            "-v", f"{ROOT}:/project:ro", "-w", "/project", args.image,
            "-m", "scripts.notebooks.smoke"], check=True)
        path = ROOT / ".devcontainer/devcontainer.json"
        config = json.loads(path.read_text())
        config.pop("build", None)
        config["image"] = args.image
        path.write_text(json.dumps(config, indent=2) + "\n")


if __name__ == "__main__":
    main()
