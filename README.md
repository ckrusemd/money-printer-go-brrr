# Money Printer Go BRRR

> Since 1971, Money Printer Has Gone BRRR. Let's Make the Most of It.

A collection of macroeconomic analysis notebooks covering interest rates, housing markets, equity indices, ETFs, currencies, and crypto — published as a [bookdown site](https://ckrusemd.github.io/money-printer-go-brrr/).

## Project Structure

```
├── index.Rmd                     # Bookdown entry point
├── _bookdown.yml                 # Chapter rendering config
├── money_theme.R                 # Shared ggplot2 theme
├── Chapters/
│   ├── 00_ReleaseCalendar/       # Economic release calendar
│   ├── 01_Indicators/            # Leading & lagging indicators
│   ├── 02_Housing/               # US & Danish housing markets
│   ├── 03_InterestRates/         # Interest rates & yield curves
│   ├── 04_Markets/               # Equity market analysis
│   ├── 05_ETFs/                  # ETF analysis
│   ├── 06_Currency/              # Currency pairs
│   └── 07_Crypto/                # Cryptocurrency analysis
├── vignettes/                    # Standalone analysis notebooks
├── datacollection/               # ETL pipeline & modeling
│   ├── 01_etl.ipynb              # Data ingestion (FRED, Yahoo, DST, etc.)
│   ├── 02_models.ipynb           # Modeling & analytics
│   └── database_benchmark.ipynb  # Storage benchmarks
└── knowledgegraph/               # Network analysis & dashboard
    └── app/                      # Dash analytics dashboard
```

## Data Sources

- [FRED](https://fred.stlouisfed.org/) (Federal Reserve Economic Data)
- [Yahoo Finance](https://finance.yahoo.com/)
- [Statistics Denmark (DST)](https://www.dst.dk/)
- [FinansDanmark](https://finansdanmark.dk/)

## Setup

### Prerequisites

- R (≥ 4.0) with [renv](https://rstudio.github.io/renv/)
- Python 3 with Jupyter (for ETL and dashboard)
- A [FRED API key](https://fred.stlouisfed.org/docs/api/api_key.html)

### Quick Start

```bash
# Clone
git clone https://github.com/ckrusemd/money-printer-go-brrr.git
cd money-printer-go-brrr

# Set up FRED API key locally (do not commit this file)
echo "FRED_API=your_key_here" > .Renviron

# Restore R dependencies
Rscript -e "renv::restore()"

# Build the book
Rscript -e "bookdown::render_book('index.Rmd', output_format = 'bookdown::gitbook')"
```

### Data Pipeline

```bash
# Run ETL (populates DuckDB)
jupyter notebook datacollection/01_etl.ipynb

# Run models
jupyter notebook datacollection/02_models.ipynb
```

### Knowledge Graph Dashboard

```bash
cd knowledgegraph/app
pip install -r requirements.txt
python dashboard.py    # Runs on http://localhost:8051
```

## CI/CD

A GitHub Actions workflow renders the book in a prebuilt public GHCR
container on every relevant push to `main` and on a daily schedule, then
deploys it to GitHub Pages. Set the repository secret `FRED_API` for
publication. The container workflow rebuilds only when the R lockfile or
container definition changes.

## License

This project is for personal/educational use.
