# Knowledge Graph: FRED Economic Indicators Analysis

## Overview

This project creates a comprehensive knowledge graph of FRED API economic indicators, analyzing correlation patterns, temporal relationships, and network structures to identify which indicators universally drive others. The analysis extends to include stock indices and large-cap stocks to understand market-economic relationships.

## Features

### 🔍 **Comprehensive Data Collection**
- **140+ Popular FRED Indicators** across 9 categories:
  - Employment & Labor (20 indicators: PAYEMS, UNRATE, CIVPART, JTSJOL, U6RATE, etc.)
  - Inflation & Prices (18 indicators: CPIAUCSL, PCEPI, T10YIE, GOLDAMGBD228NLBM, etc.)
  - Interest Rates & Monetary Policy (22 indicators: DFF, DGS10, DGS2, MORTGAGE30US, etc.)
  - Money Supply & Credit (15 indicators: M1SL, M2SL, WALCL, TOTRESNS, etc.)
  - Economic Output & Growth (18 indicators: GDP, INDPRO, NAPMPI, CAPUTLB50001SQ, etc.)
  - Housing Market (12 indicators: CSUSHPINSA, HOUST, PERMIT, EXHOSLUSM495S, etc.)
  - Consumer & Business Sentiment (12 indicators: UMCSENT, PSAVERT, RECPROUSM156N, etc.)
  - Financial Stress & Risk (18 indicators: VIXCLS, NFCI, TEDRATE, BAMLH0A0HYM2, etc.)
  - International & Trade (8 indicators: DEXUSEU, DEXJPUS, EXPGS, IMPGS, etc.)

- **150+ Stock Market Symbols** across 11 categories:
  - Major Market Indices (15: S&P 500, NASDAQ, Dow Jones, VIX, international indices)
  - Large-Cap Technology (25: AAPL, MSFT, GOOGL, NVDA, TSLA, META, etc.)
  - Financial Sector (25: JPM, BAC, GS, BLK, V, MA, PYPL, etc.)
  - Healthcare & Pharmaceuticals (20: JNJ, UNH, PFE, ABBV, TMO, etc.)
  - Consumer Discretionary (20: HD, MCD, NKE, SBUX, DIS, etc.)
  - Consumer Staples (15: PG, KO, PEP, WMT, COST, etc.)
  - Industrial & Materials (15: CAT, BA, GE, MMM, HON, etc.)
  - Energy Sector (12: XOM, CVX, COP, EOG, SLB, etc.)
  - Utilities (10: NEE, DUK, SO, D, AEP, etc.)
  - Real Estate & REITs (10: AMT, PLD, CCI, EQIX, etc.)
  - Other Large Cap (8: BRK-A, BRK-B, LLY, etc.)

### 📊 **Advanced Correlation Analysis**
- **Cross-correlation with lag analysis** (up to 60-day lags)
- **Statistical significance testing** with minimum observation requirements
- **Temporal relationship classification** (leading, coincident, lagging)
- **Directional causality inference** based on lag patterns

### 🕸️ **Interactive Knowledge Graph**
- **Multiple visualization engines** (visNetwork, networkD3, igraph)
- **Dynamic network visualization** with advanced physics simulation
- **Node importance analysis** (degree centrality, strength, betweenness)
- **Edge attributes** (correlation strength, lag relationships, statistical significance)
- **Color-coded categories** with 11+ indicator types for easy interpretation
- **Interactive exploration** with zoom, drag, selection, and filtering features
- **Sector-specific sub-networks** (financial, technology, healthcare, etc.)
- **Performance optimization** with simplified views for large networks

### 📈 **Economic Driver Analysis**
- **Leadership scoring** algorithm to identify market drivers vs. followers
- **Temporal precedence analysis** showing which indicators lead others
- **Economic transmission mechanisms** visualization
- **Risk concentration identification**

### 💹 **Stock Market Integration**
- **Stock-economic indicator relationships** with lead-lag analysis
- **Sector-specific economic sensitivities**
- **Market efficiency indicators** (how quickly stocks respond to economic data)
- **Investment strategy insights** based on economic leading indicators

