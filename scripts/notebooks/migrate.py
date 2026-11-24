"""One-time, explicit migration of legacy Rmd sources. Never run by publication."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def split_options(text):
    """Split R chunk options without breaking strings or function arguments."""
    parts, start, depth, quote, escaped = [], 0, 0, None, False
    for i, char in enumerate(text):
        if escaped:
            escaped = False
        elif char == "\\" and quote:
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:i].strip())
            start = i + 1
    parts.append(text[start:].strip())
    result = {}
    for part in parts:
        if not part:
            continue
        if "=" in part:
            key, value = part.split("=", 1)
            result[key.strip()] = value.strip()
        else:
            result["label"] = part
    return result


def cell(kind, source, metadata=None):
    result = {"cell_type": kind, "metadata": metadata or {}, "source": source.splitlines(True)}
    result["id"] = hashlib.sha256((kind + source).encode()).hexdigest()[:12]
    if kind == "code":
        result.update(outputs=[], execution_count=None)
    return result


def convert(content, version="4.6.1"):
    content = content.replace("\r\n", "\n")
    content = re.sub(r"\A---\n.*?\n---\n", "", content, flags=re.S)
    chunks, position = [], 0
    for match in re.finditer(r"^```\{r([^\n]*)\}\s*\n(.*?)^```\s*$", content, re.M | re.S):
        if content[position:match.start()].strip():
            chunks.append(cell("markdown", content[position:match.start()].strip() + "\n"))
        options = split_options(match[1])
        code = match[2].strip() + "\n"
        # Notebook execution does not interpret knitr options.
        code = re.sub(r"^.*knitr::opts_chunk\$set\([^\n]*\)\s*\n?", "", code, flags=re.M)
        code = re.sub(r'^if \(file.exists\("Renviron.site"\)\).*\n?', '', code, flags=re.M)
        if options.get("eval") in {"F", "FALSE", "false"}:
            metadata = {"legacy_chunk": options}
            if options.get("echo") not in {"T", "TRUE", "true"}:
                metadata["publication"] = {"include": False}
            chunks.append(cell("markdown", "```r\n" + code + "```\n", metadata))
        elif code.strip():
            echo = "true" if options.get("echo") in {"T", "TRUE", "true"} else "false"
            headers = ["#| echo: " + echo, "#| warning: false"]
            if options.get("include") in {"F", "FALSE", "false"}:
                headers.append("#| include: false")
            if "label" in options:
                headers.append("#| label: " + options["label"])
            for key in ("fig.alt",):
                value = options.get(key)
                if value and value[:1] in {'"', "'"}:
                    headers.append("#| fig-alt: " + json.dumps(value[1:-1]))
            if options.get("results", "").strip("\"'") == "asis":
                headers.append("#| output: asis")
            setup = []
            dimensions = {"repr.plot.width": options.get("fig.width", "10"),
                          "repr.plot.height": options.get("fig.height", "7"),
                          "repr.plot.res": options.get("dpi", "120")}
            setup.append("options(" + ", ".join(k + " = " + v for k, v in dimensions.items()) + ")")
            # Turn dynamically calculated figure descriptions into display metadata.
            alt = options.get("fig.alt")
            if alt:
                setup.append("options(book.figure.alt = " + alt + ")")
            chunks.append(cell("code", "\n".join(headers + setup) + "\n" + code,
                               {"legacy_chunk": options}))
        position = match.end()
    if content[position:].strip():
        chunks.append(cell("markdown", content[position:].strip() + "\n"))
    # Duplicate content is valid, but cell IDs must be unique.
    for i, item in enumerate(chunks):
        item["id"] = hashlib.sha256((str(i) + ''.join(item['source'])).encode()).hexdigest()[:12]
    return {"nbformat": 4, "nbformat_minor": 5, "cells": chunks,
            "metadata": {"kernelspec": {"name": "money-r", "language": "R",
                                         "display_name": "Money Printer R " + version},
                         "language_info": {"name": "R", "version": version,
                                           "file_extension": ".r", "mimetype": "text/x-r-source"}}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Explicitly replace legacy-generated notebooks")
    args = parser.parse_args()
    if not args.write:
        parser.error("Migration replaces notebooks. Review sources, then pass --write exactly once.")
    version = json.loads((ROOT / "renv.lock").read_text())["R"]["Version"]
    for path in sorted(ROOT.rglob("*.Rmd")):
        if any(part.startswith('.') for part in path.relative_to(ROOT).parts):
            continue
        notebook = convert(path.read_text(), version)
        path.with_suffix(".ipynb").write_text(json.dumps(notebook, indent=1, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
