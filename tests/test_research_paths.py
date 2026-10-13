"""Offline portability tests; only disposable fixtures are opened or written.

python -m unittest discover -s tests -p test_research_paths.py -v
R fixtures use Rscript when available. DuckDB/pandas schema fixtures skip if absent.
"""

import contextlib
import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts import research_paths as paths


ROOT = Path(__file__).resolve().parents[1]
GRAPH_NOTEBOOK = ROOT / 'knowledgegraph/app/create_database.ipynb'


@contextlib.contextmanager
def working_directory(directory):
    previous = Path.cwd()
    try:
        os.chdir(directory)
        yield
    finally:
        os.chdir(previous)


def csv_inputs(directory):
    directory.mkdir(parents=True, exist_ok=True)
    fixtures = {
        'knowledge_graph_nodes.csv': (
            'id,label,title,color,size,node_type,degree,avg_strength,total_strength',
            [('A', 'A', 'Alpha', '#123456', 10, 'Economy', 1, 0.8, 0.8),
             ('B', 'B', 'Beta', '#234567', 10, 'Market', 1, 0.8, 0.8)]),
        'knowledge_graph_edges.csv': (
            'from,to,weight,width,color,title,arrows',
            [('A', 'B', 0.8, 1, '#888888', 'A-B', '')]),
        'correlations_detailed.csv': (
            'x1,x2,best_lag,best_corr,zero_lag_corr,n_obs,correlation_type,lag_type,strength',
            [('A', 'B', 2, 0.8, 0.6, 20, 'positive', 'leading', 0.8)]),
        'leadership_analysis.csv': (
            'x1,total_connections,avg_lag,median_lag,leading_connections,'
            'coincident_connections,lagging_connections,avg_correlation_strength,'
            'leadership_score,indicator_role,indicator_category',
            [('A', 1, 2, 2, 1, 0, 0, 0.8, 1, 'Leader', 'Economy')]),
        'stock_economic_relationships.csv': (
            'x1,x2,best_lag,best_corr,zero_lag_corr,n_obs,correlation_type,lag_type,'
            'strength,stock_symbol,economic_indicator,stock_leads,stock_type,econ_category',
            [('A', 'B', 2, 0.8, 0.6, 20, 'positive', 'leading', 0.8,
              'A', 'B', True, 'Index', 'Economy')]),
    }
    for filename, (columns, rows) in fixtures.items():
        with (directory / filename).open('w', newline='') as handle:
            writer = csv.writer(handle)
            writer.writerow(columns.split(','))
            writer.writerows(rows)


