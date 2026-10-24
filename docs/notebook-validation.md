# Notebook container acceptance — 24 October 2026

The corrected Dockerfile built successfully and was loaded locally as
`money-notebook-candidate:latest`. Its immutable local image ID is
`sha256:012a9e0e66f0ef39970b0ab79d932d424940b35cec1d8cb11d076133f4e6d2f5`.
The dependency-context fingerprint is
`0e4ee976cdfe9dcde385c0c9ec347728883d4e25350fdc242c665ee9db7f63a0`.
Local acceptance was performed over the original HEAD
`0da67f6fa0fa25a43d3e05353addb1850787e51a`. The migration subsequently passed all
GitHub checks and merged through [PR #68](https://github.com/ckrusemd/money-printer-go-brrr/pull/68).

The [container publication run](https://github.com/ckrusemd/money-printer-go-brrr/actions/runs/40092769235)
built and validated the registry image
`ghcr.io/ckrusemd/money-printer-go-brrr-r@sha256:1fcecffcfdb0135077130e9973fcfdd036c4c8342871e1a380c08366c8f24d6a`.
It passed the R audit, notebook/Quarto smoke, Chromium interactions, and non-root
kernel execution. That image was downloaded and independently verified locally
before pinning. Its dependency-context fingerprint matches the local candidate;
the local image ID above is not a registry digest.

Observed acceptance results:

| Check | Result |
| --- | --- |
| Final Dockerfile build | Passed; exported archive, then loaded into Docker |
| Final image audit as `notebook` | Exact locked R/Python packages, Quarto, context and vanilla kernel passed |
| Python suite in final image as `notebook`, offline/read-only | 159 tests run, 15 skipped, no failures |
| R fixtures in the locked container environment, offline/read-only | 13 fixture files passed across the checks, including version-normalization and numerical-parity regressions |
| Final image kernel/widget smoke as `notebook`, offline/read-only | Static R plot, DT, market snapshot Plotly function, visNetwork and Quarto passed |
| Chromium on final image widget output | Filtering, sorting, date slider presence, zoom and network canvas passed |
| Final image book pipeline as `notebook` | `build --chapter index.ipynb` completed in about 6.8 seconds, without network |
| Workflow lint and Git whitespace | Passed |
| Full live book | All 12 chapters executed and rendered; page/asset/anchor checks passed; 1423.06 seconds |
| Peak live container memory | 2,843,906,048 bytes observed from cgroup `memory.peak`; 5 GiB limit; this includes more than process RSS |
| Full offline replay | All 12 chapters passed without network access or an API key; 925.86 seconds |
| Live/replay numerical parity | Every captured prediction/metric value and both full correlation input/output records matched at absolute tolerance `1e-8` |
| Input immutability | SHA-256 hashes of all 334 input snapshot files unchanged after replay |
| Real-book browser checks | All 12 pages and widget frames loaded without JS errors with outside requests blocked; real market zoom/date controls and tax navigation passed |
| Final asset-pipeline integration | Markets chapter replay passed through the updated CLI, including local browser dependency packaging |
| Legacy Bookdown replay | All 457 processing steps and HTML rendering completed offline; R reported 13 warnings |
| Legacy/notebook numerical parity | Complete captured predictions/metrics and both full correlation input/output records matched at absolute tolerance `1e-8` |
| Input immutability after legacy replay | All 334 snapshot file SHA-256 hashes still unchanged |
| Promoted registry image Python suite | 163 tests run, 15 skipped, no failures, offline/read-only as `notebook` |
| Promoted image selection | Actual CI selector passed locally; four fixtures cover digest priority, dependency changes, candidate builds and wrong labels |
| VS Code Dev Containers tooling | Started the pinned configuration as `notebook` at `/project`; startup audit passed; container image ID equals the pulled registry image ID |
| Container checkout ownership regression | Scoped Git trust reads a foreign-owned checkout; the root/read-only home-chapter pipeline passes with only its run cache writable |

Container testing exposed and fixed equivalent R version strings being rejected
(`1.2-5` versus `1.2.5`), the shared Jupyter data directory being private to root,
and Quarto's cache being unwritable in read-only CI. CI now also exercises the
kernel/render path as the VS Code notebook user.

Real-book browser checks also exposed Quarto's dependency on CDN RequireJS. The
downloaded CDN minification did not match either SRI hash in Quarto's tag. The
pipeline now packages the original RequireJS 2.3.6 release and jQuery 3.5.1 with
their verified hashes and licenses. CI's browser checks block outside requests,
and unbundled script dependencies stop publication. The completed live/replay
HTML was localized after this presentation fix; the final CLI integration was
checked with a market-chapter replay. Statistical calculations were unchanged.

The live input manifest contains 331 successful unique requests and seven
optional Yahoo failures: JJG, JJC, FXSG, UGAZ, LBND, DGAZ and OIL. These appear in
the appendix. The rendered HTML was checked against the configured API key and
did not contain it. Correlation computations took about 238 and 285 seconds;
the conservative RNG-sensitive cache also recomputed them in the offline replay.

The first export exhausted the host's available disk space. Only artifacts from
this build attempt were cleaned up. The successful retry exported an image
archive into `/tmp`, removed this build's cache by its specific cache IDs, and
then loaded the archive. No unrelated images, containers or user files were
removed. About 2.3 GB remained available on the system disk after loading.

The host also had an unused, empty Buildx lock owned by root with mode 0600.
After checking that no Buildx process or lock user was active, that single file
was preserved under `.lock.before-notebook-20261024T081957`; Docker recreated the
lock under the desktop user's ownership. Default Buildx access then passed.
An existing desktop/VS Code session may still need a new login to inherit the
Docker group that was added during setup.

Automatic devcontainer UID rewriting is disabled: the image's `notebook` user
already matches this desktop's UID 1000. This prevents Dev Containers from adding
a UID-adjustment image layer and preserves the actual promoted image identity.

The first cloud notebook publication stopped before calculations because Git
rejected the runner-owned checkout from the root container. The receipt lookup
now trusts only the explicitly selected checkout for that one Git command.
Pre-kernel failures retain an incomplete receipt and restore runtime settings.
CI now runs the actual home-chapter pipeline under the runner/container ownership
mismatch. Quarto also uses a writable cache inside the isolated run, supporting
read-only containers without writing to the user's home directory.

Logs and a machine-readable receipt are retained locally under
`.cache/notebook-acceptance/`; widget HTML is under
`/tmp/money-container-final-widget-output/`. These temporary artifacts are not
committed. The `.env` file is private and Git-ignored, and is passed to Docker at
runtime rather than copied into the image.

The first notebook Pages deployment follows the digest-pinning merge. Manual
VS Code editor checks remain; the host Dev Containers extension is now installed.
Legacy Rmd sources remain available as the comparison baseline until final
acceptance.
