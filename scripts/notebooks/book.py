"""Execute authoritative R notebooks once, then assemble a Quarto HTML book.

python -m scripts.notebooks.book build [--chapter PATH] [--replay DIR]
python -m scripts.notebooks.book preview --chapter PATH
python -m scripts.notebooks.book check
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]


def configuration(root=ROOT):
    import yaml
    return yaml.safe_load((root / "_quarto.yml").read_text())


def chapters(root=ROOT):
    return configuration(root)["book"]["chapters"]


def check(root=ROOT, require_clean=True):
    import nbformat
    expected = json.loads((root / "renv.lock").read_text())["R"]["Version"]
    paths = chapters(root)
    if len(paths) != len(set(paths)) or paths[0] != "index.ipynb":
        raise ValueError("Book requires a unique ordered chapter list beginning with index.ipynb")
    if Path(paths[-1]).stem != "Data_Status":
        raise ValueError("The data-status appendix must run last to aggregate all chapters")
    for name in paths:
        path = root / name
        nb = nbformat.read(path, as_version=4)
        nbformat.validate(nb)
        first_code = next((c.source for c in nb.cells if c.cell_type == "code"), "")
        if 'scripts/notebooks/bootstrap.R' not in first_code:
            raise ValueError(f"Missing project bootstrap in the first code cell: {name}")
        if nb.metadata.kernelspec.name != "money-r" or nb.metadata.language_info.version != expected:
            raise ValueError(f"Wrong project kernel or R version: {name}")
        for c in nb.cells:
            if require_clean and c.cell_type == "code" and (c.outputs or c.execution_count is not None):
                raise ValueError(f"Clear notebook outputs before committing: {name}:{c.id}")
            if c.cell_type == "markdown" and "`r " in c.source:
                raise ValueError(f"Unconverted inline knitr expression: {name}:{c.id}")
    print(f"Validated {len(paths)} clean R notebooks")


def clean(root=ROOT):
    """Explicit author action; builds never rewrite tracked notebooks."""
    import nbformat
    for name in chapters(root):
        nb = nbformat.read(root / name, as_version=4)
        for c in nb.cells:
            if c.cell_type == "code":
                c.outputs, c.execution_count = [], None
        nbformat.write(nb, root / name)


def capture_cells(nb):
    """Capture intermediate numerical domains formerly observed by knitr hooks."""
    import nbformat
    output = []
    for c in nb.cells:
        output.append(c)
        if c.cell_type == "code":
            output.append(nbformat.v4.new_code_cell(
                '#| include: false\nbook_capture_results(.GlobalEnv)\nbook_write_manifest()\n'))
    nb.cells = output
    return nb


def execute(path, destination, cwd, *, capture=True, timeout=3600):
    import nbformat
    from nbclient import NotebookClient
    nb = nbformat.read(path, as_version=4)
    # Disabled legacy experiments stay visible and non-executable in the editor,
    # while retaining their original hidden publication behavior.
    nb.cells = [c for c in nb.cells if not (
        c.cell_type == "markdown" and c.metadata.get("publication", {}).get("include") is False
    )]
    for c in nb.cells:
        if c.cell_type == "code":
            c.outputs, c.execution_count = [], None
    if capture:
        nb = capture_cells(nb)
    client = NotebookClient(nb, kernel_name="money-r", timeout=timeout,
                            allow_errors=False, resources={"metadata": {"path": str(cwd)}})
    try:
        client.execute()
        # IRkernel can report failed rich displays as streams rather than
        # execution errors. Those must not silently become a published page.
        for c in nb.cells:
            if c.cell_type == "code":
                for output in c.outputs:
                    if output.output_type == "stream" and re.search(
                        r"ERROR while rich displaying an object", output.text, re.I
                    ):
                        raise RuntimeError(f"Rich output failed in {path.name}, cell {c.id}")
                    data = output.get("data", {})
                    if "srcdoc=" in data.get("text/html", ""):
                        # Quarto must render the packaged HTML representation,
                        # rather than choose Plotly's separate JSON MIME bundle.
                        for mime in list(data):
                            if mime not in {"text/html", "text/plain"}:
                                del data[mime]
    finally:
        destination.parent.mkdir(parents=True, exist_ok=True)
        nbformat.write(nb, destination)
    return nb


def install_output(output, destination, run):
    """Prepare the complete replacement before moving the previous local book."""
    replacement = run / "validated-output"
    backup = run / "previous-output"
    shutil.copytree(output, replacement)
    had_previous = destination.exists()
    if had_previous:
        destination.rename(backup)
    try:
        replacement.rename(destination)
    except BaseException:
        if had_previous:
            backup.rename(destination)
        raise


def build(root=ROOT, chapter=None, replay=None, preview=False):
    from scripts.notebooks.environment import audit
    audit(root)
    check(root, require_clean=False)
    names = chapters(root)
    if chapter and chapter not in names:
        raise ValueError("--chapter must name a published notebook from _quarto.yml")
    selected = [chapter] if chapter else names
    options = configuration(root).get("notebook-publication", {})
    page_names = options.get("page-names", {})
    stage_names = {name: page_names.get(name, Path(name).stem) + ".ipynb" for name in names}
    if len(set(stage_names.values())) != len(names):
        raise ValueError("Notebook HTML page names must be unique")
    if any(Path(value).name != value for value in stage_names.values()):
        raise ValueError("Notebook page names must be plain filenames")
    # Each invocation is isolated; an earlier failed run cannot supply live inputs.
    run_id = datetime.now(ZoneInfo("UTC")).strftime("%Y%m%dT%H%M%S") + "-" + os.urandom(4).hex()
    run = root / ".cache" / "notebook-runs" / run_id
    stage = run / "book"
    stage.mkdir(parents=True)
    as_of = os.environ.get("BOOK_AS_OF")
    if not as_of and replay and (Path(replay) / "as-of.txt").is_file():
        as_of = (Path(replay) / "as-of.txt").read_text().strip()
    if not as_of and replay:
        as_of = subprocess.check_output([
            "Rscript", "--vanilla", "-e",
            'cat(as.character(readRDS(commandArgs(TRUE)[1L])$as_of))',
            str(Path(replay).resolve() / "manifest.rds"),
        ], text=True).strip()
    as_of = as_of or datetime.now(ZoneInfo("Europe/Copenhagen")).date().isoformat()
    datetime.strptime(as_of, "%Y-%m-%d")
    if not replay:
        (run / "inputs").mkdir()
        (run / "inputs/as-of.txt").write_text(as_of + "\n")
    env = {
        "BOOK_AS_OF": as_of, "BOOK_RUN_ID": run_id,
        "BOOK_SNAPSHOT_MODE": "replay" if replay else "record",
        "BOOK_SNAPSHOT_DIR": str(Path(replay).resolve()) if replay else str(run / "inputs"),
        "BOOK_DERIVED_DIR": str(root / ".cache/book-derived"),
        "BOOK_METRICS_FILE": str(run / "metrics.csv"),
        "BOOK_RESULTS_DIR": str(run / "results"),
    }
    before = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    start = time.monotonic()
    receipt = {"run_id": run_id, "as_of": as_of, "chapters": [], "complete": False,
               "mode": env["BOOK_SNAPSHOT_MODE"], "source_sha": subprocess.check_output(
                   ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()}
    try:
        # Read-only source assets are copied; personal inputs and credentials never enter staging.
        for name in ("scripts/book-style.css", "book.bib", "packages.bib"):
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / name, target)
        import yaml
        config = configuration(root)
        config.pop("notebook-publication", None)
        # Full-book navigation is retained for chapter preview; other sources remain unexecuted.
        for name in names:
            target = stage / stage_names[name]
            shutil.copy2(root / name, target)
        config["book"]["chapters"] = list(stage_names.values())
        for name in selected:
            os.environ["BOOK_CHAPTER_ID"] = Path(name).stem
            os.environ["BOOK_RESULTS_DIR"] = str(run / "results" / Path(name).stem)
            print("Executing", name, flush=True)
            execute(root / name, stage / stage_names[name], root)
            receipt["chapters"].append({"path": name, "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest()})
        (stage / "_quarto.yml").write_text(yaml.safe_dump(config, sort_keys=False))
        command = ["quarto", "render"]
        if chapter:
            command.append(stage_names[chapter])
        command.append("--no-execute")
        subprocess.run(command, cwd=stage, check=True)
        output = stage / "_book"
        from scripts.notebooks.assets import localize
        localize(output)
        if not chapter:
            from scripts.notebooks.validate import validate
            validate(output)
        # Publish only the completed artifact, never a partially rendered directory.
        destination = root / (".cache/notebook-preview" if chapter else "_book")
        install_output(output, destination, run)
        receipt["complete"] = True
        receipt["elapsed_seconds"] = time.monotonic() - start
        if preview:
            from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
            from functools import partial
            print("Preview: http://localhost:8000/" + Path(stage_names[chapter]).with_suffix(".html").name, flush=True)
            ThreadingHTTPServer(("0.0.0.0", 8000), partial(SimpleHTTPRequestHandler, directory=str(destination))).serve_forever()
        return run
    finally:
        receipt["elapsed_seconds"] = time.monotonic() - start
        (run / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        (root / ".cache/notebook-last-run.json").write_text(json.dumps({"directory": str(run), **receipt}, indent=2) + "\n")
        os.environ.pop("BOOK_CHAPTER_ID", None)
        for k, value in before.items():
            if value is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "preview", "check", "clean"))
    parser.add_argument("--chapter")
    parser.add_argument("--replay", type=Path)
    args = parser.parse_args()
    if args.command == "check":
        check()
    elif args.command == "clean":
        clean()
    else:
        if args.command == "preview" and not args.chapter:
            parser.error("preview requires --chapter")
        build(chapter=args.chapter, replay=args.replay, preview=args.command == "preview")


if __name__ == "__main__":
    main()
