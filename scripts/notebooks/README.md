# Notebook tooling

`book` executes clean source notebooks through the registered `money-r` kernel,
then renders the executed scratch copies with Quarto. `migrate` is a one-time
legacy importer, never a synchronization or production step.

The `.Rmd` files and `_bookdown.yml` remain as the verified numerical comparison
baseline. Edit `.ipynb` only. Legacy documents are not inputs to the notebook
publication pipeline.