## Files Structure

```
knowledgegraph/
├── KnowledgeGraph_FRED_Analysis.ipynb    # Main analysis notebook
├── README.md                             # This documentation
├── knowledge_graph_data.rds              # Complete R data export
├── knowledge_graph_nodes.csv             # Network nodes data
├── knowledge_graph_edges.csv             # Network edges data
├── leadership_analysis.csv               # Economic drivers analysis
├── correlations_detailed.csv             # Detailed correlation results
└── stock_economic_relationships.csv      # Stock-economic relationships
```

## Key Insights

### 🎯 **Universal Economic Drivers**
The analysis identifies which economic indicators consistently lead others across different time periods:

1. **Monetary Policy Tools** (Federal Funds Rate, Money Supply)
2. **Financial Stress Indicators** (VIX, Credit Spreads, TED Spread)
3. **Leading Employment Indicators** (Initial Claims, Job Openings)
4. **Forward-Looking Surveys** (Consumer Sentiment, PMI)

### 🔄 **Economic Transmission Mechanisms**
The knowledge graph reveals key transmission pathways:
- **Monetary Policy → Financial Markets → Real Economy**
- **Employment → Consumer Spending → Corporate Earnings**
- **Housing Market → Wealth Effects → Economic Activity**
- **International Trade → Currency → Domestic Prices**

### 📊 **Market-Economic Relationships**
Stock market analysis shows:
- **Technology stocks** are highly sensitive to monetary policy and growth indicators
- **Financial stocks** lead economic indicators more often than they follow
- **Market indices** often provide early signals for economic turning points
- **Sector rotation** patterns correlate with economic cycle phases

## Usage Instructions

### Prerequisites
```r
# Required R packages
install.packages(c(
    "fredr", "dplyr", "tidyr", "lubridate", "ggplot2",
    "visNetwork", "igraph", "corrplot", "quantmod",
    "data.table", "DT", "plotly", "networkD3", "scales",
    "RColorBrewer", "tidyquant", "PerformanceAnalytics", "psych"
))
```

