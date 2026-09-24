"""Offline checks for the dated Danish investment catalogue refresh."""

import unittest
import csv
from pathlib import Path

from scripts.build_investment_catalogue import classify, locate_positive_workbook, valid_isin, yahoo_quote


class InvestmentCatalogueTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
