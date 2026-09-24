"""Build dated Danish fund-tax CSV snapshots from official sources and local exports.

Run with --etfs and --funds pointing to the two locally downloaded UTF-16 TSV
exports. Those inputs are never copied into the repository. The output contains
only products with a verified Yahoo symbol and a supported tax classification.
"""

from __future__ import annotations

import argparse
import csv
from concurrent.futures import ThreadPoolExecutor, as_completed
from html.parser import HTMLParser
import io
import json
from pathlib import Path
import re
import sys
import time
from urllib.parse import quote, urljoin
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
from zipfile import ZipFile


YEAR = 2026
SKAT_PAGE = "https://skat.dk/erhverv/ekapital/vaerdipapirer/beviser-og-aktier-i-investeringsforeninger-og-selskaber-ifpa"
VP_PAGE = "https://info.skat.dk/data.aspx?oid=2460620"
VP_WORKBOOK = "https://info.skat.dk/getfile.aspx?id=159618&type=xlsx"
NAMESPACE = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
RELATIONSHIP = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PACKAGE_RELATIONSHIP = "http://schemas.openxmlformats.org/package/2006/relationships"
HEADERS = [
    "name", "type", "isin", "distribution_policy", "yahoo_ticker",
    "yahoo_exchange", "yahoo_source_url", "ordinary_tax_principle", "ordinary_income_type",
    "ask_eligible", "tax_basis", "tax_source_url", "classification_as_of",
]
POSITIVE_HEADERS = [
    "tax_year", "isin", "tax_residence", "share_class_name", "subfund_name",
    "legal_entity_name", "lei", "registered_years", "source_published",
    "source_url",
]


