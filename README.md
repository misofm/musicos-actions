# Protocol Actions

Composable, custody-agnostic actions for the Miso protocol. Each top-level directory is an independently publishable Sui Move 2024 package:

- `composition_royalty_pool` creates and funds canonical Composition royalty pools.
- `recording_royalty_pool` creates and funds canonical Recording royalty pools.
- `release_revenue_distributor` splits Release revenue across its immutable tracklist.
- `composition_routed_stake` manages Composition-owned Recording-share stakes whose rewards are permissionlessly swept to the Composition pool.

Production APIs accept the protocol's raw admin capabilities. They contain no Vault dependency, installation state, package witness, plugin endpoint, or `entry` function. Created pools and routed stakes are returned unshared so callers can compose registration before sharing. Released principal is returned as a `Balance` so the caller controls its next safe destination.

## Capability invariant

Production construction issues exactly one share type, one `TreasuryCap`, and one protocol object for each Composition or Recording admin capability. Tests sometimes create multiple same-typed fixtures to exercise address-level defenses; those fixtures are intentionally stronger than the reachable production model and are not evidence that duplicate same-type production caps can exist.

## Accumulator redemption

Every accumulator redemption is a fixed "redeem all" crank: `redeem_all_and_distribute` (Release) and `redeem_all_and_deposit` (Composition and Recording) take the framework `AccumulatorRoot`, read `balance::settled_funds_value` on chain, and redeem exactly that snapshot. No action accepts a caller-chosen amount. A zero snapshot is an authorized no-op that emits no event, and the pool actions are likewise a no-op (with nothing redeemed) while the pool has no registered stake, so an item cranked in an earlier consensus commit, or an unstaked item, passes through a batched permissionless crank untouched.

The no-op holds only **across** consensus commits. `settled_funds_value` is written solely by the settlement system transaction, so it is constant for every transaction in a commit; redeeming the same object twice in one PTB, or from two crankers in the same commit, withdraws the snapshot twice and the network fails that whole transaction with `InsufficientFundsForWithdraw` (a transaction-level failure with no Move abort code). Operational requirements for any crank: include each object at most once per PTB, and treat `InsufficientFundsForWithdraw` as "retry next commit", not as a poisoned item.

## Accumulator testing

The Move VM covers the settled-value redemption path with a positive value through each module's private helper (exposed as `redeem_settled_value_and_*_for_testing`), including exact amounts, events, claims, batches with no-op items, and later redemption after a stake registers. It cannot expose a positive `settled_funds_value` consensus snapshot: `test_scenario` discards accumulator events at the end of every transaction and the framework offers no test-only settlement into `AccumulatorRoot`, so the public `redeem_all_*` entry is exercised only against a zero snapshot locally and its funded path is a Sui network E2E. The VM also does not check accumulator withdrawals against a balance, so overdraw rejection is a network property; tests pin both boundaries explicitly rather than faking either.

## Build

Run in each package directory:

```sh
sui move build
sui move test --coverage
sui move coverage source --module <module-name>
```

Licensed under Apache-2.0.
