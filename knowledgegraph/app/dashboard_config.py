"""Shared dashboard settings, independent of the process working directory."""

import os
from pathlib import Path


APP_DIR = Path(__file__).resolve().parent


def resolve_db_path(path=None):
    """Resolve explicit/environment paths relative to the dashboard module."""
    configured = path if path is not None else os.environ.get(
        "KNOWLEDGE_GRAPH_DB_PATH", "knowledge_graph.db"
    )
    db_path = Path(configured).expanduser()
    if not db_path.is_absolute():
        db_path = APP_DIR / db_path
    return db_path.resolve()


DB_PATH = resolve_db_path()
PORT = int(os.environ.get("KNOWLEDGE_GRAPH_PORT", "8051"))
DEBUG = os.environ.get("KNOWLEDGE_GRAPH_DEBUG", "false").lower() in {
    "1", "true", "yes", "on"
}
