# Research definitions and model evidence

The editable R notebooks publish a morning brief and deeper interactive chapters.
`scripts/analysis/research_data.R` defines sources, units, frequency, observation
periods and availability metadata. `research_math.R` contains pure transformations;
`research_models.R` performs chronological comparisons; `research_views.R`
provides the charts and tables. Source notebooks retain no execution outputs.

## Sources and comparability

| Theme | Sources and definitions |
| --- | --- |
| Danish construction | StatBank BYGV99: delay-adjusted, seasonally adjusted dwelling counts, permits/starts/completions and construction in progress. BYGV90 gives detailed building-type counts without seasonal adjustment; BYGV80 gives square metres. In-progress construction is a stock; the other phases are flows. Selected residential m² sums detached, terraced/linked and apartment-building completions explicitly. |
| Residential prices | Finans Danmark BM010 realized DKK/m² prices, separate property categories; BIS national house-price indices via FRED; US Case-Shiller CSUSHPISA. Average transaction prices can change with sales composition. PRIS90 measures new-construction producer prices, not resale homes. |
| Purchasing power | Current Danish consumer CPI PRIS01, all items; US CPIAUCNS, plus separately labelled seasonally adjusted CPIAUCSL. PRIS111 and LBESK03 are archived tables and are not used for current observations. Euro-area HICP comes via FRED; Japanese CPI uses OECD COICOP 2018. CPI is not extrapolated more than 100 days after its last observed period. |
| Labour | US PAYEMS counts payroll jobs; CE16OV counts employed people; UNRATE/CIVPART/ICSA measure different labour-market concepts. Danish LBESK103 covers employees under DB25, with history from 2018; AKU100K/AKU101K are quarterly labour-force-survey levels/rates. Country populations, ages and coverage differ. |
| Equities | Yahoo daily completed closes: S&P 500, Nasdaq Composite, Dow, Russell 2000, OMX C25, Euro Stoxx 50 and Nikkei 225. ACWI is an ETF price proxy for global equities. Price growth excludes dividends and investment costs. |
| Rates | FRED Treasury maturities 1m–30y, effective fed funds, TIPS real yield, breakeven compensation and mortgage rates. ECB AAA euro-area spot yields and Finans Danmark weekly mortgage-bond yields describe different instruments; the latter do not form a sovereign yield curve. |
| Crypto | Yahoo BTC-USD, ETH-USD and SOL-USD completed daily closes. Native calendar-day histories retain weekends and actual inception dates. Gold is a futures-price reference, not spot gold or a total-return investment. |
| Valuation | OECD housing price/income and price/rent indices. Yale Shiller CAPE is optional: an unavailable source produces an explicit placeholder, not an invented estimate. Dimensionless ratios are not deflated twice. |

Official interfaces: [Statistics Denmark API](https://www.dst.dk/da/Statistik/hjaelp-til-statistikbanken/api),
[Finans Danmark BM010](https://rkr.statistikbank.dk/BM010),
[OECD housing definitions](https://www.oecd.org/en/data/indicators/housing-prices.html),
[FRED/ALFRED API](https://fred.stlouisfed.org/docs/api/fred/series_observations.html),
[ECB yield curves](https://data.ecb.europa.eu/data/datasets/YC).
Finans Danmark downloads use its own anonymous export forms and retain PC-Axis
codes, metadata and raw public responses. `dstcollect` preserves StatBank source
categories and explicit, versioned analytical mappings; it does not equate
incompatible categories or silently splice historical classifications.

## Historical transformations

Asset return statistics use native observed closes; prices are not filled over
missing exchange sessions for training. Crypto/equity correlations first sample
common observation endpoints and then calculate interval returns, so a weekend
move belongs to the same interval on both sides. Recent returns use the last
observation at or before the requested historical cutoff. Volatility scales with
252 exchange sessions or 365 crypto days. Drawdown and full-history CAGR depend
on the displayed instrument's actual available history.

Real DKK values convert native prices using contemporaneous observed DKK/USD,
USD/EUR or JPY/USD before dividing by Danish CPI. Domestic views use the relevant
consumer index. Historical CPI/FX joins only use periods on or before the price
date; they describe revised purchasing power, not an executable historical
strategy or a claim that same-period CPI was already published. Charts use a
common starting window and explicit rebasing. Future real values are not forecast.

Housing relationships use quarterly price changes and quarterly average
indicators, with a separate annual-change view. Rates change in percentage points;
positive-valued levels use percentage growth. Missing quarters remain missing
before differences and lags are computed. Indicator leads span 0–8 quarters, with
at least 40 complete pairs; rolling correlations require 40 consecutive complete
quarters. BH q-values summarize an exploratory comparison family, not causality;
serial dependence, overlapping annual changes, revisions and many comparisons
limit conventional correlation p-values.

ALFRED initial releases and their recorded release dates are captured for US CPI,
house prices, payrolls and unemployment. Latest-data charts and correlations
remain retrospective. Asset models use their own observed prices; Danish models
use revised series and an explicit reporting gap. These are not presented as
fully vintage-correct macroeconomic backtests.

## Models, selection and uncertainty

Construction targets are total, one-family and multi-dwelling completions and
selected residential completed m², at 3/6/12 months from the edition month. The
unreported gap after the latest construction observation is included in the
model horizon and displayed. Equity horizons are 5/20/63/126/252 native trading
sessions after the last completed close; crypto uses 7/30/90/180/365 calendar days
after its last completed close. No future exchange holiday dates are fabricated.

Candidates are a seasonal-naive construction benchmark or unchanged-price asset
benchmark, ETS for construction/log drift for assets, bounded automatic ARIMA,
and a 100-tree random forest. Forest features are fixed: lagged construction
levels, season and corresponding permits/starts where available (the selected
floor-area aggregate uses its own lags and season); or asset log momentum and volatility.
Asset forest targets are forward log returns, not future absolute levels.
Every supervised target must mature by its training origin. All preprocessing
and scale denominators use training observations only. The minimum initial
histories are 120 construction months, 756 equity sessions and 1,095 crypto days;
windows are bounded at 240/2,520/3,650 observations respectively.

The weekly review uses up to 60 origins spaced 3 construction months, 21 equity
sessions or 30 crypto days. Shorter histories or longer horizons yield fewer
matured comparisons. MAE, RMSE, signed bias, training-scaled MASE and same-origin
benchmark-relative MAE are retained. An alternative must have at least 30 matured
origins, improve MAE by at least 5%, and have a positive 2.5th-percentile
block-bootstrap lower bound on paired MAE improvement. Blocks cover at least
the overlapping forecast horizon, with 399 deterministic replicates. Otherwise
the benchmark remains published. This fixed candidate comparison is not a
guarantee against selection bias or structural change.

80%/95% ranges use empirical out-of-sample residual quantiles from the selected
model and require at least 30 available errors. Historical coverage uses only
errors whose outcomes were available before each forecast origin, with a
conservative construction publication delay. Missing calibration stays missing.
These are empirical ranges, not guaranteed coverage; construction ranges are
nonnegative. Daily selection requires the exact code/lock signature, matching
construction reporting gap and a review no more than eight days old. An absent,
stale or incompatible review falls back to the benchmark. Weekly artifacts are
authenticated against a successful same-repository main workflow and digests.

Tests and render evidence are recorded separately in the acceptance report.
The original Rmds remain a historical comparison baseline. Several old in-sample
timing/all-pairs experiments are intentionally removed from the default edition;
their unchanged methods are not evidence for the new forecasts.
