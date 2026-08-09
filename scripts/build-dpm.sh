#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/vendor/declarative-postgres-migrate.rs"
expected="$(python3 - "$root/bootstrap-manifest.json" <<'PY'
import json
import re
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
commit = manifest["production_dependency"]["commit"]
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("bootstrap manifest does not contain an exact DPM commit")
print(commit)
PY
)"
actual="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual" != "$expected" ]]; then
  echo "production dependency drift: expected $expected, observed $actual" >&2
  exit 1
fi
cargo build --locked --release --manifest-path "$source_dir/Cargo.toml" --bin dpm
printf '%s\n' "$source_dir/target/release/dpm"