### FRED API Setup
1. Get a free FRED API key from [https://fred.stlouisfed.org/docs/api/api_key.html](https://fred.stlouisfed.org/docs/api/api_key.html)
2. Set your API key:
   ```r
   fredr::fredr_set_key("your_api_key_here")
   ```

### Running the Analysis
1. Open `KnowledgeGraph_FRED_Analysis.ipynb` in RStudio or Jupyter
2. Set your FRED API key in the configuration cell
3. Run all cells to perform the complete analysis
4. Explore the interactive visualizations and export results

## Analysis Parameters

### Configurable Settings
- **Analysis Period**: Default 10 years (adjustable)
- **Correlation Threshold**: 0.7 for strong relationships (adjustable)
- **Maximum Lag**: 60 days for cross-correlation (adjustable)
- **Minimum Observations**: 500 for statistical significance (adjustable)

### Statistical Methods
- **Cross-Correlation Function (CCF)** for lag analysis
- **Pearson Correlation** for linear relationships
- **Network Analysis** using igraph algorithms
- **Centrality Measures** for influence identification

## Visualizations

### 1. Interactive Knowledge Graph
- **Nodes**: Economic indicators and stocks sized by importance
- **Edges**: Correlations colored by type (positive/negative) and weighted by strength
- **Layout**: Force-directed algorithm for optimal positioning
- **Interactivity**: Hover for details, click to highlight connections

### 2. Correlation Heatmap
- **Matrix visualization** of pairwise correlations
- **Hierarchical clustering** to group similar indicators
- **Interactive plotly version** with zoom and hover details

### 3. Economic Driver Rankings
- **Leadership score** visualization showing drivers vs. followers
- **Temporal analysis** of lead-lag relationships
- **Category-based analysis** of different economic sectors

### 4. Stock-Economic Integration
- **Scatter plot** showing correlation strength vs. leadership
- **Sector analysis** of stock market sensitivities
- **Time series** of key relationships

## Applications

### 📈 **Investment Strategy**
- **Early Warning System**: Identify leading indicators for market timing
- **Sector Rotation**: Use economic drivers to predict sector performance
- **Risk Management**: Monitor interconnected risks through network analysis
- **Portfolio Optimization**: Include economic indicators in asset allocation models

### 🏛️ **Economic Research**
- **Policy Analysis**: Understand transmission mechanisms of monetary/fiscal policy
- **Forecasting**: Build models using identified leading relationships
- **Crisis Analysis**: Study network vulnerabilities and contagion pathways
- **International Comparison**: Extend framework to other economies

### 🏢 **Business Intelligence**
- **Strategic Planning**: Anticipate economic conditions affecting business
- **Supply Chain**: Monitor indicators relevant to operational planning
- **Financial Planning**: Use economic drivers for cash flow forecasting
- **Market Research**: Understand consumer and business cycle relationships

## Technical Notes

### Performance Considerations
- **Batch Processing**: Large correlation matrices processed in chunks
- **Memory Management**: Efficient data structures for large datasets
- **API Rate Limits**: Includes retry logic and delay handling
- **Error Handling**: Robust error handling for data collection failures

### Data Quality
- **Missing Data**: Automatic handling of gaps and irregular frequencies
- **Outlier Detection**: Statistical checks for data quality
- **Frequency Alignment**: Smart alignment of daily, weekly, monthly, and quarterly data
- **Seasonality**: Option to use seasonally adjusted series where available

### Extensibility
- **Modular Design**: Easy to add new indicators or modify parameters
- **Export Functionality**: Multiple formats for downstream analysis
- **API Integration**: Ready for integration with other data sources
- **Scalability**: Framework can handle hundreds of indicators

## Limitations & Considerations

### Statistical Limitations
- **Correlation ≠ Causation**: Results show associations, not definitive causality
- **Non-linear Relationships**: Focus on linear correlations may miss complex relationships
- **Regime Changes**: Relationships may vary across different economic periods
- **Sample Bias**: Results dependent on chosen time period and indicators

### Data Limitations
- **Revision Bias**: Economic data subject to revisions not captured in historical analysis
- **Frequency Mismatch**: Different reporting frequencies may affect relationship strength
- **Publication Lags**: Real-world application must account for data availability delays
- **Survivorship Bias**: Focus on popular indicators may miss important niche measures

## Future Enhancements

### Planned Features
- **Machine Learning Integration**: Add predictive modeling capabilities
- **Real-time Updates**: Automated daily/weekly refresh of analysis
- **International Expansion**: Include global economic indicators
- **Alternative Data**: Integrate satellite, search, and social media data
- **Regime Detection**: Automatic identification of structural breaks

### Advanced Analytics
- **Granger Causality**: More rigorous causality testing
- **Vector Autoregression**: Multi-variate time series modeling
- **Network Dynamics**: Time-varying network analysis
- **Stress Testing**: Scenario analysis and shock propagation

## Contributing

We welcome contributions to enhance the analysis framework:

1. **Fork the repository**
2. **Add new indicators** or data sources
3. **Improve visualization** methods
4. **Enhance statistical methods**
5. **Submit pull request** with documentation

## Citation

If you use this analysis in research or publications, please cite:

```
Economic Indicators Knowledge Graph Analysis
Money Printer Go BRRR Project
[Current Date]
Data Sources: FRED API, Yahoo Finance
```

## License

This project is part of the Money Printer Go BRRR repository. Please refer to the main repository for licensing information.

## Support

For questions or issues:
1. Check the notebook documentation
2. Review existing issues in the main repository
3. Create new issue with detailed description
4. Include sample data and error messages if applicable

---

**Disclaimer**: This analysis is for educational and research purposes only. Economic relationships identified should not be used as the sole basis for investment decisions. Past correlations do not guarantee future relationships. Always consult qualified financial advisors for investment guidance.