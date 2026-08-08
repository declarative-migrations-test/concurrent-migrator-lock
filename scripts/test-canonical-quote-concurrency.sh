#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:quote-concurrency@localhost:5432/postgres}"
PG_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
CONTENDERS="${CONTENDERS:-8}"
ROLE_PASSWORD="${TEST_ROLE_PASSWORD:-quote-concurrency}"

if [[ ! "$PG_MAJOR" =~ ^(17|18)$ ]]; then
  echo "unsupported PostgreSQL test major: $PG_MAJOR" >&2
  exit 1
fi
if [[ ! "$CONTENDERS" =~ ^[0-9]+$ ]] || ((CONTENDERS < 2 || CONTENDERS > 16)); then
  echo "CONTENDERS must be between 2 and 16" >&2
  exit 1
fi

DB="canonical_quote_concurrency_pg${PG_MAJOR}"
TARGET_ADMIN="postgres://postgres:${ROLE_PASSWORD}@localhost:5432/${DB}"
MIGRATOR="postgres://canonical_cloud__quote__migrator:${ROLE_PASSWORD}@localhost:5432/${DB}"
API_RUNTIME="postgres://canonical_cloud__quote__api_rw:${ROLE_PASSWORD}@localhost:5432/${DB}"
WEB_RUNTIME="postgres://canonical_cloud__quote__web_ro:${ROLE_PASSWORD}@localhost:5432/${DB}"
SCHEMA="$API_DIR/db/schema.sql"
BOOTSTRAP="$API_DIR/db/bootstrap.sql"
GRANTS="$API_DIR/db/grants.sql"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/artifacts/canonical-quote-concurrency/pg${PG_MAJOR}"
mkdir -p "$LOGS"

for required in "$SCHEMA" "$BOOTSTRAP" "$GRANTS"; do
  if [[ ! -f "$required" ]]; then
    echo "missing Canonical database source: $required" >&2
    exit 1
  fi
done

cleanup() {
  psql "$ADMIN" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
  for role in \
    canonical_cloud__quote__web_ro \
    canonical_cloud__quote__api_rw \
    canonical_cloud__quote__migrator
  do
    psql "$ADMIN" -v ON_ERROR_STOP=1 \
      -c "DROP ROLE IF EXISTS ${role}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
cleanup

psql "$ADMIN" -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${DB}" >/dev/null
psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 \
  -f "$BOOTSTRAP" >"$LOGS/bootstrap.out"
psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 -v role_password="$ROLE_PASSWORD" \
  >"$LOGS/test-role-passwords.out" <<'SQL'
ALTER ROLE canonical_cloud__quote__migrator PASSWORD :'role_password';
ALTER ROLE canonical_cloud__quote__api_rw PASSWORD :'role_password';
ALTER ROLE canonical_cloud__quote__web_ro PASSWORD :'role_password';
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
        --target "$MIGRATOR" \
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

  local successes=0 failures=0
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
    --target "$MIGRATOR" \
    --shadow "$ADMIN" \
    --yes \
    >"$LOGS/${phase}-recovery.out" \
    2>"$LOGS/${phase}-recovery.err"
  psql "$TARGET_ADMIN" -v ON_ERROR_STOP=1 \
    -f "$GRANTS" >"$LOGS/${phase}-grants.out"
  "$DPM" diff \
    --source-sql "$SCHEMA" \
    --target "$MIGRATOR" \
    --shadow "$ADMIN" \
    --fail-on-diff \
    >"$LOGS/${phase}-diff.sql"
  "$DPM" verify \
    --source-sql "$SCHEMA" \
    --target "$MIGRATOR" \
    --shadow "$ADMIN" \
    >"$LOGS/${phase}-verify.out" \
    2>"$LOGS/${phase}-verify.err"
}

# Empty-namespace race: contenders may be rejected by DDL contention, but none
# may crash and a serialized recovery must converge the exact Canonical schema.
run_wave initial "$CONTENDERS"
converge initial

psql "$API_RUNTIME" -v ON_ERROR_STOP=1 >"$LOGS/seed.out" <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'concurrency-owner';
INSERT INTO canonical_cloud__quote.canonical_context (
  id, owner_subject, name, context_markdown, context_json
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  'concurrency-owner',
  'Concurrency fixture',
  '# Synthetic concurrency context',
  '{"environment":"test","contains_secrets":false}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_quote (
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
  '{"organizationName":"Concurrency Fixture","contactName":"Test Operator","contactEmail":"test@example.invalid","employeeCount":42,"frameworks":["soc2_type_2","nist_800_53"],"currentStage":"readiness","infrastructure":["aws"],"dataSensitivity":["confidential"],"hasSecurityProgram":true,"hasPolicies":true,"hasRiskAssessment":false,"hasIncidentResponsePlan":true,"hasVendorManagement":false,"answersVersion":1}'::jsonb,
  '# Synthetic application policy',
  '# Synthetic concurrency context',
  '{"environment":"test","contains_secrets":false}'::jsonb,
  'gemini-3.6-pro',
  'queued'
);
INSERT INTO canonical_cloud__quote.canonical_quote_event (
  quote_id, owner_subject, status, details_json
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'concurrency-owner',
  'queued',
  '{"analysis_available":false}'::jsonb
);
COMMIT;
SQL

