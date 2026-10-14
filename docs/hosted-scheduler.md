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

## Provisioning status (14 October 2026)

Bookdown job `8642126` has been created disabled. Enable only after the
new workflow is on `main` and its provider test and completion gate pass.
At the owner's request, its dispatch credential was reused from the existing
provider-held weather job after checking authenticated Actions read access to
this repository. The source job was not modified, credential values were not
displayed or saved locally, and no broad CLI credential was used. Dispatch
write access still requires the live test. Rotate shared credentials in both
repositories before expiry, or replace Bookdown's with a single-repository token.
