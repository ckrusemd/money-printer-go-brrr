# Notebook tooling

`book` executes clean source notebooks through the registered `money-r` kernel,
then renders the executed scratch copies with Quarto. `migrate` is a one-time
legacy importer, never a synchronization or production step.

The `.Rmd` files and `_bookdown.yml` remain temporarily as a numerical comparison
baseline until full live/replay acceptance succeeds. Edit `.ipynb` only. They are
not inputs to the notebook publication pipeline.
