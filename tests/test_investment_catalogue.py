"""Offline checks for the dated Danish investment catalogue refresh."""

import unittest
import csv
from copy import deepcopy
import io
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import call, patch
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
from zipfile import ZipFile

from scripts import build_investment_catalogue as catalogue
from scripts.build_investment_catalogue import classify, locate_positive_workbook, valid_isin, yahoo_quote


ISIN = "IE000XNGQNH4"
FUND_ISIN = "DK0010268606"
NOW = 1_800_000_000
QUOTE = {
    "symbol": "EXAMPLE.DE", "exchange": "GER", "quoteType": "ETF",
    "isYahooFinance": True, "longname": "Example Global Equity",
}
CHART = {"chart": {"error": None, "result": [{"timestamp": [NOW - 86400, NOW]}]}}


def json_bytes(value):
    return json.dumps(value).encode("utf-8")


def count_yahoo_calls(calls):
    """Count mocked Yahoo API requests by their parsed, exact hostname."""
    return sum(urlsplit(request.args[0]).hostname == "query1.finance.yahoo.com" for request in calls)


def versioned_cache(values=None, age=0):
    return {
        "schema_version": catalogue.CACHE_SCHEMA_VERSION,
        "entries": {
            key: {"fetched_at": NOW - age, "status": "positive" if value else "negative", "value": value}
            for key, value in (values or {}).items()
        },
    }


def workbook_fixture(sheet_name, headers, rows):
    """Synthetic inline-string XLSX, never a copy of the original workbooks."""
    namespace = catalogue.NAMESPACE["s"]
    workbook = ET.Element(f"{{{namespace}}}workbook")
    sheets = ET.SubElement(workbook, f"{{{namespace}}}sheets")
    ET.SubElement(sheets, f"{{{namespace}}}sheet", {
        "name": sheet_name, f"{{{catalogue.RELATIONSHIP}}}id": "rId1",
    })
    relationships = ET.Element(f"{{{catalogue.PACKAGE_RELATIONSHIP}}}Relationships")
    ET.SubElement(relationships, f"{{{catalogue.PACKAGE_RELATIONSHIP}}}Relationship", {
        "Id": "rId1", "Target": "worksheets/sheet1.xml",
    })
    sheet = ET.Element(f"{{{namespace}}}worksheet")
    data = ET.SubElement(sheet, f"{{{namespace}}}sheetData")
    for number, values in enumerate([headers] + rows, 1):
        row = ET.SubElement(data, f"{{{namespace}}}row", {"r": str(number)})
        for index, value in enumerate(values):
            cell = ET.SubElement(row, f"{{{namespace}}}c", {"r": f"{chr(65 + index)}{number}", "t": "inlineStr"})
            inline = ET.SubElement(cell, f"{{{namespace}}}is")
            ET.SubElement(inline, f"{{{namespace}}}t").text = value
    contents = io.BytesIO()
    with ZipFile(contents, "w") as archive:
        for path, element in (
            ("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", relationships),
            ("xl/worksheets/sheet1.xml", sheet),
        ):
            archive.writestr(path, ET.tostring(element))
    return contents.getvalue()


def official_workbook_fixtures():
    positive_headers = sorted(catalogue.POSITIVE_COLUMNS)
    positive = {
        "ISIN-kode/-Code": ISIN, "Registrerede år/Registered": "2025, 2026",
        "Skattemæssigt hjemsted/Tax residence": "IE", "Navn andelsklasse/Name Shareclass": "Example Global Equity",
        "Navn afdeling/Name Sub-fund": "Global", "Navn/Name": "Example Funds", "LEI-kode/-Code": "synthetic",
    }
    vp_headers = sorted(catalogue.VP_COLUMNS)
    vp = {"ISIN": FUND_ISIN, "Klassifikationinvesteringsinstitut": "A", "Udlodningskode": "1", "Status": "Aktiv", "Reguleret_Marked": "1"}
    return (
        workbook_fixture("2026", positive_headers, [[positive[key] for key in positive_headers]]),
        workbook_fixture("KURS (002)", vp_headers, [[vp[key] for key in vp_headers]]),
    )


