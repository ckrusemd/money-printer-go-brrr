"""Compatibility check only: authoritative notebooks are never regenerated."""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.notebooks.book import check


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check:
        parser.error("Rmd synchronization is retired. Edit ipynb files directly; use --check to validate them.")
    check()


if __name__ == "__main__":
    main()
