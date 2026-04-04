# Knowledge Graph Dashboard

An interactive Dash application for exploring economic indicators knowledge graph data generated from the FRED analysis.

## Features

### 📊 Overview Dashboard
- Summary statistics of the knowledge graph
- Node type distribution charts
- Correlation distribution histograms
- Interactive correlation heatmap

### 🔗 Network Graph Visualization
- Interactive network graph with multiple layout algorithms
- Node filtering by type and properties
- Customizable node sizes based on different metrics
- Hover information for nodes and edges

### 📈 Correlation Analysis
- Interactive scatter plots of correlations
- Configurable axes and filtering thresholds
- Top correlations data table with sorting
- Color-coded correlation types (positive/negative)

### 👑 Leadership Analysis
- Economic indicator leadership rankings
- Leadership score visualizations
- Role-based categorization (Leaders, Followers, Coincident)
- Connection and influence metrics

### 💹 Stock Market Integration
- Stock-economic indicator relationship analysis
- Leadership patterns between stocks and economic indicators
- Stock type categorization and performance metrics
- Interactive correlation scatter plots

### 📋 Data Tables
- Exportable data tables for all datasets
- Filtering and sorting capabilities
- CSV export functionality

## Setup Instructions

### 1. Create the Database
First, run the database creation notebook to generate the DuckDB database:

```bash
# Navigate to the app directory
cd app

# Run the notebook (using Jupyter)
jupyter notebook create_database.ipynb
```

Or run it programmatically:
```bash
python -c "
import nbformat
from nbconvert.preprocessors import ExecutePreprocessor
import os

# Read and execute the notebook
with open('create_database.ipynb') as f:
    nb = nbformat.read(f, as_version=4)

ep = ExecutePreprocessor(timeout=600, kernel_name='python3')
ep.preprocess(nb, {'metadata': {'path': os.getcwd()}})
print('Database created successfully!')
"
```

### 2. Install Dependencies
```bash
pip install -r requirements.txt
```

### 3. Run the Dashboard
```bash
python dashboard.py
```

The dashboard will be available at: http://localhost:8050

## Project Structure

```
app/
├── create_database.ipynb    # Database creation notebook
├── dashboard.py            # Main Dash application
├── requirements.txt        # Python dependencies
├── README.md              # This file
└── knowledge_graph.db     # Generated DuckDB database (after running notebook)
```

## Database Schema

The DuckDB database contains the following tables:

### Tables
- **nodes**: Network nodes with metadata (id, label, type, degree, etc.)
- **edges**: Network edges with weights and relationships
- **correlations**: Detailed correlation analysis between indicators
- **leadership**: Leadership scores and roles for economic indicators
- **stock_relationships**: Stock-economic indicator relationships
- **metadata**: Database creation metadata

### Views
- **strong_correlations_with_nodes**: Correlations ≥0.7 with node information
- **node_type_stats**: Aggregated statistics by node type
- **top_correlations_by_type**: Top correlations grouped by indicator types

## Usage Tips

### Navigation
- Use the tab navigation to explore different aspects of the data
- Each tab provides different perspectives on the economic indicators network

### Interactive Features
- **Network Graph**: Click and drag nodes, zoom in/out, hover for details
- **Correlation Analysis**: Adjust thresholds with sliders, change axes
- **Data Tables**: Sort columns, filter data, export to CSV
- **Charts**: Hover for details, zoom, pan

### Filtering Options
- Filter network nodes by type or properties
- Adjust correlation thresholds to focus on strong relationships
- Use table filters to find specific indicators

### Export Capabilities
- All data tables support CSV export
- Charts can be downloaded as PNG images
- Network graphs can be exported through the plotly interface

## Data Sources

The dashboard displays data from:
- **FRED API**: Economic indicators from the Federal Reserve Economic Data
- **Yahoo Finance**: Stock market data and indices
- **Analysis Period**: Last 10 years (configurable in the source analysis)

## Technical Details

### Architecture
- **Backend**: DuckDB for fast analytical queries
- **Frontend**: Dash with Plotly for interactive visualizations
- **Data Processing**: pandas, numpy for data manipulation
- **Network Analysis**: NetworkX for graph algorithms

### Performance
- DuckDB provides fast analytical queries on the dataset
- Network layouts are computed efficiently using NetworkX
- Interactive updates are optimized for responsive user experience

### Customization
The dashboard can be customized by:
- Modifying color schemes in the `COLORS` dictionary
- Adding new visualization types in separate tab functions
- Extending the database schema with additional views
- Adding new filtering and interaction capabilities

## Troubleshooting

### Database Not Found
If you see "Data Not Available", ensure you've run the `create_database.ipynb` notebook first.

### Missing Dependencies
Install all requirements: `pip install -r requirements.txt`

### Port Already in Use
Change the port in `dashboard.py`: `app.run_server(port=8051)`

### Performance Issues
- Reduce the number of nodes/edges in network visualization
- Increase correlation thresholds to show fewer relationships
- Use the simplified network layouts for better performance

## Future Enhancements

Potential improvements:
- Real-time data updates from FRED API
- Machine learning predictions based on correlations
- Additional financial data sources (Bloomberg, Quandl)
- Advanced network analysis metrics (centrality, clustering)
- Time-series visualization of correlations
- Alert system for significant correlation changes