class InvestmentCatalogueTests(unittest.TestCase):
    def setUp(self):
        # Every network-capable call must supply an explicit synthetic response.
        self.network_guard = patch.object(catalogue, "fetch", side_effect=AssertionError("Live network forbidden in catalogue tests"))
        self.network_guard.start()
        self.addCleanup(self.network_guard.stop)

    def test_selects_excel_anchor_inside_closed_section(self):
        html = '<button aria-expanded="false">Liste over aktiebaserede investeringsselskaber</button><div aria-hidden="true"><a href="/media/list-2026.xlsx">Liste over aktiebaserede investeringsselskaber</a></div>'
        self.assertEqual(locate_positive_workbook(html), "https://skat.dk/media/list-2026.xlsx")

    def test_rejects_ambiguous_workbook_links(self):
        html = '<a href="/a.xlsx">Liste over aktiebaserede investeringsselskaber</a><a href="/b.xlsx">Liste over aktiebaserede investeringsselskaber</a>'
        with self.assertRaises(ValueError):
            locate_positive_workbook(html)

    def test_tax_matrix_and_missing_evidence(self):
        vp = {
            "DK0000000001": {"P": "1", "M": "A", "Q": "Aktiv"},
            "DK0000000002": {"P": "1", "M": "B", "Q": "Aktiv"},
            "DK0000000003": {"P": "1", "M": "O", "Q": "Aktiv"},
            "DK0000000004": {"P": "8", "M": "B", "Q": "Aktiv"},
            "DK0000000005": {"P": "8", "M": "O", "Q": "Aktiv"},
        }
        self.assertEqual(classify("DK0000000001", set(), vp)[:3], ("realisations", "aktieindkomst", "yes"))
        for isin in ("DK0000000002", "DK0000000003"):
            self.assertEqual(classify(isin, set(), vp)[:3], ("realisations", "kapitalindkomst", "no"))
        for isin in ("DK0000000004", "DK0000000005"):
            self.assertEqual(classify(isin, set(), vp)[:3], ("lager", "kapitalindkomst", "no"))
        self.assertEqual(classify("IE0000000001", {"IE0000000001"}, vp)[:3], ("lager", "aktieindkomst", "yes"))
        self.assertIsNone(classify("IE0000000002", set(), vp))
        self.assertIsNone(classify("DK0000000001", {"DK0000000001"}, vp))

    def test_isin_checksum(self):
        self.assertTrue(valid_isin("IE000XNGQNH4"))
        self.assertFalse(valid_isin("IE000XNGQNH5"))
        self.assertFalse(valid_isin("Udstedt uden"))

    def test_committed_catalogue_is_complete_and_provider_neutral(self):
        data_dir = Path(__file__).resolve().parents[1] / "data"
        path = data_dir / "investment_products_2026.csv"
        with path.open(encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        with (data_dir / "positivliste_2026.csv").open(encoding="utf-8", newline="") as handle:
            positive_rows = list(csv.DictReader(handle))
        positive_isins = {row["isin"] for row in positive_rows}
        self.assertTrue(all(row["tax_year"] == "2026" and "2026" in row["registered_years"] for row in positive_rows))
        self.assertTrue(all(row["source_published"] for row in positive_rows))
        self.assertGreater(len(rows), 0)
        self.assertEqual(len(rows), len({row["isin"] for row in rows}))
        self.assertEqual(len(rows), len({row["yahoo_ticker"] for row in rows}))
        self.assertTrue(all(valid_isin(row["isin"]) for row in rows))
        self.assertTrue(all(row["ask_eligible"] in {"yes", "no"} for row in rows))
        self.assertTrue(all(row["yahoo_ticker"] and row["tax_basis"] for row in rows))
        self.assertTrue(all(row["yahoo_source_url"].startswith("https://finance.yahoo.com/quote/") for row in rows))
        self.assertTrue(all((row["isin"] in positive_isins) == row["tax_basis"].startswith("ABIS") for row in rows))
        self.assertFalse(any("nordnet" in " ".join(row.values()).lower() for row in rows))
        self.assertEqual(
            {(row["ordinary_tax_principle"], row["ordinary_income_type"]) for row in rows},
            {("lager", "aktieindkomst"), ("lager", "kapitalindkomst"),
             ("realisations", "aktieindkomst"), ("realisations", "kapitalindkomst")},
        )

    def test_yahoo_match_requires_type_and_price_history(self):
        isin = "IE000XNGQNH4"
        cache = {
            isin: [{"symbol": "AZC0.DE", "exchange": "GER", "quoteType": "ETF", "isYahooFinance": True, "longname": "Allianz Smart EUR Corporate Bond"}],
            "chart:AZC0.DE": True,
        }
        match = yahoo_quote(isin, "Allianz Smart EUR Corporate Bond", "AZC0", "ETF", cache)
        self.assertEqual(match, {"ticker": "AZC0.DE", "exchange": "GER"})
        self.assertIsNone(yahoo_quote(isin, "Allianz Smart EUR Corporate Bond", "AZC0", "Investeringsforeninger", cache))

    def lookup(self, cache, **kwargs):
        return yahoo_quote(ISIN, "Example Global Equity", "EXAMPLE", "ETF", cache, **kwargs)

    def test_fresh_timestamped_positive_cache_avoids_fetch(self):
        cache = versioned_cache({ISIN: [QUOTE], "chart:EXAMPLE.DE": True})
        with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch") as fetch:
            self.assertEqual(self.lookup(cache), {"ticker": "EXAMPLE.DE", "exchange": "GER"})
        fetch.assert_not_called()

    def test_search_and_chart_positive_expire_at_seven_days(self):
        for key in (ISIN, "chart:EXAMPLE.DE"):
            with self.subTest(key=key):
                cache = versioned_cache({ISIN: [QUOTE], "chart:EXAMPLE.DE": True})
                cache["entries"][key]["fetched_at"] = NOW - 7 * 86400
                payload = {"quotes": [QUOTE]} if key == ISIN else CHART
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", return_value=json_bytes(payload)) as fetch:
                    self.assertIsNotNone(self.lookup(cache))
                fetch.assert_called_once()
                self.assertEqual(cache["entries"][key]["fetched_at"], NOW)

    def test_positive_max_age_and_force_refresh(self):
        cache = versioned_cache({ISIN: [QUOTE], "chart:EXAMPLE.DE": True}, age=86400)
        with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", side_effect=[json_bytes({"quotes": [QUOTE]}), json_bytes(CHART)]) as fetch:
            self.assertIsNotNone(self.lookup(cache, max_age_days=1))
        self.assertEqual(fetch.call_count, 2)
        with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", side_effect=[json_bytes({"quotes": [QUOTE]}), json_bytes(CHART)]) as fetch:
            self.assertIsNotNone(self.lookup(cache, refresh=True))
        self.assertEqual(fetch.call_count, 2)

    def test_confirmed_negative_search_and_chart_expire_after_one_hour(self):
        for key, negative in ((ISIN, []), ("chart:EXAMPLE.DE", False)):
            with self.subTest(key=key):
                cache = versioned_cache({ISIN: [QUOTE], "chart:EXAMPLE.DE": True})
                cache["entries"].update(versioned_cache({key: negative}, age=3599)["entries"])
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch") as fetch:
                    self.assertIsNone(self.lookup(cache, max_age_days=30))
                fetch.assert_not_called()
                cache["entries"][key]["fetched_at"] -= 1
                payload = {"quotes": [QUOTE]} if key == ISIN else CHART
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", return_value=json_bytes(payload)) as fetch:
                    self.assertIsNotNone(self.lookup(cache, max_age_days=30))
                fetch.assert_called_once()

    def test_new_negative_entries_are_timestamped(self):
        for payload, key, reason in (
            ({"quotes": []}, ISIN, "no_search_matches"),
            ({"chart": {"result": [], "error": None}}, "chart:EXAMPLE.DE", "no_price_history"),
            ({"chart": {"result": None, "error": {"code": "Not Found"}}}, "chart:EXAMPLE.DE", "no_price_history"),
            ({"chart": {"result": [{"timestamp": []}], "error": None}}, "chart:EXAMPLE.DE", "no_price_history"),
        ):
            with self.subTest(payload=payload):
                cache = versioned_cache({ISIN: [QUOTE]}) if key.startswith("chart:") else versioned_cache()
                diagnostics = {}
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", return_value=json_bytes(payload)):
                    self.assertIsNone(self.lookup(cache, diagnostics=diagnostics))
                self.assertEqual(diagnostics["reason"], reason)
                self.assertEqual(cache["entries"][key], {"status": "negative", "fetched_at": NOW, "value": False if key.startswith("chart:") else []})

    def test_transient_and_malformed_search_never_create_negative_entries(self):
        for failure in (
            TimeoutError("temporary"), b"not json", json_bytes({}),
            json_bytes({"error": "rate limited", "quotes": []}),
            json_bytes({"finance": {"error": {"code": "Unauthorized"}}, "quotes": []}),
            json_bytes({"quotes": [{}]}),
        ):
            with self.subTest(failure=failure):
                cache, diagnostics = versioned_cache(), {}
                options = {"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure}
                with patch.object(catalogue, "fetch", **options):
                    self.assertIsNone(self.lookup(cache, diagnostics=diagnostics))
                self.assertEqual(cache["entries"], {})
                self.assertEqual(diagnostics["reason"], "transient_search_error")

    def test_transient_and_malformed_chart_never_create_false_entries(self):
        for failure in (
            TimeoutError("temporary"), b"not json", json_bytes({}),
            json_bytes({"chart": {"error": {"code": "Too Many Requests"}, "result": None}}),
            json_bytes({"chart": {"result": None, "error": None}}),
            json_bytes({"chart": {"result": [{}], "error": None}}),
            json_bytes({"chart": {"result": [{"timestamp": [None]}], "error": None}}),
        ):
            with self.subTest(failure=failure):
                cache, diagnostics = versioned_cache({ISIN: [QUOTE]}), {}
                options = {"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure}
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", **options):
                    self.assertIsNone(self.lookup(cache, diagnostics=diagnostics))
                self.assertNotIn("chart:EXAMPLE.DE", cache["entries"])
                self.assertEqual(diagnostics["reason"], "transient_chart_error")

    def test_expired_positive_is_not_used_after_transient_failure(self):
        for key in (ISIN, "chart:EXAMPLE.DE"):
            with self.subTest(key=key):
                cache = versioned_cache({ISIN: [QUOTE], "chart:EXAMPLE.DE": True})
                cache["entries"][key]["fetched_at"] = NOW - 8 * 86400
                original = deepcopy(cache)
                diagnostics = {}
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", side_effect=TimeoutError("offline")):
                    self.assertIsNone(self.lookup(cache, diagnostics=diagnostics))
                self.assertTrue(diagnostics["reason"].startswith("transient_"))
                self.assertEqual(cache, original)

    def test_future_corrupt_and_inconsistent_cache_entries_are_refetched(self):
        for entry in (
            {"fetched_at": NOW + 1, "status": "positive", "value": [QUOTE]},
            {"fetched_at": "yesterday", "status": "positive", "value": [QUOTE]},
            {"fetched_at": float("nan"), "status": "positive", "value": [QUOTE]},
            {"fetched_at": NOW, "status": "negative", "value": [QUOTE]},
            {"fetched_at": NOW, "status": "positive", "value": [{}]},
        ):
            with self.subTest(entry=entry):
                cache = versioned_cache({"chart:EXAMPLE.DE": True})
                cache["entries"][ISIN] = entry
                with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", return_value=json_bytes({"quotes": [QUOTE]})) as fetch:
                    self.assertIsNotNone(self.lookup(cache))
                fetch.assert_called_once()

    def test_legacy_disk_cache_is_migrated_without_promoting_undated_entries(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            path.write_text(json.dumps({ISIN: [QUOTE], "chart:EXAMPLE.DE": False}), encoding="utf-8")
            cache = catalogue.load_cache(path)
            self.assertEqual(cache, versioned_cache())
            with patch.object(catalogue.time, "time", return_value=NOW), patch.object(catalogue, "fetch", side_effect=[json_bytes({"quotes": [QUOTE]}), json_bytes(CHART)]) as fetch:
                self.assertIsNotNone(self.lookup(cache))
            self.assertEqual(fetch.call_count, 2)
            catalogue.write_json_atomic(path, cache)
            self.assertEqual(catalogue.load_cache(path), cache)

    def test_bad_disk_cache_and_unknown_schema_are_refreshable(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            for content in ("{broken", "[]", '{"schema_version": 99, "entries": {}}', '{"schema_version": 1, "entries": []}'):
                path.write_text(content, encoding="utf-8")
                self.assertEqual(catalogue.load_cache(path), versioned_cache())

    def test_legacy_in_memory_confirmed_negatives_are_supported(self):
        for cache in ({ISIN: []}, {ISIN: [QUOTE], "chart:EXAMPLE.DE": False}):
            with patch.object(catalogue, "fetch") as fetch:
                self.assertIsNone(self.lookup(cache))
            fetch.assert_not_called()

    def test_ambiguous_symbols_are_excluded_without_chart_lookup(self):
        other = dict(QUOTE, symbol="EXAMPLE.L")
        diagnostics = {}
        with patch.object(catalogue, "fetch") as fetch:
            self.assertIsNone(self.lookup({ISIN: [QUOTE, other]}, diagnostics=diagnostics))
        fetch.assert_not_called()
        self.assertEqual(diagnostics["reason"], "ambiguous_quote")

    def test_identical_search_records_do_not_cause_false_ambiguity(self):
        cache = {ISIN: [QUOTE, dict(QUOTE)], "chart:EXAMPLE.DE": True}
        self.assertIsNotNone(self.lookup(cache))

    def test_malformed_official_workbooks_are_rejected(self):
        for workbook in (
            b"not a zip", workbook_fixture("wrong sheet", ["ISIN"], [[ISIN]]),
            workbook_fixture("2026", ["ISIN-kode/-Code", "Registrerede år/Registered"], [[ISIN, "2026"]]),
            workbook_fixture("2026", ["ISIN-kode/-Code", "ISIN-kode/-Code"], [[ISIN, ISIN]]),
            workbook_fixture("2026", [], []),
        ):
            with self.subTest(workbook=workbook[:20]):
                with self.assertRaises(ValueError):
                    catalogue.positive_rows(workbook, "https://example.test/positive.xlsx", "2026-02-01")
        with self.assertRaises(ValueError):
            catalogue.vp_index(workbook_fixture("KURS (002)", ["ISIN"], [[FUND_ISIN]]))

    def test_workbook_tax_classification_conflicts_stay_excluded(self):
        headers = ["ISIN", "Klassifikationinvesteringsinstitut", "Udlodningskode", "Status", "Reguleret_Marked"]
        workbook = workbook_fixture("KURS (002)", headers, [
            [FUND_ISIN, "A", "1", "Aktiv", "1"], [FUND_ISIN, "B", "1", "Aktiv", "1"],
        ])
        self.assertEqual(catalogue.vp_index(workbook), {})

    def test_formatted_blank_workbook_columns_do_not_invalidate_table(self):
        positive, _ = official_workbook_fixtures()
        # A harmless extra formatted blank header occurs in real XLSX exports.
        headers = sorted(catalogue.POSITIVE_COLUMNS) + [""]
        original_rows = catalogue.workbook_rows(positive, "2026")
        workbook = workbook_fixture("2026", headers, [[original_rows[0].get(key, "") for key in headers]])
        self.assertEqual(len(catalogue.positive_rows(workbook, "https://example.test/positive.xlsx", "2026-02-01")), 1)

    def create_refresh_fixture(self, directory):
        root = Path(directory)
        etfs, funds = root / "original-etfs.tsv", root / "original-funds.tsv"
        for path, rows in (
            (etfs, [["Example Global Equity", "EXAMPLE", ISIN, "Akkumulerende"]]),
            (funds, [["Example Danish Equity", "DANISH", FUND_ISIN, "Udbyttebetalende"]]),
        ):
            with path.open("w", encoding="utf-16", newline="") as handle:
                writer = csv.writer(handle, delimiter="\t")
                writer.writerow(["Navn", "Ticker", "ISIN", "Udbyttepolitik"])
                writer.writerows(rows)
        output = root / "published"
        output.mkdir()
        previous = {
            output / "positivliste_2026.csv": b"previous positive snapshot\n",
            output / "investment_products_2026.csv": b"previous investment snapshot\n",
        }
        for path, contents in previous.items():
            path.write_bytes(contents)
        originals = {path: path.read_bytes() for path in (etfs, funds)}
        argv = ["--etfs", str(etfs), "--funds", str(funds), "--output-dir", str(output), "--cache", str(root / "cache" / "yahoo.json"), "--workers", "1"]
        return root, argv, previous, originals

    def fixture_fetch(self, url):
        positive, vp = official_workbook_fixtures()
        if url == catalogue.SKAT_PAGE:
            return b'<a href="https://example.test/positive.xlsx">Liste over aktiebaserede investeringsselskaber</a> offentliggjort den 1. februar 2026'
        if url == "https://example.test/positive.xlsx":
            return positive
        if url == catalogue.VP_WORKBOOK:
            return vp
        if "/search?" in url:
            item = QUOTE if ISIN in url else dict(QUOTE, symbol="DANISH.CO", quoteType="EQUITY", longname="Example Danish Equity", exchange="CPH")
            return json_bytes({"quotes": [item]})
        if "/chart/" in url:
            return json_bytes(CHART)
        raise AssertionError(f"Unexpected fixture URL: {url}")

    def assert_files_unchanged(self, files):
        for path, contents in files.items():
            self.assertEqual(path.read_bytes(), contents, str(path))

    def test_successful_fixture_refresh_preserves_headers_classification_and_originals(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, originals = self.create_refresh_fixture(directory)
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue.time, "time", return_value=NOW):
                self.assertEqual(catalogue.main(argv), 0)
            self.assert_files_unchanged(originals)
            positive = catalogue.validate_csv(root / "published/positivliste_2026.csv", catalogue.POSITIVE_HEADERS)
            products = catalogue.validate_csv(root / "published/investment_products_2026.csv", catalogue.HEADERS)
            self.assertEqual(len(positive), 1)
            self.assertEqual(len(products), 2)
            self.assertEqual({row["isin"]: row["tax_basis"] for row in products}, {ISIN: "ABIS 2026", FUND_ISIN: "VP 2026: 1/A"})
            report = json.loads((root / "cache/exclusion_report.json").read_text())
            self.assertEqual(report["exclusions"], [])
            self.assertEqual(report["matched_products"], 2)
            cache = catalogue.load_cache(root / "cache/yahoo.json")
            self.assertEqual(len(cache["entries"]), 4)
            self.assertTrue(all(entry["fetched_at"] == NOW for entry in cache["entries"].values()))
            self.assertEqual({path.name for path in (root / "published").iterdir()}, {path.name for path in previous})

    def test_yahoo_call_count_uses_exact_hostname(self):
        for url, expected in (
            ("https://query1.finance.yahoo.com/v1/finance/search?q=example", 1),
            ("https://QUERY1.FINANCE.YAHOO.COM:443/v8/finance/chart/example", 1),
            ("https://evil.test/query1.finance.yahoo.com", 0),
            ("https://evil.test/?next=https://query1.finance.yahoo.com/", 0),
            ("https://query1.finance.yahoo.com@evil.test/", 0),
            ("https://query1.finance.yahoo.com.evil.test/", 0),
            ("https://not-query1.finance.yahoo.com/", 0),
            ("https://finance.yahoo.com/quote/example", 0),
            ("query1.finance.yahoo.com", 0),
        ):
            with self.subTest(url=url):
                self.assertEqual(count_yahoo_calls([call(url)]), expected)
        self.assertEqual(count_yahoo_calls([]), 0)

    def test_cli_cache_expiry_and_refresh_flags_control_real_lookup_path(self):
        for flags, age, expected_yahoo_calls in (
            ([], 86400, 0), (["--cache-max-age-days", "1"], 86400, 4),
            (["--refresh-cache"], 0, 4),
        ):
            with self.subTest(flags=flags), TemporaryDirectory() as directory:
                _, argv, _, originals = self.create_refresh_fixture(directory)
                with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue.time, "time", return_value=NOW):
                    self.assertEqual(catalogue.main(argv), 0)
                with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch) as fetch, patch.object(catalogue.time, "time", return_value=NOW + age):
                    self.assertEqual(catalogue.main(argv + flags), 0)
                self.assertEqual(count_yahoo_calls(fetch.call_args_list), expected_yahoo_calls)
                # Essential official workbooks are retrieved even with a warm cache.
                self.assertEqual(sum(call.args[0] in {catalogue.SKAT_PAGE, "https://example.test/positive.xlsx", catalogue.VP_WORKBOOK} for call in fetch.call_args_list), 3)
                self.assert_files_unchanged(originals)

    def test_transient_refresh_failure_preserves_published_pair_and_reports_reason(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, originals = self.create_refresh_fixture(directory)
            def flaky(url):
                if "/chart/EXAMPLE.DE" in url:
                    raise TimeoutError("fixture timeout")
                return self.fixture_fetch(url)
            with patch.object(catalogue, "fetch", side_effect=flaky):
                self.assertEqual(catalogue.main(argv), 1)
            self.assert_files_unchanged(previous)
            self.assert_files_unchanged(originals)
            report = json.loads((root / "cache/exclusion_report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["exclusions"], [{"isin": ISIN, "reason": "transient_chart_error", "detail": "fixture timeout"}])
            self.assertNotIn("chart:EXAMPLE.DE", catalogue.load_cache(root / "cache/yahoo.json")["entries"])

    def test_malformed_official_refresh_preserves_both_snapshots(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, originals = self.create_refresh_fixture(directory)
            def malformed(url):
                return b"malformed workbook" if url == catalogue.VP_WORKBOOK else self.fixture_fetch(url)
            with patch.object(catalogue, "fetch", side_effect=malformed):
                self.assertEqual(catalogue.main(argv), 1)
            self.assert_files_unchanged(previous)
            self.assert_files_unchanged(originals)
            report = json.loads((root / "cache/exclusion_report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("Malformed workbook", report["error"])

    def test_confirmed_no_matches_and_ambiguity_emit_json_exclusions(self):
        for response, reason in (
            ({"quotes": []}, "no_search_matches"),
            ({"quotes": [QUOTE, dict(QUOTE, symbol="EXAMPLE.L")]}, "ambiguous_quote"),
        ):
            with self.subTest(reason=reason), TemporaryDirectory() as directory:
                root, argv, previous, originals = self.create_refresh_fixture(directory)
                def excluded(url):
                    return json_bytes(response) if "/search?" in url and ISIN in url else self.fixture_fetch(url)
                with patch.object(catalogue, "fetch", side_effect=excluded):
                    self.assertEqual(catalogue.main(argv), 0)
                report = json.loads((root / "cache/exclusion_report.json").read_text())
                self.assertEqual(report["exclusions"], [{"isin": ISIN, "reason": reason}])
                products = catalogue.validate_csv(root / "published/investment_products_2026.csv", catalogue.HEADERS)
                self.assertEqual([row["isin"] for row in products], [FUND_ISIN])
                self.assert_files_unchanged(originals)

    def test_empty_match_refresh_does_not_publish_empty_catalogue(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, _ = self.create_refresh_fixture(directory)
            def empty(url):
                return json_bytes({"quotes": []}) if "/search?" in url else self.fixture_fetch(url)
            with patch.object(catalogue, "fetch", side_effect=empty):
                self.assertEqual(catalogue.main(argv), 1)
            self.assert_files_unchanged(previous)
            self.assertFalse(list((root / "published").glob(".catalogue-refresh-*")))

    def test_second_csv_replace_failure_rolls_back_first(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, originals = self.create_refresh_fixture(directory)
            real_replace = os.replace
            def fail_second(source, destination):
                if Path(destination).name == "investment_products_2026.csv":
                    # The first rename really occurred before this failure.
                    self.assertNotEqual((root / "published/positivliste_2026.csv").read_bytes(), next(iter(previous.values())))
                    raise OSError("fixture second rename failure")
                return real_replace(source, destination)
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue.os, "replace", side_effect=fail_second):
                self.assertEqual(catalogue.main(argv), 1)
            self.assert_files_unchanged(previous)
            self.assert_files_unchanged(originals)
            self.assertFalse(list((root / "published").glob(".catalogue-refresh-*")))

    def test_validation_of_second_csv_happens_before_any_replacement(self):
        with TemporaryDirectory() as directory:
            _, argv, previous, _ = self.create_refresh_fixture(directory)
            real_validate = catalogue.validate_csv
            def invalid(path, headers):
                if headers == catalogue.HEADERS:
                    raise ValueError("fixture invalid second CSV")
                return real_validate(path, headers)
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue, "validate_csv", side_effect=invalid), patch.object(catalogue.os, "replace", wraps=os.replace) as replace:
                self.assertEqual(catalogue.main(argv), 1)
            self.assert_files_unchanged(previous)
            self.assertFalse(any(Path(call.args[1]) in previous for call in replace.call_args_list))

    def test_report_write_failure_prevents_csv_publication(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, _ = self.create_refresh_fixture(directory)
            real_write = catalogue.write_json_atomic
            def unwritable_report(path, payload):
                if path.name == "exclusion_report.json":
                    raise OSError("fixture report disk full")
                return real_write(path, payload)
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue, "write_json_atomic", side_effect=unwritable_report):
                self.assertEqual(catalogue.main(argv), 1)
            self.assert_files_unchanged(previous)
            self.assertFalse(list((root / "published").glob(".catalogue-refresh-*")))

    def test_rollback_failure_keeps_recoverable_originals(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, _ = self.create_refresh_fixture(directory)
            real_replace = os.replace
            def fail_publish_and_rollback(source, destination):
                if Path(destination).name == "investment_products_2026.csv" or str(source).endswith(".previous"):
                    raise OSError("fixture filesystem failure")
                return real_replace(source, destination)
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue.os, "replace", side_effect=fail_publish_and_rollback):
                self.assertEqual(catalogue.main(argv), 1)
            staging, = (root / "published").glob(".catalogue-refresh-*")
            for path, contents in previous.items():
                self.assertEqual((staging / f"{path.name}.previous").read_bytes(), contents)
            report = json.loads((root / "cache/exclusion_report.json").read_text())
            self.assertIn(str(staging), report["error"])

    def test_first_publication_failure_removes_new_first_csv(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, _ = self.create_refresh_fixture(directory)
            for path in previous:
                path.unlink()
            real_replace = os.replace
            def fail_second(source, destination):
                if Path(destination).name == "investment_products_2026.csv":
                    raise OSError("fixture first publication failure")
                return real_replace(source, destination)
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue.os, "replace", side_effect=fail_second):
                self.assertEqual(catalogue.main(argv), 1)
            self.assertEqual(list((root / "published").iterdir()), [])

    def test_provider_branding_and_duplicate_tickers_fail_validation_before_publish(self):
        for failure in ("branding", "duplicate"):
            with self.subTest(failure=failure), TemporaryDirectory() as directory:
                _, argv, previous, _ = self.create_refresh_fixture(directory)
                original_build = catalogue.build_catalogue
                def invalid_output(args, report):
                    positive, products = original_build(args, report)
                    if failure == "branding":
                        products[0]["name"] = "Nordnet synthetic original export"
                    else:
                        products[1]["yahoo_ticker"] = products[0]["yahoo_ticker"]
                    return positive, products
                with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch), patch.object(catalogue, "build_catalogue", side_effect=invalid_output):
                    self.assertEqual(catalogue.main(argv), 1)
                self.assert_files_unchanged(previous)

    def test_invalid_isin_and_missing_tax_evidence_are_reported(self):
        with TemporaryDirectory() as directory:
            root, argv, _, _ = self.create_refresh_fixture(directory)
            with (root / "original-funds.tsv").open("a", encoding="utf-16", newline="") as handle:
                writer = csv.writer(handle, delimiter="\t")
                writer.writerow(["Synthetic unknown product", "UNKNOWN", "IE00B4L5Y983", "Akkumulerende"])
                writer.writerow(["Synthetic invalid product", "INVALID", "INVALID", "Akkumulerende"])
            with patch.object(catalogue, "fetch", side_effect=self.fixture_fetch):
                self.assertEqual(catalogue.main(argv), 0)
            report = json.loads((root / "cache/exclusion_report.json").read_text())
            self.assertEqual(report["exclusions"], [
                {"isin": "INVALID", "type": "Investeringsforeninger", "reason": "invalid_isin"},
                {"isin": "IE00B4L5Y983", "reason": "unsupported_or_conflicting_tax_evidence"},
            ])

    def test_output_path_cannot_overwrite_original_input(self):
        with TemporaryDirectory() as directory:
            root, argv, previous, originals = self.create_refresh_fixture(directory)
            with self.assertRaises(SystemExit), patch.object(catalogue, "fetch") as fetch:
                catalogue.main(argv + ["--exclusion-report", str(root / "original-etfs.tsv")])
            fetch.assert_not_called()
            self.assert_files_unchanged(previous)
            self.assert_files_unchanged(originals)


if __name__ == "__main__":
    unittest.main()
