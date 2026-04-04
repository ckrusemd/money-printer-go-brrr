"""
Knowledge Graph Dashboard

A Dash application for exploring economic indicators knowledge graph data.
Features correlation analysis, network visualization, and interactive exploration.
"""

import dash
from dash import dcc, html, Input, Output, callback, dash_table
import plotly.express as px
import plotly.graph_objects as go
import pandas as pd
import numpy as np
import duckdb
from pathlib import Path
import networkx as nx
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
import warnings
warnings.filterwarnings('ignore')

# Configuration
DB_PATH = Path('./knowledge_graph.db')
APP_TITLE = "Economic Indicators Knowledge Graph Explorer"

# Initialize Dash app
app = dash.Dash(__name__, title=APP_TITLE)
app._favicon = ("https://plotly.com/favicon.ico")

# Custom CSS styling
external_stylesheets = [
    'https://codepen.io/chriddyp/pen/bWLwgP.css',
    'https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap'
]

app = dash.Dash(__name__, external_stylesheets=external_stylesheets, title=APP_TITLE)

# Color scheme
COLORS = {
    'primary': '#2E86AB',
    'secondary': '#A23B72',
    'accent': '#F18F01',
    'success': '#C73E1D',
    'background': '#F8F9FA',
    'text': '#212529',
    'light': '#E9ECEF'
}

# Database connection helper
def get_db_connection():
    """Get DuckDB connection to the knowledge graph database."""
    if not DB_PATH.exists():
        raise FileNotFoundError(f"Database not found at {DB_PATH}. Please run create_database.ipynb first.")
    return duckdb.connect(str(DB_PATH))

def load_data():
    """Load all necessary data for the dashboard."""
    conn = get_db_connection()

    data = {}

    try:
        # Load main tables
        data['nodes'] = conn.execute("SELECT * FROM nodes").df()
        data['edges'] = conn.execute("SELECT * FROM edges").df()
        data['correlations'] = conn.execute("SELECT * FROM correlations").df()
        data['leadership'] = conn.execute("SELECT * FROM leadership").df()
        data['stock_relationships'] = conn.execute("SELECT * FROM stock_relationships").df()

        # Load views
        data['node_type_stats'] = conn.execute("SELECT * FROM node_type_stats").df()
        data['strong_correlations'] = conn.execute("SELECT * FROM strong_correlations_with_nodes").df()
        data['correlation_types'] = conn.execute("SELECT * FROM top_correlations_by_type").df()

        print(f"Loaded data successfully:")
        for key, df in data.items():
            print(f"  {key}: {len(df)} rows")

    except Exception as e:
        print(f"Error loading data: {e}")
        raise
    finally:
        conn.close()

    return data

# Load data at startup
try:
    DATA = load_data()
    print("Dashboard data loaded successfully!")
except Exception as e:
    print(f"Failed to load data: {e}")
    DATA = {}

# Helper functions for visualizations
def create_correlation_heatmap(correlations_df, top_n=20):
    """Create a correlation heatmap of top indicators."""

    # Get top indicators by connection count
    top_indicators = (
        pd.concat([correlations_df['x1'], correlations_df['x2']])
        .value_counts()
        .head(top_n)
        .index
        .tolist()
    )

    # Filter correlations to top indicators
    filtered_corr = correlations_df[
        (correlations_df['x1'].isin(top_indicators)) &
        (correlations_df['x2'].isin(top_indicators))
    ]

    # Create correlation matrix
    corr_matrix = filtered_corr.pivot_table(
        index='x1',
        columns='x2',
        values='zero_lag_corr',
        fill_value=0
    )

    # Make symmetric
    for i in corr_matrix.index:
        for j in corr_matrix.columns:
            if corr_matrix.loc[i, j] == 0 and j in corr_matrix.index and i in corr_matrix.columns:
                corr_matrix.loc[i, j] = corr_matrix.loc[j, i]

    # Set diagonal to 1
    np.fill_diagonal(corr_matrix.values, 1)

    # Create heatmap
    fig = go.Figure(data=go.Heatmap(
        z=corr_matrix.values,
        x=corr_matrix.columns,
        y=corr_matrix.index,
        colorscale='RdBu',
        zmid=0,
        text=np.round(corr_matrix.values, 2),
        texttemplate="%{text}",
        textfont={"size": 10},
        hoverongaps=False,
        hovertemplate='<b>%{y} vs %{x}</b><br>Correlation: %{z:.3f}<extra></extra>'
    ))

    fig.update_layout(
        title=f"Correlation Heatmap - Top {top_n} Most Connected Indicators",
        xaxis_title="",
        yaxis_title="",
        height=600,
        font=dict(size=10)
    )

    return fig

