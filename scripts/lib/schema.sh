#!/usr/bin/env bash
# schema.sh — single source of truth for the ledger schema.
# ensure_schema DB_PATH: CREATE-if-missing plus idempotent column migrations for
# pre-existing DBs. Always returns 0 and stays silent: it is called from the
# Stop/SessionStart hooks, which must never fail or block the session.
#
# Sourced by setup.sh, backfill.sh, and persist-session.sh; must stay
# side-effect-free beyond the DB it is handed.

ensure_schema() {
  local db="$1"
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    project TEXT,
    model TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cache_read_tokens INTEGER DEFAULT 0,
    cache_creation_tokens INTEGER DEFAULT 0,
    cost_usd REAL,
    co2_grams REAL,
    started_at TEXT,
    ended_at TEXT,
    source TEXT DEFAULT 'live',
    methodology_version INTEGER DEFAULT 1,
    excluded INTEGER DEFAULT 0,
    energy_wh REAL,
    water_ml REAL,
    embodied_gco2e REAL
  ); CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN methodology_version INTEGER DEFAULT 1;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN excluded INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN energy_wh REAL;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN water_ml REAL;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN embodied_gco2e REAL;" 2>/dev/null || true
  # One row per (session, calendar day the session actually spent tokens on).
  # A session that ran past midnight has two. Written by the Stop hook from the
  # transcript's own per-message timestamps, so this is a grouping of measured
  # usage and not an apportionment — see lib/day-split.sh for why it matters.
  # Sessions recorded before this table existed simply have no rows here, and
  # every reader falls back to charging them to the day they began.
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS session_days (
    session_id TEXT NOT NULL,
    day TEXT NOT NULL,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cache_read_tokens INTEGER DEFAULT 0,
    cache_creation_tokens INTEGER DEFAULT 0,
    co2_grams REAL DEFAULT 0,
    energy_wh REAL DEFAULT 0,
    water_ml REAL DEFAULT 0,
    embodied_gco2e REAL DEFAULT 0,
    PRIMARY KEY (session_id, day)
  ); CREATE INDEX IF NOT EXISTS idx_session_days_day ON session_days(day);" 2>/dev/null || true
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS offsets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    purchase_date TEXT NOT NULL,
    vendor TEXT NOT NULL,
    pathway TEXT NOT NULL,
    kg_co2e REAL NOT NULL CHECK (kg_co2e > 0),
    usd REAL NOT NULL CHECK (usd >= 0),
    category TEXT NOT NULL CHECK (category IN ('removal', 'prevention')),
    payer TEXT NOT NULL,
    receipt_path TEXT,
    receipt_sha256 TEXT,
    verified INTEGER NOT NULL DEFAULT 1,
    retirement_id TEXT,
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  );" 2>/dev/null || true
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS receipt_blobs (
    offset_id INTEGER PRIMARY KEY REFERENCES offsets(id),
    filename TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    content BLOB NOT NULL,
    extracted_text TEXT,
    stored_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  );" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE receipt_blobs ADD COLUMN extracted_text TEXT;" 2>/dev/null || true
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS donations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    donation_date TEXT NOT NULL,
    org TEXT NOT NULL,
    usd REAL NOT NULL CHECK (usd > 0),
    payer TEXT NOT NULL,
    receipt_path TEXT,
    receipt_sha256 TEXT,
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  );" 2>/dev/null || true
  return 0
}
