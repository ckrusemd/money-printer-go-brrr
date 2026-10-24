"""Validate a completed notebook book, including legacy URLs and local assets."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

PAGES = (
    "index", "economic-release-calendar", "leading-economic-indicators",
    "united-states-housing-market", "danish-housing-market",
    "interest-rates-and-yield-curves", "equity-markets-and-the-sp-500",
    "market-chart-gallery", "bond-etf-chart-gallery", "sector-etf-chart-gallery",
    "etf-tracking-and-analysis", "inflation-and-purchasing-power",
    "employment-and-labour-markets", "bitcoin-and-crypto", "data-status",
)


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.ids, self.links, self.assets, self.missing_alt = set(), [], [], []
        self.duplicate_ids, self.empty_sources, self.image_count, self.widget_count = [], [], 0, 0
        self.feed(text)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if attrs.get("id"):
            if attrs["id"] in self.ids:
                self.duplicate_ids.append(attrs["id"])
            self.ids.add(attrs["id"])
        if tag in {"script", "img", "iframe"} and "src" in attrs and not attrs["src"].strip():
            self.empty_sources.append(tag)
        if tag == "img":
            self.image_count += 1
        if tag == "iframe" and "srcdoc" in attrs:
            self.widget_count += 1
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])
        if tag in {"script", "img", "iframe"} and attrs.get("src"):
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("href"):
            self.assets.append(attrs["href"])
        if tag == "img" and not attrs.get("alt", "").strip():
            self.missing_alt.append(attrs.get("src", ""))


def validate(root, require_results=True):
    root = Path(root).resolve()
    docs = {p.resolve(): Page(p.read_text()) for p in root.rglob("*.html")}
    errors = []
    for name in PAGES:
        if root / (name + ".html") not in docs:
            errors.append("Missing legacy page " + name)
    for path, doc in docs.items():
        if doc.duplicate_ids:
            errors.append(f"{path.name}: duplicate fragment IDs {doc.duplicate_ids}")
        if doc.empty_sources:
            errors.append(f"{path.name}: empty src attributes {doc.empty_sources}")
        for ref in doc.links + doc.assets:
            url = urlsplit(ref)
            if url.scheme or url.netloc or url.path.startswith("/"):
                continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if not target.is_relative_to(root) or not target.exists():
                errors.append(f"{path.name}: missing local reference {ref}")
            elif url.fragment and target in docs and unquote(url.fragment) not in docs[target].ids:
                errors.append(f"{path.name}: missing anchor {ref}")
        if doc.missing_alt:
            errors.append(f"{path.name}: missing image descriptions: {doc.missing_alt}")
    tax = root / "etf-tracking-and-analysis.html"
    if tax in docs and "danish-fund-tax" not in docs[tax].ids:
        errors.append("Missing Danish tax anchor")
    if require_results:
        for name, minimum in {"market-chart-gallery": 8, "bond-etf-chart-gallery": 16,
                              "sector-etf-chart-gallery": 20}.items():
            doc = docs.get(root / (name + ".html"))
            if doc and doc.image_count < minimum:
                errors.append(f"{name}: expected at least {minimum} gallery figures, found {doc.image_count}")
        overview = docs.get(root / "equity-markets-and-the-sp-500.html")
        if overview and overview.widget_count + overview.image_count < 6:
            errors.append("Market overview: expected six snapshots, including explicit unavailable-data placeholders")
    if errors:
        raise ValueError("Book validation failed:\n" + "\n".join(errors))
    print(f"Checked {len(docs)} HTML pages and their local references")
