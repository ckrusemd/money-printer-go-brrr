"""Create an untracked historical book with current snapshot adapters only.

Analysis, joins, model fitting, charts and chapter order remain historical.
Only retrieval, dependency loading and date reads are adapted for offline replay.
"""

import argparse
import io
from pathlib import Path
import re
import shutil
import subprocess
import tarfile


def adapt_source(text):
    text = re.sub(r"if \(!require\(pacman\)\) \{ install.packages\(\"pacman\"\) \}", "", text)
    text = text.replace("pacman::p_load(", "book_load_packages(")
    text = text.replace("fredr::fredr_set_key(", 'if (.book_runtime$mode != "replay") fredr::fredr_set_key(')
    text = text.replace("fredr::fredr_series_observations(", "book_fred(")
    text = text.replace("fredr::fredr(", "book_fred(")
    text = re.sub(r"(?<![\w:])fredr\(", "book_fred(", text)
    text = text.replace("fredr::fredr_tags_series(", 'book_fred_metadata("fredr_tags_series", ')
    text = text.replace("fredr::fredr_series(", 'book_fred_metadata("fredr_series", ')
    text = re.sub(r"(?:dkstat::)?\bdst_get_data\(", "book_dst(", text)
    text = re.sub(r"(?:dkstat::)?\bdst_meta\(", "book_dst_metadata(", text)
    text = text.replace("getSymbols(", "book_yahoo(")
    text = text.replace("openxlsx::read.xlsx(xlsxFile = xlsx_url", "book_workbook(url = xlsx_url")
    # Leave YAML's display date intact; all analytical windows are frozen.
    if text.startswith("---"):
        end = text.find("\n---", 3)
        text = text[:end + 4] + text[end + 4:].replace("Sys.Date()", "book_date()")
    else:
        text = text.replace("Sys.Date()", "book_date()")
    return text


def prepare(ref, target, repository):
    if target.exists():
        raise ValueError(f"Baseline destination already exists: {target}")
    target.mkdir(parents=True)
    archive = subprocess.run(["git", "archive", ref], cwd=repository,
                             check=True, stdout=subprocess.PIPE).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
        tree.extractall(target, filter="data")
    for path in [target / "index.Rmd", *sorted((target / "Chapters").glob("*/*.Rmd"))]:
        path.write_text(adapt_source(path.read_text()), encoding="utf-8")
    runtime = target / "scripts" / "book_runtime.R"
    runtime.parent.mkdir(exist_ok=True)
    shutil.copyfile(repository / "scripts" / "book_runtime.R", runtime)
    theme = target / "money_theme.R"
    original = theme.read_text()
    beginning = original.index("theme_money_printer_go_brrr <- function")
    theme.write_text('source("scripts/book_runtime.R")\n\n' + original[beginning:], encoding="utf-8")
    index = target / "index.Rmd"
    text = index.read_text()
    text = re.sub(r"(```\{r[^\n]*\}\n)", '\\1source("scripts/book_runtime.R")\n', text, count=1)
    index.write_text(text, encoding="utf-8")
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    print(prepare(args.ref, args.output.resolve(), repository))


if __name__ == "__main__":
    main()