def create_network_graph(nodes_df, edges_df, layout='spring', node_size_col='degree'):
    """Create an interactive network graph."""

    # Create NetworkX graph
    G = nx.Graph()

    # Add nodes
    for _, node in nodes_df.iterrows():
        G.add_node(
            node['id'],
            **{col: node[col] for col in nodes_df.columns if col != 'id'}
        )

    # Add edges
    for _, edge in edges_df.iterrows():
        if edge['from_node'] in G.nodes and edge['to_node'] in G.nodes:
            G.add_edge(
                edge['from_node'],
                edge['to_node'],
                weight=edge['weight']
            )

    # Calculate layout
    if layout == 'spring':
        pos = nx.spring_layout(G, k=1, iterations=50)
    elif layout == 'circular':
        pos = nx.circular_layout(G)
    elif layout == 'kamada_kawai':
        pos = nx.kamada_kawai_layout(G)
    else:
        pos = nx.spring_layout(G)

    # Extract edge coordinates
    edge_x = []
    edge_y = []
    edge_info = []

    for edge in G.edges():
        x0, y0 = pos[edge[0]]
        x1, y1 = pos[edge[1]]
        edge_x.extend([x0, x1, None])
        edge_y.extend([y0, y1, None])

        # Find edge data
        edge_data = edges_df[
            ((edges_df['from_node'] == edge[0]) & (edges_df['to_node'] == edge[1])) |
            ((edges_df['from_node'] == edge[1]) & (edges_df['to_node'] == edge[0]))
        ]

        if not edge_data.empty:
            edge_info.append(edge_data.iloc[0]['title'])
        else:
            edge_info.append(f"{edge[0]} - {edge[1]}")

    # Create edge trace
    edge_trace = go.Scatter(
        x=edge_x, y=edge_y,
        line=dict(width=0.5, color='#888'),
        hoverinfo='none',
        mode='lines'
    )

    # Extract node coordinates and info
    node_x = []
    node_y = []
    node_text = []
    node_info = []
    node_colors = []
    node_sizes = []

    for node in G.nodes():
        x, y = pos[node]
        node_x.append(x)
        node_y.append(y)

        node_data = nodes_df[nodes_df['id'] == node].iloc[0]
        node_text.append(node)
        node_info.append(node_data['title'] if 'title' in node_data else node)
        node_colors.append(node_data['color'] if 'color' in node_data else COLORS['primary'])

        # Size based on selected column
        if node_size_col in node_data and pd.notna(node_data[node_size_col]):
            node_sizes.append(max(5, min(50, float(node_data[node_size_col]))))
        else:
            node_sizes.append(10)

    # Create node trace
    node_trace = go.Scatter(
        x=node_x, y=node_y,
        mode='markers+text',
        hoverinfo='text',
        text=node_text,
        textposition="middle center",
        hovertext=node_info,
        marker=dict(
            size=node_sizes,
            color=node_colors,
            line=dict(width=2, color='white'),
            opacity=0.8
        ),
        textfont=dict(size=8, color='white')
    )

    # Create figure
    fig = go.Figure(data=[edge_trace, node_trace],
                   layout=go.Layout(
                        title=f'Knowledge Graph Network ({len(G.nodes)} nodes, {len(G.edges)} edges)',
                        titlefont_size=16,
                        showlegend=False,
                        hovermode='closest',
                        margin=dict(b=20,l=5,r=5,t=40),
                        annotations=[ dict(
                            text="Hover over nodes for details",
                            showarrow=False,
                            xref="paper", yref="paper",
                            x=0.005, y=-0.002,
                            xanchor="left", yanchor="bottom",
                            font=dict(color="#888", size=12)
                        )],
                        xaxis=dict(showgrid=False, zeroline=False, showticklabels=False),
                        yaxis=dict(showgrid=False, zeroline=False, showticklabels=False),
                        height=700
                    ))

    return fig

