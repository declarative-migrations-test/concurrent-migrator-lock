# concurrent-migrator-lock

Concurrent migrator stress certification, final convergence proof, idempotent replay, and actionable contender failure classification.

This repository is part of the isolated `declarative-migrations-test` certification fleet. It pins the certification implementation as a Git submodule at `declarative-migrations/declarative-postgres-migrate.rs@a5e868acc0206fa9c3e91b5e36e0b1b111805885` and exercises real PostgreSQL and CockroachDB instances in GitHub Actions. The Canonical source contract independently records its production DPM revision `d05a7880987ddaa271fa88b52c787390ef12b899`, so the lane detects both application-contract drift and migration-engine regressions.

## Canonical quote concurrency lane

The Canonical lane checks out `canonical-cloud/canonical-api-server.rs@7987c05944df5c03ff2fcbeeedf2c8e79f973d75` exactly and verifies its schema digest, dedicated `canonical_cloud__quote` namespace, bootstrap/grants paths, minimum PostgreSQL major, source-declared DPM revision, and distinct certification DPM revision.

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

## Test-org harness metadata

Recorded by the `zed-pkg-test/test-org-fleet` bootstrapper (the generated harness under `scripts/`, `tests/` and `pyproject.toml`); the certification lane above remains the source of truth.

- **Readiness:** `ready`
- **Primary dependency strategy:** `matrix`
- **Scheduled cadence:** `17 5 * * *` UTC
- **Live infrastructure:** PostgreSQL, multi-process runner

Acceptance objectives:

1. Verify competing migrators, single ownership, killed-owner recovery, and duplicate-record prevention across the supported happy-path states and canonical fixtures.
2. Verify competing migrators, single ownership, killed-owner recovery, and duplicate-record prevention under retries, interruption, concurrency, offline operation, or partial failure.
3. Verify competing migrators, single ownership, killed-owner recovery, and duplicate-record prevention preserves authorization, idempotency, integrity, observability, and actionable failure classification.
