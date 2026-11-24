"""Offline image acceptance: execute an R kernel and render real rich outputs."""
import json
import argparse
from contextlib import nullcontext
import os
from pathlib import Path
import subprocess
import tempfile

from scripts.notebooks.book import ROOT, execute


def main():
    import nbformat
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Keep HTML and outputs for browser checks")
    args = parser.parse_args()
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    with (nullcontext(str(args.output)) if args.output else tempfile.TemporaryDirectory(prefix="money-notebook-smoke-")) as tmp:
        stage = Path(tmp)
        nb = nbformat.v4.new_notebook(metadata={"kernelspec": {
            "name": "money-r", "display_name": "Money Printer R", "language": "R"}})
        nb.cells = [nbformat.v4.new_markdown_cell("# R notebook smoke test\n"),
                    nbformat.v4.new_code_cell(f'setwd({json.dumps(str(ROOT))})\nsource("scripts/notebooks/bootstrap.R")'),
                    nbformat.v4.new_code_cell('stopifnot(getRversion() == "4.6.1")\nplot(1:5, 1:5)'),
                    nbformat.v4.new_code_cell('DT::datatable(data.frame(label = c("A", "B"), value = c(0, 2)))'),
                    nbformat.v4.new_code_cell('''suppressPackageStartupMessages(library(dplyr))
definitions <- parse("scripts/analysis/market_notebooks.R")
snapshot <- Filter(function(x) is.call(x) && identical(x[[1L]], as.name("<-")) &&
                   identical(x[[2L]], as.name("draw_market_snapshot")), definitions)
stopifnot(length(snapshot) == 1L)
eval(snapshot[[1L]])
df_tickers_yahoo <- data.frame(ticker = "FIXTURE",
  date = seq.Date(book_date() - 365, book_date(), length.out = 50), price = seq_len(50))
stopifnot(inherits(draw_market_snapshot("MISSING", "USD", "Unavailable"), "ggplot"))
draw_market_snapshot("FIXTURE", "USD", "Offline market snapshot")'''),
                    nbformat.v4.new_code_cell('visNetwork::visNetwork(data.frame(id=1:2), data.frame(from=1, to=2))')]
        source = stage / "source.ipynb"
        nbformat.write(nb, source)
        executed = execute(source, stage / "index.ipynb", ROOT, capture=False)
        mime = [output.get("data", {}) for c in executed.cells if c.cell_type == "code" for output in c.outputs]
        assert any("image/png" in item for item in mime), "R plots did not produce images"
        html = "\n".join(item.get("text/html", "") for item in mime)
        assert html.count("srcdoc=") >= 3, "Missing self-contained interactive widgets"
        # Offline CI mounts the image read-only. Quarto still needs a writable
        # cache even when rendering already-executed notebook outputs.
        subprocess.run(["quarto", "render", "index.ipynb", "--no-execute", "--to", "html"],
                       cwd=stage, env={**os.environ, "XDG_CACHE_HOME": str(stage / ".cache")},
                       check=True)
        from scripts.notebooks.assets import localize
        localize(stage)
        rendered = (stage / "index.html").read_text()
        assert "iframe" in rendered and "srcdoc" in rendered
        assert "data:image/png" in rendered or list(stage.rglob("*.png"))
        print("R kernel, static plots, DT, Plotly, visNetwork and Quarto smoke passed")


if __name__ == "__main__":
    main()
