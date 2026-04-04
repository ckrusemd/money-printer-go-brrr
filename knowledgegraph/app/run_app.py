#!/usr/bin/env python3
"""
Knowledge Graph Dashboard Launcher

This script checks requirements and launches the dashboard application.
"""

import sys
import subprocess
import os
from pathlib import Path

def check_database():
    """Check if the database exists."""
    db_path = Path('./knowledge_graph.db')
    if not db_path.exists():
        print("❌ Database not found!")
        print("\n📋 To create the database:")
        print("1. Run the Jupyter notebook: jupyter notebook create_database.ipynb")
        print("2. Or execute all cells in create_database.ipynb")
        print("\nThe database will be created from the CSV files in:")
        print("../2025_10_11_13_36_15_KnowledgeGraph_FRED_Analysis/outputs/csv/")
        return False
    else:
        print(f"✅ Database found: {db_path.absolute()}")
        print(f"   Size: {db_path.stat().st_size / 1024 / 1024:.2f} MB")
        return True

def check_requirements():
    """Check if required packages are installed."""
    print("🔍 Checking requirements...")

    required_packages = [
        'dash', 'plotly', 'pandas', 'numpy', 'duckdb', 'networkx', 'sklearn'
    ]

    missing_packages = []

    for package in required_packages:
        try:
            __import__(package)
            print(f"  ✅ {package}")
        except ImportError:
            print(f"  ❌ {package}")
            missing_packages.append(package)

    if missing_packages:
        print(f"\n❌ Missing packages: {', '.join(missing_packages)}")
        print("📦 Install with: pip install -r requirements.txt")
        return False
    else:
        print("✅ All requirements satisfied!")
        return True

def main():
    """Main launcher function."""
    print("🚀 Knowledge Graph Dashboard Launcher")
    print("=" * 50)

    # Check current directory
    if not Path('./dashboard.py').exists():
        print("❌ Please run this script from the app directory!")
        print("   cd app && python run_app.py")
        sys.exit(1)

    # Check requirements
    if not check_requirements():
        sys.exit(1)

    # Check database
    if not check_database():
        print("\n⚠️  You can still run the dashboard, but it will show 'Data Not Available'")
        response = input("\nDo you want to continue anyway? (y/N): ")
        if response.lower() != 'y':
            sys.exit(1)

    print("\n🌐 Starting Knowledge Graph Dashboard...")
    print("📍 URL: http://localhost:8050")
    print("🛑 Press Ctrl+C to stop")
    print("=" * 50)

    # Import and run the dashboard
    try:
        from dashboard import app
        app.run_server(debug=False, host='0.0.0.0', port=8050)
    except KeyboardInterrupt:
        print("\n👋 Dashboard stopped by user")
    except Exception as e:
        print(f"\n❌ Error running dashboard: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()