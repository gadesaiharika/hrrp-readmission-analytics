#!/usr/bin/env bash
# =====================================================================
# 02_load_synthea.sh
# Loads Synthea CSVs into the raw_* staging tables.
#
# Usage:
#   bash 02_load_synthea.sh /absolute/path/to/synthea/output/csv
#
# Prerequisites:
#   - PostgreSQL running locally
#   - Database 'readmission_db' created
#   - 01_create_staging.sql already executed
#   - psql client on PATH
# =====================================================================

set -euo pipefail

CSV_DIR="${1:?Usage: $0 /path/to/synthea/output/csv}"
DB="${PGDATABASE:-readmission_db}"

if [[ ! -d "$CSV_DIR" ]]; then
  echo "ERROR: directory not found: $CSV_DIR" >&2
  exit 1
fi

echo "Loading Synthea CSVs from: $CSV_DIR"
echo "Target database:           $DB"
echo "----------------------------------------"

load_table () {
  local table="$1"
  local file="$2"
  local fullpath="$CSV_DIR/$file"
  if [[ ! -f "$fullpath" ]]; then
    echo "  SKIP $table   (file not found: $fullpath)"
    return
  fi
  echo "  LOAD $table   from $file"
  psql -d "$DB" -v ON_ERROR_STOP=1 -c \
    "\copy $table FROM '$fullpath' WITH (FORMAT CSV, HEADER true, NULL '');"
}

# Truncate before reload (idempotent)
psql -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
TRUNCATE
  raw_patients, raw_encounters, raw_conditions, raw_procedures,
  raw_payers, raw_providers, raw_organizations
  RESTART IDENTITY;
SQL

# Load in dependency order (parents first if FKs existed; here all raw_* are flat)
load_table raw_organizations  organizations.csv
load_table raw_providers      providers.csv
load_table raw_payers         payers.csv
load_table raw_patients       patients.csv
load_table raw_encounters     encounters.csv
load_table raw_conditions     conditions.csv
load_table raw_procedures     procedures.csv

echo "----------------------------------------"
echo "Row counts after load:"
psql -d "$DB" -At -F $'\t' -c "
  SELECT 'patients',      COUNT(*) FROM raw_patients      UNION ALL
  SELECT 'encounters',    COUNT(*) FROM raw_encounters    UNION ALL
  SELECT 'conditions',    COUNT(*) FROM raw_conditions    UNION ALL
  SELECT 'procedures',    COUNT(*) FROM raw_procedures    UNION ALL
  SELECT 'payers',        COUNT(*) FROM raw_payers        UNION ALL
  SELECT 'providers',     COUNT(*) FROM raw_providers     UNION ALL
  SELECT 'organizations', COUNT(*) FROM raw_organizations
  ORDER BY 1;"
echo "Done."
