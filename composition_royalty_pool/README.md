# Composition Royalty Pool

Raw-cap actions for creating and funding the canonical `RoyaltyPool` derived from a musicos `Composition`. `new_pool` returns the pool unshared so a caller can register a fresh stake before calling `royalty_pool::pool::share`.

Production construction guarantees one `CompositionShare` type, `TreasuryCap`, Composition, and matching capability passed as `admin_cap`. Same-typed duplicate fixtures are test-only tools for exercising address checks, not reachable production attacks.

`redeem_all_and_deposit` is the only accumulator redemption path: it takes the framework `AccumulatorRoot`, reads the Composition's settled snapshot on chain, and deposits exactly that value. It is an authorized no-op that emits no event when the snapshot is zero or when the pool has no registered stake; with no stakers nothing is redeemed, so the funds stay in the Composition's accumulator until a stake registers instead of being folded into a pool nobody can claim from. Either no-op lets a batched permissionless crank continue past a Composition cranked in an earlier consensus commit, or an unstaked one.

The no-op holds only across commits: the snapshot is written solely by consensus settlement and is constant within a commit, so redeeming the same Composition twice in one PTB, or from two crankers in the same commit, withdraws the snapshot twice and the network fails that whole transaction with `InsufficientFundsForWithdraw` (not a Move abort). A crank must include each Composition at most once per PTB and retry that status next commit.

The suite covers the positive settled-value path through the private helper `redeem_settled_value_and_deposit_for_testing` (exact amounts, events, claims, the unit VM's zero snapshot after a funded call, same-transaction duplicate withdrawals, the `u64::MAX` cap, zero-staker deferral with later redemption, and batches containing no-op items), receive paths, and the zero snapshot through the public entry. A positive `settled_funds_value` reader snapshot and accumulator overdraw rejection still require a network E2E across a real consensus commit.

## Action events

Each successful action emits one rich, phantom typed event after the wrapped
dependency mutation. Dependency events remain in their original order.

| Event | When | Payload |
|---|---|---|
| `CompositionRoyaltyPoolCreatedEvent<CompositionShare, Currency>` | `new_pool` succeeds | Composition, admin-cap, and pool addresses plus the initial pool balance, staked shares, reward index, carry, and cumulative deposits |
| `CompositionCoinsDepositedEvent<CompositionShare, Currency>` | `receive_and_deposit` succeeds | Composition, admin-cap, and pool addresses; actual received amount; caller-order receiving coin IDs; and before/after pool snapshots |
| `CompositionFundsDepositedEvent<CompositionShare, Currency>` | `redeem_all_and_deposit` deposits a positive settled snapshot | Composition, admin-cap, and pool addresses; exact redeemed amount from the accumulator; and before/after pool snapshots |

`pool_address` is a pure derivation view and emits no event. Failed dependency
guards and no-op redemptions emit no action event. Indexers can use `coin_ids` to identify the
objects consumed by a receive action; the funds event identifies the
accumulator source by the composition address.

```sh
sui move build
sui move test --coverage
```