def create_leadership_chart(leadership_df, top_n=15):
    """Create leadership score visualization."""

    top_leaders = leadership_df.nlargest(top_n, 'leadership_score')

    fig = px.bar(
        top_leaders,
        x='leadership_score',
        y='x1',
        color='indicator_category',
        orientation='h',
        title=f'Top {top_n} Economic Leaders by Leadership Score',
        labels={
            'leadership_score': 'Leadership Score',
            'x1': 'Indicator',
            'indicator_category': 'Category'
        },
        hover_data=['indicator_role', 'total_connections']
    )

    fig.update_layout(
        height=500,
        yaxis={'categoryorder': 'total ascending'},
        showlegend=True
    )

    return fig

def create_correlation_scatter(correlations_df, x_col='best_lag', y_col='best_corr'):
    """Create correlation scatter plot."""

    fig = px.scatter(
        correlations_df,
        x=x_col,
        y=y_col,
        color='correlation_type',
        size='n_obs',
        hover_data=['x1', 'x2', 'lag_type'],
        title=f'Correlation Analysis: {y_col} vs {x_col}',
        labels={
            x_col: x_col.replace('_', ' ').title(),
            y_col: y_col.replace('_', ' ').title()
        }
    )

    fig.update_layout(height=500)

    return fig

# App Layout
app.layout = html.Div([
    # Header
    html.Div([
        html.H1(APP_TITLE, className="header-title"),
        html.P("Interactive exploration of economic indicators and their relationships",
               className="header-subtitle")
    ], className="header"),

    # Navigation tabs
    dcc.Tabs(id="main-tabs", value="overview", children=[
        dcc.Tab(label="📊 Overview", value="overview"),
        dcc.Tab(label="🔗 Network Graph", value="network"),
        dcc.Tab(label="📈 Correlations", value="correlations"),
        dcc.Tab(label="👑 Leadership", value="leadership"),
        dcc.Tab(label="💹 Stock Relations", value="stocks"),
        dcc.Tab(label="📋 Data Tables", value="tables")
    ]),

    # Main content area
    html.Div(id="tab-content")

], style={'fontFamily': 'Inter, sans-serif'})

# Tab content callbacks
@app.callback(
    Output("tab-content", "children"),
    Input("main-tabs", "value")
)
def render_tab_content(active_tab):
    """Render content based on active tab."""

    if not DATA:
        return html.Div([
            html.H3("⚠️ Data Not Available"),
            html.P("Please run the create_database.ipynb notebook first to generate the database.")
        ], style={'textAlign': 'center', 'padding': '50px'})

    if active_tab == "overview":
        return create_overview_tab()
    elif active_tab == "network":
        return create_network_tab()
    elif active_tab == "correlations":
        return create_correlations_tab()
    elif active_tab == "leadership":
        return create_leadership_tab()
    elif active_tab == "stocks":
        return create_stocks_tab()
    elif active_tab == "tables":
        return create_tables_tab()
    else:
        return html.Div("Tab not found")

