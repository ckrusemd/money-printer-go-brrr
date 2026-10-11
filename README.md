# Money Printer Go BRRR

> Since 1971, Money Printer Has Gone BRRR. Let's Make the Most of It.

A collection of macroeconomic analysis notebooks covering interest rates, housing markets, equity indices, and ETFs — published as a [bookdown site](https://ckrusemd.github.io/money-printer-go-brrr/).

## Project Structure

```
├── index.Rmd                     # Bookdown entry point
├── _bookdown.yml                 # Published chapter order
├── money_theme.R                 # Shared ggplot2 theme
├── scripts/
│   ├── book_runtime.R            # Shared source retrieval, derived cache, timing
│   ├── book-style.css            # Accessible links and responsive book layout
│   └── check_bookdown_output.R   # Rendered page and chart-image checks
├── tests/                        # Runtime fixtures and investment catalogue tests
├── Chapters/
│   ├── 00_ReleaseCalendar/       # Economic release calendar
│   ├── 01_Indicators/            # Leading & lagging indicators
│   ├── 02_Housing/               # US & Danish housing markets
│   ├── 03_InterestRates/         # Interest rates & yield curves
│   ├── 04_Markets/               # Market snapshots and detailed chart galleries
│   ├── 05_ETFs/                  # ETF analysis
│   ├── 06_Currency/              # Unpublished chapter draft
│   └── 07_Crypto/                # Unpublished chapter draft
├── vignettes/                    # Standalone analysis notebooks
├── datacollection/               # ETL pipeline & modeling
│   ├── 01_etl.ipynb              # Data ingestion (FRED, Yahoo, DST, etc.)
│   ├── 02_models.ipynb           # Modeling & analytics
│   └── database_benchmark.ipynb  # Storage benchmarks
└── knowledgegraph/               # Network analysis & dashboard
    └── app/                      # Dash analytics dashboard
```

## Data Sources

- [FRED](https://fred.stlouisfed.org/) (Federal Reserve Economic Data)
- [Yahoo Finance](https://finance.yahoo.com/)
- [Statistics Denmark (DST)](https://www.dst.dk/)
- [FinansDanmark](https://finansdanmark.dk/)

## Setup

### Prerequisites

- R (≥ 4.0) with [renv](https://rstudio.github.io/renv/)
- Python 3 with Jupyter (for ETL and dashboard)
- A [FRED API key](https://fred.stlouisfed.org/docs/api/api_key.html)

### Quick Start

```bash
# Clone
git clone https://github.com/ckrusemd/money-printer-go-brrr.git
cd money-printer-go-brrr

# Supply FRED credentials in the process environment (do not commit credentials)
export FRED_API=your_key_here

# Restore R dependencies
Rscript -e "renv::restore()"

# Build the book
Rscript --vanilla -e "bookdown::render_book('index.Rmd', output_format = 'bookdown::gitbook')"
```

Dependency restoration is an explicit setup step. Rendering uses the installed,
locked dependencies and must not restore the environment or install packages
from inside a chapter.
`Rscript --vanilla` does not automatically read `.Renviron`; export `FRED_API`
before rendering, as above.

### Book runtime and freshness

The first hidden setup chunk in `index.Rmd` sources `scripts/book_runtime.R`
once, before loading chapters. `money_theme.R` loads it only if `book_fred`
is missing, so repeated theme loads preserve the render's source cache.

- `book_fred(series_id, ...)` forwards observation requests to FRED.
- `book_ecb_data(key, ...)` records the original ECB parsed observations.
- `book_yahoo(ticker, ...)` returns an xts price history like
  `quantmod::getSymbols(ticker, env = NULL)`; it does not assign symbols.
- `book_dst(...)` forwards requests to Statistics Denmark.
- `book_load_packages(...)` loads installed dependencies and fails if one is
  missing; it never installs packages.
- `book_date()` gives the build's fixed analysis date, optionally set with
  `BOOK_AS_OF=YYYY-MM-DD`.
- `book_cache_derived(namespace, inputs, compute, packages = character(), code = NULL)`
  calls the zero-argument `compute` function on a miss. Keys include input
  content, computation code, declared package versions, R version, and RNG
  state. On a hit it restores the RNG state that followed the original
  computation. Include every external input in `inputs` and helper definitions
  in `code` when they affect a result.

`BOOK_SNAPSHOT_MODE` defaults to `live`: retrieve current essential data and
deduplicate identical requests within the render. `record` also saves source
responses and a manifest; `replay` reads those snapshots for reproducible,
offline validation and fails on missing requests. Replay is for validation,
not scheduled publication. Live retrieval failures must not fall back to
old snapshots. Derived cache hits reuse calculations only after their input
content matches.

`BOOK_SNAPSHOT_DIR`, `BOOK_DERIVED_DIR`, and `BOOK_METRICS_FILE` default to
`.cache/book-inputs`, `.cache/book-derived`, and `.cache/book-metrics.csv`.
Keep benchmark runs isolated and use the same recorded inputs and `BOOK_AS_OF`
for cold/warm comparisons. The optimization target is at least a 30% reduction
in warm full-book runtime while preserving methods and chart coverage;
measure it from completed renders rather than cache-hit counts alone.

The homepage distinguishes compilation time in `Europe/Copenhagen` from
observation dates, release lags, revisions, and carried-forward market prices.
Its [data-status appendix](https://ckrusemd.github.io/money-printer-go-brrr/data-status.html)
lists provider retrieval times, latest observation dates, and failed optional
requests for the edition. The manifest records request parameters without secrets.
The Danish tax tables below are dated source snapshots.

### Validation

```bash
# Offline runtime fixtures: retrieval failures, cache keys, and RNG behavior
Rscript --vanilla tests/test_book_runtime.R

# Python fixture suite (no external data needed)
python3 -m unittest discover -s tests -p 'test_*.py'

# Check shared R syntax
Rscript --vanilla -e "invisible(parse(file = 'money_theme.R')); invisible(parse(file = 'scripts/book_runtime.R'))"

# Reject unavailable or undeclared publication packages before fetching data
Rscript --vanilla scripts/check_publication_dependencies.R

# After a complete book render, check page titles, galleries, and chart images
Rscript --vanilla scripts/check_bookdown_output.R
```

Run R checks in the publication container if local locked packages are unavailable:

```bash
sudo -n docker run --rm \
  -v "$PWD:/project" -w /project \
  ghcr.io/ckrusemd/money-printer-go-brrr-r:latest \
  Rscript --vanilla tests/test_book_runtime.R
```

Gallery alternative text identifies panel order, units, and unavailable data.
When editing charts, preserve the statistical settings, chart coverage, existing
page URLs, and explicit anchor IDs, and keep descriptions accurate. Paired
notebooks must be synchronized by the worker responsible for that handoff.

For the full-book acceptance benchmark, download `book-provider-snapshots`
from a successful validation run and prepare an isolated historical checkout:

```bash
python3 scripts/prepare_benchmark_baseline.py --ref BASELINE_SHA --output .cache/benchmark-baseline
Rscript --vanilla scripts/benchmark_book.R .cache/benchmark-baseline . .cache/benchmark-inputs .cache/book-benchmark
```

Run this in the locked publication container with `--network none`. It primes
both versions, interleaves three measured renders each, and checks complete
model results at a tolerance of `1e-8`. Acceptance requires at least 30% lower
median warm runtime and no increase in median peak RSS. Historical ETF
duplicate-correlation differences are reported separately from model parity.
Use new, empty baseline and artifact directories; existing evidence is preserved.

Mortgage-rate year/week observations are dated to ISO-week Mondays. The former
Sunday-based `%U` parser shifted some dates and returned `NA` for valid week-53
observations in 1998, 2009, 2015, and 2020. This is an intentional input-date
correction: the historical benchmark adapter applies the same normalization
before comparing unchanged statistical methods and complete prediction tables.
The correlation audit separately proves that remaining input differences are
only the exact duplicated ETF append and checks all pairs against the original
three-horizon CCF calculation on corrected, deduplicated observations.

### Data Pipeline

```bash
# Run ETL (populates DuckDB)
jupyter notebook datacollection/01_etl.ipynb

# Run models
jupyter notebook datacollection/02_models.ipynb
```

### Danish investment-fund tax catalogue

`data/positivliste_2026.csv` is the registered-2026 extract from
[Skattestyrelsen's workbook](https://skat.dk/erhverv/ekapital/vaerdipapirer/beviser-og-aktier-i-investeringsforeninger-og-selskaber-ifpa).
`data/investment_products_2026.csv` contains only products with a supported
tax category, aktiesparekonto eligibility, and a Yahoo Finance ticker with
price history. The book reads these snapshots without calling external APIs.

To refresh, download separate ETF and investment-fund exports locally and run:

```bash
python3 scripts/build_investment_catalogue.py \
  --etfs /path/to/etfs.csv \
  --funds /path/to/investment-funds.csv
python3 -m unittest discover -s tests -p 'test_investment_catalogue.py'
```

The source exports stay outside the repository. The script retrieves the
current linked SKAT workbook by its visible link text and `.xlsx` URL
(equivalent XPath: `//a[contains(normalize-space(.), 'Liste over aktiebaserede investeringsselskaber') and contains(@href, '.xlsx')]`),
plus the [SKAT securities-classification list](https://info.skat.dk/data.aspx?oid=2460620),
then writes dated CSV snapshots. Review changed source dates, classifications,
and excluded-product counts before committing a refresh; the 2026 rules and
worksheet selection must be updated for a new income year.

### Knowledge Graph Dashboard

```bash
python -m pip install -r knowledgegraph/app/requirements.txt
python knowledgegraph/app/run_app.py    # http://localhost:8051
# Direct launch also works:
python knowledgegraph/app/dashboard.py
```

Both entry points work from any working directory when invoked by their absolute
path. The default database is `knowledgegraph/app/knowledge_graph.db`, resolved
relative to the dashboard module. Set `KNOWLEDGE_GRAPH_DB_PATH` to use another
existing DuckDB file; relative overrides also resolve from `knowledgegraph/app`.
Connections are read-only, and starting the dashboard never creates or refreshes
the database. Missing data displays a diagnostic message; an absent optional
stock-relationships table leaves the other tabs available.

The port defaults to **8051** (`KNOWLEDGE_GRAPH_PORT` overrides it). Debug mode is
off by default; explicitly set `KNOWLEDGE_GRAPH_DEBUG=true` for development.
Network layouts are deterministic (spring seed 42) and use a bounded 16-entry
cache keyed by nodes, weighted edges, and layout, so changing node size reuses
positions. The heatmap preserves measured zeros, fills missing reverse pairs
only, leaves unavailable correlations blank, and uses aligned axes for the
self-correlation diagonal; conflicting observed directions remain as recorded.
These display fixes do not alter the database schema or stored values.

Run dashboard regression tests with disposable fixture databases:

```bash
python -m unittest discover -s tests -p test_dashboard.py -v
```

Configuration tests run with the standard library. Database/rendering tests skip
with an explicit reason if dashboard dependencies are unavailable.

## CI/CD

A GitHub Actions workflow renders the book in a prebuilt public GHCR
container on every relevant push to `main` and on a daily schedule, then
deploys it to GitHub Pages. Set the repository secret `FRED_API` for
publication. The container workflow rebuilds only when the R lockfile or
container definition changes. The output check verifies the home-page title,
gallery pages, and referenced chart images before Pages upload.

For candidate-image validation, dispatch the book workflow with `publish=false`
and `publication_tag=candidate-<commit-sha>`; only tags in
`ghcr.io/ckrusemd/money-printer-go-brrr-r` are accepted. Use the same tag with
`benchmark=true` and a successful validation `snapshot_run_id` to run the
fixed-input comparison on CI rather than a memory-constrained local machine.
The input defaults to `latest` and is ignored for publishing: normal builds use
`latest`, while successful default-branch container-triggered builds use their
exact commit tag. Candidate selection does not push an image or deploy Pages.

## License

This project is for personal/educational use.
