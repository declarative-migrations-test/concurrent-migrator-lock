# Concurrency contract

The certification launches multiple independent `dpm apply` processes against one target while the current production implementation does not yet hold a database-wide lock across planning, execution, and final verification.

The initial wave is intentionally adversarial. PostgreSQL commonly permits one contender to complete while the rest receive duplicate-object errors. CockroachDB may reject every simultaneous schema-change contender. The test therefore does **not** equate “at least one concurrent process exited zero” with safety.

The non-negotiable contract is:

1. every contender records an exit status;
2. every failed contender produces an actionable diagnostic and does not panic or crash;
3. a serialized recovery apply succeeds after the concurrent wave;
4. `dpm verify` and `dpm diff --fail-on-diff` prove that the target converged;
5. a second concurrent no-op wave succeeds completely;
6. the final catalog remains converged.

This proves recovery and eventual consistency under real DDL contention without claiming that the current implementation serializes migrations. Once production-wide locking lands, this repository should tighten the initial-wave assertions to require deterministic lock acquisition, timeout behavior, owner failure recovery, and exactly one active migration executor.
