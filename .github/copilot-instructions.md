# Copilot instructions for this repository

## Build, run, and validation commands

### Bookdown site (repository root)
- Restore R environment: `Rscript -e "renv::restore()"`
- Build the full book (CI renders `index.Rmd`): `Rscript -e "bookdown::render_book('index.Rmd', output_format = 'bookdown::gitbook')"`
- Build a single chapter file (targeted run pattern): `Rscript -e "rmarkdown::render('Chapters/03_InterestRates/InterestRates.Rmd')"`

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
- No repository-wide automated test suite or lint task is currently configured (no project test/lint config files were found).
- Single-test command is therefore not available in the current codebase.

## High-level architecture

### 1) Book publication layer
- `index.Rmd` is the bookdown entry point.
- `_bookdown.yml` controls which chapter subdirectories are rendered; many chapter groups are present but commented out, so edit this file when changing published scope.
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

- `renv` is the default R dependency workflow; root and subprojects use `.Rprofile` to source `renv/activate.R`.
- Chapter and vignette content is maintained as paired `.Rmd` + `.ipynb` files; keep both in sync when making structural edits.
- FRED credentials are expected through the `FRED_API` environment variable.
  Use a local `.Renviron` file for development; GitHub Actions injects the
  repository secret directly and never writes it to disk.
- Shared R visuals commonly source `money_theme.R`; preserve this styling hook in chapter updates.
- Output artifact convention in `datacollection` is date-partitioned directories with sequential names:
  - plots: `output/YYYY_MM_DD/plots/plotNNN.png`
  - tables: `output/YYYY_MM_DD/tables/tableNNN.rds`
- `dashboard.py` is the source of truth for dashboard runtime settings and currently binds to port `8051`; keep README/run commands aligned if changing ports.
