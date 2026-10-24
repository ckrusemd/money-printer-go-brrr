"""Fixtures for the authoritative notebook execution/publication contract."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.notebooks import book, image, environment
from scripts.notebooks.collect import collect
from scripts.publication_image_key import image_key
from scripts.notebooks.migrate import convert, split_options
from scripts.notebooks.validate import PAGES, validate


class MigrationTests(unittest.TestCase):
    def test_options_keep_nested_expressions_and_quoted_equals(self):
        options = split_options('chart, fig.alt=market_chart_description("GC=F", "USD"), fig.height=30, eval=FALSE')
        self.assertEqual(options["fig.alt"], 'market_chart_description("GC=F", "USD")')
        self.assertEqual(options["eval"], "FALSE")

    def test_disabled_chunks_are_non_executing_examples(self):
        nb = convert('# Example\n```{r eval=FALSE}\nstop("must not execute")\n```\n')
        self.assertTrue(all(c["cell_type"] == "markdown" for c in nb["cells"]))
        self.assertIn('stop("must not execute")', ''.join(nb["cells"][-1]["source"]))

    def test_hidden_setup_and_plot_options_survive(self):
        nb = convert('```{r setup,include=FALSE,fig.width=12,fig.alt="Two panels"}\nx <- 1\ny <- 2\n```\n')
        c = nb["cells"][0]
        text = ''.join(c["source"])
        self.assertIn('#| include: false', text)
        self.assertIn('#| fig-alt: "Two panels"', text)
        self.assertIn('repr.plot.width = 12', text)
        self.assertIn('x <- 1\ny <- 2\n', text)
        self.assertEqual(c['outputs'], [])

    def test_explicit_echo_is_preserved_for_evaluated_and_disabled_code(self):
        nb = convert('```{r echo=TRUE}\nx <- 1\n```\n```{r eval=FALSE,echo=TRUE}\nx <- 2\n```')
        self.assertIn('#| echo: true', ''.join(nb['cells'][0]['source']))
        self.assertNotIn('publication', nb['cells'][1]['metadata'])


class NotebookContractTests(unittest.TestCase):
    def test_receipt_reads_foreign_owned_checkout_with_scoped_git_trust(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '--quiet', root], check=True)
            subprocess.run(['git', '-c', 'user.name=Fixture', '-c',
                            'user.email=fixture@example.invalid', 'commit', '--quiet',
                            '--allow-empty', '-m', 'Fixture'], cwd=root, check=True)
            expected = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
            with patch.dict(os.environ, {'GIT_TEST_ASSUME_DIFFERENT_OWNER': '1'}):
                untrusted = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True)
                self.assertNotEqual(untrusted.returncode, 0)
                self.assertEqual(book.source_commit(root), expected)

    def test_unbundled_browser_scripts_stop_publication(self):
        from scripts.notebooks.assets import localize
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'index.html').write_text('<script src="https://example.invalid/new-library.js"></script>')
            with self.assertRaisesRegex(ValueError, 'Unbundled browser script'):
                localize(root)

    def test_quarto_cdn_tags_use_local_release_files_and_matching_integrity(self):
        import base64
        import hashlib
        import re
        from scripts.notebooks.assets import localize, DEPENDENCIES
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            page = root/'chapter/page.html'
            page.parent.mkdir()
            page.write_text(''.join('<script src="'+url+'" integrity="old-cdn-hash"></script>'
                                    for url in DEPENDENCIES))
            localize(root)
            text = page.read_text()
            self.assertNotIn('https://cdn.jsdelivr.net', text)
            for src, integrity in re.findall(r'src="([^"]+)" integrity="([^"]+)"', text):
                data = (page.parent/src).read_bytes()
                self.assertEqual(integrity, 'sha384-'+base64.b64encode(hashlib.sha384(data).digest()).decode())
            original = page.read_bytes()
            localize(root)
            self.assertEqual(page.read_bytes(), original)

    def test_partial_provider_responses_are_retained_for_failed_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / '.cache/notebook-runs/failed'
            (run/'inputs').mkdir(parents=True)
            (run/'inputs/provider.rds').write_bytes(b'partial fixture response')
            (root/'.cache/notebook-last-run.json').write_text(json.dumps({
                'directory': str(run), 'source_sha': 'b'*40, 'complete': False}))
            collect(root)
            self.assertEqual((root/'.cache/book-inputs/provider.rds').read_bytes(), b'partial fixture response')
            self.assertEqual((root/'.cache/book-inputs/source-sha.txt').read_text(), 'b'*40+'\n')

    def test_stale_container_and_bootstrap_image_cannot_publish(self):
        with patch.dict(os.environ, {'NOTEBOOK_IMAGE_CONTEXT': 'wrong', 'NOTEBOOK_REQUIRE_PIN': 'true'}):
            with self.assertRaisesRegex(ValueError, 'dependency context'):
                environment.audit()
        with patch.dict(os.environ, {'NOTEBOOK_IMAGE_CONTEXT': 'development', 'NOTEBOOK_REQUIRE_PIN': 'true'}):
            with self.assertRaisesRegex(ValueError, 'dependency context'):
                environment.audit()

    def test_python_package_and_renderer_drift_are_rejected(self):
        with patch.dict(os.environ, {'NOTEBOOK_IMAGE_CONTEXT': image_key(book.ROOT)}):
            with patch('scripts.notebooks.environment.version', return_value='0.0.0'):
                with self.assertRaisesRegex(ValueError, 'Python package mismatch'):
                    environment.audit()
            with patch('scripts.notebooks.environment.subprocess.check_output', return_value='wrong-quarto'):
                with self.assertRaisesRegex(ValueError, 'Quarto version mismatch'):
                    environment.audit()

    def test_legacy_sync_command_cannot_overwrite_notebooks(self):
        import subprocess
        import sys
        path = book.ROOT / 'index.ipynb'
        contents = path.read_bytes()
        result = subprocess.run([sys.executable, str(book.ROOT / 'scripts/sync_book_notebooks.py')],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('retired', result.stderr)
        self.assertEqual(path.read_bytes(), contents)

    def test_all_published_notebooks_have_bootstrap_and_correct_kernel(self):
        book.check()
        for name in book.chapters():
            nb = json.loads((book.ROOT / name).read_text())
            self.assertIn('scripts/notebooks/bootstrap.R', ''.join(nb['cells'][0]['source']))

    def test_build_trigger_includes_notebooks_and_canonical_configuration(self):
        workflow = (book.ROOT / '.github/workflows/deploy_bookdown.yml').read_text()
        for path in ['"**.ipynb"', '"_quarto.yml"', '".devcontainer/devcontainer.json"']:
            self.assertIn(path, workflow)
        self.assertIn('python3 -m scripts.notebooks.book build', workflow)

    def test_sources_with_saved_outputs_are_rejected_by_check(self):
        import nbformat
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'_quarto.yml').write_text('book:\n  chapters: [index.ipynb, Data_Status.ipynb]\n')
            (root/'renv.lock').write_text((book.ROOT/'renv.lock').read_text())
            nb = nbformat.read(book.ROOT/'index.ipynb', as_version=4)
            c = next(c for c in nb.cells if c.cell_type=='code')
            c.outputs = [nbformat.v4.new_output('stream', name='stdout', text='old output')]
            nbformat.write(nb, root/'index.ipynb')
            nbformat.write(nb, root/'Data_Status.ipynb')
            with self.assertRaisesRegex(ValueError, 'Clear notebook outputs'):
                book.check(root)

    def test_capture_has_separate_cells_and_preserves_source(self):
        import nbformat
        nb = nbformat.v4.new_notebook(cells=[nbformat.v4.new_code_cell('x <- 1')])
        original = copy.deepcopy(nb)
        prepared = book.capture_cells(copy.deepcopy(nb))
        self.assertEqual(len(prepared.cells), 2)
        self.assertIn('book_capture_results', prepared.cells[1].source)
        self.assertEqual(nb, original)

    def test_hidden_disabled_examples_remain_in_source_but_not_publication(self):
        import nbformat
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nb = nbformat.v4.new_notebook(cells=[
                nbformat.v4.new_markdown_cell('```r\nexperimental()\n```', metadata={'publication': {'include': False}}),
                nbformat.v4.new_code_cell('x <- 1')])
            source = root/'source.ipynb'
            nbformat.write(nb, source)
            original = source.read_bytes()
            with patch('nbclient.NotebookClient.execute'):
                result = book.execute(source, root/'executed.ipynb', root, capture=False)
            self.assertEqual(len(result.cells), 1)
            self.assertEqual(source.read_bytes(), original)

    def test_failed_kernel_leaves_diagnostics_without_quarto_or_deployment(self):
        import nbformat
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'input.ipynb'
            nb = nbformat.v4.new_notebook(cells=[nbformat.v4.new_code_cell('stop("failed")')])
            nbformat.write(nb, source)
            contents = source.read_bytes()
            with patch('nbclient.NotebookClient.execute', side_effect=RuntimeError('kernel failed')):
                with self.assertRaisesRegex(RuntimeError, 'kernel failed'):
                    book.execute(source, root/'failed.ipynb', root, capture=False)
            self.assertTrue((root/'failed.ipynb').is_file())
            self.assertEqual(source.read_bytes(), contents)

    def test_irkernel_rich_display_stream_errors_fail_execution(self):
        import nbformat
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nb = nbformat.v4.new_notebook(cells=[nbformat.v4.new_code_cell('widget()')])
            nbformat.write(nb, root/'input.ipynb')
            def broken_display(client):
                client.nb.cells[0].outputs = [nbformat.v4.new_output(
                    'stream', name='stderr', text='ERROR while rich displaying an object: fixture')]
            with patch('nbclient.NotebookClient.execute', autospec=True, side_effect=broken_display):
                with self.assertRaisesRegex(RuntimeError, 'Rich output failed'):
                    book.execute(root/'input.ipynb', root/'failed.ipynb', root, capture=False)
            self.assertTrue((root/'failed.ipynb').is_file())

    def test_failed_build_keeps_previous_book_and_records_incomplete_run(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['_quarto.yml', 'renv.lock', 'scripts/book-style.css', 'book.bib', 'packages.bib', *book.chapters()]:
                target = root/name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(book.ROOT/name, target)
            (root/'_book').mkdir()
            (root/'_book/index.html').write_text('previous successful publication')
            originals = {name: (root/name).read_bytes() for name in book.chapters()}
            old_run = os.environ.get('BOOK_RUN_ID')
            with patch('subprocess.check_output', return_value='a'*40), \
                 patch('scripts.notebooks.environment.audit'), \
                 patch('scripts.notebooks.book.execute', side_effect=RuntimeError('fixture calculation failed')):
                with self.assertRaisesRegex(RuntimeError, 'fixture calculation failed'):
                    book.build(root=root)
            self.assertEqual((root/'_book/index.html').read_text(), 'previous successful publication')
            receipt = json.loads((root/'.cache/notebook-last-run.json').read_text())
            self.assertFalse(receipt['complete'])
            self.assertEqual(os.environ.get('BOOK_RUN_ID'), old_run)
            for name, data in originals.items():
                self.assertEqual((root/name).read_bytes(), data)
            # Failure before the first kernel must still restore the environment
            # and retain an incomplete receipt for diagnostics.
            import subprocess
            with patch('scripts.notebooks.environment.audit'), \
                 patch('scripts.notebooks.book.source_commit', side_effect=subprocess.CalledProcessError(128, 'git')):
                with self.assertRaises(subprocess.CalledProcessError):
                    book.build(root=root)
            receipt = json.loads((root/'.cache/notebook-last-run.json').read_text())
            self.assertFalse(receipt['complete'])
            self.assertIsNone(receipt['source_sha'])
            self.assertEqual(os.environ.get('BOOK_RUN_ID'), old_run)
            collect(root)
            self.assertFalse((root/'.cache/book-inputs').exists())

    def test_output_copy_failure_preserves_previous_local_book(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['old', 'new', 'run']:
                (root/name).mkdir()
            (root/'old/index.html').write_text('previous')
            with patch('shutil.copytree', side_effect=OSError('disk full')):
                with self.assertRaisesRegex(OSError, 'disk full'):
                    book.install_output(root/'new', root/'old', root/'run')
            self.assertEqual((root/'old/index.html').read_text(), 'previous')

    def test_digest_pin_cannot_escape_fixed_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'.devcontainer').mkdir()
            config = root/'.devcontainer/devcontainer.json'
            config.write_text(json.dumps({'image': image.REPOSITORY+'@sha256:'+'a'*64}))
            self.assertEqual(image.pinned(root), image.REPOSITORY+'@sha256:'+'a'*64)
            for value in ['evil/image@sha256:'+'a'*64, image.REPOSITORY+':latest', '']:
                config.write_text(json.dumps({'image':value}))
                with self.assertRaises(ValueError):
                    image.pinned(root)

    def test_legacy_links_and_assets_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in PAGES:
                (root/(name+'.html')).write_text('<h1 id="danish-fund-tax">Title</h1>')
            validate(root, require_results=False)
            (root/'index.html').write_text('<img src="missing.png"><a href="data-status.html#missing">Broken</a>')
            with self.assertRaisesRegex(ValueError, 'missing local reference'):
                validate(root, require_results=False)


if __name__ == '__main__':
    unittest.main()
