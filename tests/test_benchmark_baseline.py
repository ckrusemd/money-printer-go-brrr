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

    def test_ecb_requests_preserve_arguments_and_existing_retry_loop(self):
        old = ('for (attempt in seq_len(attempts)) {\n'
               '  ecb::get_data(key = key, filter = list(startPeriod="2020"), httr::timeout(12))\n'
               '}\nfit <- caret::train(x, ntree = 300)\n')
        new = adapt_source(old)
        self.assertIn('for (attempt in seq_len(attempts)) {', new)
        self.assertIn('book_ecb_data(attempts = 1L, key = key, filter = list(startPeriod="2020"), httr::timeout(12))', new)
        self.assertNotIn('ecb::get_data(', new)
        self.assertIn('fit <- caret::train(x, ntree = 300)', new)
        self.assertEqual(adapt_source(new), new)

    def test_approved_finans_iso_input_correction_leaves_statistics_original(self):
        old_date = 'as.Date(paste(df_interest$År, df_interest$Uge, 1, sep="-"), "%Y-%U-%u")'
        surrounding = ('df_interest$År[1] = 1997\n'
                       'df_interest = df_interest %>% fill(År,.direction = "down")\n')
        statistics = ('df_all = bind_rows(df_fred, df_yahoo, df_dst, df_interest, df_etfs)\n'
                      'result = ccf(value.x, value.y, lag.max=365, plot=FALSE)\n'
                      'fit <- caret::train(x, ntree = 300)\n')
        old = surrounding + 'df_interest$Date = ' + old_date + '\n' + statistics
        new = adapt_source(old)
        expected = surrounding + ('df_interest$Date = '
                   'book_iso_week_monday(df_interest$År, df_interest$Uge)\n') + statistics
        self.assertEqual(new, expected)
        self.assertEqual(adapt_source(new), new)
        # Do not replace unrelated Sunday-week parsers or another data source.
        unrelated = old_date.replace('df_interest', 'other_source')
        self.assertEqual(adapt_source(unrelated), unrelated)


if __name__ == "__main__":
    unittest.main()
