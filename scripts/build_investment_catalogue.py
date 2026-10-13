"""Build dated Danish fund-tax CSV snapshots from official sources and local exports.

Run with --etfs and --funds pointing to the two locally downloaded UTF-16 TSV
exports. Those inputs are never copied into the repository. The output contains
only products with a verified Yahoo symbol and a supported tax classification.
Yahoo cache entries expire after seven days (positive) or one hour (confirmed
negative). --refresh-cache bypasses both; --cache-max-age-days tunes the positive
lifetime. Exclusion diagnostics go beside the cache, outside the published CSVs.
"""

from __future__ import annotations

import argparse
import csv
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from html.parser import HTMLParser
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
from urllib.parse import quote, urljoin
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile


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
CACHE_SCHEMA_VERSION = 1
POSITIVE_CACHE_DAYS = 7
NEGATIVE_CACHE_SECONDS = 60 * 60
POSITIVE_COLUMNS = {
    "ISIN-kode/-Code", "Registrerede år/Registered",
    "Skattemæssigt hjemsted/Tax residence", "Navn andelsklasse/Name Shareclass",
    "Navn afdeling/Name Sub-fund", "Navn/Name", "LEI-kode/-Code",
}
VP_COLUMNS = {
    "ISIN", "Klassifikationinvesteringsinstitut", "Udlodningskode",
    "Status", "Reguleret_Marked",
}


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


def workbook_rows(contents: bytes, sheet_name: str, required_columns: set[str] | None = None) -> list[dict[str, str]]:
    try:
        return _workbook_rows(contents, sheet_name, required_columns or set())
    except (BadZipFile, KeyError, IndexError, StopIteration, ET.ParseError) as error:
        raise ValueError(f"Malformed workbook worksheet {sheet_name!r}: {error}") from error


def _workbook_rows(contents: bytes, sheet_name: str, required_columns: set[str]) -> list[dict[str, str]]:
    """Read an XLSX sheet with the Python standard library; preserve ISIN text."""
    with ZipFile(io.BytesIO(contents)) as archive:
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        sheet = next((item for item in workbook.findall("s:sheets/s:sheet", NAMESPACE) if item.get("name") == sheet_name), None)
        if sheet is None:
            raise ValueError(f"Missing worksheet {sheet_name!r}")
        relationship_id = sheet.get(f"{{{RELATIONSHIP}}}id")
        relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        relationship = next(item for item in relationships.findall(f"{{{PACKAGE_RELATIONSHIP}}}Relationship") if item.get("Id") == relationship_id)
        target = relationship.get("Target")
        if not target or relationship.get("TargetMode") == "External":
            raise ValueError(f"Invalid worksheet relationship for {sheet_name!r}")
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
        # Excel may serialize formatted blank cells past the actual table.
        headings = {column: value for column, value in raw_rows.pop(0).items() if value}
        if not headings or len(set(headings.values())) != len(headings):
            raise ValueError(f"Empty or duplicate column headings in {sheet_name!r}")
        missing = required_columns - set(headings.values())
        if missing:
            raise ValueError(f"Missing columns in {sheet_name!r}: {sorted(missing)}")
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
    rows = workbook_rows(workbook, str(YEAR), POSITIVE_COLUMNS)
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


def read_export(path: Path, product_type: str, exclusions: list[dict[str, str]] | None = None) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"Navn", "Ticker", "ISIN", "Udbyttepolitik"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError(f"Missing columns in {path}: {required - set(reader.fieldnames or [])}")
        rows = []
        for row in reader:
            if None in row or any(row.get(column) is None for column in required):
                raise ValueError(f"Malformed export row in {path}")
            isin = (row.get("ISIN") or "").strip().upper()
            if valid_isin(isin):
                rows.append({
                    "name": (row.get("Navn") or "").strip(),
                    "type": product_type, "isin": isin,
                    "distribution_policy": (row.get("Udbyttepolitik") or "").strip(),
                    "input_ticker": (row.get("Ticker") or "").strip(),
                })
            elif exclusions is not None:
                exclusions.append({"isin": isin, "type": product_type, "reason": "invalid_isin"})
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
    rows = workbook_rows(workbook, "KURS (002)", VP_COLUMNS)
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


def load_cache(path: Path) -> dict[str, object]:
    """Legacy disk entries have no age evidence and must be fetched again."""
    try:
        cache = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        cache = {}
    if not isinstance(cache, dict) or cache.get("schema_version") != CACHE_SCHEMA_VERSION or not isinstance(cache.get("entries"), dict):
        return {"schema_version": CACHE_SCHEMA_VERSION, "entries": {}}
    return cache