def create_overview_tab():
    """Create the overview dashboard tab."""

    node_type_stats = DATA['node_type_stats']
    correlations = DATA['correlations']

    # Summary statistics
    total_nodes = len(DATA['nodes'])
    total_edges = len(DATA['edges'])
    total_correlations = len(correlations)
    avg_correlation = correlations['best_corr'].abs().mean()

    return html.Div([
        # Summary cards
        html.Div([
            html.Div([
                html.H3(f"{total_nodes:,}", className="metric-value"),
                html.P("Economic Indicators", className="metric-label")
            ], className="metric-card"),

            html.Div([
                html.H3(f"{total_edges:,}", className="metric-value"),
                html.P("Network Connections", className="metric-label")
            ], className="metric-card"),

            html.Div([
                html.H3(f"{total_correlations:,}", className="metric-value"),
                html.P("Correlations Analyzed", className="metric-label")
            ], className="metric-card"),

            html.Div([
                html.H3(f"{avg_correlation:.3f}", className="metric-value"),
                html.P("Avg |Correlation|", className="metric-label")
            ], className="metric-card")
        ], className="metrics-container"),

        # Charts row
        html.Div([
            html.Div([
                dcc.Graph(
                    figure=px.bar(
                        node_type_stats.head(10),
                        x='node_type',
                        y='node_count',
                        title='Indicators by Category',
                        color='avg_degree',
                        color_continuous_scale='viridis'
                    ).update_layout(xaxis_tickangle=-45)
                )
            ], className="chart-container", style={'width': '50%'}),

            html.Div([
                dcc.Graph(
                    figure=px.histogram(
                        correlations,
                        x='best_corr',
                        nbins=50,
                        title='Distribution of Correlations',
                        color_discrete_sequence=[COLORS['primary']]
                    )
                )
            ], className="chart-container", style={'width': '50%'})
        ], style={'display': 'flex'}),

        # Correlation heatmap
        html.Div([
            dcc.Graph(
                figure=create_correlation_heatmap(correlations, top_n=15)
            )
        ], className="chart-container full-width")

    ], className="tab-content")

def create_network_tab():
    """Create the network visualization tab."""

    return html.Div([
        # Controls
        html.Div([
            html.Div([
                html.Label("Layout Algorithm:"),
                dcc.Dropdown(
                    id='network-layout',
                    options=[
                        {'label': 'Spring Layout', 'value': 'spring'},
                        {'label': 'Circular Layout', 'value': 'circular'},
                        {'label': 'Kamada-Kawai', 'value': 'kamada_kawai'}
                    ],
                    value='spring'
                )
            ], style={'width': '200px', 'marginRight': '20px'}),

            html.Div([
                html.Label("Node Size Based On:"),
                dcc.Dropdown(
                    id='node-size-column',
                    options=[
                        {'label': 'Degree (Connections)', 'value': 'degree'},
                        {'label': 'Average Strength', 'value': 'avg_strength'},
                        {'label': 'Total Strength', 'value': 'total_strength'}
                    ],
                    value='degree'
                )
            ], style={'width': '200px', 'marginRight': '20px'}),

            html.Div([
                html.Label("Filter by Node Type:"),
                dcc.Dropdown(
                    id='node-type-filter',
                    options=[{'label': 'All Types', 'value': 'all'}] +
                            [{'label': nt, 'value': nt} for nt in DATA['nodes']['node_type'].unique() if pd.notna(nt)],
                    value='all',
                    multi=True
                )
            ], style={'width': '300px'})
        ], style={'display': 'flex', 'marginBottom': '20px'}),

        # Network graph
        html.Div([
            dcc.Graph(
                id='network-graph',
                figure=create_network_graph(DATA['nodes'], DATA['edges'])
            )
        ])

    ], className="tab-content")

