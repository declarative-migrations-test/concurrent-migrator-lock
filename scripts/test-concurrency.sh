#!/usr/bin/env bash
set -euo pipefail
DPM="${DPM_BIN:?DPM_BIN is required}"
PG_ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
CR_ADMIN="${COCKROACH_ADMIN_URL:-postgresql://root@localhost:26257/defaultdb?sslmode=disable}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logs="$root/artifacts/concurrency"
mkdir -p "$logs"

run_wave() {
  local engine="$1" target="$2" admin="$3" count="$4" phase="$5"
  local pids=()
  for i in $(seq 1 "$count"); do
    (
      set +e
      "$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --yes >"$logs/${engine}-${phase}-${i}.out" 2>"$logs/${engine}-${phase}-${i}.err"
      echo "$?" >"$logs/${engine}-${phase}-${i}.status"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  local successes=0 failures=0
  for status_file in "$logs/${engine}-${phase}-"*.status; do
    status="$(cat "$status_file")"
    if [[ "$status" -eq 0 ]]; then
      successes=$((successes + 1))
    else
      failures=$((failures + 1))
      prefix="${status_file%.status}"
      if [[ ! -s "${prefix}.err" && ! -s "${prefix}.out" ]]; then
        echo "failed contender produced no diagnostic: $prefix" >&2
        exit 1
      fi
      if grep -Eqi 'panicked at|stack backtrace|segmentation fault' "${prefix}.err" "${prefix}.out"; then
        echo "failed contender crashed: $prefix" >&2
        exit 1
      fi
    fi
  done
  if [[ "$phase" == "initial" && "$successes" -lt 1 ]]; then
    echo "$engine initial wave had no successful contender" >&2
    exit 1
  fi
  if [[ "$phase" == "idempotent" && "$failures" -ne 0 ]]; then
    echo "$engine idempotent wave had $failures failures" >&2
    exit 1
  fi
  echo "$engine $phase wave: successes=$successes failures=$failures"
}

certify_engine() {
  local engine="$1" admin="$2" target="$3" create_sql="$4" drop_sql="$5" count="$6"
  eval "$drop_sql" >/dev/null 2>&1 || true
  eval "$create_sql" >/dev/null
  "$DPM" apply --source-sql "$root/fixtures/v1.sql" --target "$target" --shadow "$admin" --yes
  run_wave "$engine" "$target" "$admin" "$count" initial
  "$DPM" verify --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin"
  run_wave "$engine" "$target" "$admin" "$count" idempotent
  "$DPM" diff --source-sql "$root/fixtures/v2.sql" --target "$target" --shadow "$admin" --fail-on-diff >/dev/null
  eval "$drop_sql" >/dev/null 2>&1 || true
}

trap 'psql "$PG_ADMIN" -c "DROP DATABASE IF EXISTS dm_concurrent_pg WITH (FORCE)" >/dev/null 2>&1 || true; psql "$CR_ADMIN" -c "DROP DATABASE IF EXISTS dm_concurrent_cr CASCADE" >/dev/null 2>&1 || true' EXIT
certify_engine postgres "$PG_ADMIN" "postgres://postgres@localhost:5432/dm_concurrent_pg"   'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_concurrent_pg"'   'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_concurrent_pg WITH (FORCE)"' 6
certify_engine cockroach "$CR_ADMIN" "postgresql://root@localhost:26257/dm_concurrent_cr?sslmode=disable"   'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_concurrent_cr"'   'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_concurrent_cr CASCADE"' 4

echo "Concurrent migrator certification passed"
