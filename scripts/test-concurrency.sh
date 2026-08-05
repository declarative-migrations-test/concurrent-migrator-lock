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
      "$DPM" apply \
        --source-sql "$root/fixtures/v2.sql" \
        --target "$target" \
        --shadow "$admin" \
        --yes \
        >"$logs/${engine}-${phase}-${i}.out" \
        2>"$logs/${engine}-${phase}-${i}.err"
      echo "$?" >"$logs/${engine}-${phase}-${i}.status"
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  local successes=0 failures=0
  for i in $(seq 1 "$count"); do
    local prefix="$logs/${engine}-${phase}-${i}"
    local status_file="${prefix}.status"
    if [[ ! -s "$status_file" ]]; then
      echo "contender did not record an exit status: $prefix" >&2
      exit 1
    fi

    local status
    status="$(cat "$status_file")"
    if [[ "$status" -eq 0 ]]; then
      successes=$((successes + 1))
      continue
    fi

    failures=$((failures + 1))
    if [[ ! -s "${prefix}.err" && ! -s "${prefix}.out" ]]; then
      echo "failed contender produced no diagnostic: $prefix" >&2
      exit 1
    fi
    if grep -Eqi 'panicked at|stack backtrace|segmentation fault' \
      "${prefix}.err" "${prefix}.out"; then
      echo "failed contender crashed: $prefix" >&2
      exit 1
    fi
  done

  if [[ $((successes + failures)) -ne "$count" ]]; then
    echo "$engine $phase wave lost contender results" >&2
    exit 1
  fi
  if [[ "$phase" == "idempotent" && "$failures" -ne 0 ]]; then
    echo "$engine idempotent wave had $failures failures" >&2
    exit 1
  fi

  printf '%s\n' \
    "engine=$engine" \
    "phase=$phase" \
    "contenders=$count" \
    "successes=$successes" \
    "failures=$failures" \
    >"$logs/${engine}-${phase}-summary.txt"
  echo "$engine $phase wave: successes=$successes failures=$failures"
}

certify_engine() {
  local engine="$1" admin="$2" target="$3" create_sql="$4" drop_sql="$5" count="$6"
  eval "$drop_sql" >/dev/null 2>&1 || true
  eval "$create_sql" >/dev/null

  "$DPM" apply \
    --source-sql "$root/fixtures/v1.sql" \
    --target "$target" \
    --shadow "$admin" \
    --yes

  # PostgreSQL commonly leaves one winner, while CockroachDB can reject every
  # simultaneous DDL contender. Either outcome is acceptable only when every
  # failure is actionable and a serialized recovery apply converges afterward.
  run_wave "$engine" "$target" "$admin" "$count" initial

  "$DPM" apply \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --yes \
    >"$logs/${engine}-recovery.out" \
    2>"$logs/${engine}-recovery.err"
  "$DPM" verify \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin"
  "$DPM" diff \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --fail-on-diff \
    >"$logs/${engine}-recovery-diff.sql"

  # Once the recovery apply has converged the catalog, all no-op contenders
  # must succeed. This distinguishes recoverable DDL contention from a target
  # left in an unstable or permanently divergent state.
  run_wave "$engine" "$target" "$admin" "$count" idempotent
  "$DPM" diff \
    --source-sql "$root/fixtures/v2.sql" \
    --target "$target" \
    --shadow "$admin" \
    --fail-on-diff \
    >"$logs/${engine}-final-diff.sql"

  eval "$drop_sql" >/dev/null 2>&1 || true
}

trap 'psql "$PG_ADMIN" -c "DROP DATABASE IF EXISTS dm_concurrent_pg WITH (FORCE)" >/dev/null 2>&1 || true; psql "$CR_ADMIN" -c "DROP DATABASE IF EXISTS dm_concurrent_cr CASCADE" >/dev/null 2>&1 || true' EXIT

certify_engine \
  postgres \
  "$PG_ADMIN" \
  "postgres://postgres@localhost:5432/dm_concurrent_pg" \
  'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_concurrent_pg"' \
  'psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_concurrent_pg WITH (FORCE)"' \
  6

certify_engine \
  cockroach \
  "$CR_ADMIN" \
  "postgresql://root@localhost:26257/dm_concurrent_cr?sslmode=disable" \
  'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE dm_concurrent_cr"' \
  'psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS dm_concurrent_cr CASCADE"' \
  4

echo "Concurrent migrator certification passed"