def create_correlations_tab():
    """Create the correlations analysis tab."""

    return html.Div([
        html.H3("Correlation Analysis"),

        # Controls
        html.Div([
            html.Div([
                html.Label("X-Axis:"),
                dcc.Dropdown(
                    id='corr-x-axis',
                    options=[
                        {'label': 'Best Lag', 'value': 'best_lag'},
                        {'label': 'Zero Lag Correlation', 'value': 'zero_lag_corr'},
                        {'label': 'Observations', 'value': 'n_obs'}
                    ],
                    value='best_lag'
                )
            ], style={'width': '200px', 'marginRight': '20px'}),

            html.Div([
                html.Label("Y-Axis:"),
                dcc.Dropdown(
                    id='corr-y-axis',
                    options=[
                        {'label': 'Best Correlation', 'value': 'best_corr'},
                        {'label': 'Strength', 'value': 'strength'},
                        {'label': 'Zero Lag Correlation', 'value': 'zero_lag_corr'}
                    ],
                    value='best_corr'
                )
            ], style={'width': '200px', 'marginRight': '20px'}),

            html.Div([
                html.Label("Minimum |Correlation|:"),
                dcc.Slider(
                    id='corr-threshold',
                    min=0,
                    max=1,
                    step=0.05,
                    value=0.7,
                    marks={i/10: str(i/10) for i in range(0, 11, 2)},
                    tooltip={"placement": "bottom", "always_visible": True}
                )
            ], style={'width': '300px'})
        ], style={'display': 'flex', 'marginBottom': '20px'}),

        # Scatter plot
        html.Div([
            dcc.Graph(id='correlation-scatter')
        ]),

        # Top correlations table
        html.Div([
            html.H4("Top Correlations"),
            dash_table.DataTable(
                id='top-correlations-table',
                columns=[
                    {'name': 'Indicator 1', 'id': 'x1'},
                    {'name': 'Indicator 2', 'id': 'x2'},
                    {'name': 'Correlation', 'id': 'best_corr', 'type': 'numeric', 'format': '.3f'},
                    {'name': 'Lag (days)', 'id': 'best_lag', 'type': 'numeric'},
                    {'name': 'Type', 'id': 'correlation_type'},
                    {'name': 'Lag Type', 'id': 'lag_type'},
                    {'name': 'Observations', 'id': 'n_obs', 'type': 'numeric'}
                ],
                sort_action='native',
                page_size=10,
                style_cell={'textAlign': 'left'},
                style_data_conditional=[
                    {
                        'if': {'filter_query': '{correlation_type} = positive'},
                        'backgroundColor': '#d4edda',
                        'color': 'black',
                    },
                    {
                        'if': {'filter_query': '{correlation_type} = negative'},
                        'backgroundColor': '#f8d7da',
                        'color': 'black',
                    }
                ]
            )
        ])

    ], className="tab-content")

def create_leadership_tab():
    """Create the leadership analysis tab."""

    return html.Div([
        html.H3("Economic Leadership Analysis"),

        # Leadership chart
        html.Div([
            dcc.Graph(
                figure=create_leadership_chart(DATA['leadership'])
            )
        ]),

        # Leadership table
        html.Div([
            html.H4("Leadership Rankings"),
            dash_table.DataTable(
                data=DATA['leadership'].round(3).to_dict('records'),
                columns=[
                    {'name': 'Indicator', 'id': 'x1'},
                    {'name': 'Category', 'id': 'indicator_category'},
                    {'name': 'Role', 'id': 'indicator_role'},
                    {'name': 'Leadership Score', 'id': 'leadership_score', 'type': 'numeric', 'format': '.3f'},
                    {'name': 'Connections', 'id': 'total_connections', 'type': 'numeric'},
                    {'name': 'Leading', 'id': 'leading_connections', 'type': 'numeric'},
                    {'name': 'Lagging', 'id': 'lagging_connections', 'type': 'numeric'},
                    {'name': 'Avg Correlation', 'id': 'avg_correlation_strength', 'type': 'numeric', 'format': '.3f'}
                ],
                sort_action='native',
                sort_by=[{'column_id': 'leadership_score', 'direction': 'desc'}],
                page_size=15,
                style_cell={'textAlign': 'left'},
                style_data_conditional=[
                    {
                        'if': {'filter_query': '{indicator_role} contains "Leader"'},
                        'backgroundColor': '#d1ecf1',
                        'color': 'black',
                    }
                ]
            )
        ])

    ], className="tab-content")

