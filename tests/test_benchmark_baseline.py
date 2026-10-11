import unittest
from scripts.prepare_benchmark_baseline import adapt_source


class BaselineAdapterTests(unittest.TestCase):
    def test_only_adapts_retrieval_and_runtime(self):
        old = 'getSymbols(ticker, env = NULL)\nfredr::fredr("DFF")\nSys.Date()\nfit <- randomForest(x, ntree = 300)\n'
        new = adapt_source(old)
        self.assertIn('book_yahoo(ticker, env = NULL)', new)
        self.assertIn('book_fred("DFF")', new)
        self.assertIn('book_date()', new)
        self.assertIn('fit <- randomForest(x, ntree = 300)', new)

    def test_namespaced_metadata_and_dst_are_replayable(self):
        new = adapt_source('fredr::fredr_series(id)\ndkstat::dst_get_data(table="X")\ndst_meta(table="X")\n')
        self.assertIn('book_fred_metadata("fredr_series", id)', new)
        self.assertIn('book_dst(table="X")', new)
        self.assertIn('book_dst_metadata(table="X")', new)

    def test_unused_animation_loader_is_removed_not_analysis(self):
        new = adapt_source('pacman::p_load(fredr,\n  gganimate,\n  dplyr)\nfit <- randomForest(x, ntree = 300)\n')
        self.assertNotIn('gganimate,', new)
        self.assertIn('book_load_packages(fredr,\n  dplyr)', new)
        self.assertIn('fit <- randomForest(x, ntree = 300)', new)


if __name__ == "__main__":
    unittest.main()
