"""Cheap Copenhagen-time gate and successful Pages publication journal.

No waiting, polling, package installation, or render container in this step.
Only the separate post-deployment job can write the state branch.
"""
import base64
from datetime import datetime, date
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

BRANCH = "book-publication-state"
FILE = "state.json"
ZONE = ZoneInfo("Europe/Copenhagen")


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self):
        self.repository = os.environ["GITHUB_REPOSITORY"]
        if self.repository != "ckrusemd/money-printer-go-brrr":
            raise RuntimeError("Unexpected repository")
        self.opener = urllib.request.build_opener(NoRedirects())

    def request(self, method, path, payload=None, missing=False):
        request = urllib.request.Request(
            "https://api.github.com/repos/" + self.repository + path,
            data=None if payload is None else json.dumps(payload).encode(), method=method,
            headers={"Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2026-03-10"},
        )
        try:
            with self.opener.open(request, timeout=8) as response:
                raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise RuntimeError("Oversized GitHub response")
            return json.loads(raw)
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise RuntimeError(f"GitHub HTTP {error.code}; refusing to assume empty state") from None
        except (urllib.error.URLError, OSError, ValueError):
            raise RuntimeError("GitHub request failed; refusing to assume empty state") from None


def validate_state(state):
    if not isinstance(state, dict) or type(state.get("schema")) is not int or state["schema"] != 1:
        raise ValueError("Invalid publication state schema")
    value = state.get("last_publication_date")
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise ValueError("Invalid publication date")
    date.fromisoformat(value)
    if not isinstance(state.get("source_sha"), str) or not re.fullmatch(r"[0-9a-f]{40}", state["source_sha"]):
        raise ValueError("Invalid publication source")
    return state


def read_state(api):
    # Confirm repository access first: an authentication 404 must not be
    # mistaken for an uninitialized state branch.
    metadata = api.request("GET", "")
    if metadata.get("full_name") != api.repository:
        raise RuntimeError("Could not confirm repository access")
    branch = api.request("GET", "/git/ref/heads/" + BRANCH, missing=True)
    if branch is None:
        return None, None
    response = api.request("GET", "/contents/" + FILE + "?ref=" + BRANCH)
    try:
        if response.get("encoding") != "base64":
            raise ValueError("Invalid state encoding")
        encoded = "".join(response["content"].split())
        state = json.loads(base64.b64decode(encoded, validate=True))
        validate_state(state)
        sha = response["sha"]
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("Invalid state file SHA")
        return state, sha
    except (KeyError, TypeError, ValueError):
        raise RuntimeError("Publication state is malformed; refusing to render") from None


def decide(now, state):
    local = now.astimezone(ZONE)
    if state is not None:
        validate_state(state)
        if state["last_publication_date"] > local.date().isoformat():
            raise ValueError("Publication journal is dated in the future")
    if local.hour < 5:
        return False, "Before 05:00 Europe/Copenhagen; a later invocation will recover."
    if state is not None and state["last_publication_date"] == local.date().isoformat():
        return False, "Today's validated book was already deployed."
    return True, "Today's publication is due."


def scheduled_event(event_name, event):
    if event_name == "schedule":
        return True
    inputs = event.get("inputs", {})
    value = inputs.get("scheduled_delivery", False)
    if value not in (True, False, "true", "false"):
        raise ValueError("Invalid scheduled_delivery input")
    scheduled = event_name == "workflow_dispatch" and value in (True, "true")
    if scheduled and (inputs.get("publish") not in (True, "true") or
                      inputs.get("benchmark", False) not in (False, "false")):
        raise ValueError("Hosted schedule must publish, never benchmark")
    if scheduled and event.get("ref") not in ("main", "refs/heads/main"):
        raise ValueError("Hosted schedule must target main")
    return scheduled


def write_state(api, publication_date, source_sha):
    replacement = validate_state({"schema": 1, "last_publication_date": publication_date,
                                  "source_sha": source_sha})
    previous, blob_sha = read_state(api)
    if previous is not None and previous["last_publication_date"] > publication_date:
        raise RuntimeError("Refusing to move publication state backwards")
    content = json.dumps(replacement, indent=2) + "\n"
    if blob_sha is None:
        # A tiny independent orphan branch, not a copy of the research tree.
        tree = api.request("POST", "/git/trees", {"tree": [
            {"path": FILE, "mode": "100644", "type": "blob", "content": content}]})
        commit = api.request("POST", "/git/commits", {
            "message": "Record successful Bookdown publication", "tree": tree["sha"], "parents": []})
        api.request("POST", "/git/refs", {"ref": "refs/heads/" + BRANCH, "sha": commit["sha"]})
    else:
        # Contents API SHA is a compare-and-swap; conflicts fail, not overwrite.
        api.request("PUT", "/contents/" + FILE, {
            "message": "Record successful Bookdown publication", "branch": BRANCH,
            "sha": blob_sha, "content": base64.b64encode(content.encode()).decode()})


def main():
    try:
        if sys.argv[1:] == ["record"]:
            write_state(GitHub(), os.environ["BOOK_AS_OF"], os.environ["BOOK_SOURCE_SHA"])
            print("Recorded successful Pages publication.")
            return 0
        now = datetime.now(ZONE)
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        if scheduled_event(os.environ["GITHUB_EVENT_NAME"], event):
            # An early invocation doesn't need even a state/network lookup.
            state = read_state(GitHub())[0] if now.hour >= 5 else None
            allowed, reason = decide(now, state)
        else:
            allowed, reason = True, "Ordinary manual/push/container event is unchanged."
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"schedule_allowed={'true' if allowed else 'false'}\n")
            output.write(f"as_of={now.date().isoformat()}\n")
        print(reason)
        return 0
    except (KeyError, RuntimeError, ValueError, OSError):
        print("Publication schedule/state check failed; no render authorized.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
