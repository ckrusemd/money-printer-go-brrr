# Money Printer Go BRRR

Macroeconomic research on interest rates, US/Danish housing, markets, and ETFs,
published as an interactive [HTML book](https://ckrusemd.github.io/money-printer-go-brrr/).

## Edit notebooks in VS Code

The `.ipynb` files are the editable source of truth. `_quarto.yml` defines the
published chapters. Each published notebook runs independently with the project's
**Money Printer R 4.6.1** kernel. Rmd files remain only as a temporary numerical
comparison baseline; do not edit them or synchronize them over notebook edits.

1. Install Docker and the VS Code **Dev Containers** extension.
2. Create `.env` in the repository root from `.env.example` if it does not
   already exist. Set `FRED_API=your_key_here` without quotes and keep the file
   private (`chmod 600 .env` on Linux). The devcontainer loads this Git-ignored
   file at startup; it is excluded from the image build. Recreate the container
   after changing the key. CI obtains the same variable from its GitHub secret.
3. Open this checkout and select **Dev Containers: Reopen in Container**.
4. Open a published notebook and choose **Money Printer R 4.6.1**. Restart the
   kernel and run all cells, or edit/run individual cells as usual.
5. Preview a chapter from the container terminal:

   ```bash
   python -m scripts.notebooks.book preview --chapter Chapters/04_Markets/Markets.ipynb
   ```

   Trust this project in VS Code to allow widget JavaScript.
   Open the forwarded port 8000. Run the command again after editing to recompute
   the preview. Use the browser preview to check the published widget controls.
6. Before committing, clear execution outputs and validate the source notebooks:

   ```bash
   python -m scripts.notebooks.book clean
   python -m scripts.notebooks.book check
   ```

Main is protected. Create a working branch in VS Code, commit and publish that
branch, then open a pull request and merge after its checks pass. Merged notebook
changes enter the publication workflow; pull requests run offline checks.
To add a chapter, create
an R notebook with the same bootstrap cell/kernel metadata, add its path to
`book.chapters` in `_quarto.yml`, and optionally set a stable HTML filename in
`notebook-publication.page-names`. Put the data-status appendix last.

The bootstrap verifies the installed R version and every locked package before
performing calculations. Do not install packages from notebook cells. Add a new
package deliberately to the canonical environment and rebuild/promote the image.
Disabled legacy experiments remain non-executable Markdown examples in the
editor; their publication metadata keeps originally hidden examples out of the
published book.

## One environment for development and publication

`Dockerfile` provides R 4.6.1, IRkernel 1.3.2, Quarto 1.10.19, and Jupyter tooling.
`renv.lock` is the canonical R environment (230 packages, including Plotly from the
same 2026-10-14 CRAN snapshot). `renv/publication.lock` is an identical compatibility
copy for historical tooling; pruning kernel packages is no longer supported.
`scripts/notebooks/requirements.lock` pins the complete Python execution stack.
Quarto and the R base image have fixed checksums/digests.

The devcontainer pins a validated GHCR image by immutable digest. VS Code,
publication, and offline CI for notebook edits use that same image. Publication
refuses to substitute an unpinned image. To change the environment, first build
and validate a new candidate:

```bash
# On a machine with Docker access, build and validate a candidate.
context_hash=$(python scripts/publication_image_key.py)
docker build --build-arg PUBLICATION_CONTEXT="$context_hash" -t money-notebook-candidate .
docker run --rm --network none --entrypoint python3 \
  -v "$PWD:/project:ro" -w /project money-notebook-candidate -m scripts.notebooks.smoke
```

The **Build R publication container** workflow builds/publishes a candidate and
reports its digest after smoke checks. Pin that real digest locally:

```bash
python -m scripts.notebooks.image pin ghcr.io/ckrusemd/money-printer-go-brrr-r@sha256:REAL_DIGEST
```

This verifies the image context fingerprint, installed R packages, and R notebook
smoke test, then records that immutable image reference in the devcontainer
configuration. Commit the configuration. CI and VS Code then use
the **same image digest**. Never invent a digest or promote a tag as a digest.
Changes to locks or the Dockerfile require a new candidate and promotion.

Refresh the R environment explicitly with the target R installed:
`Rscript --vanilla scripts/refresh_r_locks.R YYYY-MM-DD`.

## Statistics Denmark helper

The internal [dstcollect R package](packages/dstcollect/README.md) collects
StatBank discovery, metadata and observations into one data-and-metadata bundle.
Use `library(dstcollect)` in the pinned container and start with the
[example R notebook](packages/dstcollect/examples/collection.ipynb). Its source
codes, Date boundaries, units and curated concept mappings remain separate from
display labels. Large selections are automatically split into bounded requests.

The book uses compatibility views to preserve its existing calculations. The
collection notebook also uses the package while keeping its database aliases;
the package itself never writes to a database. Package source and mapping edits
require a new container, just like external dependency changes. For a candidate
branch, run `gh workflow run build-container.yml --ref BRANCH -f candidate=true`,
wait for validation, then pin the reported digest before merging. A branch
candidate does not replace the production `latest` tag or deploy the book.

## Build and morning publication

Inside the environment:

```bash
python -m scripts.notebooks.book build
```

The runner executes each chapter in a **fresh R kernel**, from the repository
root, and writes executed copies under `.cache/notebook-runs/`. It then assembles
those copies with Quarto execution disabled. Calculations run once; rendering
never modifies the tracked notebooks or installs packages. `_book/` is replaced
only after a successful full render and validation.

Market galleries use explicit shared preparation in
`scripts/analysis/market_notebooks.R`; they do not need a preceding Markets kernel.
Existing model methods and detailed static galleries are retained. Main market
snapshots gain Plotly hover/zoom/date controls; DT and visNetwork outputs are
packaged with their JavaScript/CSS into standalone embedded widget frames.
Quarto's notebook RequireJS/jQuery tags are replaced with checked local release
files, so viewing the rendered book does not depend on their CDN.

The existing workflow identifier, GitHub Pages destination, and scheduler protocol
are retained. Calculations start at **05:00 Europe/Copenhagen**, with the existing
05:10/05:30 recovery calls and hourly watchdog. A completed deployment records the
Copenhagen analysis date; failed calculations or deployment leave the previous
edition available. See [scheduler operations](docs/hosted-scheduler.md).

Each build uses a new input directory and fixed analysis date. Provider requests
are reused across chapter kernels only within that invocation; they cannot reuse
source responses from an earlier morning. Derived calculations can be reused
when their input content, code, package versions, and RNG state match. Essential
provider failures stop publication; optional missing series appear in the final
freshness appendix. Providers include FRED (`FRED_API`), Yahoo Finance, ECB,
Statistics Denmark, and Finans Danmark. The Danish tax catalogue uses separately
maintained dated snapshots and is not refreshed by the daily build.

Manual `publish=false` runs retain the full candidate book and diagnostics without
Pages deployment. Logs, executed notebooks, numeric captures, timing, and provider
snapshots are retained as workflow artifacts. Existing `benchmark=true` controls
are explicitly **legacy Rmd benchmark/recovery**, not evidence of notebook speed.

## Validation and parity

```bash
python -m unittest discover -s tests -p 'test_*.py'
Rscript --vanilla scripts/check_sources.R
Rscript --vanilla scripts/check_publication_dependencies.R
Rscript --vanilla scripts/check_publication_closure.R
Rscript --vanilla tests/test_notebook_runtime.R
Rscript --vanilla tests/test_notebook_parity.R
python -m scripts.notebooks.smoke
```

Offline image smoke executes a real R kernel and renders a static figure, DT,
Plotly, and visNetwork through Quarto. The full pipeline checks required legacy
page URLs, anchors, image descriptions, and local dependencies. Completed builds
include per-run receipts and duration metrics; the publication limit is 90 minutes.

For reproducible validation, download a successful `book-provider-snapshots`
artifact, then execute without network:

```bash
python -m scripts.notebooks.book build --replay /path/to/recorded-inputs
Rscript --vanilla scripts/notebooks/parity.R /path/to/legacy-results /path/to/notebook-run/results
```

Parity compares complete captured model/correlation tables in both directions
with an elementwise absolute tolerance of `1e-8`, including correlation inputs.
Use identical inputs and analysis dates. The published container passed its R,
notebook, browser, and non-root checks before digest promotion. Deployment results
are recorded in the [publication workflow](https://github.com/ckrusemd/money-printer-go-brrr/actions/workflows/deploy_bookdown.yml).

Container acceptance on 24 October 2026 now includes the canonical locked R and
Python environments, 13 R fixture files, and 159 Python tests (15 skipped).
The final image executed the home chapter through the actual book pipeline as
the `notebook` user. Offline kernel/widget rendering also passed with a read-only
image and source checkout; Chromium exercised DT filtering/sorting, Plotly date
controls and zoom, and the network canvas. The earlier structural render covered
all 12 published chapters without calculations. Full live execution of all 12
chapters subsequently passed in 23.7 minutes, with 2.84 GB peak observed container
memory under a 5 GiB limit. Replay without network or an API key passed in 15.4
minutes; all captured predictions, metrics and correlation records matched the
live run at absolute tolerance `1e-8`, and all 334 input files were unchanged.
All 12 real pages and their widgets loaded in Chromium with outside requests
blocked. Seven optional Yahoo symbols were unavailable and are listed in the
data-status appendix. The isolated legacy Bookdown replay also completed, and its
complete captured forecasts/metrics and both correlation input/output records
matched the notebooks at absolute tolerance `1e-8`. The published GHCR image also
passed clean-runner checks. Actual VS Code editor behavior remains a manual check.
See [container acceptance evidence](docs/notebook-validation.md).

The [first hosted notebook publication](https://github.com/ckrusemd/money-printer-go-brrr/actions/runs/40094633934)
subsequently passed in 25.9 minutes and deployed all 12 chapters. Browser checks
passed on the public pages and all 31 widget frames. A repeat scheduled call
correctly skipped a duplicate build. After the rollout fixes, the promoted-image
Python suite passed with 164 tests run and 15 skipped.

## Research outside the daily book

All 23 Rmd documents have notebook counterparts. Currency/crypto drafts and
vignettes stay unpublished. `datacollection/` contains R-kernel ETL/modeling
notebooks requiring separate local inputs; `knowledgegraph/` includes R analysis
and a Python/DuckDB Dash app. Those research pipelines remain outside the daily
publication migration. The dashboard's own Python requirements are separate from
the notebook publication image; see its documentation.

The investment catalogue refresh tools, public CSV snapshots, shared plotting
style, and historical benchmark/recovery evidence remain in the repository.

This project is for personal/educational use.