def fetch(url: str, attempts: int = 4) -> bytes:
    for attempt in range(attempts):
        try:
            request = Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible; bookdown-data-refresh/1.0)", "Accept": "*/*"})
            with urlopen(request, timeout=30) as response:
                return response.read()
        except Exception:
            if attempt + 1 == attempts:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


class WorkbookLinkParser(HTMLParser):
    """Select the workbook anchor by its visible text and .xlsx href."""

    def __init__(self) -> None:
        super().__init__()
        self.current_href: str | None = None
        self.current_text: list[str] = []
        self.matches: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "a":
            self.current_href = dict(attrs).get("href")
            self.current_text = []

    def handle_data(self, data: str) -> None:
        if self.current_href is not None:
            self.current_text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self.current_href is not None:
            title = " ".join(self.current_text)
            if "Liste over aktiebaserede investeringsselskaber" in title and self.current_href.lower().endswith(".xlsx"):
                self.matches.append(urljoin(SKAT_PAGE, self.current_href))
            self.current_href = None


def locate_positive_workbook(page_html: str) -> str:
    parser = WorkbookLinkParser()
    parser.feed(page_html)
    matches = sorted(set(parser.matches))
    if len(matches) != 1:
        raise ValueError(f"Expected one Positivliste workbook link, found {len(matches)}")
    return matches[0]


def workbook_rows(contents: bytes, sheet_name: str) -> list[dict[str, str]]:
    """Read an XLSX sheet with the Python standard library; preserve ISIN text."""
    with ZipFile(io.BytesIO(contents)) as archive:
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        sheet = next((item for item in workbook.findall("s:sheets/s:sheet", NAMESPACE) if item.get("name") == sheet_name), None)
        if sheet is None:
            raise ValueError(f"Missing worksheet {sheet_name!r}")
        relationship_id = sheet.get(f"{{{RELATIONSHIP}}}id")
        relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        target = next(item.get("Target") for item in relationships.findall(f"{{{PACKAGE_RELATIONSHIP}}}Relationship") if item.get("Id") == relationship_id)
        path = target.lstrip("/") if target.startswith("/") else f"xl/{target}"
        strings: list[str] = []
        if "xl/sharedStrings.xml" in archive.namelist():
            shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
            strings = ["".join(node.text or "" for node in item.findall(".//s:t", NAMESPACE)) for item in shared.findall("s:si", NAMESPACE)]
        root = ET.fromstring(archive.read(path))
        raw_rows: list[dict[str, str]] = []
        for row in root.findall(".//s:sheetData/s:row", NAMESPACE):
            values: dict[str, str] = {}
            for cell in row.findall("s:c", NAMESPACE):
                column = re.match(r"[A-Z]+", cell.get("r", ""))
                if column is None:
                    continue
                value = cell.find("s:v", NAMESPACE)
                inline = cell.find("s:is", NAMESPACE)
                if value is not None:
                    text = value.text or ""
                    if cell.get("t") == "s":
                        text = strings[int(text)]
                elif inline is not None:
                    text = "".join(node.text or "" for node in inline.findall(".//s:t", NAMESPACE))
                else:
                    text = ""
                values[column.group()] = text.strip()
            raw_rows.append(values)
        if not raw_rows:
            raise ValueError(f"Empty worksheet {sheet_name!r}")
        headings = raw_rows.pop(0)
        return [{headings.get(col, col): value for col, value in row.items()} for row in raw_rows]


def valid_isin(value: str) -> bool:
    if not re.fullmatch(r"[A-Z]{2}[A-Z0-9]{9}[0-9]", value):
        return False
    digits = "".join(str(ord(char) - 55) if char.isalpha() else char for char in value)
    total = 0
    for position, char in enumerate(reversed(digits)):
        number = int(char)
        if position % 2:
            number *= 2
            if number > 9:
                number -= 9
        total += number
    return total % 10 == 0


def positive_rows(workbook: bytes, source_url: str, published: str) -> list[dict[str, str]]:
    rows = workbook_rows(workbook, str(YEAR))
    result = []
    for row in rows:
        isin = row.get("ISIN-kode/-Code", "").upper()
        registered = row.get("Registrerede år/Registered", "")
        years = {item for item in re.split(r"[,.;\s]+", registered) if item}
        if str(YEAR) not in years:
            continue
        result.append({
            "tax_year": str(YEAR), "isin": isin,
            "tax_residence": row.get("Skattemæssigt hjemsted/Tax residence", ""),
            "share_class_name": row.get("Navn andelsklasse/Name Shareclass", ""),
            "subfund_name": row.get("Navn afdeling/Name Sub-fund", ""),
            "legal_entity_name": row.get("Navn/Name", ""),
            "lei": row.get("LEI-kode/-Code", ""),
            "registered_years": registered, "source_published": published,
            "source_url": source_url,
        })
    if not result:
        raise ValueError("No registered 2026 Positivliste entries")
    return sorted(result, key=lambda row: (row["isin"], row["share_class_name"], row["subfund_name"]))


def read_export(path: Path, product_type: str) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"Navn", "Ticker", "ISIN", "Udbyttepolitik"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError(f"Missing columns in {path}: {required - set(reader.fieldnames or [])}")
        rows = []
        for row in reader:
            isin = (row.get("ISIN") or "").strip().upper()
            if valid_isin(isin):
                rows.append({
                    "name": (row.get("Navn") or "").strip(),
                    "type": product_type, "isin": isin,
                    "distribution_policy": (row.get("Udbyttepolitik") or "").strip(),
                    "input_ticker": (row.get("Ticker") or "").strip(),
                })
        return rows


def classify(isin: str, positives: set[str], vp: dict[str, dict[str, str]]) -> tuple[str, str, str, str] | None:
    """Return ordinary principle, income, ASK eligibility, and evidence basis."""
    record = vp.get(isin)
    if isin in positives:
        if record and record.get("P") == "1":
            return None  # conflicting official product status
        return ("lager", "aktieindkomst", "yes", "ABIS 2026")
    if not record or record.get("Q") != "Aktiv":
        return None
    art, activity = record.get("P"), record.get("M")
    if art == "1" and activity == "A":
        return ("realisations", "aktieindkomst", "yes", "VP 2026: 1/A")
    if art == "1" and activity in {"B", "O"}:
        return ("realisations", "kapitalindkomst", "no", f"VP 2026: 1/{activity}")
    if art == "8" and activity in {"B", "O"}:
        return ("lager", "kapitalindkomst", "no", f"VP 2026: 8/{activity}")
    return None


def vp_index(workbook: bytes) -> dict[str, dict[str, str]]:
    """Use source columns, retaining only unique active classifications."""
    rows = workbook_rows(workbook, "KURS (002)")
    index: dict[str, dict[str, str]] = {}
    conflicts: set[str] = set()
    for row in rows:
        isin = row.get("ISIN", "").upper()
        if not valid_isin(isin):
            continue
        record = {
            "M": row.get("Klassifikationinvesteringsinstitut", ""),
            "P": row.get("Udlodningskode", ""),
            "Q": row.get("Status", ""),
            "K": row.get("Reguleret_Marked", ""),
        }
        if isin in index and index[isin] != record:
            conflicts.add(isin)
        else:
            index[isin] = record
    for isin in conflicts:
        index.pop(isin, None)
    return index


def yahoo_quote(isin: str, name: str, input_ticker: str, product_type: str, cache: dict[str, object]) -> dict[str, str] | None:
    if not cache.get(isin):
        url = f"https://query1.finance.yahoo.com/v1/finance/search?q={quote(isin)}&quotesCount=10&newsCount=0"
        try:
            quotes = json.loads(fetch(url).decode("utf-8")).get("quotes", [])
            if quotes:
                cache[isin] = quotes
        except Exception:
            return None
    quotes = cache.get(isin, [])
    if not isinstance(quotes, list):
        return None
    candidates = []
    significant = {word for word in re.findall(r"[a-z0-9]+", name.lower()) if len(word) > 3 and word not in {"ucits", "etf", "fund", "invest", "acc", "dist", "class"}}
    for item in quotes:
        if not isinstance(item, dict):
            continue
        expected_types = {"ETF"} if product_type == "ETF" else {"EQUITY", "MUTUALFUND"}
        if item.get("quoteType") not in expected_types:
            continue
        symbol = item.get("symbol", "")
        display = " ".join(str(item.get(key, "")) for key in ("longname", "shortname")).lower()
        common = significant.intersection(re.findall(r"[a-z0-9]+", display))
        ticker_matches = bool(input_ticker and symbol.upper().split(".")[0] == input_ticker.upper())
        if not symbol or not item.get("isYahooFinance") or not (ticker_matches or len(common) >= 2):
            continue
        score = (100 if ticker_matches else 0) + len(common) * 4 + (10 if item.get("quoteType") == "ETF" else 0)
        candidates.append((score, symbol, str(item.get("exchange", ""))))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    if len(candidates) > 1 and candidates[0][0] == candidates[1][0]:
        return None
    ticker = candidates[0][1]
    chart_key = f"chart:{ticker}"
    if chart_key not in cache:
        chart_url = f"https://query1.finance.yahoo.com/v8/finance/chart/{quote(ticker)}?range=1mo&interval=1d"
        try:
            payload = json.loads(fetch(chart_url).decode("utf-8"))
            chart = payload.get("chart", {}).get("result") or []
            cache[chart_key] = bool(chart and chart[0].get("timestamp"))
        except Exception:
            return None
    if not cache[chart_key]:
        return None
    return {"ticker": ticker, "exchange": candidates[0][2]}


def write_csv(path: Path, headers: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--etfs", type=Path, required=True)
    parser.add_argument("--funds", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("data"))
    parser.add_argument("--cache", type=Path, default=Path(".cache/investment_catalogue/yahoo.json"))
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    page = fetch(SKAT_PAGE).decode("utf-8")
    workbook_url = locate_positive_workbook(page)
    published_match = re.search(rf"offentliggjort den (\d{{1,2}})\. (\w+) {YEAR}", page)
    month = {name: f"{number:02}" for number, name in enumerate((
        "januar", "februar", "marts", "april", "maj", "juni", "juli", "august",
        "september", "oktober", "november", "december",
    ), start=1)}
    published = f"{YEAR}-{month[published_match.group(2)]}-{int(published_match.group(1)):02}" if published_match and published_match.group(2) in month else ""
    if not published:
        raise ValueError("Cannot confirm Positivliste publication date")
    positive = positive_rows(fetch(workbook_url), workbook_url, published)
    positives = {row["isin"] for row in positive if valid_isin(row["isin"])}
    vp = vp_index(fetch(VP_WORKBOOK))
    inputs = read_export(args.etfs, "ETF") + read_export(args.funds, "Investeringsforeninger")
    if args.cache.exists():
        cache = json.loads(args.cache.read_text(encoding="utf-8"))
    else:
        cache = {}
    grouped: dict[str, list[dict[str, str]]] = {}
    for row in inputs:
        grouped.setdefault(row["isin"], []).append(row)
    classified = []
    for isin, rows in grouped.items():
        tax = classify(isin, positives, vp)
        if tax is not None:
            classified.append((isin, rows, tax))
    print(f"Input ISINs: {len(grouped)}; defensible tax classification: {len(classified)}", file=sys.stderr)
    matches: dict[str, dict[str, str] | None] = {}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(yahoo_quote, isin, rows[0]["name"], rows[0]["input_ticker"], rows[0]["type"], cache): isin for isin, rows, _ in classified}
        for future in as_completed(futures):
            matches[futures[future]] = future.result()
    args.cache.parent.mkdir(parents=True, exist_ok=True)
    args.cache.write_text(json.dumps(cache, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    output = []
    for isin, rows, tax in classified:
        yahoo = matches[isin]
        if yahoo is None:
            continue
        principle, income, eligible, basis = tax
        row = rows[0]
        output.append({
            "name": row["name"], "type": row["type"], "isin": isin,
            "distribution_policy": row["distribution_policy"],
            "yahoo_ticker": yahoo["ticker"], "yahoo_exchange": yahoo["exchange"],
            "yahoo_source_url": f"https://finance.yahoo.com/quote/{quote(yahoo['ticker'])}/",
            "ordinary_tax_principle": principle, "ordinary_income_type": income,
            "ask_eligible": eligible, "tax_basis": basis,
            "tax_source_url": workbook_url if basis.startswith("ABIS") else VP_PAGE,
            "classification_as_of": published if basis.startswith("ABIS") else "2026-02-01",
        })
    output.sort(key=lambda row: (row["type"], row["name"].casefold(), row["isin"]))
    write_csv(args.output_dir / "positivliste_2026.csv", POSITIVE_HEADERS, positive)
    write_csv(args.output_dir / "investment_products_2026.csv", HEADERS, output)
    print(f"Published Yahoo-matched products: {len(output)}; excluded: {len(grouped) - len(output)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