def create_stocks_tab():
    """Create the stock relationships tab."""

    if 'stock_relationships' not in DATA or DATA['stock_relationships'].empty:
        return html.Div([
            html.H3("Stock-Economic Relationships"),
            html.P("No stock relationship data available.")
        ], className="tab-content")

    stock_data = DATA['stock_relationships']

    # Stock type summary
    stock_summary = (
        stock_data.groupby(['stock_type', 'econ_category'])
        .agg({
            'best_corr': ['count', 'mean'],
            'stock_leads': 'mean'
        })
        .round(3)
        .reset_index()
    )

    stock_summary.columns = ['Stock Type', 'Economic Category', 'Count', 'Avg Correlation', 'Stock Leads %']
    stock_summary['Stock Leads %'] = (stock_summary['Stock Leads %'] * 100).round(1)

    return html.Div([
        html.H3("Stock-Economic Indicator Relationships"),

        # Summary chart
        html.Div([
            dcc.Graph(
                figure=px.scatter(
                    stock_summary,
                    x='Avg Correlation',
                    y='Stock Leads %',
                    size='Count',
                    color='Stock Type',
                    hover_name='Economic Category',
                    title='Stock Leadership vs Economic Correlation',
                    labels={'Stock Leads %': '% of Time Stock Leads Economic Indicator'}
                )
            )
        ]),

        # Top stock-economic relationships
        html.Div([
            html.H4("Strongest Stock-Economic Correlations"),
            dash_table.DataTable(
                data=stock_data.nlargest(20, 'strength').round(3).to_dict('records'),
                columns=[
                    {'name': 'Stock', 'id': 'stock_symbol'},
                    {'name': 'Economic Indicator', 'id': 'economic_indicator'},
                    {'name': 'Correlation', 'id': 'best_corr', 'type': 'numeric', 'format': '.3f'},
                    {'name': 'Lag', 'id': 'best_lag', 'type': 'numeric'},
                    {'name': 'Stock Type', 'id': 'stock_type'},
                    {'name': 'Econ Category', 'id': 'econ_category'},
                    {'name': 'Stock Leads', 'id': 'stock_leads', 'type': 'text'}
                ],
                sort_action='native',
                page_size=15,
                style_cell={'textAlign': 'left'}
            )
        ])

    ], className="tab-content")

def create_tables_tab():
    """Create the data tables tab."""

    return html.Div([
        html.H3("Data Tables"),

        dcc.Tabs(id="table-tabs", value="nodes-table", children=[
            dcc.Tab(label="Nodes", value="nodes-table"),
            dcc.Tab(label="Edges", value="edges-table"),
            dcc.Tab(label="Correlations", value="correlations-table"),
            dcc.Tab(label="Statistics", value="stats-table")
        ]),

        html.Div(id="table-content")

    ], className="tab-content")

# Callback for network graph updates
@app.callback(
    Output('network-graph', 'figure'),
    [Input('network-layout', 'value'),
     Input('node-size-column', 'value'),
     Input('node-type-filter', 'value')]
)
def update_network_graph(layout, size_col, type_filter):
    """Update network graph based on controls."""

    nodes_df = DATA['nodes'].copy()
    edges_df = DATA['edges'].copy()

    # Filter by node type if specified
    if type_filter and type_filter != 'all' and not isinstance(type_filter, list):
        type_filter = [type_filter]

    if type_filter and 'all' not in type_filter:
        nodes_df = nodes_df[nodes_df['node_type'].isin(type_filter)]
        # Filter edges to only include filtered nodes
        node_ids = set(nodes_df['id'])
        edges_df = edges_df[
            (edges_df['from_node'].isin(node_ids)) &
            (edges_df['to_node'].isin(node_ids))
        ]

    return create_network_graph(nodes_df, edges_df, layout, size_col)

# Callback for correlation scatter plot
@app.callback(
    [Output('correlation-scatter', 'figure'),
     Output('top-correlations-table', 'data')],
    [Input('corr-x-axis', 'value'),
     Input('corr-y-axis', 'value'),
     Input('corr-threshold', 'value')]
)
def update_correlation_analysis(x_axis, y_axis, threshold):
    """Update correlation scatter and table."""

    correlations = DATA['correlations']
    filtered_corr = correlations[correlations['strength'] >= threshold]

    # Create scatter plot
    scatter_fig = create_correlation_scatter(filtered_corr, x_axis, y_axis)

    # Top correlations for table
    top_corr = (
        filtered_corr
        .nlargest(20, 'strength')[['x1', 'x2', 'best_corr', 'best_lag', 'correlation_type', 'lag_type', 'n_obs']]
        .round(3)
        .to_dict('records')
    )

    return scatter_fig, top_corr

