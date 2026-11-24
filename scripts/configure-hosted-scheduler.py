#!/usr/bin/env python3
"""Manage only this repository's cron-job.org job; never log credentials."""
import argparse
import getpass
import json
import os
import sys
import urllib.error
import urllib.request
import warnings

REPOSITORY = "ckrusemd/money-printer-go-brrr"
API = "https://api.cron-job.org"


def job_spec(dispatch_credential=None):
    headers = {"Accept": "application/vnd.github+json", "Content-Type": "application/json",
               "X-GitHub-Api-Version": "2026-03-10"}
    if dispatch_credential is not None:
        headers["Authorization"] = "Bearer " + dispatch_credential
    return {
        "title": REPOSITORY + ": bookdown",
        "url": f"https://api.github.com/repos/{REPOSITORY}/actions/workflows/deploy_bookdown.yml/dispatches",
        "enabled": False, "saveResponses": True, "requestMethod": 1,
        "requestTimeout": 20, "redirectSuccess": False, "auth": {"enable": False},
        "schedule": {"timezone": "Europe/Copenhagen", "expiresAt": 0,
                     "hours": [5], "minutes": [0, 10, 30],
                     "mdays": [-1], "months": [-1], "wdays": [-1]},
        "notification": {"onFailure": True, "onFailureCount": 1, "onSuccess": True,
                         "onDisable": True, "mode": 2, "selectedChannels": [0]},
        "extendedData": {"headers": headers, "body": json.dumps({
            "ref": "main", "inputs": {"publish": True, "benchmark": False,
            "scheduled_delivery": True, "dispatch_id": "cronjob-bookdown-%cjo:uuid4%"}})},
    }


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Provider:
    def __init__(self, key):
        self.key = key
        self.opener = urllib.request.build_opener(NoRedirects())

    def request(self, method, path, payload=None):
        request = urllib.request.Request(API + path, method=method,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={"Authorization": "Bearer " + self.key, "Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=20) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise RuntimeError("Provider response exceeds size limit")
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise RuntimeError("Invalid provider response")
            return result
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Provider HTTP {error.code}; check the console before retrying") from None
        except (urllib.error.URLError, OSError, ValueError):
            raise RuntimeError("Provider request failed; check the console before retrying") from None


def managed_job(provider):
    result = provider.request("GET", "/jobs")
    if result.get("someFailed") or not isinstance(result.get("jobs"), list):
        raise RuntimeError("Incomplete job listing; refusing changes")
    expected = job_spec()
    found = [job for job in result["jobs"] if isinstance(job, dict) and job.get("title") == expected["title"]]
    if len(found) > 1:
        raise RuntimeError("Duplicate managed jobs; resolve in the console")
    if not found:
        return None
    job = found[0]
    if job.get("url") != expected["url"] or type(job.get("jobId")) is not int or job["jobId"] <= 0:
        raise RuntimeError("Unexpected managed job identity; refusing changes")
    return job


def configure(provider, dispatch_credential=None, prepare=False):
    existing = managed_job(provider)
    if prepare and existing is not None:
        raise RuntimeError("Job already exists; prepare never changes an existing job")
    if not prepare and (not isinstance(dispatch_credential, str) or
                        not dispatch_credential.startswith("github_pat_") or
                        any(c.isspace() for c in dispatch_credential)):
        raise RuntimeError("Use a dedicated fine-grained repository-restricted GitHub token")
    specification = job_spec(dispatch_credential)
    if existing:
        job_id = existing["jobId"]
        provider.request("PATCH", f"/jobs/{job_id}", {"job": specification})
    else:
        job_id = provider.request("PUT", "/jobs", {"job": specification}).get("jobId")
        if type(job_id) is not int or job_id <= 0:
            raise RuntimeError("No valid job ID; inspect console before retrying")
    return {"jobId": job_id, "enabled": False,
            "next_step": "Configure dedicated GitHub credential" if prepare else "Test deployed workflow, then enable in console"}


def credential(name, label):
    value = os.environ.get(name)
    if value is None:
        if not sys.stdin.isatty():
            raise RuntimeError("Provide " + name + " through a secure environment or hidden terminal prompt")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                value = getpass.getpass(label + " (hidden): ")
        except getpass.GetPassWarning:
            raise RuntimeError("Hidden input unavailable; refusing to echo credentials") from None
    if not value or any(c.isspace() for c in value):
        raise RuntimeError("Invalid credential input")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "prepare", "configure", "status"))
    args = parser.parse_args()
    try:
        if args.command == "plan":
            result = job_spec()
        else:
            provider = Provider(credential("CRONJOB_API_KEY", "cron-job.org management key"))
            if args.command == "status":
                job = managed_job(provider)
                result = None if job is None else {field: job.get(field) for field in
                    ("jobId", "enabled", "lastStatus", "lastExecution", "nextExecution")}
            else:
                supplied = None if args.command == "prepare" else credential(
                    "GITHUB_SCHEDULER_TOKEN", "Dedicated GitHub fine-grained token")
                result = configure(provider, supplied, prepare=args.command == "prepare")
        print(json.dumps(result, indent=2))
        return 0
    except (RuntimeError, KeyboardInterrupt, EOFError) as error:
        print(str(error) if isinstance(error, RuntimeError) else "Setup cancelled", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
