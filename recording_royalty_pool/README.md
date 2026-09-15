# Recording Royalty Pool

Raw-cap actions for creating and funding the canonical `RoyaltyPool` derived from a musicos `Recording`. `new_pool` returns the pool unshared so a caller can register a fresh stake before calling `royalty_pool::pool::share`.

Production construction guarantees one `RecordingShare` type, `TreasuryCap`, Recording, and matching capability passed as `admin_cap`. Same-typed duplicate fixtures are test-only tools for exercising address checks, not reachable production attacks.

`redeem_all_and_deposit` is the only accumulator redemption path: it takes the framework `AccumulatorRoot`, reads the Recording's settled snapshot on chain, and deposits exactly that value. It is an authorized, idempotent no-op that emits no event when the snapshot is zero or when the pool has no registered stake; with no stakers nothing is redeemed, so the funds stay in the Recording's accumulator until a stake registers instead of being folded into a pool nobody can claim from. Either no-op lets a batched permissionless crank continue past an already-cranked or unstaked Recording.

The suite covers the positive settled-value path through the private helper `redeem_settled_value_and_deposit_for_testing` (exact amounts, events, claims, a second call being a no-op, zero-staker deferral with later redemption, and batches containing no-op items), receive paths, and the zero snapshot through the public entry. A positive `settled_funds_value` reader snapshot and accumulator overdraw rejection still require a network E2E across a real consensus commit.

## Action events

Each successful action emits one rich, phantom typed event after the wrapped
dependency mutation. Dependency events remain in their original order.

| Event | When | Payload |
|---|---|---|
| `RecordingRoyaltyPoolCreatedEvent<RecordingShare, CompositionShare, Currency>` | `new_pool` succeeds | Recording, composition relationship, admin-cap, and pool addresses plus the initial pool balance, staked shares, reward index, carry, and cumulative deposits |
| `RecordingCoinsDepositedEvent<RecordingShare, CompositionShare, Currency>` | `receive_and_deposit` succeeds | Recording, composition relationship, admin-cap, and pool addresses; actual received amount; caller-order receiving coin IDs; and before/after pool snapshots |
| `RecordingFundsDepositedEvent<RecordingShare, CompositionShare, Currency>` | `redeem_all_and_deposit` deposits a positive settled snapshot | Recording, composition relationship, admin-cap, and pool addresses; exact redeemed amount from the recording accumulator; and before/after pool snapshots |

`pool_address` is a pure derivation view and emits no event. Failed dependency
guards and no-op redemptions emit no action event. The recording address is the accumulator source
for funds events; `composition_id` is relationship metadata. Indexers can use
`coin_ids` to identify the objects consumed by a receive action.

```sh
sui move build
sui move test --coverage
```
