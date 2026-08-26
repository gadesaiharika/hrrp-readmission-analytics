"""Database connection and SQL execution helpers."""

from __future__ import annotations

import os
import re
from pathlib import Path

import psycopg2

REPO_ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = REPO_ROOT / "sql"


def _load_dotenv():
    """Read .env into os.environ without adding a dependency.

    Values already set in the real environment win, so CI and shell exports
    override the file rather than the other way round.
    """
    env_file = REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def settings() -> dict:
    _load_dotenv()
    return {
        "host": os.getenv("PGHOST", "localhost"),
        "port": int(os.getenv("PGPORT", "5432")),
        "dbname": os.getenv("PGDATABASE", "readmission_db"),
        "user": os.getenv("PGUSER", "postgres"),
        "password": os.getenv("PGPASSWORD", ""),
    }


def connect(dbname: str | None = None, autocommit: bool = False):
    cfg = settings()
    if dbname:
        cfg["dbname"] = dbname
    conn = psycopg2.connect(**cfg)
    conn.autocommit = autocommit
    return conn


def ensure_database():
    """Create the target database if it does not exist yet.

    Connects to `postgres` to do it, so a fresh clone needs no manual createdb.

    Deliberately does NOT use `with connect(...) as conn`. psycopg2's connection
    context manager opens a transaction block even when autocommit is set, and
    PostgreSQL refuses CREATE DATABASE inside one. The connection is managed by
    hand here so the statement runs genuinely unwrapped.
    """
    cfg = settings()
    target = cfg["dbname"]

    # Identifier cannot be parameterised; the name comes from our own config,
    # but validate it anyway rather than interpolating blindly.
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", target):
        raise ValueError(f"unsafe database name: {target!r}")

    conn = connect(dbname="postgres", autocommit=True)
    try:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (target,))
        if cur.fetchone():
            return False
        cur.execute(f'CREATE DATABASE "{target}"')
        return True
    finally:
        conn.close()


def run_sql_file(conn, filename: str):
    """Execute one .sql file from sql/ as a single transaction."""
    path = SQL_DIR / filename
    sql = path.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    return path.name


def query(conn, sql: str, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [d[0] for d in cur.description]
        return cols, cur.fetchall()


def scalar(conn, sql: str, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
        return row[0] if row else None
