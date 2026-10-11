import unittest
from convert_rmd_to_ipynb import parse_rmd_content, create_jupyter_notebook


class NotebookSyncTests(unittest.TestCase):
    def test_adjacent_code_lines_remain_separate(self):
        source = "# Example\n\n```{r}\nx <- 1\ny <- x + 2\n```\n"
        notebook = create_jupyter_notebook(parse_rmd_content(source))
        code = next(cell for cell in notebook["cells"] if cell["cell_type"] == "code")
        self.assertEqual("".join(code["source"]), "x <- 1\ny <- x + 2\n")
        self.assertEqual(code["outputs"], [])
        self.assertIsNone(code["execution_count"])

    def test_markdown_paragraphs_keep_line_breaks(self):
        notebook = create_jupyter_notebook(parse_rmd_content("# Title\n\nFirst.\nSecond.\n"))
        self.assertEqual("".join(notebook["cells"][0]["source"]), "# Title\n\nFirst.\nSecond.\n")


if __name__ == "__main__":
    unittest.main()