class ResearchPathTests(unittest.TestCase):
    def test_defaults_and_relative_overrides_are_independent_of_cwd(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True):
            with working_directory(directory):
                self.assertEqual(paths.repo_root(), ROOT)
                self.assertEqual(paths.knowledge_graph_paths(), (
                    ROOT / 'knowledgegraph', ROOT / 'knowledgegraph/app/knowledge_graph.db'))
                with mock.patch.dict(os.environ, {
                    'KNOWLEDGE_GRAPH_CSV_DIR': 'fixtures/csv',
                    'KNOWLEDGE_GRAPH_DB_PATH': 'alternate.db',
                }):
                    self.assertEqual(paths.knowledge_graph_paths(), (
                        ROOT / 'fixtures/csv', ROOT / 'knowledgegraph/app/alternate.db'))
                    from knowledgegraph.app.dashboard_config import resolve_db_path
                    self.assertEqual(paths.knowledge_graph_paths()[1], resolve_db_path())

    def test_explicit_checkout_and_absolute_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.dict(os.environ, {
                'RESEARCH_REPO_ROOT': directory,
                'KNOWLEDGE_GRAPH_CSV_DIR': str(root / 'inputs'),
                'KNOWLEDGE_GRAPH_DB_PATH': str(root / 'new.db'),
            }):
                self.assertEqual(paths.repo_root(), root)
                self.assertEqual(paths.knowledge_graph_paths(), (root / 'inputs', root / 'new.db'))
            with mock.patch.dict(os.environ, {'RESEARCH_REPO_ROOT': 'relative-checkout'}):
                with self.assertRaisesRegex(ValueError, 'absolute checkout'):
                    paths.repo_root()

    def test_missing_inputs_fail_before_opening_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            connector = mock.Mock()
            with self.assertRaisesRegex(FileNotFoundError, 'KNOWLEDGE_GRAPH_CSV_DIR'):
                paths.connect_new_database(root / 'missing', root / 'new.db', connector)
            connector.assert_not_called()
            self.assertFalse((root / 'new.db').exists())

    def test_existing_database_sidecars_and_backups_are_preserved(self):
        for suffix in ('', '.wal', '.lock', '.tmp', '.unlock_backup', '.bak'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                csv_inputs(root / 'csv')
                database = root / 'graph.db'
                existing = root / ('graph.db' + suffix)
                existing.write_bytes(b'valuable fixture content')
                connector = mock.Mock()
                with self.assertRaisesRegex(FileExistsError, 'KNOWLEDGE_GRAPH_DB_PATH'):
                    paths.connect_new_database(root / 'csv', database, connector)
                connector.assert_not_called()
                self.assertEqual(existing.read_bytes(), b'valuable fixture content')
                if suffix:
                    self.assertFalse(database.exists())

    def test_connection_failure_is_not_retried_and_keeps_new_sidecars(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            csv_inputs(root / 'csv')
            database = root / 'graph.db'

            def locked(path):
                Path(path).write_bytes(b'database created by connector')
                Path(path + '.wal').write_bytes(b'pending transaction')
                Path(path + '.unlock_backup').write_bytes(b'backup')
                raise OSError('database is locked')

            connector = mock.Mock(side_effect=locked)
            with self.assertRaisesRegex(RuntimeError, 'Close other database users'):
                paths.connect_new_database(root / 'csv', database, connector)
            connector.assert_called_once_with(str(database))
            self.assertEqual(database.read_bytes(), b'database created by connector')
            self.assertEqual(Path(str(database) + '.wal').read_bytes(), b'pending transaction')
            self.assertEqual(Path(str(database) + '.unlock_backup').read_bytes(), b'backup')

    def test_notebooks_have_no_destructive_unlocking_or_personal_startup_paths(self):
        for path in (ROOT / 'datacollection/01_etl.ipynb', ROOT / 'datacollection/02_models.ipynb', GRAPH_NOTEBOOK):
            notebook = json.loads(path.read_text())
            code = '\n'.join(''.join(cell['source']) for cell in notebook['cells'] if cell['cell_type'] == 'code')
            with self.subTest(path=path.name):
                self.assertNotIn('setwd(', code)
                self.assertNotIn('source("~/', code)
                self.assertNotIn('file.remove(', code)
                self.assertNotIn('.unlink(', code)
                self.assertNotIn('overwrite = TRUE', code)
                self.assertNotIn('DB_COPY_PATH', code)
                self.assertNotIn('2025_10_11_13_36_15', code)
        # Temporary HTTP-download cleanup is retained; database cleanup is removed.


@unittest.skipUnless(all(importlib.util.find_spec(name) for name in ('duckdb', 'pandas', 'numpy')),
                     'DuckDB/pandas/numpy unavailable for notebook schema fixture')
class GraphNotebookFixtureTests(unittest.TestCase):
    def test_notebook_builds_same_schema_from_tiny_csvs_from_unrelated_cwd(self):
        import duckdb

        notebook = json.loads(GRAPH_NOTEBOOK.read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            csv_inputs(root / 'csv')
            database = root / 'fixture.db'
            namespace = {}
            with mock.patch.dict(os.environ, {
                'RESEARCH_REPO_ROOT': str(ROOT),
                'KNOWLEDGE_GRAPH_CSV_DIR': str(root / 'csv'),
                'KNOWLEDGE_GRAPH_DB_PATH': str(database),
            }), working_directory(root), contextlib.redirect_stdout(io.StringIO()):
                try:
                    for cell in notebook['cells'][1:11]:
                        exec(compile(''.join(cell['source']), str(GRAPH_NOTEBOOK), 'exec'), namespace)
                finally:
                    if 'conn' in namespace:
                        namespace['conn'].close()
            with duckdb.connect(str(database), read_only=True) as connection:
                for table, count in (('nodes', 2), ('edges', 1), ('correlations', 1),
                                     ('leadership', 1), ('stock_relationships', 1), ('metadata', 4)):
                    self.assertEqual(connection.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0], count)
                self.assertEqual(connection.execute(
                    'SELECT from_node, to_node, weight FROM edges').fetchone(), ('A', 'B', 0.8))
                self.assertEqual([row[1] for row in connection.execute("PRAGMA table_info('nodes')").fetchall()],
                                 ['id', 'label', 'title', 'color', 'size', 'node_type', 'degree', 'avg_strength', 'total_strength'])
                self.assertEqual(connection.execute('SELECT COUNT(*) FROM strong_correlations_with_nodes').fetchone()[0], 1)
                self.assertEqual(connection.execute('SELECT COUNT(*) FROM node_type_stats').fetchone()[0], 2)
                self.assertEqual(connection.execute('SELECT COUNT(*) FROM top_correlations_by_type').fetchone()[0], 0)
            before = database.read_bytes()
            with self.assertRaises(FileExistsError):
                paths.connect_new_database(root / 'csv', database, duckdb.connect)
            self.assertEqual(database.read_bytes(), before)


# This same script can run in the publication image with a read-only repository
# mount and RESEARCH_TEST_ROOT=/project. All writes stay in R's temporary directory.
R_FIXTURE_SCRIPT = r'''
root <- normalizePath(Sys.getenv("RESEARCH_TEST_ROOT"), mustWork = TRUE)
configuration <- c("RESEARCH_REPO_ROOT", "RESEARCH_DB_PATH", "RESEARCH_DATA_DIR",
                   "RESEARCH_OUTPUT_DIR", "RESEARCH_ENV_FILE", "RESEARCH_REPORT_HELPER",
                   "RESEARCH_REPORT_TEMPLATE", "RESEARCH_CORPORATE_DB_HELPER", "RESEARCH_LOGGER_HELPER")
Sys.unsetenv(configuration)
sandbox <- tempfile("research-fixture-")
dir.create(sandbox)
setwd(sandbox)
source(file.path(root, "scripts/research_paths.R"))
stopifnot(identical(research_repo_root(), root), identical(getwd(), sandbox))
stopifnot(identical(research_path("datacollection"), file.path(root, "datacollection")))
Sys.setenv(RESEARCH_DB_PATH = "fixtures/data.duckdb")
stopifnot(identical(research_path("unused", "RESEARCH_DB_PATH"), file.path(root, "fixtures/data.duckdb")))
Sys.setenv(RESEARCH_DB_PATH = file.path(sandbox, "financial_data.duckdb"))
stopifnot(identical(research_path("unused", "RESEARCH_DB_PATH"), Sys.getenv("RESEARCH_DB_PATH")))
stopifnot(identical(research_load_env(), FALSE))
cat("R paths and optional credentials: passed\n")

expect_error <- function(expression, pattern) {
  error <- tryCatch({ force(expression); NULL }, error = function(error) error)
  if (!inherits(error, "error")) stop("Expected error missing: ", pattern)
  if (!grepl(pattern, conditionMessage(error))) stop("Unexpected error: ", conditionMessage(error))
}
for (kind in c("report", "corporate_db", "logger")) {
  expect_error(research_call_integration(kind, "fixture_function"), "Set RESEARCH_")
}
integration_path <- file.path(sandbox, "integration.R")
writeLines("fixture_function <- function(value) value + 1", integration_path)
Sys.setenv(RESEARCH_LOGGER_HELPER = integration_path)
stopifnot(identical(research_call_integration("logger", "fixture_function", 2), 3))
expect_error(research_call_integration("logger", "missing_function"), "must define function")
Sys.setenv(RESEARCH_REPORT_HELPER = integration_path)
expect_error(research_call_integration("report", "fixture_function", value = 2,
             template_path = file.path(sandbox, "missing-template.pptx")), "RESEARCH_REPORT_TEMPLATE")
Sys.setenv(RESEARCH_REPORT_HELPER = file.path(sandbox, "missing-report.R"))
expect_error(research_call_integration("report", "generate_report"), "does not exist")
cat("R lazy optional integrations: passed\n")

database <- Sys.getenv("RESEARCH_DB_PATH")
files <- paste0(database, c("", ".wal", ".lock", ".unlock_backup", ".bak"))
copy <- file.path(sandbox, "financial_data_readonly.duckdb")
files <- c(files, copy, paste0(copy, ".wal"))
for (file in files) writeLines(paste("valuable", basename(file)), file)
before <- tools::md5sum(files)
calls <- 0L
read_flags <- logical()
locked <- function(path, read_only) {
  calls <<- calls + 1L
  read_flags <<- c(read_flags, read_only)
  stop("database is locked by another process")
}
expect_error(research_connect_database(database, connector = locked), "Close other database users")
stopifnot(calls == 1L, identical(before, tools::md5sum(files)))
missing <- file.path(sandbox, "missing.duckdb")
expect_error(research_connect_database(missing, read_only = TRUE, connector = locked), "Run 01_etl")
stopifnot(calls == 1L, !file.exists(missing))
cat("R connection failures preserve databases, WAL, locks and backups: passed\n")

# Source standalone save helpers from an unrelated cwd, in an isolated environment.
helpers <- new.env(parent = baseenv())
source(file.path(root, "datacollection/save_plot.R"), local = helpers)
source(file.path(root, "datacollection/save_table.R"), local = helpers)
Sys.setenv(RESEARCH_OUTPUT_DIR = sandbox)
original <- data.frame(group = c("A", "A", "B"), value = 1:3)
first <- helpers$save_table(original)
second <- helpers$save_table(original, duplicate_columns = "group")
stopifnot(basename(first) == "table001.rds", basename(second) == "table002.rds",
          identical(readRDS(first), original),
          identical(readRDS(second)$group, c("A", "", "B")),
          startsWith(first, sandbox), identical(getwd(), sandbox))
if (requireNamespace("ggplot2", quietly = TRUE)) {
  plot <- ggplot2::ggplot(original, ggplot2::aes(x = value, y = value)) + ggplot2::geom_point()
  first_plot <- helpers$save_plot(plot, width_ratio = 1, height_ratio = 1, base_size = 40)
  second_plot <- helpers$save_plot(plot, width_ratio = 1, height_ratio = 1, base_size = 40)
  stopifnot(file.exists(first_plot), file.info(first_plot)$size > 0,
            basename(first_plot) == "plot001.png", basename(second_plot) == "plot002.png",
            startsWith(first_plot, sandbox))
  helpers$save_plot_png(plot, width_ratio = 1, height_ratio = 1, base_size = 40)
  stopifnot(file.exists(file.path(sandbox, "plot.png")))
  cat("R plot fixture and numbering: passed\n")
} else cat("R plot fixture: skipped (ggplot2 unavailable)\n")
cat("R table fixture, values and numbering: passed\n")

if (requireNamespace("jsonlite", quietly = TRUE)) {
  # Execute just the notebook bootstrap/setup and force a lock in the DB cell.
  # No analysis or real database connection runs.
  for (name in c("01_etl.ipynb", "02_models.ipynb")) {
    notebook <- jsonlite::fromJSON(file.path(root, "datacollection", name), simplifyVector = FALSE)
    kernel <- new.env(parent = .GlobalEnv)
    Sys.setenv(RESEARCH_REPO_ROOT = root)
    # An invalid optional integration must not fail during startup.
    for (index in c(3L, 5L)) {
      eval(parse(text = paste(unlist(notebook$cells[[index]]$source), collapse = "")), kernel)
    }
    stopifnot(identical(getwd(), sandbox))
    real_connect <- kernel$research_connect_database
    kernel$research_connect_database <- function(path, read_only = FALSE) {
      real_connect(path, read_only, connector = locked)
    }
    expect_error(eval(parse(text = paste(unlist(notebook$cells[[8L]]$source), collapse = "")), kernel),
                 "Close other database users")
    stopifnot(identical(before, tools::md5sum(files)))
    cat("R notebook startup and lock fixture:", name, "passed\n")
    # Parse every R cell without running the analyses.
    for (cell in notebook$cells) {
      if (identical(cell$cell_type, "code")) parse(text = paste(unlist(cell$source), collapse = ""))
    }
  }
  stopifnot(identical(tail(read_flags, 2L), c(FALSE, TRUE)))
} else cat("R notebook fixtures: skipped (jsonlite unavailable)\n")
cat("R portability fixtures passed\n")
'''


@unittest.skipUnless(shutil.which('Rscript'), 'Rscript unavailable')
class RResearchFixtureTests(unittest.TestCase):
    def test_r_paths_save_helpers_optional_integrations_and_non_destructive_startup(self):
        environment = dict(os.environ, RESEARCH_TEST_ROOT=str(ROOT))
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['Rscript', '--vanilla', '-'], input=R_FIXTURE_SCRIPT,
                                    cwd=directory, env=environment, text=True,
                                    capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('R portability fixtures passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
