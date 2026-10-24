"""Download a public Finans Danmark PX export through its anonymous forms."""
import argparse
from html.parser import HTMLParser
import http.cookiejar
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request


class Forms(HTMLParser):
    def __init__(self):
        super().__init__()
        self.forms = {}
        self.current = self.select = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form":
            self.current = attrs.get("name", "")
            self.forms[self.current] = {"action": attrs.get("action", ""), "fields": [], "options": {}}
        if self.current is None:
            return
        form = self.forms[self.current]
        if tag == "input" and attrs.get("type", "").lower() == "hidden":
            form["fields"].append((attrs["name"], attrs.get("value", "")))
        if tag == "select":
            self.select = attrs.get("name")
            form["options"][self.select] = []
        if tag == "option" and self.select:
            form["options"][self.select].append(attrs.get("value", ""))

    def handle_endtag(self, tag):
        if tag == "form":
            self.current = None
        if tag == "select":
            self.select = None


def download(table, selection):
    if not re.fullmatch(r"[A-Z0-9]+", table):
        raise ValueError("Invalid public table identifier")
    base = "https://rkr.statistikbank.dk/statbank5a/SelectVarVal/"
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def resolve(url, action):
        result = urllib.parse.urljoin(url, action)
        if urllib.parse.urlsplit(result).hostname != "rkr.statistikbank.dk":
            raise ValueError("Unexpected StatBank form host")
        return result

    def read(url, fields=None):
        request = urllib.request.Request(url, data=None if fields is None else
            urllib.parse.urlencode(fields, encoding="windows-1252").encode())
        with opener.open(request, timeout=60) as response:
            raw, location = response.read(), response.url
        forms = Forms()
        forms.feed(raw.decode("windows-1252"))
        return raw, location, forms.forms

    _, url, forms = read(base + "Define.asp?" + urllib.parse.urlencode({"MainTable": table, "PLanguage": 0, "PXSId": 0}))
    form = forms["main"]
    fields = [(k, "ShowTable" if k == "TS" else v) for k, v in form["fields"]]
    for name, options in form["options"].items():
        if not re.fullmatch(r"var[0-9]+", name):
            continue
        chosen = selection.get(name, options)
        if isinstance(chosen, str):
            chosen = [chosen]
        if not chosen or not set(chosen).issubset(options):
            raise ValueError("Unknown category selection: " + name)
        fields.extend((name, value) for value in chosen)
    _, url, forms = read(resolve(url, form["action"]), fields)
    form = forms["ready"]
    raw, _, _ = read(resolve(url, form["action"]), form["fields"] + [("fileformatid", "1"), ("run.x", "1"), ("run.y", "1")])
    if b"DATA=" not in raw:
        raise ValueError("StatBank did not return a PC-Axis export")
    return raw


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("table")
    parser.add_argument("selection", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(download(args.table, json.loads(args.selection.read_text())))
