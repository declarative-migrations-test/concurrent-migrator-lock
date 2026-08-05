# Test plan

- Verify competing migrators, single ownership, killed-owner recovery, and duplicate-record prevention across the supported happy-path states and canonical fixtures.
- Verify competing migrators, single ownership, killed-owner recovery, and duplicate-record prevention under retries, interruption, concurrency, offline operation, or partial failure.
- Verify competing migrators, single ownership, killed-owner recovery, and duplicate-record prevention preserves authorization, idempotency, integrity, observability, and actionable failure classification.

## Classification

- product regression
- blocked dependency
- harness regression
