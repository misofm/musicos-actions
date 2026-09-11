# Composition Royalty Pool

Raw-cap actions for creating and funding the canonical `RoyaltyPool` derived from a musicos `Composition`. `new_pool` returns the pool unshared so a caller can register a fresh stake before calling `royalty_pool::pool::share`.

Production construction guarantees one `CompositionShare` type, `TreasuryCap`, Composition, and matching capability passed as `admin_cap`. Same-typed duplicate fixtures are test-only tools for exercising address checks, not reachable production attacks.

The suite covers positive direct redemption after `send_funds` and a transaction boundary, receive paths, and zero/overdraw behavior. A positive `settled_funds_value` reader snapshot still requires a network E2E across a real consensus commit.

## Action events

Each successful action emits one rich, phantom typed event after the wrapped
dependency mutation. Dependency events remain in their original order.

| Event | When | Payload |
|---|---|---|
| `CompositionRoyaltyPoolCreatedEvent<CompositionShare, Currency>` | `new_pool` succeeds | Composition, admin-cap, and pool addresses plus the initial pool balance, staked shares, reward index, carry, and cumulative deposits |
| `CompositionCoinsDepositedEvent<CompositionShare, Currency>` | `receive_and_deposit` succeeds | Composition, admin-cap, and pool addresses; actual received amount; caller-order receiving coin IDs; and before/after pool snapshots |
| `CompositionFundsDepositedEvent<CompositionShare, Currency>` | `redeem_and_deposit` succeeds | Composition, admin-cap, and pool addresses; exact redeemed amount from the accumulator; and before/after pool snapshots |

`pool_address` is a pure derivation view and emits no event. Failed dependency
guards emit no action event. Indexers can use `coin_ids` to identify the
objects consumed by a receive action; the funds event identifies the
accumulator source by the composition address.

```sh
sui move build
sui move test --coverage
```