def cache_value(cache: dict[str, object], key: str, max_age_days: float, refresh: bool) -> object | None:
    if refresh:
        return None
    if "schema_version" not in cache:
        # Retain the historical in-memory API for fixtures and callers.
        return cache.get(key)
    entries = cache.get("entries", {})
    entry = entries.get(key) if isinstance(entries, dict) else None
    if not isinstance(entry, dict):
        return None
    fetched_at = entry.get("fetched_at")
    if isinstance(fetched_at, bool) or not isinstance(fetched_at, (int, float)) or not math.isfinite(fetched_at):
        return None
    age = time.time() - fetched_at
    status, value = entry.get("status"), entry.get("value")
    if key.startswith("chart:"):
        valid = isinstance(value, bool) and status == ("positive" if value else "negative")
    else:
        valid = isinstance(value, list) and status == ("positive" if value else "negative")
    ttl = max_age_days * 86400 if status == "positive" else NEGATIVE_CACHE_SECONDS
    return value if valid and 0 <= age < ttl else None


def cache_store(cache: dict[str, object], key: str, value: object) -> None:
    if "schema_version" not in cache:
        cache[key] = value
    else:
        cache["entries"][key] = {
            "fetched_at": time.time(), "status": "positive" if value else "negative", "value": value,
        }


def search_quotes(payload: object) -> list[dict[str, object]]:
    if not isinstance(payload, dict) or payload.get("error") or not isinstance(payload.get("quotes"), list):
        raise ValueError("Invalid or failed Yahoo search response")
    finance = payload.get("finance")
    if isinstance(finance, dict) and finance.get("error"):
        raise ValueError("Failed Yahoo search response")
    quotes = payload["quotes"]
    for item in quotes:
        if not isinstance(item, dict) or not isinstance(item.get("symbol"), str) or not item["symbol"] or not isinstance(item.get("quoteType"), str):
            raise ValueError("Malformed Yahoo search quote")
        for field in ("longname", "shortname", "exchange"):
            if item.get(field) is not None and not isinstance(item[field], str):
                raise ValueError(f"Malformed Yahoo search {field}")
    return quotes


def chart_has_history(payload: object) -> bool:
    if not isinstance(payload, dict) or not isinstance(payload.get("chart"), dict):
        raise ValueError("Invalid Yahoo chart response")
    chart = payload["chart"]
    error = chart.get("error")
    if error:
        if isinstance(error, dict) and error.get("code") == "Not Found":
            return False
        raise ValueError(f"Yahoo chart error: {error}")
    results = chart.get("result")
    if not isinstance(results, list):
        raise ValueError("Missing Yahoo chart result")
    if not results:
        return False
    if len(results) != 1 or not isinstance(results[0], dict) or not isinstance(results[0].get("timestamp"), list):
        raise ValueError("Malformed Yahoo chart history")
    timestamps = results[0]["timestamp"]
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0 for value in timestamps):
        raise ValueError("Malformed Yahoo chart timestamps")
    return bool(timestamps)


def yahoo_quote(isin: str, name: str, input_ticker: str, product_type: str, cache: dict[str, object], *,
                max_age_days: float = POSITIVE_CACHE_DAYS, refresh: bool = False,
                diagnostics: dict[str, str] | None = None) -> dict[str, str] | None:
    def excluded(reason: str, error: Exception | None = None) -> None:
        if diagnostics is not None:
            diagnostics["reason"] = reason
            if error is not None:
                diagnostics["detail"] = str(error)

    quotes = cache_value(cache, isin, max_age_days, refresh)
    if quotes is not None:
        try:
            quotes = search_quotes({"quotes": quotes})
        except ValueError:
            quotes = None
    if quotes is None:
        url = f"https://query1.finance.yahoo.com/v1/finance/search?q={quote(isin)}&quotesCount=10&newsCount=0"
        try:
            quotes = search_quotes(json.loads(fetch(url).decode("utf-8")))
            cache_store(cache, isin, quotes)
        except Exception as error:
            excluded("transient_search_error", error)
            return None
    if not quotes:
        excluded("no_search_matches")
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
        excluded("no_compatible_quote")
        return None
    # Repeated identical search records do not make a symbol ambiguous.
    candidates = list(set(candidates))
    candidates.sort(reverse=True)
    if len(candidates) > 1 and candidates[0][0] == candidates[1][0]:
        excluded("ambiguous_quote")
        return None
    ticker = candidates[0][1]
    chart_key = f"chart:{ticker}"
    history = cache_value(cache, chart_key, max_age_days, refresh)
    if not isinstance(history, bool):
        chart_url = f"https://query1.finance.yahoo.com/v8/finance/chart/{quote(ticker)}?range=1mo&interval=1d"
        try:
            history = chart_has_history(json.loads(fetch(chart_url).decode("utf-8")))
            cache_store(cache, chart_key, history)
        except Exception as error:
            excluded("transient_chart_error", error)
            return None
    if not history:
        excluded("no_price_history")
        return None
    return {"ticker": ticker, "exchange": candidates[0][2]}


