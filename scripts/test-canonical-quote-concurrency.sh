#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:quote-concurrency@localhost:5432/postgres}"
PG_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
CONTENDERS="${CONTENDERS:-8}"
DB="canonical_quote_concurrency_pg${PG_MAJOR}"
TARGET="postgres://postgres:quote-concurrency@localhost:5432/${DB}"
RUNTIME="postgres://canonical_api_server:runtime-concurrency@localhost:5432/${DB}"
SCHEMA="$API_DIR/db/schema.sql"
GRANTS="$API_DIR/db/runtime-grants.sql"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/artifacts/canonical-quote-concurrency/pg${PG_MAJOR}"
mkdir -p "$LOGS"

cleanup() {
  psql "$ADMIN" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$ADMIN" -v ON_ERROR_STOP=1 \
    -c "DROP ROLE IF EXISTS canonical_api_server" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

psql "$ADMIN" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE ROLE canonical_api_server
  LOGIN
  PASSWORD 'runtime-concurrency'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION
  NOBYPASSRLS;
CREATE DATABASE ${DB};
SQL

run_wave() {
  local phase="$1"
  local count="$2"
  local pids=()

  for i in $(seq 1 "$count"); do
    (
      set +e
      "$DPM" apply \
        --source-sql "$SCHEMA" \
        --target "$TARGET" \
        --shadow "$ADMIN" \
        --yes \
        >"$LOGS/${phase}-${i}.out" \
        2>"$LOGS/${phase}-${i}.err"
      echo "$?" >"$LOGS/${phase}-${i}.status"
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  local successes=0
  local failures=0
  for i in $(seq 1 "$count"); do
    local prefix="$LOGS/${phase}-${i}"
    if [[ ! -s "${prefix}.status" ]]; then
      echo "${phase}: contender ${i} did not record an exit status" >&2
      exit 1
    fi

    local status
    status="$(cat "${prefix}.status")"
    if [[ "$status" -eq 0 ]]; then
      successes=$((successes + 1))
      continue
    fi

    failures=$((failures + 1))
    if [[ ! -s "${prefix}.err" && ! -s "${prefix}.out" ]]; then
      echo "${phase}: failed contender ${i} produced no diagnostic" >&2
      exit 1
    fi
    if grep -Eqi 'panicked at|stack backtrace|segmentation fault|memory safety' \
      "${prefix}.err" "${prefix}.out"; then
      echo "${phase}: contender ${i} crashed" >&2
      exit 1
    fi
  done

  if [[ $((successes + failures)) -ne "$count" ]]; then
    echo "${phase}: lost contender results" >&2
    exit 1
  fi
  if [[ "$phase" == noop-* && "$failures" -ne 0 ]]; then
    echo "${phase}: converged no-op wave had ${failures} failures" >&2
    exit 1
  fi

  printf '%s\n' \
    "postgres_major=${PG_MAJOR}" \
    "phase=${phase}" \
    "contenders=${count}" \
    "successes=${successes}" \
    "failures=${failures}" \
    >"$LOGS/${phase}-summary.txt"
  echo "PostgreSQL ${PG_MAJOR} ${phase}: successes=${successes} failures=${failures}"
}

converge() {
  local phase="$1"
  "$DPM" apply \
    --source-sql "$SCHEMA" \
    --target "$TARGET" \
    --shadow "$ADMIN" \
    --yes \
    >"$LOGS/${phase}-recovery.out" \
    2>"$LOGS/${phase}-recovery.err"
  "$DPM" diff \
    --source-sql "$SCHEMA" \
    --target "$TARGET" \
    --shadow "$ADMIN" \
    --fail-on-diff \
    >"$LOGS/${phase}-diff.sql"
  "$DPM" verify \
    --source-sql "$SCHEMA" \
    --target "$TARGET" \
    --shadow "$ADMIN" \
    >"$LOGS/${phase}-verify.out" \
    2>"$LOGS/${phase}-verify.err"
}

# Exercise an empty-database deployment race. Individual DDL contenders may be
# rejected, but none may crash and a serialized recovery must always converge.
run_wave initial "$CONTENDERS"
converge initial
psql "$TARGET" -v ON_ERROR_STOP=1 -f "$GRANTS" >"$LOGS/runtime-grants.out"

psql "$TARGET" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO canonical_context (
  id, owner_subject, name, context_markdown, context_json
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  'concurrency-owner',
  'Concurrency fixture',
  '# Concurrency fixture',
  '{"region":"us"}'::jsonb
);
INSERT INTO canonical_quote (
  id,
  owner_subject,
  context_record_id,
  request_json,
  application_context_markdown,
  context_snapshot_markdown,
  context_snapshot_json,
  gemini_model,
  status
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'concurrency-owner',
  '11111111-1111-4111-8111-111111111111',
  '{"frameworks":["soc2"],"organization":{"employee_count":42,"industry":"Software","legal_name":"Concurrency Fixture"}}'::jsonb,
  '# application',
  '# Concurrency fixture',
  '{"region":"us"}'::jsonb,
  'gemini-3.6-pro',
  'queued'
);
INSERT INTO canonical_quote_event (
  quote_id, owner_subject, status, details_json
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'concurrency-owner',
  'queued',
  '{}'::jsonb
);
SQL

# Once converged, every simultaneous no-op apply must succeed.
run_wave noop-after-initial "$CONTENDERS"
converge noop-after-initial

# Exercise a real repair race against a database containing durable quote data.
psql "$TARGET" -v ON_ERROR_STOP=1 \
  -c "DROP POLICY canonical_quote_owner_policy ON canonical_quote" >/dev/null
run_wave policy-repair "$CONTENDERS"
converge policy-repair
run_wave noop-after-repair "$CONTENDERS"
converge noop-after-repair

# The race and repair must preserve data and restore all security boundaries.
test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM canonical_quote WHERE id='22222222-2222-4222-8222-222222222222'")" = "1"
test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='canonical_quote' AND policyname='canonical_quote_owner_policy'")" = "1"
test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM pg_class WHERE oid IN ('canonical_context'::regclass,'canonical_quote'::regclass,'canonical_quote_event'::regclass,'canonical_model_attempt'::regclass) AND relrowsecurity AND relforcerowsecurity")" = "4"
test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM pg_constraint WHERE conname IN ('canonical_quote_context_owner_fk','canonical_quote_event_quote_owner_fk','canonical_model_attempt_quote_owner_fk') AND convalidated")" = "3"
test "$(psql "$TARGET" -Atqc "SELECT NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls FROM pg_roles WHERE rolname='canonical_api_server'")" = "t"
test "$(psql "$RUNTIME" -Atqc "SELECT has_table_privilege(current_user, 'canonical_quote', 'DELETE')")" = "f"

owner_count="$(psql "$RUNTIME" -Atv ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT set_config('app.current_subject', 'concurrency-owner', true);
SELECT count(*) FROM canonical_quote;
COMMIT;
SQL
)"
owner_count="$(printf '%s\n' "$owner_count" | grep -E '^[0-9]+$' | tail -1)"
test "$owner_count" = "1"

other_count="$(psql "$RUNTIME" -Atv ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT set_config('app.current_subject', 'other-owner', true);
SELECT count(*) FROM canonical_quote;
COMMIT;
SQL
)"
other_count="$(printf '%s\n' "$other_count" | grep -E '^[0-9]+$' | tail -1)"
test "$other_count" = "0"

printf 'Canonical quote concurrent migration certification passed on PostgreSQL %s.\n' "$PG_MAJOR"
