# Release Revenue Distributor

Raw-cap actions accept the Release capability as `admin_cap`, receive or redeem Release-held revenue, and route it to the Recording addresses fixed by the immutable tracklist. A successful receive emits one `ReleaseCoinsReceivedEvent` with the Release and admin-cap addresses, receiving coin IDs in caller order, and the combined amount. A successful accumulator redemption emits one `ReleaseFundsRedeemedEvent` with the same authorization identities and redeemed amount.

Each distribution then emits one `ReleaseTrackRevenueDistributedEvent` per track, in tracklist order, including the Release address, track index, composition and recording addresses, split basis points, total input, and rounded amount. It emits one `ReleaseRevenueDistributedEvent` summary with track count, total input, total distributed, and remainder. All event IDs are primitive addresses. Flooring remainder returns to the Release.

`redeem_and_distribute` preserves composable amount selection for authorized raw-cap callers. `redeem_all_and_distribute` is the fixed permissionless-crank primitive for custody adapters: it reads the canonical `AccumulatorRoot` snapshot and redeems the full settled value (up to the framework's `u64::MAX` bound), so an arbitrary caller cannot fragment revenue into dust-sized distributions. An empty snapshot is an idempotent no-op. Newly sent funds and flooring remainder become eligible after a later consensus settlement.

The balance-splitting primitive is intentionally private: the package exposes no public donation path unrelated to Release custody. Receiving a real zero-valued coin still consumes that coin and emits the source, zero-valued per-track, and summary events. An empty settled accumulator snapshot is an authorized no-op and emits no event family, while explicit zero redemption and empty receive retain their Hikida aborts. The Move VM honestly covers the zero snapshot and direct positive amount redemption, including later redemption of requeued remainder. A positive `settled_funds_value -> redeem_all_and_distribute` snapshot requires a network E2E across a real consensus commit.

```sh
sui move build
sui move test --coverage
```