def write_csv(path: Path, headers: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
        handle.flush()
        os.fsync(handle.fileno())


def write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_csv(path: Path, headers: list[str]) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != headers:
            raise ValueError(f"Unexpected CSV headers in {path.name}")
        rows = list(reader)
    if not rows or any(None in row or any(value is None for value in row.values()) for row in rows):
        raise ValueError(f"Empty or malformed CSV contents in {path.name}")
    if headers == POSITIVE_HEADERS:
        for row in rows:
            if row["tax_year"] != str(YEAR) or str(YEAR) not in re.split(r"[,.;\s]+", row["registered_years"]):
                raise ValueError("Wrong tax year in Positivliste CSV")
            datetime.strptime(row["source_published"], "%Y-%m-%d")
            if not row["source_url"].startswith("https://"):
                raise ValueError("Missing Positivliste source URL")
    else:
        if len(rows) != len({row["isin"] for row in rows}) or len(rows) != len({row["yahoo_ticker"] for row in rows}):
            raise ValueError("Duplicate catalogue ISIN or Yahoo ticker")
        allowed = {
            ("lager", "aktieindkomst"), ("lager", "kapitalindkomst"),
            ("realisations", "aktieindkomst"), ("realisations", "kapitalindkomst"),
        }
        for row in rows:
            if not valid_isin(row["isin"]) or not row["yahoo_ticker"] or not row["name"]:
                raise ValueError("Invalid catalogue identity")
            if (row["ordinary_tax_principle"], row["ordinary_income_type"]) not in allowed or row["ask_eligible"] not in {"yes", "no"}:
                raise ValueError("Invalid catalogue tax classification")
            if not row["tax_basis"] or not row["tax_source_url"].startswith("https://") or not row["yahoo_source_url"].startswith("https://finance.yahoo.com/quote/"):
                raise ValueError("Missing catalogue evidence")
            datetime.strptime(row["classification_as_of"], "%Y-%m-%d")
            if any("nordnet" in value.lower() for value in row.values()):
                raise ValueError("Provider branding in neutral catalogue")
    return rows


def sync_directory(path: Path) -> None:
    if os.name == "posix":
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def replace_csv_pair(output_dir: Path, positive: list[dict[str, str]], products: list[dict[str, str]]) -> None:
    """Stage and validate both files, then replace with recoverable originals.

    Each rename is atomic. A failed second rename rolls back the first; backups
    survive an interrupted process or a rollback failure in the staging folder.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".catalogue-refresh-", dir=output_dir))
    changed: list[Path] = []
    originals: dict[Path, Path | None] = {}
    recoverable = False
    try:
        files = (
            (output_dir / f"positivliste_{YEAR}.csv", POSITIVE_HEADERS, positive),
            (output_dir / f"investment_products_{YEAR}.csv", HEADERS, products),
        )
        for destination, headers, rows in files:
            staged = staging / destination.name
            write_csv(staged, headers, rows)
            validated = validate_csv(staged, headers)
            if validated != [{key: row[key] for key in headers} for row in rows]:
                raise ValueError(f"CSV round-trip mismatch in {destination.name}")
        positives = {row["isin"] for row in positive if valid_isin(row["isin"])}
        if any((row["isin"] in positives) != row["tax_basis"].startswith("ABIS") for row in products):
            raise ValueError("Catalogue and Positivliste evidence disagree")
        for destination, _, _ in files:
            backup = staging / f"{destination.name}.previous"
            if destination.exists():
                shutil.copy2(destination, backup)
                with backup.open("rb") as handle:
                    os.fsync(handle.fileno())
                originals[destination] = backup
            else:
                originals[destination] = None
        sync_directory(staging)
        sync_directory(output_dir)
        for destination, _, _ in files:
            os.replace(staging / destination.name, destination)
            changed.append(destination)
        sync_directory(output_dir)
    except BaseException:
        try:
            for destination in reversed(changed):
                backup = originals[destination]
                if backup is None:
                    destination.unlink()
                else:
                    os.replace(backup, destination)
            if changed:
                sync_directory(output_dir)
        except BaseException as rollback_error:
            recoverable = True
            raise RuntimeError(f"CSV rollback failed; recover originals from {staging}") from rollback_error
        raise
    finally:
        if not recoverable:
            # Cleanup cannot turn a completed publication into a failed refresh.
            shutil.rmtree(staging, ignore_errors=True)


def build_catalogue(args: argparse.Namespace, report: dict[str, object]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    exclusions = report["exclusions"]
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
    datetime.strptime(published, "%Y-%m-%d")
    positive = positive_rows(fetch(workbook_url), workbook_url, published)
    positives = {row["isin"] for row in positive if valid_isin(row["isin"])}
    vp = vp_index(fetch(VP_WORKBOOK))
    if not positives or not vp:
        raise ValueError("No usable official tax evidence")
    inputs = read_export(args.etfs, "ETF", exclusions) + read_export(args.funds, "Investeringsforeninger", exclusions)
    if not inputs:
        raise ValueError("No valid input ISINs")
    cache = load_cache(args.cache)
    grouped: dict[str, list[dict[str, str]]] = {}
    for row in inputs:
        grouped.setdefault(row["isin"], []).append(row)
    classified = []
    for isin, rows in grouped.items():
        tax = classify(isin, positives, vp)
        if tax is not None:
            classified.append((isin, rows, tax))
        else:
            exclusions.append({"isin": isin, "reason": "unsupported_or_conflicting_tax_evidence"})
    report["input_isins"] = len(grouped)
    report["classified_isins"] = len(classified)
    print(f"Input ISINs: {len(grouped)}; defensible tax classification: {len(classified)}", file=sys.stderr)
    matches: dict[str, dict[str, str] | None] = {}
    diagnostics: dict[str, dict[str, str]] = {isin: {} for isin, _, _ in classified}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(yahoo_quote, isin, rows[0]["name"], rows[0]["input_ticker"], rows[0]["type"], cache,
                        max_age_days=args.cache_max_age_days, refresh=args.refresh_cache,
                        diagnostics=diagnostics[isin]): isin
            for isin, rows, _ in classified
        }
        for future in as_completed(futures):
            matches[futures[future]] = future.result()
    for isin, _, _ in classified:
        if matches[isin] is None:
            exclusions.append({"isin": isin, **diagnostics[isin]})
    write_json_atomic(args.cache, cache)
    if any(item.get("reason", "").startswith("transient_") for item in exclusions):
        raise ValueError("Transient Yahoo lookup failures; existing CSV pair preserved")
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
    report["matched_products"] = len(output)
    return positive, output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--etfs", type=Path, required=True)
    parser.add_argument("--funds", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("data"))
    parser.add_argument("--cache", type=Path, default=Path(".cache/investment_catalogue/yahoo.json"))
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--refresh-cache", action="store_true", help="Bypass all cached Yahoo search/chart entries")
    parser.add_argument("--cache-max-age-days", type=float, default=POSITIVE_CACHE_DAYS,
                        help="Positive cache lifetime in days (default: 7); confirmed negatives expire after 1 hour")
    parser.add_argument("--exclusion-report", type=Path, help="JSON diagnostic report (default: exclusion_report.json beside --cache)")
    args = parser.parse_args(argv)
    if args.workers < 1 or not math.isfinite(args.cache_max_age_days) or args.cache_max_age_days < 0:
        parser.error("--workers must be positive and --cache-max-age-days finite and nonnegative")
    report_path = args.exclusion_report or args.cache.parent / "exclusion_report.json"
    destinations = [args.cache, report_path, args.output_dir / f"positivliste_{YEAR}.csv", args.output_dir / f"investment_products_{YEAR}.csv"]
    resolved = [path.resolve() for path in destinations]
    if len(set(resolved)) != len(resolved) or set(resolved).intersection({args.etfs.resolve(), args.funds.resolve()}):
        parser.error("Cache, report, outputs and original inputs must have distinct paths")
    report: dict[str, object] = {
        "schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
        "tax_year": YEAR, "status": "building", "exclusions": [],
    }
    try:
        positive, output = build_catalogue(args, report)
        # Persist diagnostics before replacement, so report I/O cannot cause a
        # refresh to fail after the published pair has already been changed.
        report["status"] = "validated_inputs"
        write_json_atomic(report_path, report)
        replace_csv_pair(args.output_dir, positive, output)
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        try:
            write_json_atomic(report_path, report)
        except OSError as report_error:
            print(f"Cannot write exclusion report: {report_error}", file=sys.stderr)
        print(f"Catalogue refresh failed: {error}", file=sys.stderr)
        return 1
    print(f"Published Yahoo-matched products: {len(output)}; exclusions: {len(report['exclusions'])}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
