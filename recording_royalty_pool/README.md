# Recording Royalty Pool

Raw-cap actions for creating and funding the canonical `RoyaltyPool` derived from a musicos `Recording`. `new_pool` returns the pool unshared so a caller can register a fresh stake before calling `royalty_pool::pool::share`.

Production construction guarantees one `RecordingShare` type, `TreasuryCap`, Recording, and matching capability passed as `admin_cap`. Same-typed duplicate fixtures are test-only tools for exercising address checks, not reachable production attacks.

The suite covers positive direct redemption after `send_funds` and a transaction boundary, receive paths, and zero/overdraw behavior. A positive `settled_funds_value` reader snapshot still requires a network E2E across a real consensus commit.

```sh
sui move build
sui move test --coverage
```
