"""Portable research paths and non-destructive database creation checks.

Relative settings resolve from this repository, never the process cwd.
RESEARCH_REPO_ROOT may select another checkout (use an absolute path).
KNOWLEDGE_GRAPH_CSV_DIR defaults to the analysis exports in knowledgegraph/.
KNOWLEDGE_GRAPH_DB_PATH uses dashboard-module-relative overrides, matching Dash.
"""

import os
from pathlib import Path


_DEFAULT_ROOT = Path(__file__).resolve().parents[1]
REQUIRED_GRAPH_CSVS = (
    "knowledge_graph_nodes.csv", "knowledge_graph_edges.csv",
    "correlations_detailed.csv", "leadership_analysis.csv",
)


def repo_root():
    configured = os.environ.get("RESEARCH_REPO_ROOT")
    if configured:
        root = Path(configured).expanduser()
        if not root.is_absolute():
            raise ValueError("Set RESEARCH_REPO_ROOT to an absolute checkout path.")
        return root.resolve()
    return _DEFAULT_ROOT


def research_path(default, env_var=None, override_base=None):
    configured = os.environ.get(env_var) if env_var else None
    path = Path(configured or default).expanduser()
    base = override_base if configured and override_base is not None else repo_root()
    if not path.is_absolute():
        path = Path(base) / path
    return path.resolve()


def knowledge_graph_paths():
    return (
        research_path("knowledgegraph", "KNOWLEDGE_GRAPH_CSV_DIR"),
        research_path("knowledgegraph/app/knowledge_graph.db", "KNOWLEDGE_GRAPH_DB_PATH",
                      override_base=repo_root() / "knowledgegraph/app"),
    )


def validate_new_database(csv_dir, db_path):
    """Require complete inputs and a fresh destination; never remove sidecars."""
    csv_dir, db_path = Path(csv_dir), Path(db_path)
    existing = sorted(db_path.parent.glob(db_path.name + ".*"))
    if db_path.exists() or db_path.is_symlink() or existing:
        raise FileExistsError(
            f"Database destination or sidecar/backup already exists: {db_path}. "
            "Close other database users and set KNOWLEDGE_GRAPH_DB_PATH to a new "
            "destination. Existing databases, WAL, locks and backups are left intact."
        )
    missing = [name for name in REQUIRED_GRAPH_CSVS if not (csv_dir / name).is_file()]
    if missing:
        raise FileNotFoundError(
            f"Missing knowledge graph CSV inputs in {csv_dir}: {', '.join(missing)}. "
            "Export the analysis CSVs or set KNOWLEDGE_GRAPH_CSV_DIR to their directory."
        )


def connect_new_database(csv_dir, db_path, connector):
    """Open a fresh destination once, with actionable errors and no recovery writes."""
    validate_new_database(csv_dir, db_path)
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        return connector(str(db_path))
    except Exception as error:
        raise RuntimeError(
            f"Cannot open knowledge graph database at {db_path}: {error}. "
            "Close other database users, check permissions, or select a new "
            "KNOWLEDGE_GRAPH_DB_PATH. Do not delete WAL, lock or backup files to unlock it."
        ) from error
