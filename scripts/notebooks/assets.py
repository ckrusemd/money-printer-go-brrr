"""Replace Quarto's notebook CDN dependencies with verified local release files."""
import base64
import hashlib
from html.parser import HTMLParser
import os
from pathlib import Path
import re
from urllib.parse import urlsplit

VENDOR = Path(__file__).with_name("vendor")
DEPENDENCIES = {
    "https://cdn.jsdelivr.net/npm/requirejs@2.3.6/require.min.js": (
        "require-2.3.6.js",
        "sha384-WKPjHIEhBzyEuCp8//j0gXBM/TP1OwKdWMPBRFZ6q8g66Pce1n6o0M/q4duEXrmA",
    ),
    "https://cdn.jsdelivr.net/npm/jquery@3.5.1/dist/jquery.min.js": (
        "jquery-3.5.1.min.js",
        "sha384-ZvpUoO/+PpLXR1lu4jmpXWu80pZlYUAfxl5NsBMWOEPSjUn/6Z/hRTt8+pR6L4N2",
    ),
}


class ScriptDependencies(HTMLParser):
    def handle_starttag(self, tag, attrs):
        src = dict(attrs).get("src", "")
        url = urlsplit(src)
        if tag == "script" and (url.netloc or url.scheme in {"http", "https"}):
            raise ValueError("Unbundled browser script dependency; vendor it before publication")


def localize(output):
    """Keep the dependency versions and SRI checks, without browser CDN requests."""
    output = Path(output)
    used = set()
    script = re.compile(r'<script\b[^>]*\bsrc=(["\'])([^"\']+)\1[^>]*>\s*</script>', re.I)
    for page in output.rglob("*.html"):
        def replace(match):
            url = match[2]
            if url not in DEPENDENCIES:
                return match[0]
            name, integrity = DEPENDENCIES[url]
            used.add(url)
            relative = Path(os.path.relpath(output / "scripts/vendor" / name,
                                           page.parent)).as_posix()
            tag = match[0].replace(url, relative)
            tag, count = re.subn(r'\bintegrity=(["\'])[^"\']*\1',
                                 'integrity="' + integrity + '"', tag, flags=re.I)
            if not count:
                tag = tag.replace(">", ' integrity="' + integrity + '">', 1)
            return tag
        before = page.read_text()
        after = script.sub(replace, before)
        ScriptDependencies().feed(after)
        if after != before:
            page.write_text(after)
    for url in used:
        name, integrity = DEPENDENCIES[url]
        data = (VENDOR / name).read_bytes()
        actual = "sha384-" + base64.b64encode(hashlib.sha384(data).digest()).decode()
        if actual != integrity:
            raise ValueError("Notebook browser dependency integrity mismatch: " + name)
        target = output / "scripts/vendor" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
