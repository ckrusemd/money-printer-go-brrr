"""Dashboard regression tests; all database access uses disposable fixtures.

Run with: python -m unittest discover -s tests -p test_dashboard.py -v
Rendering tests skip when the dashboard's optional dependencies are absent.
"""

import contextlib
import importlib
import importlib.util
import io
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from knowledgegraph.app import dashboard_config as config
from knowledgegraph.app import run_app


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = ('dash', 'plotly', 'pandas', 'numpy', 'duckdb', 'networkx', 'scipy')
MISSING = [name for name in DEPENDENCIES if importlib.util.find_spec(name) is None]


class DashboardConfigurationTests(unittest.TestCase):
    def test_paths_are_module_relative_from_another_directory(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            with mock.patch.dict(os.environ, {'KNOWLEDGE_GRAPH_DB_PATH': 'fixture.db'}):
                self.assertEqual(config.resolve_db_path(), config.APP_DIR / 'fixture.db')
            self.assertEqual(config.resolve_db_path('nested/test.db'), config.APP_DIR / 'nested/test.db')
            absolute = Path(directory) / 'explicit.db'
            self.assertEqual(config.resolve_db_path(absolute), absolute)

    def test_defaults_and_environment_overrides(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            settings = runpy.run_path(str(config.APP_DIR / 'dashboard_config.py'))
        self.assertEqual(settings['DB_PATH'], config.APP_DIR / 'knowledge_graph.db')
        self.assertEqual(settings['PORT'], 8051)
        self.assertFalse(settings['DEBUG'])
        with mock.patch.dict(os.environ, {
            'KNOWLEDGE_GRAPH_DB_PATH': 'alternate.db',
            'KNOWLEDGE_GRAPH_PORT': '8099',
            'KNOWLEDGE_GRAPH_DEBUG': 'true',
        }):
            settings = runpy.run_path(str(config.APP_DIR / 'dashboard_config.py'))
        self.assertEqual(settings['DB_PATH'], config.APP_DIR / 'alternate.db')
        self.assertEqual(settings['PORT'], 8099)
        self.assertTrue(settings['DEBUG'])

    def test_launcher_checks_explicit_path_and_does_not_create_missing_file(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            path = Path(directory) / 'missing.db'
            self.assertFalse(run_app.check_database(path))
            self.assertFalse(path.exists())
            self.assertFalse(run_app.check_database(directory))


def create_fixture(path):
    """Tiny database with the notebook's table/view schema and no external data."""
    import duckdb

    with duckdb.connect(str(path)) as connection:
        connection.execute("""
            CREATE TABLE nodes (
                id VARCHAR PRIMARY KEY, label VARCHAR, title VARCHAR, color VARCHAR,
                size DOUBLE, node_type VARCHAR, degree INTEGER,
                avg_strength DOUBLE, total_strength DOUBLE
            );
            INSERT INTO nodes VALUES
                ('A', 'A', 'Alpha', '#123456', 10, 'Economy', 2, 0.4, 0.8),
                ('B', 'B', 'Beta', '#234567', 10, 'Economy', 60, 0.6, 1.2),
                ('C', 'C', 'Gamma', '#345678', 10, 'Market', NULL, 0.8, 1.6),
                ('D', 'D', 'Delta', '#456789', 10, 'Market', 1, 0.4, 0.4);
            CREATE TABLE edges (
                from_node VARCHAR, to_node VARCHAR, weight DOUBLE, width DOUBLE,
                color VARCHAR, title VARCHAR, arrows VARCHAR
            );
            INSERT INTO edges VALUES
                ('A', 'B', 0.6, 1, '#888888', 'A-B', ''),
                ('A', 'C', 0.8, 1, '#888888', 'A-C', ''),
                ('D', 'A', 0.4, 1, '#888888', 'D-A', ''),
                ('A', 'absent', 0.9, 1, '#888888', 'Dangling', '');
            CREATE TABLE correlations (
                x1 VARCHAR, x2 VARCHAR, best_lag INTEGER, best_corr DOUBLE,
                zero_lag_corr DOUBLE, n_obs INTEGER, correlation_type VARCHAR,
                lag_type VARCHAR, strength DOUBLE
            );
            INSERT INTO correlations VALUES
                ('A', 'B', 0, 0.0, 0.0, 100, 'positive', 'coincident', 0.0),
                ('B', 'A', 2, 0.6, 0.6, 100, 'positive', 'leading', 0.6),
                ('A', 'C', 0, 0.8, 0.8, 100, 'positive', 'coincident', 0.8),
                ('C', 'A', 0, 0.8, 0.8, 100, 'positive', 'coincident', 0.8),
                ('D', 'A', -2, -0.4, -0.4, 100, 'negative', 'lagging', 0.4);
            CREATE TABLE leadership (
                x1 VARCHAR PRIMARY KEY, total_connections INTEGER, avg_lag DOUBLE,
                median_lag DOUBLE, leading_connections INTEGER,
                coincident_connections INTEGER, lagging_connections INTEGER,
                avg_correlation_strength DOUBLE, leadership_score DOUBLE,
                indicator_role VARCHAR, indicator_category VARCHAR
            );
            INSERT INTO leadership VALUES
                ('A', 3, 1, 1, 2, 1, 0, 0.6, 2, 'Leader', 'Economy'),
                ('B', 1, -1, -1, 0, 0, 1, 0.6, -1, 'Follower', 'Economy');
            CREATE TABLE stock_relationships (
                x1 VARCHAR, x2 VARCHAR, best_lag INTEGER, best_corr DOUBLE,
                zero_lag_corr DOUBLE, n_obs INTEGER, correlation_type VARCHAR,
                lag_type VARCHAR, strength DOUBLE, stock_symbol VARCHAR,
                economic_indicator VARCHAR, stock_leads BOOLEAN,
                stock_type VARCHAR, econ_category VARCHAR
            );
            INSERT INTO stock_relationships VALUES
                ('C', 'A', 2, 0.8, 0.6, 100, 'positive', 'leading',
                 0.8, 'C', 'A', true, 'Index', 'Economy');
            CREATE VIEW strong_correlations_with_nodes AS
                SELECT c.*, n1.node_type AS x1_type, n1.degree AS x1_degree,
                       n2.node_type AS x2_type, n2.degree AS x2_degree
                FROM correlations c LEFT JOIN nodes n1 ON c.x1 = n1.id
                LEFT JOIN nodes n2 ON c.x2 = n2.id WHERE ABS(c.best_corr) >= 0.7;
            CREATE VIEW node_type_stats AS
                SELECT node_type, COUNT(*) AS node_count, AVG(degree) AS avg_degree,
                       MAX(degree) AS max_degree,
                       AVG(avg_strength) AS avg_correlation_strength
                FROM nodes WHERE node_type IS NOT NULL GROUP BY node_type
                ORDER BY avg_degree DESC;
            CREATE VIEW top_correlations_by_type AS
                SELECT x1_type, x2_type, COUNT(*) AS relationship_count,
                       AVG(ABS(best_corr)) AS avg_correlation, AVG(best_lag) AS avg_lag
                FROM strong_correlations_with_nodes
                WHERE x1_type IS NOT NULL AND x2_type IS NOT NULL
                GROUP BY x1_type, x2_type HAVING COUNT(*) >= 5
                ORDER BY avg_correlation DESC;
        """)


@unittest.skipIf(MISSING, 'Missing dashboard dependencies: ' + ', '.join(MISSING))
class DashboardFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import dash

        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.path = Path(cls.temporary.name) / 'fixture.db'
        create_fixture(cls.path)
        with mock.patch.dict(os.environ, {'KNOWLEDGE_GRAPH_DB_PATH': str(cls.path)}):
            importlib.reload(config)
            with mock.patch.object(dash, 'Dash', wraps=dash.Dash) as constructor:
                with contextlib.redirect_stdout(io.StringIO()):
                    cls.dashboard = importlib.import_module('knowledgegraph.app.dashboard')
                cls.dash_initializations = constructor.call_count
        importlib.reload(config)

    def setUp(self):
        self.dashboard._cached_network_layout.cache_clear()

    def test_single_dash_initialization_and_read_only_loading(self):
        import duckdb

        self.assertEqual(self.dash_initializations, 1)
        self.assertEqual(self.dashboard.DB_PATH, self.path)
        self.assertEqual(len(self.dashboard.DATA['nodes']), 4)
        self.assertEqual(len(self.dashboard.DATA['correlations']), 5)
        with self.dashboard.get_db_connection(self.path) as connection:
            with self.assertRaises(duckdb.Error):
                connection.execute("CREATE TABLE must_not_write (id INTEGER)")
        with duckdb.connect(str(self.path), read_only=True) as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM nodes').fetchone()[0], 4)
            self.assertEqual(connection.execute(
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='must_not_write'"
            ).fetchone()[0], 0)

    def test_missing_database_is_not_created_and_missing_data_callbacks_render(self):
        missing = Path(self.temporary.name) / 'missing.db'
        with self.assertRaises(FileNotFoundError):
            self.dashboard.load_data(missing)
        self.assertFalse(missing.exists())
        with mock.patch.object(self.dashboard, 'DATA', {}):
            self.assertIn('Data Not Available', str(self.dashboard.render_tab_content('overview')))
            self.assertEqual(len(self.dashboard.update_network_graph('spring', 'degree', 'all').data), 0)
            figure, records = self.dashboard.update_correlation_analysis('best_lag', 'best_corr', 0.7)
            self.assertEqual(len(figure.data), 0)
            self.assertEqual(records, [])
            self.assertIn('Data Not Available', str(self.dashboard.render_table_content('nodes-table')))

    def test_missing_required_table_closes_connection(self):
        import duckdb

        incomplete = Path(self.temporary.name) / 'incomplete.db'
        with duckdb.connect(str(incomplete)) as connection:
            connection.execute('CREATE TABLE nodes (id VARCHAR)')
        connection = self.dashboard.get_db_connection(incomplete)
        with mock.patch.object(self.dashboard, 'get_db_connection', return_value=connection):
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(duckdb.Error):
                self.dashboard.load_data(incomplete)
        with self.assertRaises(duckdb.Error):
            connection.execute('SELECT 1')

    def test_missing_optional_stock_table_keeps_other_tabs_available(self):
        import duckdb

        path = Path(self.temporary.name) / 'no-stocks.db'
        create_fixture(path)
        with duckdb.connect(str(path)) as connection:
            connection.execute('DROP TABLE stock_relationships')
        with contextlib.redirect_stdout(io.StringIO()):
            data = self.dashboard.load_data(path)
        self.assertEqual(len(data['nodes']), 4)
        self.assertTrue(data['stock_relationships'].empty)
        with mock.patch.object(self.dashboard, 'DATA', data):
            self.assertIn('No stock relationship data', str(self.dashboard.create_stocks_tab()))
            self.assertIsNotNone(self.dashboard.create_overview_tab())

    def test_all_tabs_and_tables_render_and_serialize(self):
        from plotly.utils import PlotlyJSONEncoder
        import json

        for tab in ('overview', 'network', 'correlations', 'leadership', 'stocks', 'tables'):
            with self.subTest(tab=tab):
                content = self.dashboard.render_tab_content(tab)
                self.assertTrue(json.dumps(content, cls=PlotlyJSONEncoder))
        for table, key in (('nodes', 'nodes'), ('edges', 'edges'),
                           ('correlations', 'correlations'), ('stats', 'node_type_stats')):
            content = self.dashboard.render_table_content(table + '-table')
            self.assertEqual(len(content.data), len(self.dashboard.DATA[key]))
            self.assertEqual(content.export_format, 'csv')
        figure, records = self.dashboard.update_correlation_analysis('best_lag', 'best_corr', 0.7)
        self.assertEqual(len(records), 2)
        self.assertTrue(all(abs(row['best_corr']) >= 0.7 for row in records))
        self.assertEqual(sum(len(trace.x) for trace in figure.data), 2)

    def test_heatmap_preserves_observed_zero_and_missing_pairs(self):
        import numpy as np

        trace = self.dashboard.create_correlation_heatmap(self.dashboard.DATA['correlations']).data[0]
        self.assertEqual(list(trace.x), list(trace.y))
        self.assertEqual(set(trace.x), {'A', 'B', 'C', 'D'})
        matrix = np.asarray(trace.z)
        indices = {node: index for index, node in enumerate(trace.x)}
        self.assertEqual(matrix[indices['A'], indices['B']], 0.0)
        self.assertEqual(matrix[indices['B'], indices['A']], 0.6)
        self.assertTrue(np.isnan(matrix[indices['B'], indices['C']]))
        self.assertEqual(matrix[indices['A'], indices['D']], -0.4)
        np.testing.assert_array_equal(np.diag(matrix), np.ones(4))
        # A single directed zero must also survive diagonal filling.
        zero = self.dashboard.DATA['correlations'].iloc[:1]
        trace = self.dashboard.create_correlation_heatmap(zero).data[0]
        indices = {node: index for index, node in enumerate(trace.x)}
        self.assertEqual(trace.z[indices['A']][indices['B']], 0.0)
        self.assertEqual(trace.z[indices['B']][indices['A']], 0.0)

    def test_empty_render_helpers(self):
        data = self.dashboard.DATA
        heatmap = self.dashboard.create_correlation_heatmap(data['correlations'].iloc[:0])
        self.assertEqual(len(heatmap.data[0].x), 0)
        network = self.dashboard.create_network_graph(data['nodes'].iloc[:0], data['edges'])
        self.assertEqual(len(network.data[1].text), 0)
        figure, rows = self.dashboard.update_correlation_analysis('best_lag', 'best_corr', 1.0)
        self.assertEqual(rows, [])
        self.assertEqual(len(figure.data), 0)
        empty_data = {key: frame.iloc[:0] for key, frame in data.items()}
        with mock.patch.object(self.dashboard, 'DATA', empty_data):
            for tab in ('overview', 'network', 'correlations', 'leadership', 'stocks', 'tables'):
                with self.subTest(tab=tab):
                    self.assertIsNotNone(self.dashboard.render_tab_content(tab))

    @staticmethod
    def positions(figure):
        trace = figure.data[1]
        return dict(zip(trace.text, zip(trace.x, trace.y)))

    def test_network_preserves_metadata_filters_and_excludes_dangling_edges(self):
        figure = self.dashboard.create_network_graph(self.dashboard.DATA['nodes'], self.dashboard.DATA['edges'])
        self.assertEqual(list(figure.data[1].hovertext), ['Alpha', 'Beta', 'Gamma', 'Delta'])
        self.assertEqual(list(figure.data[1].marker.size), [5, 50, 10, 5])
        self.assertEqual(len(figure.data[0].x), 9)
        self.assertEqual(set(figure.data[1].text), {'A', 'B', 'C', 'D'})
        for filter_value in ('Economy', ['Economy']):
            filtered = self.dashboard.update_network_graph('spring', 'degree', filter_value)
            self.assertEqual(set(filtered.data[1].text), {'A', 'B'})
            self.assertEqual(len(filtered.data[0].x), 3)
        self.assertEqual(len(self.dashboard.update_network_graph('spring', 'degree', ['missing']).data[1].text), 0)

    def test_layout_cache_reuses_topology_but_invalidates_weights_and_filters(self):
        dashboard = self.dashboard
        nodes, edges = dashboard.DATA['nodes'], dashboard.DATA['edges']
        with mock.patch.object(dashboard.nx, 'spring_layout', wraps=dashboard.nx.spring_layout) as compute:
            first = dashboard.create_network_graph(nodes, edges)
            resized = dashboard.create_network_graph(nodes.iloc[::-1], edges.iloc[::-1], node_size_col='total_strength')
            self.assertEqual(self.positions(first), self.positions(resized))
            self.assertEqual(compute.call_count, 1)
            self.assertEqual(compute.call_args.kwargs['seed'], 42)
            changed = edges.copy()
            changed.loc[0, 'weight'] = 0.2
            dashboard.create_network_graph(nodes, changed)
            dashboard.update_network_graph('spring', 'degree', ['Economy'])
            self.assertEqual(compute.call_count, 3)
        for layout in ('circular', 'kamada_kawai', 'unknown'):
            first = dashboard.create_network_graph(nodes, edges, layout)
            dashboard._cached_network_layout.cache_clear()
            second = dashboard.create_network_graph(nodes.iloc[::-1], edges.iloc[::-1], layout)
            self.assertEqual(self.positions(first), self.positions(second))

    def test_layout_cache_is_bounded_and_deterministic_after_eviction(self):
        dashboard = self.dashboard
        nodes, edges = dashboard.DATA['nodes'], dashboard.DATA['edges']
        first = dashboard.create_network_graph(nodes, edges)
        for weight in range(1, 18):
            changed = edges.copy()
            changed.loc[0, 'weight'] = 1 + weight / 20
            dashboard.create_network_graph(nodes, changed)
        info = dashboard._cached_network_layout.cache_info()
        self.assertEqual(info.maxsize, 16)
        self.assertEqual(info.currsize, 16)
        recomputed = dashboard.create_network_graph(nodes, edges)
        self.assertEqual(dashboard._cached_network_layout.cache_info().misses, info.misses + 1)
        self.assertEqual(self.positions(first), self.positions(recomputed))

    def test_launcher_runs_from_unrelated_directory_with_shared_settings(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            with mock.patch.object(run_app, 'check_requirements', return_value=True), \
                    mock.patch.object(run_app, 'DB_PATH', self.path), \
                    mock.patch.object(self.dashboard.app, 'run') as run, \
                    contextlib.redirect_stdout(io.StringIO()):
                run_app.main()
        run.assert_called_once_with(debug=False, host='0.0.0.0', port=8051)

    def test_script_import_and_missing_database_startup_use_only_fixture_paths(self):
        missing = Path(self.temporary.name) / 'never-create.db'
        environment = dict(os.environ, KNOWLEDGE_GRAPH_DB_PATH=str(missing),
                           KNOWLEDGE_GRAPH_PORT='8051', KNOWLEDGE_GRAPH_DEBUG='false')
        environment['PYTHONPATH'] = str(config.APP_DIR)
        result = subprocess.run(
            [sys.executable, '-c',
             'import dashboard, run_app; '
             'assert dashboard.DATA == {}; '
             'assert dashboard.DB_PATH == run_app.DB_PATH; '
             'assert dashboard.PORT == run_app.PORT == 8051; '
             'assert not dashboard.DEBUG and not run_app.DEBUG; '
             'assert "Data Not Available" in str(dashboard.render_tab_content("overview")); '
             'assert dashboard.app.server.test_client().get("/_dash-layout").status_code == 200'],
            cwd=self.temporary.name, env=environment, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(missing.exists())

    def test_direct_entry_point_uses_shared_port_and_debug_default(self):
        missing = Path(self.temporary.name) / 'direct-missing.db'
        environment = dict(os.environ, KNOWLEDGE_GRAPH_DB_PATH=str(missing),
                           KNOWLEDGE_GRAPH_PORT='8051', KNOWLEDGE_GRAPH_DEBUG='false')
        environment['PYTHONPATH'] = str(config.APP_DIR)
        result = subprocess.run(
            [sys.executable, '-c',
             'import dash, runpy; from unittest.mock import patch; '
             'runner = patch.object(dash.Dash, "run"); run = runner.start(); '
             f'runpy.run_path({str(config.APP_DIR / "dashboard.py")!r}, run_name="__main__"); '
             'run.assert_called_once_with(debug=False, host="0.0.0.0", port=8051); runner.stop()'],
            cwd=self.temporary.name, env=environment, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(missing.exists())


if __name__ == '__main__':
    unittest.main()