# Once converged, every simultaneous no-op apply must succeed.
run_wave noop-after-initial "$CONTENDERS"
converge noop-after-initial

# Exercise a policy-repair race while durable quote data is present.
psql "$MIGRATOR" -v ON_ERROR_STOP=1 \
  -c "DROP POLICY canonical_quote_owner_policy ON canonical_cloud__quote.canonical_quote" \
  >"$LOGS/drop-policy.out"
run_wave policy-repair "$CONTENDERS"
converge policy-repair
run_wave noop-after-repair "$CONTENDERS"
converge noop-after-repair

assert_scalar() {
  local expected="$1" query="$2" observed
  observed="$(psql "$TARGET_ADMIN" -Atq -v ON_ERROR_STOP=1 -c "$query")"
  if [[ "$observed" != "$expected" ]]; then
    echo "assertion failed: expected $expected, observed $observed" >&2
    echo "query: $query" >&2
    exit 1
  fi
}

assert_scalar 1 "SELECT count(*) FROM canonical_cloud__quote.canonical_quote WHERE id='22222222-2222-4222-8222-222222222222'"
assert_scalar 1 "SELECT count(*) FROM canonical_cloud__quote.canonical_quote_event WHERE quote_id='22222222-2222-4222-8222-222222222222'"
assert_scalar 1 "SELECT count(*) FROM pg_policies WHERE schemaname='canonical_cloud__quote' AND tablename='canonical_quote' AND policyname='canonical_quote_owner_policy'"
assert_scalar 4 "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='canonical_cloud__quote' AND c.relname IN ('canonical_context','canonical_quote','canonical_quote_event','canonical_model_attempt') AND c.relrowsecurity AND c.relforcerowsecurity"
assert_scalar 0 "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='canonical_cloud__quote' AND c.relkind IN ('r','p','S') AND pg_get_userbyid(c.relowner)<>'canonical_cloud__quote__migrator'"
assert_scalar canonical_cloud__quote__migrator "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='canonical_cloud__quote'"
assert_scalar 0 "SELECT count(*) FROM pg_roles WHERE rolname IN ('canonical_cloud__quote__migrator','canonical_cloud__quote__api_rw','canonical_cloud__quote__web_ro') AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)"
assert_scalar f "SELECT has_schema_privilege('canonical_cloud__quote__api_rw','canonical_cloud__quote','CREATE')"
assert_scalar f "SELECT has_schema_privilege('canonical_cloud__quote__api_rw','public','CREATE')"
assert_scalar f "SELECT has_table_privilege('canonical_cloud__quote__api_rw','canonical_cloud__quote.canonical_quote','DELETE')"
assert_scalar f "SELECT has_schema_privilege('canonical_cloud__quote__web_ro','canonical_cloud__quote','USAGE')"
assert_scalar f "SELECT has_table_privilege('canonical_cloud__quote__web_ro','canonical_cloud__quote.canonical_quote','SELECT')"

owner_count="$(psql "$API_RUNTIME" -Atq -v ON_ERROR_STOP=1 <<'SQL' | grep -E '^[0-9]+$' | tail -1
BEGIN;
SET LOCAL app.current_subject = 'concurrency-owner';
SELECT count(*) FROM canonical_cloud__quote.canonical_quote;
ROLLBACK;
SQL
)"
other_count="$(psql "$API_RUNTIME" -Atq -v ON_ERROR_STOP=1 <<'SQL' | grep -E '^[0-9]+$' | tail -1
BEGIN;
SET LOCAL app.current_subject = 'other-owner';
SELECT count(*) FROM canonical_cloud__quote.canonical_quote;
ROLLBACK;
SQL
)"
test "$owner_count" = "1"
test "$other_count" = "0"

if psql "$WEB_RUNTIME" -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM canonical_cloud__quote.canonical_quote" \
  >"$LOGS/web-read.out" 2>"$LOGS/web-read.err"
then
  echo "web role unexpectedly read Canonical quote rows" >&2
  exit 1
fi

grep -Eqi 'permission denied|no permission' "$LOGS/web-read.err"

printf 'Canonical quote concurrent migration certification passed on PostgreSQL %s.\n' "$PG_MAJOR"
