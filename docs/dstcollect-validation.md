# dstcollect acceptance — 24 October 2026

The internal R package directly uses StatBank's public HTTPS JSON APIs. Its
versioned concept registry covers selected categories from BYGV80, BYG1, PRIS90,
BYG42, PRIS114 and FOLK1A. Other tables retain native category codes and labels;
this is not a complete semantic crosswalk of the StatBank catalogue.

Observed local acceptance:

- `R CMD build` and `R CMD check --no-manual --no-build-vignettes`: passed.
- Package fixtures: 44 assertions passed, no warnings or skips. They cover typed
  endpoint bundles, duplicate labels, leading-zero codes, chunk equivalence,
  missing/sparse observations, period boundaries, selectors, changing metadata,
  conflicting duplicates, curated measures, multi-row aliases and R-kernel rich
  representations.
- The repository's Python suite: 164 tests, 15 skips, no failures. All 14 root R
  fixture files passed, including the new database-free collection boundary.
- Paired live dkstat/JSON-stat extracts: all 91,346 rows across the five book
  tables matched in values, categories, ordering and compatibility timestamps.
  Source table update timestamps matched during collection.
- All five database collection configurations matched the old collector's
  series aliases, dates and values. No database connection or write was executed.
- The bounded live FOLK1A example verified the Denmark and Copenhagen mappings.
- All 12 publication notebooks executed and rendered in an offline replay in
  978.61 seconds. The receipt records source `2342deee6769fc11114feff9872d8853da9c3372`.
  Complete model/metric captures and both correlation input/output records
  matched the previous accepted book at absolute tolerance `1e-8`.
- All 333 original input files other than the manifest still match their copies
  made before replay. New DST bundle records and the augmented manifest were
  written separately; the original input set was not rewritten.
- The example notebook executed against the live public API in the candidate
  container. Source notebook outputs remain cleared.
- Chromium loaded all 12 pages and 32 widgets at 375px and 1440px, with outside
  requests blocked, no page-wide horizontal overflow and no JavaScript errors.
  The data-status search also passed.

The numerical replay preceded two subsequent fixes confined to the collector's
multi-row alias allocation and the bundle's rich notebook representation, plus
handling of invalid daily period strings. These do not alter the book's sampled
monthly/quarterly series or its statistical code; their targeted fixtures and
live examples were rerun.

New DST snapshots use the `dstcollect-1` request identity and retain complete
bundles, including raw API responses. Old snapshots remain usable with their
original source revision. Compatibility views deliberately preserve the old
client's Copenhagen-midnight timestamps and code-prefixed labels; the canonical
model uses Date boundaries and separate codes/labels. Historical notebook display
aliases are not evidence that source housing categories are equivalent.

The external R and Python locks are unchanged. The internal package is installed
from repository source and independently fingerprinted. Image fingerprints and
workflow gates cover its source, dictionaries, documentation and fixtures. A
manually requested branch image can be validated before promoting its immutable
digest; branch candidates do not replace the production latest tag or deploy.

Detailed logs, paired source responses, execution outputs and receipts are kept
locally under `.cache/dstcollect/` and `.cache/notebook-runs/`. They are ignored by
Git. The rollout still requires a validated registry image, matching VS Code pin,
and passing protected-branch checks before merging.
