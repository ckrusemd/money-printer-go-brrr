# Copilot instructions for this repository

## Build, run, and validation commands

### Bookdown site (repository root)
- Restore R environment: `Rscript -e "renv::restore()"`
- Build the full book (CI renders `index.Rmd`): `Rscript --vanilla -e "bookdown::render_book('index.Rmd', output_format = 'bookdown::gitbook')"`
- The initial hidden setup in `index.Rmd` initializes the shared runtime before chapters. Chapters and galleries can depend on earlier setup and objects; a standalone `rmarkdown::render()` is not an equivalent full-book validation.

### Data collection and modeling notebooks (`datacollection/`)
- Run ETL notebook: `jupyter notebook datacollection/01_etl.ipynb`
- Run modeling notebook: `jupyter notebook datacollection/02_models.ipynb`
- Run storage benchmark notebook: `jupyter notebook datacollection/database_benchmark.ipynb`

### Knowledge graph dashboard (`knowledgegraph/app/`)
- Install Python dependencies: `cd knowledgegraph/app && pip install -r requirements.txt`
- Build the dashboard database: `cd knowledgegraph/app && jupyter notebook create_database.ipynb`
- Run the dashboard directly: `cd knowledgegraph/app && python dashboard.py`
- Alternate launcher with preflight checks: `cd knowledgegraph/app && python run_app.py`

### Tests and lint
- Offline runtime fixtures: `Rscript --vanilla tests/test_book_runtime.R`.
- Python fixture suite: `python3 -m unittest discover -s tests -p 'test_*.py'`.
- Catalogue fixtures only: `python3 -m unittest discover -s tests -p 'test_investment_catalogue.py'`.
- Shared R syntax: `Rscript --vanilla -e "invisible(parse(file = 'money_theme.R')); invisible(parse(file = 'scripts/book_runtime.R'))"`.
- After a complete render: `Rscript --vanilla scripts/check_bookdown_output.R` verifies required pages, the home title, the tax anchor, and local chart-image references.
- If locked R packages are unavailable locally, run R checks in `ghcr.io/ckrusemd/money-printer-go-brrr-r:latest` with the repository mounted at `/project`; see README for the Docker command.

## High-level architecture

### 1) Book publication layer
- `index.Rmd` is the bookdown entry point.
- `_bookdown.yml` explicitly lists published chapter files in order; currency and crypto drafts are not currently included. Change published scope only when requested.
- `scripts/book_runtime.R` owns source retrieval, derived caching, the fixed analysis date, and timing hooks; the initial hidden chunk in `index.Rmd` sources it once.
- `scripts/book-style.css` supplies responsive GitBook layout and visible keyboard focus. Maintain readable chart aspect ratios and existing URLs/anchor IDs.
- `.github/workflows/deploy_bookdown.yml` is the deployment pipeline: render book, upload `_book/`, deploy to GitHub Pages.

### 2) Data ingestion + modeling layer (`datacollection/`)
- `01_etl.ipynb` collects data from multiple sources (FRED, Yahoo, DST, FinansDanmark, housing files) and writes to DuckDB (`data/financial_data.duckdb`, table `financial_data`).
- `02_models.ipynb` reads from a read-only DuckDB copy, runs modeling/analysis, and writes artifacts (parquet outputs plus plots/tables/report assets).
- `database_benchmark.ipynb` benchmarks storage/query performance across DuckDB, SQLite, Parquet, and CSV.

### 3) Reporting utility layer (`datacollection/*.R`)
- `save_plot.R` and `save_table.R` standardize artifact persistence and numbering.
- `generate_report.R` turns plot/table objects into PowerPoint slides using a PowerPoint template.
- `powerpoint_with_annotations.R` is an alternate slide generator that can annotate table/image content before slide creation.

### 4) Knowledge graph layer (`knowledgegraph/`)
- `KnowledgeGraph_FRED_Analysis.ipynb` produces network/correlation exports.
- `knowledgegraph/app/create_database.ipynb` ingests CSV exports into `knowledge_graph.db`, creating tables (`nodes`, `edges`, `correlations`, `leadership`, `stock_relationships`, `metadata`) and views used by the app.
- `knowledgegraph/app/dashboard.py` is a Dash app that loads all data at startup and serves tabbed visual analytics.

## Repository-specific conventions

- `renv.lock` defines the publication dependencies. Restore explicitly during setup or container creation, never dynamically during a render; do not add packages as an optimization shortcut.
- Chapter and vignette content is maintained as paired `.Rmd` + `.ipynb` files; keep both in sync when making structural edits.
- FRED credentials are expected through the `FRED_API` environment variable.
  Export `FRED_API` before `Rscript --vanilla`, which does not automatically
  read `.Renviron`; ordinary interactive sessions can use a local `.Renviron`.
  GitHub Actions injects the repository secret directly and never writes it to disk.
- Shared R visuals commonly source `money_theme.R`; preserve this styling hook in chapter updates.
- The theme guards runtime loading with `exists("book_fred", mode = "function")`; repeated theme loads must not replace observation caches.
- Use `book_fred(series_id, ...)`, `book_yahoo(ticker, ...)` (returns xts directly), and `book_dst(...)` for shared source retrieval; use `book_load_packages(...)` to load existing dependencies and `book_date()` for rolling analysis windows.
- `book_cache_derived(namespace, inputs, compute, packages = character(), code = NULL)` takes a zero-argument function. Include all result-affecting input content and helper code in its key, declare package dependencies, and preserve statistical methods and RNG behavior.
- Live publication must retrieve essential data and fail on retrieval errors. `BOOK_SNAPSHOT_MODE=record`/`replay` supports reproducible fixtures and benchmarking; replay snapshots are not fresh publication data.
- Compare complete cold/warm renders using identical inputs and `BOOK_AS_OF`. Target at least 30% lower warm runtime without reducing chart coverage or changing statistical methods; report measured results.
- Every market/gallery chart needs descriptive `fig.alt` text covering units and panel meaning. Describe computed data accurately; the current market extraction selects Yahoo opening prices, not adjusted closes.
- Output artifact convention in `datacollection` is date-partitioned directories with sequential names:
  - plots: `output/YYYY_MM_DD/plots/plotNNN.png`
  - tables: `output/YYYY_MM_DD/tables/tableNNN.rds`
- `dashboard.py` is the source of truth for dashboard runtime settings and currently binds to port `8051`; keep README/run commands aligned if changing ports.
