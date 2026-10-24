# Repository instructions

The publication source of truth is `.ipynb` with the `money-r` IRkernel. Never
regenerate notebook edits from Rmd. `_quarto.yml` declares the published chapters;
currency/crypto drafts, vignettes, ETL, and the knowledge-graph pipeline remain
outside the daily book. Legacy Rmd files are retained for parity acceptance only.

Use the VS Code devcontainer and its pinned image for development and CI. The
initial bootstrap configuration builds the Dockerfile; production is blocked
until a real validated image digest is pinned with `scripts.notebooks.image`.
`renv.lock` is canonical; the compatibility publication lock must be identical.
Never restore/install packages from notebooks or during rendering.

Commands inside the image:
- `python -m scripts.notebooks.book build`
- `python -m scripts.notebooks.book preview --chapter PATH.ipynb`
- `python -m scripts.notebooks.book clean` (explicit author action before commit)
- `python -m scripts.notebooks.book check`
- `python -m scripts.notebooks.smoke`
- `python -m unittest discover -s tests -p 'test_*.py'`
- `Rscript --vanilla scripts/check_sources.R`
- `Rscript --vanilla scripts/check_publication_dependencies.R`
- `Rscript --vanilla scripts/check_publication_closure.R`

Each chapter must run from a fresh kernel using its bootstrap and explicit shared
helpers. Build execution writes only scratch copies; Quarto assembles already
executed notebooks. Retain descriptive figure alt text, existing page URLs and
anchors, statistical methods, price definitions, RNG behavior, and chart coverage.
Market preparation/helpers live in `scripts/analysis/market_notebooks.R`.

Use shared `book_*` data wrappers and content-keyed derived caches. Current inputs
are mandatory for publication; replay is validation only. A new build gets a new
source response directory, fixed Copenhagen analysis date, and per-chapter numeric
captures. Essential retrieval failures must stop publication. The last notebook
aggregates provenance and optional-source failures across all chapter kernels.

Export `FRED_API` in the process environment; do not inspect or write credentials.
Scheduled runs start at 05:00 Copenhagen. Preserve the hosted dispatch contract,
due/completion gate, serialized publication, recovery behavior, and Pages target.
The legacy benchmark/recovery inputs must never be presented as notebook runtime
acceptance. Full notebook acceptance compares numeric captures to legacy results
with identical recorded inputs at `1e-8` tolerance.

Research paths and the separate Dash app remain supported; dashboard port is
8051, debug is off by default, and database connections are read-only. Do not add
research input requirements to daily publication without a separate request.
