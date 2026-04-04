#!/usr/bin/env python3
"""
Convert R Markdown (.Rmd) files to Jupyter Notebook (.ipynb) format.
This script preserves code blocks as code cells and markdown as markdown cells.
"""

import os
import json
import re
from pathlib import Path
import argparse


def parse_rmd_content(content):
    """Parse R Markdown content and extract YAML header, markdown, and code chunks."""
    lines = content.split('\n')

    # Extract YAML header
    yaml_header = []
    in_yaml = False
    content_start = 0

    if lines[0].strip() == '---':
        in_yaml = True
        yaml_header.append('---')
        for i, line in enumerate(lines[1:], 1):
            if line.strip() == '---':
                yaml_header.append('---')
                content_start = i + 1
                break
            yaml_header.append(line)

    # Parse the rest of the content
    cells = []
    current_cell = {"type": "markdown", "content": []}

    # Add YAML header as first markdown cell if it exists
    if yaml_header:
        title_info = []
        for line in yaml_header[1:-1]:  # Skip the --- markers
            if line.strip():
                title_info.append(line)

        if title_info:
            cells.append({
                "type": "markdown",
                "content": title_info
            })

    i = content_start
    while i < len(lines):
        line = lines[i]

        # Check for R code chunk start
        if re.match(r'^```\{r.*\}', line):
            # Save current markdown cell if it has content
            if current_cell["content"]:
                cells.append(current_cell)
                current_cell = {"type": "markdown", "content": []}

            # Start new code cell
            code_cell = {"type": "code", "content": []}
            i += 1

            # Read until end of code chunk
            while i < len(lines) and lines[i].strip() != '```':
                code_cell["content"].append(lines[i])
                i += 1

            cells.append(code_cell)
            i += 1
            continue

        # Regular content goes to markdown cell
        current_cell["content"].append(line)
        i += 1

    # Add final markdown cell if it has content
    if current_cell["content"]:
        cells.append(current_cell)

    return cells


def create_jupyter_notebook(cells):
    """Create a Jupyter notebook structure from parsed cells."""
    notebook = {
        "cells": [],
        "metadata": {
            "kernelspec": {
                "display_name": "R",
                "language": "R",
                "name": "ir"
            },
            "language_info": {
                "codemirror_mode": "r",
                "file_extension": ".r",
                "mimetype": "text/x-r-source",
                "name": "R",
                "pygments_lexer": "r",
                "version": "4.0.0"
            }
        },
        "nbformat": 4,
        "nbformat_minor": 4
    }

    for cell in cells:
        if cell["type"] == "markdown":
            # Clean up markdown content
            content = []
            for line in cell["content"]:
                content.append(line)

            # Remove empty lines at the beginning and end
            while content and not content[0].strip():
                content.pop(0)
            while content and not content[-1].strip():
                content.pop()

            if content:  # Only add cell if it has content
                nb_cell = {
                    "cell_type": "markdown",
                    "metadata": {},
                    "source": content
                }
                notebook["cells"].append(nb_cell)

        elif cell["type"] == "code":
            # Clean up code content
            content = []
            for line in cell["content"]:
                content.append(line)

            # Remove empty lines at the beginning and end
            while content and not content[0].strip():
                content.pop(0)
            while content and not content[-1].strip():
                content.pop()

            if content:  # Only add cell if it has content
                nb_cell = {
                    "cell_type": "code",
                    "execution_count": None,
                    "metadata": {},
                    "outputs": [],
                    "source": content
                }
                notebook["cells"].append(nb_cell)

    return notebook


def convert_rmd_to_ipynb(rmd_path, output_path=None):
    """Convert a single R Markdown file to Jupyter notebook."""
    if output_path is None:
        output_path = rmd_path.with_suffix('.ipynb')

    print(f"Converting {rmd_path} -> {output_path}")

    # Read the R Markdown file
    with open(rmd_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Parse the content
    cells = parse_rmd_content(content)

    # Create Jupyter notebook
    notebook = create_jupyter_notebook(cells)

    # Write the notebook
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(notebook, f, indent=2, ensure_ascii=False)

    print(f"Successfully converted to {output_path}")


def main():
    """Main function to convert all Rmd files in the directory."""
    parser = argparse.ArgumentParser(description='Convert R Markdown files to Jupyter notebooks')
    parser.add_argument('--directory', '-d', default='.',
                       help='Directory to search for Rmd files (default: current directory)')
    parser.add_argument('--pattern', '-p', default='**/*.Rmd',
                       help='Pattern to match Rmd files (default: **/*.Rmd)')

    args = parser.parse_args()

    # Find all Rmd files
    root_path = Path(args.directory)
    rmd_files = list(root_path.glob(args.pattern))

    if not rmd_files:
        print(f"No Rmd files found matching pattern '{args.pattern}' in {root_path}")
        return

    print(f"Found {len(rmd_files)} Rmd files to convert:")
    for rmd_file in rmd_files:
        print(f"  {rmd_file}")

    print("\nStarting conversion...")

    # Convert each file
    for rmd_file in rmd_files:
        try:
            convert_rmd_to_ipynb(rmd_file)
        except Exception as e:
            print(f"Error converting {rmd_file}: {e}")

    print(f"\nConversion complete! Converted {len(rmd_files)} files.")


if __name__ == "__main__":
    main()