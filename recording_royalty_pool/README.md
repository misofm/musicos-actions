# Recording Royalty Pool

Raw-cap actions for creating and funding the canonical `RoyaltyPool` derived from a musicos `Recording`. `new_pool` returns the pool unshared so a caller can register a fresh stake before calling `royalty_pool::pool::share`.

Production construction guarantees one `RecordingShare` type, `TreasuryCap`, Recording, and matching capability passed as `admin_cap`. Same-typed duplicate fixtures are test-only tools for exercising address checks, not reachable production attacks.

The suite covers positive direct redemption after `send_funds` and a transaction boundary, receive paths, and zero/overdraw behavior. A positive `settled_funds_value` reader snapshot still requires a network E2E across a real consensus commit.

## Action events

Each successful action emits one rich, phantom typed event after the wrapped
dependency mutation. Dependency events remain in their original order.

| Event | When | Payload |
|---|---|---|
| `RecordingRoyaltyPoolCreatedEvent<RecordingShare, CompositionShare, Currency>` | `new_pool` succeeds | Recording, composition relationship, admin-cap, and pool addresses plus the initial pool balance, staked shares, reward index, carry, and cumulative deposits |
| `RecordingCoinsDepositedEvent<RecordingShare, CompositionShare, Currency>` | `receive_and_deposit` succeeds | Recording, composition relationship, admin-cap, and pool addresses; actual received amount; caller-order receiving coin IDs; and before/after pool snapshots |
| `RecordingFundsDepositedEvent<RecordingShare, CompositionShare, Currency>` | `redeem_and_deposit` succeeds | Recording, composition relationship, admin-cap, and pool addresses; exact redeemed amount from the recording accumulator; and before/after pool snapshots |

`pool_address` is a pure derivation view and emits no event. Failed dependency
guards emit no action event. The recording address is the accumulator source
for funds events; `composition_id` is relationship metadata. Indexers can use
`coin_ids` to identify the objects consumed by a receive action.

```sh
sui move build
sui move test --coverage
```
