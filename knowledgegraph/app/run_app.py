#!/usr/bin/env python3
"""
Knowledge Graph Dashboard Launcher

This script checks requirements and launches the dashboard application.
"""

import sys

if __package__:
    from .dashboard_config import APP_DIR, DB_PATH, PORT, DEBUG, resolve_db_path
else:
    from dashboard_config import APP_DIR, DB_PATH, PORT, DEBUG, resolve_db_path

def check_database(db_path=None):
    """Check if the database exists."""
    db_path = resolve_db_path(DB_PATH if db_path is None else db_path)
    if not db_path.is_file():
        print(f"❌ Database not found: {db_path}")
        print("\n📋 To create the database:")
        print(f"1. Run the Jupyter notebook: jupyter notebook {APP_DIR / 'create_database.ipynb'}")
        print("2. Or execute all cells in create_database.ipynb")
        print("\nThe database will be created from the CSV files in:")
        print("Repository knowledgegraph/ exports, or KNOWLEDGE_GRAPH_CSV_DIR.")
        return False
    else:
        print(f"✅ Database found: {db_path.absolute()}")
        print(f"   Size: {db_path.stat().st_size / 1024 / 1024:.2f} MB")
        return True

def check_requirements():
    """Check if required packages are installed."""
    print("🔍 Checking requirements...")

    required_packages = [
        'dash', 'plotly', 'pandas', 'numpy', 'duckdb', 'networkx', 'scipy'
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
        print(f"📦 Install with: pip install -r {APP_DIR / 'requirements.txt'}")
        return False
    else:
        print("✅ All requirements satisfied!")
        return True

def main():
    """Main launcher function."""
    print("🚀 Knowledge Graph Dashboard Launcher")
    print("=" * 50)

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
    print(f"📍 URL: http://localhost:{PORT}")
    print("🛑 Press Ctrl+C to stop")
    print("=" * 50)

    # Import and run the dashboard
    try:
        if __package__:
            from .dashboard import app
        else:
            from dashboard import app
        app.run(debug=DEBUG, host='0.0.0.0', port=PORT)
    except KeyboardInterrupt:
        print("\n👋 Dashboard stopped by user")
    except Exception as e:
        print(f"\n❌ Error running dashboard: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
