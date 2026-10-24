# dstcollect

Internal R client for the four public [StatBank v1 APIs](https://www.dst.dk/da/Statistik/hjaelp-til-statistikbanken/api).
Independent implementation inspired by [dkstat](https://github.com/rOpenGov/dkstat)'s discovery/metadata/query workflow.
No API key is required for these endpoints. The keyed DCAT catalogue is excluded.

```r
library(dstcollect)
catalogue <- dst_search("befolkning")
meta <- dst_metadata("FOLK1A")
meta$dimensions
subset(meta$categories, dimension_id == "OMRÅDE")

selection <- list(OMRÅDE = c("000", "101"), KØN = "TOT", ALDER = "IALT",
                  CIVILSTAND = "TOT", Tid = "(1)")
result <- dst_collect("FOLK1A", selection)
result$data
dst_as_tibble(result, dimensions = "labels", concepts = TRUE)
```

Verify category codes in current metadata before selecting a different table.
`dst_query(meta)` supplies a scaffold selecting all categories; narrow it before
collection. Every dimension must be explicit, including dimensions the API
could otherwise eliminate. Supported selectors are literal codes, `*` wildcards,
inclusive ranges such as `>=2020M01<=2024M12`, `(1)` for latest, and `(-1)` for
first. Labels are presentation, never identity. API calculation expressions are
not supported. Selection order is resolved using the source metadata order.

## Common model

Every function returns a `dst_bundle`: `data`, `series`, `series_dimensions`,
`dimensions`, `categories`, `concepts`, `subjects`, `tables`, and `requests`.
Discovery results contain typed empty observation tables. `dst_bind(a, b)` joins
bundles and rejects conflicting series/period values. `data` always contains
table/series IDs, period code and Date boundaries, native frequency, numeric
value, source status, unit, explicit index base (unknown unless stated in the
unit), and request ID. Dictionaries and raw responses preserve source notes,
flags, labels, update times and retrieval provenance. JSON-stat's synthetic
metric dimension participates in series identity.

`dst_as_tibble(x, "codes")` or `"labels"` expands source dimensions for analysis.
Use one language per analysis view: `dst_bind()` retains multilingual dictionaries,
while the expanded view chooses the first supplied label for each source code.
Conflicting observations from different vintages cannot silently overwrite each
other. Use separate bundles to retain multiple revisions.

Source codes and table IDs determine stable series IDs, independent of language,
response order and concept mapping version. Missing observations remain `NA`;
source flags remain flags. Unknown periods, including weekly codes whose calendar
is not established, retain their original strings and unknown Date boundaries.
Recognized formats: annual, half-yearly, quarterly, monthly and calendar daily.
The package never fills dates, rebases indices, converts units or aggregates data.

## Curated concepts and limits

Version 1 of `inst/concepts.csv` covers verified categories from BYGV80, BYG1,
PRIS90, BYG42, PRIS114, and two FOLK1A geographic categories (Denmark and
Copenhagen municipality). These are exact source-category mappings, not a
complete catalogue crosswalk. Detached houses, single-family houses and apartment
buildings have different codes. Index levels, period changes and annual changes
have different measure codes; change observations use percent units even when
table metadata says index. Index bases are never guessed from comments in a
notebook. Geography mappings do not harmonize historical boundaries.

Unmapped categories remain fully usable under native codes. Printing a bundle
reports mapping coverage. Additional mappings require source evidence, a mapping
version, and tests; never infer equivalence from translated labels alone.

## Large requests and replay

The default budget is 500,000 cells per request. Collection splits time first,
then other categories, and combines results deterministically. It checks metadata
updates before/after collection and fails completely on a failed chunk, conflicting
duplicate or changed table. HTTP retries cover bounded transient failures and rate
limits; there is no stale-data fallback. BULK streaming is deliberately excluded.

Every endpoint accepts `transport = function(endpoint, parameters) ...` for
offline fixtures or recording; it returns parsed JSON lists. The book records
the complete bundle, including raw request responses, in its existing isolated
run snapshots. New DST requests use a versioned request identity. Existing
snapshots remain unchanged and are replayable with their original source revision.

## Development and compatibility

Use the project's pinned devcontainer. `library(dstcollect)` loads the installed
version verified against this checkout. After editing package code, use
`pkgload::load_all("packages/dstcollect")` for exploratory development. Rebuild and
promote the container before running the publication pipeline; package sources
and mappings are part of its fingerprint. External dependency versions are unchanged.

Run `testthat::test_local("packages/dstcollect")` and `R CMD check` in that
environment. The example R notebook lives under `examples/` and is not a published
book chapter. Source data must be attributed to Danmarks Statistik.

Compatibility helpers are deliberately separate from the canonical model:
`dst_legacy_data()` retains code-prefixed labels and Copenhagen-midnight timestamps
used by the installed dkstat baseline; `dst_legacy_metadata()` retains its named
metadata components. `dst_legacy_series()` preserves the collector's historical
aliases and returns canonical IDs as an attribute. Alias collisions fail rather
than merge different series. Database writes are owned by the existing notebook,
not by this package.
