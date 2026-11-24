"""Stage the real home notebook with explicit synthetic inputs for offline CI.

There is no fixture mode in the production renderer or research providers.
The workflow binds this temporary notebook over the read-only source mount.
"""
import argparse
from pathlib import Path

from scripts.notebooks.book import ROOT


def stage(output):
    import nbformat
    source = ROOT / "index.ipynb"
    if output.resolve() == source.resolve():
        raise ValueError("Refusing to replace the authoritative source notebook")
    notebook = nbformat.read(source, as_version=4)
    cells = [cell for cell in notebook.cells if cell.cell_type == "code"]
    marker = "ctx <- research_context(forecasts=TRUE)"
    if not cells or cells[0].source.count(marker) != 1:
        raise ValueError("Home bootstrap changed; update the explicit offline fixture")
    cells[0].source = cells[0].source.replace(marker, 'source("tests/fixtures/research_home.R")')
    output.parent.mkdir(parents=True, exist_ok=True)
    nbformat.write(notebook, output)
    print("Staged real home presentation with synthetic offline inputs:", output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    stage(parser.parse_args().output)
