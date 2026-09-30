# Protocol Actions

Composable, custody-agnostic actions for the Miso protocol. Each top-level directory is an independently publishable Sui Move 2024 package:

- `release_revenue_distributor` splits Release revenue across its immutable tracklist and sends each track's share to its Recording's license pool address.

Composition and Recording pools, and the Composition's stake in each Recording, now come from [`recording_license`](https://github.com/misofm/musicos-extensions/tree/main/recording_license), which replaced the former `composition_royalty_pool`, `recording_royalty_pool`, and `composition_routed_stake` actions.

Production APIs accept the protocol's raw admin capabilities. They contain no Vault dependency, installation state, package witness, plugin endpoint, or `entry` function.

## Accumulator redemption

The accumulator redemption is a fixed "redeem all" crank: `redeem_all_and_distribute` takes the framework `AccumulatorRoot`, reads `balance::settled_funds_value` on chain, and redeems exactly that snapshot. No action accepts a caller-chosen amount. A zero snapshot is an authorized no-op that emits no event, so a Release cranked in an earlier consensus commit passes through a batched permissionless crank untouched.

The no-op holds only **across** consensus commits. `settled_funds_value` is written solely by the settlement system transaction, so it is constant for every transaction in a commit; redeeming the same object twice in one PTB, or from two crankers in the same commit, withdraws the snapshot twice and the network fails that whole transaction with `InsufficientFundsForWithdraw` (a transaction-level failure with no Move abort code). Operational requirements for any crank: include each object at most once per PTB, and treat `InsufficientFundsForWithdraw` as "retry next commit", not as a poisoned item.

## Accumulator testing

The Move VM covers the settled-value redemption path with a positive value through the private helper `redeem_settled_value_and_distribute_for_testing`, including exact amounts, events, batches with no-op items, and later redemption of requeued remainder. It cannot expose a positive `settled_funds_value` consensus snapshot: `test_scenario` discards accumulator events at the end of every transaction and the framework offers no test-only settlement into `AccumulatorRoot`, so the public `redeem_all_and_distribute` entry is exercised only against a zero snapshot locally and its funded path is a Sui network E2E. The VM also does not check accumulator withdrawals against a balance, so overdraw rejection is a network property; tests pin both boundaries explicitly rather than faking either.

## Build

Run in each package directory:

```sh
sui move build
sui move test --coverage
sui move coverage source --module <module-name>
```

Licensed under Apache-2.0.

Coin-receipt events retain the consumed coin count, amounts and business identities.
They do not duplicate a variable-length list of input coin IDs; transaction inputs/effects provide that provenance when needed.
