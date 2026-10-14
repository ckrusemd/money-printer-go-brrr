# Hosted Bookdown scheduling

cron-job.org dispatches `deploy_bookdown.yml` on `main` at **05:00 Europe/Copenhagen**,
with separate recovery invocations at 05:10 and 05:30. CET/CEST transitions are
handled by the provider timezone. GitHub's off-hour `17 * * * *` schedule is
an independent recovery watchdog; neither service guarantees exact runner start.
No invocation sleeps or polls for a future wall-clock time.

Hosted calls set `scheduled_delivery: true`, `publish: true`, `benchmark: false`
and a unique `dispatch_id`. A cheap preflight checks the local due time and
`book-publication-state:state.json` before the R container starts. Successfully
validated **and deployed** books record their frozen Copenhagen input date.
Before 05:00 or after today's successful publication, scheduled calls skip
rendering. Failed renders or deployments remain recoverable. Missing initial
state is accepted only after repository access and absent branch are confirmed;
malformed or inaccessible existing state fails closed. Ordinary manual, push
and container-completion publishing remain available, including same-day updates.
Pages/recovery invocations are serialized without cancelling active publications.
A container-completion callback also skips if this exact source commit was
already successfully published for today (for example by a recovery call).
Different source commits and ordinary manual force runs still publish normally.

## Setup

The management API key and GitHub dispatch credential are **different secrets**.
Create a fine-grained GitHub token restricted to this repository with only
**Actions: read/write** (plus automatic Metadata read). No Contents write,
FRED credentials, or broad CLI authentication credential is sent to the provider.
Record expiry and renew it 30 days beforehand. Do not put credentials in Git,
URLs, command arguments/history, or chat; use hidden prompts or an existing
secure environment (`CRONJOB_API_KEY`, `GITHUB_SCHEDULER_TOKEN`).

1. Review `python3 scripts/configure-hosted-scheduler.py plan` (secret-free).
2. Optionally `... prepare` creates a disabled job without a dispatch credential.
   It refuses to modify an existing job. This is **not an active scheduler**.
3. `python3 scripts/configure-hosted-scheduler.py configure` uses hidden prompts
   and creates or updates exactly the named Bookdown job. It remains disabled.
4. Deploy the workflow changes to `main`, then use Test Run in the provider console.
   Check both the dispatch HTTP response and the matching GitHub Actions result;
   dispatch acceptance alone is not publication success. API version 2026-03-10
   returns HTTP 200 and run URLs. Verify an already-completed day skips rendering.
5. Enable the tested job in the console. Failure/recovery/auto-disable alerts use
   the account email channel. Provider alerts cover HTTP dispatch failures, not
   subsequent rendering/deployment failures: inspect Actions as well.

`python3 scripts/configure-hosted-scheduler.py status` prints only allowlisted
metadata, never stored headers, bodies, or credentials. Duplicate managed titles,
unexpected URLs, incomplete lists and uncertain writes stop changes. Unrelated
weather/electricity jobs are untouched. No redirects or automatic write retries.
Rotation disables the job for retesting; enable it only after the replacement works.

See the [cron-job.org API](https://docs.cron-job.org/rest-api.html) and
[GitHub dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event).

## Active deployment (14 October 2026)

Bookdown job **`8642126` is enabled** at 05:00/05:10/05:30 Europe/Copenhagen.
The first regular calls are confirmed for 15 October 2026. Native hourly
off-hour cron remains enabled independently. No local computer is required.

- [Upgrade PR #66](https://github.com/ckrusemd/money-printer-go-brrr/pull/66)
  merged; R 4.6.1 and all 223 locked publication package versions verified.
- [Production publication](https://github.com/ckrusemd/money-printer-go-brrr/actions/runs/38522947037)
  succeeded and journaled the 14 October book from commit
  `8f216c6b7e3d1b2c2e675d088f7935cf49433e4a`. All 13 live pages and 46
  scripts/styles/representative chart assets were checked successfully.
- A single expiring provider test at 08:39 Copenhagen initiated its HTTP request
  about 9.5 seconds after the target minute and returned HTTP 200.
  [Provider-dispatched workflow](https://github.com/ckrusemd/money-printer-go-brrr/actions/runs/38523464625)
  queued without allocating a runner behind the active publication, then its
  preflight finished in **seven seconds** and skipped every render/deploy job.
  No duplicate publication occurred. The daily schedule was enabled only after
  deployment, journaling, provider dispatch and duplicate gating all passed.

At the owner's request, its dispatch credential was reused from the existing
provider-held weather job after checking authenticated Actions read access to
this repository. A subsequent dispatch against a deliberately nonexistent ref
returned the expected HTTP 422 ref-validation error, verifying dispatch access
without starting a workflow. The subsequent real provider execution passed as above.
The source job was not modified, credential values were not displayed or saved
locally, and no broad CLI credential was used. Rotate shared credentials in both
repositories before expiry, or replace Bookdown's with a single-repository token.
GitHub reports expiry at **11 October 2027, 00:00 Europe/Copenhagen**
(`2027-10-10 22:00:00 UTC`). Renew by **11 September 2027**.
