"""Synchronize existing published Rmd/notebook pairs, or check them in CI."""

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from convert_rmd_to_ipynb import parse_rmd_content, create_jupyter_notebook


def expected_notebook(path):
    notebook = create_jupyter_notebook(parse_rmd_content(path.read_text(encoding="utf-8")))
    notebook["metadata"]["language_info"]["version"] = json.loads(
        (ROOT / "renv.lock").read_text(encoding="utf-8")
    )["R"]["Version"]
    return notebook


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    files = re.findall(r"^\s*-\s+(\S+\.Rmd)\s*$", (ROOT / "_bookdown.yml").read_text(), re.M)
    stale = []
    for name in files:
        rmd = ROOT / name
        notebook = rmd.with_suffix(".ipynb")
        if not notebook.exists():
            continue
        expected = expected_notebook(rmd)
        existing = json.loads(notebook.read_text(encoding="utf-8"))
        if existing == expected:
            continue
        stale.append(name)
        if not args.check:
            notebook.write_text(json.dumps(expected, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.check and stale:
        print("Unsynchronized published notebooks: " + ", ".join(stale), file=sys.stderr)
        return 1
    print(f"Published notebook pairs {'checked' if args.check else 'synchronized'}; changed: {len(stale)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
