# concurrent-migrator-lock

Concurrent migrator stress certification, final convergence proof, idempotent replay, and actionable contender failure classification.

This repository is part of the isolated `declarative-migrations-test` certification fleet. It pins the production implementation as a Git submodule at `declarative-migrations/declarative-postgres-migrate.rs@d05a7880987ddaa271fa88b52c787390ef12b899` and exercises real PostgreSQL and CockroachDB instances in GitHub Actions.

## Canonical quote concurrency lane

The Canonical lane checks out the verified merge `canonical-cloud/canonical-api-server.rs@26967bed96b1b48ea846c3fd418018ea40f4b9e1` and verifies its schema digest, dedicated `canonical_cloud__quote` namespace, bootstrap/grants paths, minimum PostgreSQL major, and exact DPM revision.

On supported PostgreSQL 17 and 18 it runs eight concurrent applies for:

- an empty dedicated namespace after least-privilege role bootstrap;
- a converged all-success no-op wave;
- repair of a deliberately removed owner policy while durable quote data exists;
- a second all-success no-op wave after recovery.

The lane rejects contender crashes and missing diagnostics, requires deterministic serialized recovery, preserves synthetic context/quote/event rows, and revalidates schema ownership, forced RLS, API/web privilege separation, public-schema denial, and owner isolation.

No production database, Cloudflare, R2, Supabase, Kubernetes, or Gemini credential is available to this repository.

## Fleet

- `.github`
- `postgres-forward-rollback`
- `cockroach-forward-rollback`
- `cross-engine-compatibility`
- `concurrent-migrator-lock`
- `failure-injection-atomicity`
- `schema-drift-detection`
- `cli-mcp-contract`

## Local contract

```bash
git submodule update --init --recursive
scripts/build-dpm.sh
```

Every behavior change must add a regression, preserve exact dependency pinning, avoid credentials in source or logs, and land through a pull request.