# Callback for data tables tab
@app.callback(
    Output("table-content", "children"),
    Input("table-tabs", "value")
)
def render_table_content(active_table):
    """Render data table content."""

    if active_table == "nodes-table":
        return dash_table.DataTable(
            data=DATA['nodes'].round(3).to_dict('records'),
            columns=[{'name': col, 'id': col} for col in DATA['nodes'].columns],
            sort_action='native',
            filter_action='native',
            page_size=20,
            style_cell={'textAlign': 'left'},
            export_format="csv"
        )

    elif active_table == "edges-table":
        return dash_table.DataTable(
            data=DATA['edges'].round(3).to_dict('records'),
            columns=[{'name': col, 'id': col} for col in DATA['edges'].columns],
            sort_action='native',
            filter_action='native',
            page_size=20,
            style_cell={'textAlign': 'left'},
            export_format="csv"
        )

    elif active_table == "correlations-table":
        return dash_table.DataTable(
            data=DATA['correlations'].round(3).to_dict('records'),
            columns=[{'name': col, 'id': col} for col in DATA['correlations'].columns],
            sort_action='native',
            filter_action='native',
            page_size=20,
            style_cell={'textAlign': 'left'},
            export_format="csv"
        )

    elif active_table == "stats-table":
        return dash_table.DataTable(
            data=DATA['node_type_stats'].round(3).to_dict('records'),
            columns=[{'name': col, 'id': col} for col in DATA['node_type_stats'].columns],
            sort_action='native',
            page_size=20,
            style_cell={'textAlign': 'left'},
            export_format="csv"
        )

# Custom CSS
app.index_string = '''
<!DOCTYPE html>
<html>
    <head>
        {%metas%}
        <title>{%title%}</title>
        {%favicon%}
        {%css%}
        <style>
            body {
                font-family: 'Inter', sans-serif;
                margin: 0;
                background-color: #f8f9fa;
            }
            .header {
                background: linear-gradient(135deg, #2E86AB 0%, #A23B72 100%);
                color: white;
                padding: 2rem;
                text-align: center;
                margin-bottom: 0;
            }
            .header-title {
                font-size: 2.5rem;
                font-weight: 600;
                margin: 0;
            }
            .header-subtitle {
                font-size: 1.1rem;
                margin: 0.5rem 0 0 0;
                opacity: 0.9;
            }
            .metrics-container {
                display: flex;
                gap: 1rem;
                margin: 2rem;
                justify-content: center;
            }
            .metric-card {
                background: white;
                padding: 1.5rem;
                border-radius: 8px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                text-align: center;
                min-width: 150px;
            }
            .metric-value {
                font-size: 2rem;
                font-weight: 700;
                color: #2E86AB;
                margin: 0;
            }
            .metric-label {
                color: #666;
                margin: 0.5rem 0 0 0;
                font-size: 0.9rem;
            }
            .chart-container {
                background: white;
                margin: 1rem;
                padding: 1rem;
                border-radius: 8px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }
            .full-width {
                width: calc(100% - 2rem);
            }
            .tab-content {
                padding: 1rem;
            }
            ._dash-undo-redo {
                display: none;
            }
        </style>
    </head>
    <body>
        {%app_entry%}
        <footer>
            {%config%}
            {%scripts%}
            {%renderer%}
        </footer>
    </body>
</html>
'''

# Run the app
if __name__ == '__main__':
    print(f"\n🚀 Starting Knowledge Graph Dashboard...")
    print(f"📊 Database: {DB_PATH}")
    print(f"🌐 Opening dashboard at: http://127.0.0.1:8050")
    print(f"💡 Use Ctrl+C to stop the server\n")

    # app.run_server(debug=True, host='0.0.0.0', port=8050)
    app.run(debug=True, host='0.0.0.0', port=8051)